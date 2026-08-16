import AudioToolbox
import Accelerate
import Foundation

/// 生成・使用は測定専用の直列キュー上でのみ行うこと (この型自身はそれを強制しない)。
final class EQResponseProbe: @unchecked Sendable {
    private let fftSize: Int
    private let rampSettleSeconds: Double
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length

    private var chain: EQUnit?
    private var chainSampleRate: Double?
    private let impulseSource = ImpulseSource()

    /// どちらも統合テストが通る値として実測で決めた。目分量で縮めない。
    init(fftSize: Int = 65536, rampSettleSeconds: Double = 0.04) {
        self.fftSize = fftSize
        self.rampSettleSeconds = rampSettleSeconds
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        chain?.dispose()
    }

    /// チェーン構築・render のいずれかが失敗すれば nil。
    func measure(curve: [Double], sampleRate: Double) -> EQMagnitudeResponse? {
        guard let chain = ensureChain(sampleRate: sampleRate) else { return nil }

        // 前回応答の尾を落とす (チェーンを使い回すため必須)。
        chain.reset()
        chain.setAllGains(curve)

        let rampFrames = Int((rampSettleSeconds * sampleRate).rounded(.up))
        impulseSource.reset(impulseAt: rampFrames)

        guard let captured = render(chain: chain, totalFrames: rampFrames + fftSize, warmupFrames: rampFrames),
              captured.count == fftSize,
              // 無音はフラットと同じ 0dB になってしまうため、応答として採らない。
              captured.contains(where: { $0 != 0 })
        else { return nil }

        return AutoPreampSpec.response(powerSpectrum: powerSpectrum(captured), sampleRate: sampleRate)
    }

    private func ensureChain(sampleRate: Double) -> EQUnit? {
        if let chain, chainSampleRate == sampleRate { return chain }
        chain?.dispose()
        chain = nil
        chainSampleRate = nil

        guard let newChain = EQUnit() else { return nil }
        let format = EQStreamFormat(channels: 1, sampleRate: sampleRate)
        guard newChain.setup(
            format: format, maxFrames: UInt32(AudioConfig.maxRenderFrames),
            renderCallback: EQResponseProbe.renderCallback,
            refCon: Unmanaged.passUnretained(impulseSource).toOpaque()
        ) else {
            newChain.dispose()
            return nil
        }
        chain = newChain
        chainSampleRate = sampleRate
        return newChain
    }

    /// AudioUnitRender は MaximumFramesPerSlice を超える要求を弾く。
    private func render(chain: EQUnit, totalFrames: Int, warmupFrames: Int) -> [Float]? {
        let maxFrames = AudioConfig.maxRenderFrames
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)

        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { ablRaw.deallocate() }
        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = 1
        let list = UnsafeMutableAudioBufferListPointer(abl)

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        defer { buffer.deallocate() }
        list[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(maxFrames) * bytesPerSample,
            mData: UnsafeMutableRawPointer(buffer)
        )

        var out = [Float]()
        out.reserveCapacity(fftSize)
        var produced = 0
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        timestamp.mSampleTime = 0

        while produced < totalFrames {
            let n = min(maxFrames, totalFrames - produced)
            list[0].mDataByteSize = UInt32(n) * bytesPerSample
            var flags = AudioUnitRenderActionFlags()
            guard chain.render(flags: &flags, timestamp: &timestamp, frames: UInt32(n), ioData: abl) == noErr else {
                return nil
            }
            if produced + n > warmupFrames {
                let start = max(0, warmupFrames - produced)
                for f in start..<n where out.count < fftSize { out.append(buffer[f]) }
            }
            produced += n
            timestamp.mSampleTime += Double(n)
        }
        return out
    }

    private func powerSpectrum(_ samples: [Float]) -> [Float] {
        let half = fftSize / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // zrip は振幅が 2 倍でスケールされるため、パワーは 1/4 で戻す。
        return mags.map { $0 * 0.25 }
    }

    /// 絶対サンプル位置でインパルス位置を判定する (render の分割境界に依存しない)。
    private final class ImpulseSource {
        var position = 0
        var impulseAt = 0

        func reset(impulseAt: Int) {
            position = 0
            self.impulseAt = impulseAt
        }
    }

    private static let renderCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
        let source = Unmanaged<ImpulseSource>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        for b in 0..<abl.count {
            guard let p = abl[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
            p.update(repeating: 0, count: n)
        }
        let offset = source.impulseAt - source.position
        if offset >= 0 && offset < n {
            for b in 0..<abl.count {
                if let p = abl[b].mData?.assumingMemoryBound(to: Float.self) { p[offset] = 1 }
            }
        }
        source.position += n
        return noErr
    }
}
