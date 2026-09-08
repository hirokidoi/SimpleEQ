import AudioToolbox
import XCTest
@testable import SimpleEQ

/// AU 段の実機統合テスト。実 AUMatrixReverb を組む (出力デバイスは不要 — オフラインのチェーンのみ)。
///
/// AU 段が組めなければその機能は無言で効かなくなる。画面に状態を出さずに済むのは、
/// 音声経路のチャンネル数が固定で、その構成では申告しうるどのレートでも組めるという前提による。
/// 落ちたらその前提が崩れたということなので、画面表示の要否から考え直すこと。
final class SoundLabAUStageTests: XCTestCase {
    private final class SilentSource {}

    private static let renderCallback: AURenderCallback = { _, _, _, _, frames, ioData in
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for b in 0..<abl.count {
            abl[b].mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
        }
        return noErr
    }

    private func makeChain(channels: UInt32, sampleRate: Double, source: SilentSource) -> EQUnit? {
        guard let chain = EQUnit() else { return nil }
        guard chain.setup(
            format: EQStreamFormat(channels: channels, sampleRate: sampleRate),
            maxFrames: UInt32(AudioConfig.maxRenderFrames),
            renderCallback: Self.renderCallback,
            refCon: Unmanaged.passUnretained(source).toOpaque()
        ) else {
            chain.dispose()
            return nil
        }
        return chain
    }

    func testStageIsBuiltAtEveryDeclaredSampleRate() {
        let source = SilentSource()
        for rate in TestSampleRates.all {
            guard let chain = makeChain(channels: AudioConfig.channels, sampleRate: rate, source: source) else {
                XCTFail("チェーンを組めない fs=\(rate)")
                continue
            }
            defer { chain.dispose() }
            XCTAssertTrue(chain.hasSoundLabStage, "AU 段が組めない fs=\(rate)")
        }
    }

    /// AUMatrixReverb はモノラル出力を受け付けない (kAudioUnitErr_FormatNotSupported)。
    /// 拒否の条件はレートではなくチャンネル数であり、測定のチェーンが AU 段を付けない理由でもある。
    func testMonoIsRefusedWhileStereoIsAccepted() {
        for (channels, accepted) in [(UInt32(1), false), (AudioConfig.channels, true)] {
            guard let unit = Self.makeReverbUnit() else {
                XCTFail("AUMatrixReverb を生成できない")
                return
            }
            defer { AudioComponentInstanceDispose(unit) }
            var asbd = AudioConfig.makePlanarASBD(channels: channels, sampleRate: TestSampleRates.all[0])
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let stIn = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size)
            let stOut = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, size)
            XCTAssertEqual(stIn == noErr && stOut == noErr, accepted, "\(channels)ch")
        }
    }

    // MARK: - 操作値が音へ届くか

    /// 響きは操作値が届かなければ無言で消える。段が組めることだけでは、そこまで見ていない。
    /// 応答が出るまで整定が要るため、インパルスはウォームアップの後ろへ置く (実測で選定)。
    private static let warmupBlocks = 16
    private static let block = 1024

    private final class ImpulseSource {
        var position = 0
        var impulseAt = 0
    }

    private static let impulseCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
        let source = Unmanaged<ImpulseSource>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        for b in 0..<abl.count {
            guard let p = abl[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
            p.update(repeating: 0, count: n)
            let offset = source.impulseAt - source.position
            if offset >= 0 && offset < n { p[offset] = 1 }
        }
        source.position += n
        return noErr
    }

    /// インパルスを通し、ブロックごとのピークを並べて返す (ウォームアップぶんは落とす)。
    private func impulseResponse(
        _ settings: LiveSimulationSettings, seconds: Double,
        reapplyingEachBlock: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [Double] {
        let rate = TestSampleRates.all[0]
        let source = ImpulseSource()
        guard let chain = EQUnit(), chain.setup(
            format: EQStreamFormat(channels: AudioConfig.channels, sampleRate: rate),
            maxFrames: UInt32(AudioConfig.maxRenderFrames),
            renderCallback: Self.impulseCallback,
            refCon: Unmanaged.passUnretained(source).toOpaque()
        ) else {
            XCTFail("チェーンを組めない", file: file, line: line)
            return []
        }
        defer { chain.dispose() }
        chain.setAllGains(Array(repeating: 0, count: EQSpec.bandCount))
        chain.reset()
        chain.applyLiveSimulation(settings)
        source.position = 0
        source.impulseAt = Self.warmupBlocks * Self.block

        let channels = Int(AudioConfig.channels)
        let ablSize = MemoryLayout<AudioBufferList>.size + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(channels)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        let bufs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Self.block) }
        defer { bufs.forEach { $0.deallocate() } }

        var peaks: [Double] = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        let total = Self.warmupBlocks + Int(rate * seconds) / Self.block
        for index in 0..<total {
            if reapplyingEachBlock { chain.applyLiveSimulation(settings) }
            for c in 0..<channels {
                list[c] = AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(Self.block) * 4,
                    mData: UnsafeMutableRawPointer(bufs[c])
                )
            }
            var flags = AudioUnitRenderActionFlags()
            guard chain.render(flags: &flags, timestamp: &timestamp, frames: UInt32(Self.block), ioData: abl) == noErr else {
                XCTFail("render に失敗", file: file, line: line)
                return []
            }
            timestamp.mSampleTime += Double(Self.block)
            guard index >= Self.warmupBlocks else { continue }
            var peak = 0.0
            for c in 0..<channels {
                for f in 0..<Self.block { peak = max(peak, abs(Double(bufs[c][f]))) }
            }
            peaks.append(peak)
        }
        return peaks
    }

    /// 頭から規定量まで落ちきる時刻。
    private func decaySeconds(_ peaks: [Double], fallingBy db: Double) -> Double {
        guard let top = peaks.max(), top > 0 else { return 0 }
        let threshold = top * pow(10, -db / 20)
        for i in stride(from: peaks.count - 1, through: 0, by: -1) where peaks[i] > threshold {
            return Double((i + 1) * Self.block) / TestSampleRates.all[0]
        }
        return 0
    }

    func testEnablingTheLiveSimulationAddsATail() {
        var off = LiveSimulationSettings()
        off.enabled = false
        var on = LiveSimulationSettings()
        on.enabled = true

        let silent = decaySeconds(impulseResponse(off, seconds: 1), fallingBy: 40)
        let ringing = decaySeconds(impulseResponse(on, seconds: 1), fallingBy: 40)
        XCTAssertLessThanOrEqual(silent, Double(Self.block) / TestSampleRates.all[0], "切れば尾は残らない")
        XCTAssertGreaterThan(ringing, silent, "入れれば尾が付く")
    }

    /// 空間の選択が音へ届かなければ、4 つは同じ鳴り方になる。
    func testTheRoomsDecayInOrderOfTheirSize() {
        let decays = LiveSimulationRoom.allCases.map { room -> Double in
            var settings = LiveSimulationSettings()
            settings.enabled = true
            settings.room = room
            // 原音が混ざるとピークがそちらに支配され、空間ごとの差が潰れる。
            settings.mix = LiveSimulationSettings.mixRange.bounds.upperBound
            return decaySeconds(impulseResponse(settings, seconds: 2.5), fallingBy: 40)
        }
        for (index, room) in LiveSimulationRoom.allCases.enumerated() where index > 0 {
            XCTAssertGreaterThan(
                decays[index], decays[index - 1],
                "\(room.title) は \(LiveSimulationRoom.allCases[index - 1].title) より長く残る"
            )
        }
    }

    /// 混ぜる量が届かなければ、下限でも上限でも同じ出力になる。
    func testTheMixMovesTheBalanceBetweenDryAndWet() {
        var dry = LiveSimulationSettings()
        dry.enabled = true
        dry.mix = LiveSimulationSettings.mixRange.bounds.lowerBound
        var wet = LiveSimulationSettings()
        wet.enabled = true
        wet.mix = LiveSimulationSettings.mixRange.bounds.upperBound

        let dryPeaks = impulseResponse(dry, seconds: 0.5)
        let wetPeaks = impulseResponse(wet, seconds: 0.5)
        let dryHead = dryPeaks.first ?? 0
        XCTAssertGreaterThan(dryHead, 0.5, "下限では原音がそのまま出る")
        XCTAssertEqual(dryPeaks.dropFirst().max() ?? 1, 0, accuracy: 1e-6, "下限では響きが乗らない")
        // 初期反射はインパルスと同じブロックに乗るため、原音の有無は大きさの比で見る。
        XCTAssertLessThan(wetPeaks.first ?? 1, dryHead / 2, "上限では原音が消える")
        XCTAssertGreaterThan(wetPeaks.dropFirst().max() ?? 0, 0, "上限でも響きは出る")
    }

    /// 音量が動くたびに配り先の入口を通るため、同じ操作値が繰り返し届く。
    /// 書けばユニットの構成に触れて響きが断たれるので、同じ値なら何も書かない。
    func testReapplyingTheSameSettingsLeavesTheTailAlone() {
        var settings = LiveSimulationSettings()
        settings.enabled = true
        settings.room = .dome
        settings.mix = LiveSimulationSettings.mixRange.bounds.upperBound

        let undisturbed = impulseResponse(settings, seconds: 2.5)
        let reapplied = impulseResponse(settings, seconds: 2.5, reapplyingEachBlock: true)
        XCTAssertEqual(undisturbed, reapplied, "配り直しても響きが変わらない")
    }

    private static func makeReverbUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_MatrixReverb,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(comp, &created) == noErr else { return nil }
        return created
    }
}
