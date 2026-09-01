import Accelerate
import Darwin

final class LevelMeter {
    private let bandFrequencies: [Double]

    private(set) var appliedSampleRate: Double
    private var fftSize: Int
    private var log2n: vDSP_Length
    private var fftSetup: FFTSetup
    private var hopSize: Int
    /// 1 hop ぶんの実時間 (秒)。
    private var hopDt: Double
    private var bandBinRanges: [(low: Int, high: Int)]
    // 0dBFS 相当とみなす基準パワー (設計値)。
    private var referencePower: Float

    private var captureRing: RingBuffer
    private let downmixScratch: UnsafeMutablePointer<Float>

    // L/R マスターレベル用の第二のリングバッファ (SPSC)。capture() のダウンミックスループに
    // 便乗して 1 コールバックぶんの (L, R) ピーク絶対振幅だけを運ぶ。stereoCaptureEnabled が
    // false の間は producer 側で集計を止める。
    private let stereoPeakRing: RingBuffer
    /// 作業バッファ (サイズ = 出力チャンネル数)。
    private let stereoPeakWriteScratch: UnsafeMutablePointer<Float>
    /// 作業バッファ (サイズ = 容量 × 出力チャンネル数、1 回の読み取りで全量を読み切る)。
    private let stereoPeakReadScratch: UnsafeMutablePointer<Float>

    private var levelsLock = os_unfair_lock_s()
    private var bandLevelsDb: [Double]
    private var peakLevelsDb: [Double]
    private var peakHoldRemaining: [Double]
    private var leftDb: Double
    private var rightDb: Double
    private var leftPeakDb: Double
    private var rightPeakDb: Double
    private var leftPeakHoldRemaining: Double = 0
    private var rightPeakHoldRemaining: Double = 0
    private(set) var peakHoldEnabled = EQLayout.Tuning.peakHoldEnabledDefault
    var peakHoldSeconds = EQLayout.Tuning.peakHoldSecondsDefault
    var peakDecayDbPerSec = EQLayout.Tuning.peakDecayDbPerSecDefault

    private var rawBuf: UnsafeMutablePointer<Float>
    private var windowBuf: UnsafeMutablePointer<Float>
    private var windowedBuf: UnsafeMutablePointer<Float>
    private var realp: UnsafeMutablePointer<Float>
    private var imagp: UnsafeMutablePointer<Float>
    private var magnitudes: UnsafeMutablePointer<Float>

    private var rebuildLock = os_unfair_lock_s()

    var captureEnabled = true

    private let stereoPeakRingCapacityFrames = 64
    /// レベル平滑化の追従係数 (0..1)。
    var attackCoef = EQLayout.Tuning.attack.value(at: EQLayout.Tuning.attack.defaultLevel)
    var releaseCoef = EQLayout.Tuning.release.value(at: EQLayout.Tuning.release.defaultLevel)
    /// 瞬間的な読み取りずれは許容する。
    var stereoCaptureEnabled = true
    /// 数値の健全性のためだけの下限 (表示レンジとは独立)。無音時に報告される値でもあるため、
    /// 「まだ観測が届いていない」状態の初期値としても使う。
    static let silentLevelDb = -140.0
    private let internalFloorDb = LevelMeter.silentLevelDb

    private static let baseSampleRate: Double = AudioConfig.baseSampleRate
    private static let baseFFTSize: Int = 4096

    /// 基準点からのビン幅保存で導出し、radix-2 の制約を満たすよう最も近い 2 のべきへ丸める。
    static func deriveFFTSize(sampleRate: Double) -> Int {
        let idealSize = Double(baseFFTSize) * (sampleRate / baseSampleRate)
        let power = log2(idealSize).rounded()
        return Int(exp2(power))
    }

    /// 解析窓を毎回ずらす量 (サンプル)。
    static func deriveHopSize(fftSize: Int) -> Int { fftSize / 4 }

    init(bandFrequencies: [Double], appliedSampleRate: Double) {
        self.bandFrequencies = bandFrequencies
        self.appliedSampleRate = appliedSampleRate

        let state = LevelMeter.makeSampleRateDependentState(bandFrequencies: bandFrequencies, appliedSampleRate: appliedSampleRate)
        fftSize = state.fftSize
        hopSize = state.hopSize
        hopDt = state.hopDt
        log2n = state.log2n
        fftSetup = state.fftSetup
        captureRing = state.captureRing
        rawBuf = state.rawBuf
        windowBuf = state.windowBuf
        windowedBuf = state.windowedBuf
        realp = state.realp
        imagp = state.imagp
        magnitudes = state.magnitudes
        bandBinRanges = state.bandBinRanges
        referencePower = state.referencePower

        downmixScratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioConfig.maxRenderFrames)
        downmixScratch.initialize(repeating: 0, count: AudioConfig.maxRenderFrames)

        let stereoChannels = Int(AudioConfig.channels)
        stereoPeakRing = RingBuffer(capacityFrames: stereoPeakRingCapacityFrames, channels: stereoChannels)
        stereoPeakWriteScratch = UnsafeMutablePointer<Float>.allocate(capacity: stereoChannels)
        stereoPeakWriteScratch.initialize(repeating: 0, count: stereoChannels)
        // リング全容量ぶん確保する (縮めると分割読み出しが要る)。
        let stereoPeakReadScratchCapacity = stereoPeakRingCapacityFrames * stereoChannels
        stereoPeakReadScratch = UnsafeMutablePointer<Float>.allocate(capacity: stereoPeakReadScratchCapacity)
        stereoPeakReadScratch.initialize(repeating: 0, count: stereoPeakReadScratchCapacity)

        bandLevelsDb = Array(repeating: internalFloorDb, count: bandFrequencies.count)
        peakLevelsDb = Array(repeating: internalFloorDb, count: bandFrequencies.count)
        peakHoldRemaining = Array(repeating: 0, count: bandFrequencies.count)
        leftDb = internalFloorDb
        rightDb = internalFloorDb
        leftPeakDb = internalFloorDb
        rightPeakDb = internalFloorDb
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        downmixScratch.deallocate()
        stereoPeakWriteScratch.deallocate()
        stereoPeakReadScratch.deallocate()
        rawBuf.deallocate()
        windowBuf.deallocate()
        windowedBuf.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
    }

    /// realtime 出力コールバックから呼ぶ。print/alloc/lock を行わず、事前確保済みバッファへの
    /// 書き込みのみを行う。
    func capture(_ interleaved: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        guard captureEnabled else { return }
        let n = min(frameCount, AudioConfig.maxRenderFrames)
        let capturesStereo = channels == Int(AudioConfig.channels) && stereoCaptureEnabled
        var peakL: Float = 0
        var peakR: Float = 0
        let invChannels = 1.0 / Float(channels)
        for f in 0..<n {
            var sum: Float = 0
            let base = f * channels
            for c in 0..<channels { sum += interleaved[base + c] }
            downmixScratch[f] = sum * invChannels
            if capturesStereo {
                peakL = max(peakL, abs(interleaved[base]))
                peakR = max(peakR, abs(interleaved[base + 1]))
            }
        }
        captureRing.write(downmixScratch, frames: n)
        if capturesStereo {
            stereoPeakWriteScratch[0] = peakL
            stereoPeakWriteScratch[1] = peakR
            stereoPeakRing.write(stereoPeakWriteScratch, frames: 1)
        }
    }

    /// UI から読む per-band dBFS スナップショット (internalFloorDb...0 の範囲)。
    struct Snapshot: Equatable {
        /// 平滑化後の再生レベル。
        let levels: [Double]
        /// ピークホールド値。levels 以上の値を保つ。
        let peaks: [Double]
        /// L/R マスターレベル (dBFS)。
        let stereo: Stereo

        struct Stereo: Equatable {
            let leftDb: Double
            let rightDb: Double
            let leftPeakDb: Double
            let rightPeakDb: Double
        }

        /// 観測が届いていない状態を表す値。
        static func silent(bandCount: Int) -> Snapshot {
            Snapshot(
                levels: Array(repeating: LevelMeter.silentLevelDb, count: bandCount),
                peaks: Array(repeating: LevelMeter.silentLevelDb, count: bandCount),
                stereo: Stereo(
                    leftDb: LevelMeter.silentLevelDb, rightDb: LevelMeter.silentLevelDb,
                    leftPeakDb: LevelMeter.silentLevelDb, rightPeakDb: LevelMeter.silentLevelDb
                )
            )
        }
    }

    struct ClipObservation: Equatable {
        let left: Bool
        let right: Bool
        static let none = ClipObservation(left: false, right: false)
    }

    func setSnapshotForTesting(_ snapshot: Snapshot) {
        os_unfair_lock_lock(&levelsLock)
        bandLevelsDb = snapshot.levels
        peakLevelsDb = snapshot.peaks
        leftDb = snapshot.stereo.leftDb
        rightDb = snapshot.stereo.rightDb
        leftPeakDb = snapshot.stereo.leftPeakDb
        rightPeakDb = snapshot.stereo.rightPeakDb
        os_unfair_lock_unlock(&levelsLock)
    }

    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&levelsLock)
        let snap = Snapshot(
            levels: bandLevelsDb, peaks: peakLevelsDb,
            stereo: Snapshot.Stereo(leftDb: leftDb, rightDb: rightDb, leftPeakDb: leftPeakDb, rightPeakDb: rightPeakDb)
        )
        os_unfair_lock_unlock(&levelsLock)
        return snap
    }

    /// ロック取得済みの状態で呼ぶ内部実装。
    private func resetPeaksToCurrentLevelLocked() {
        for i in 0..<peakLevelsDb.count {
            peakLevelsDb[i] = bandLevelsDb[i]
            peakHoldRemaining[i] = 0
        }
        leftPeakDb = leftDb
        leftPeakHoldRemaining = 0
        rightPeakDb = rightDb
        rightPeakHoldRemaining = 0
    }

    /// 無効化前の古いピークが再有効化直後に一瞬表示されるのを防ぐ。
    func resetPeaksToCurrentLevel() {
        os_unfair_lock_lock(&levelsLock)
        resetPeaksToCurrentLevelLocked()
        os_unfair_lock_unlock(&levelsLock)
    }

    /// フラグの書き込みと (無効→有効時の) リセットを同一ロック内で行い、中途半端な状態で
    /// advancePeak が走らないようにする。
    func setPeakHoldEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&levelsLock)
        if enabled && !peakHoldEnabled {
            resetPeaksToCurrentLevelLocked()
        }
        peakHoldEnabled = enabled
        os_unfair_lock_unlock(&levelsLock)
    }

    func resetForRestart() {
        os_unfair_lock_lock(&rebuildLock)
        defer { os_unfair_lock_unlock(&rebuildLock) }

        // rawBuf の容量は fftSize までのため、1 回の読み取りを fftSize 以内にクランプして繰り返す。
        while captureRing.availableRead > 0 {
            _ = captureRing.read(into: rawBuf, frames: min(captureRing.availableRead, fftSize))
        }
        rawBuf.update(repeating: 0, count: fftSize)

        while stereoPeakRing.availableRead > 0 {
            _ = stereoPeakRing.read(into: stereoPeakReadScratch, frames: stereoPeakRing.availableRead)
        }

        os_unfair_lock_lock(&levelsLock)
        for i in 0..<bandLevelsDb.count {
            bandLevelsDb[i] = internalFloorDb
            peakLevelsDb[i] = internalFloorDb
            peakHoldRemaining[i] = 0
        }
        leftDb = internalFloorDb
        rightDb = internalFloorDb
        leftPeakDb = internalFloorDb
        rightPeakDb = internalFloorDb
        leftPeakHoldRemaining = 0
        rightPeakHoldRemaining = 0
        os_unfair_lock_unlock(&levelsLock)
    }

    private(set) var hopsAnalyzedForTesting = 0

    @discardableResult
    func analyzeAvailableHops() -> ClipObservation {
        os_unfair_lock_lock(&rebuildLock)
        defer { os_unfair_lock_unlock(&rebuildLock) }

        guard captureRing.availableRead >= hopSize else { return .none }

        var newLeftDb = internalFloorDb
        var newRightDb = internalFloorDb
        var frameLeftRoundPeak: Float = 0
        var frameRightRoundPeak: Float = 0
        let stereoAvailable = stereoPeakRing.availableRead
        let stereoObserved = stereoAvailable > 0
        if stereoObserved {
            let got = stereoPeakRing.read(into: stereoPeakReadScratch, frames: stereoAvailable)
            let stride = Int(AudioConfig.channels)
            var peakL: Float = 0
            var peakR: Float = 0
            for f in 0..<got {
                peakL = max(peakL, stereoPeakReadScratch[f * stride])
                peakR = max(peakR, stereoPeakReadScratch[f * stride + 1])
            }
            // L/R マスターは時間領域の振幅ピーク基準で dBFS 化する
            // (per-band のパワー基準とは参照する量が異なる)。
            newLeftDb = min(0, max(internalFloorDb, Double(20 * log10(max(peakL, .leastNormalMagnitude)))))
            newRightDb = min(0, max(internalFloorDb, Double(20 * log10(max(peakR, .leastNormalMagnitude)))))
            frameLeftRoundPeak = peakL
            frameRightRoundPeak = peakR
        }

        os_unfair_lock_lock(&levelsLock)
        while captureRing.availableRead >= hopSize {
            memmove(rawBuf, rawBuf + hopSize, (fftSize - hopSize) * MemoryLayout<Float>.size)
            _ = captureRing.read(into: rawBuf + (fftSize - hopSize), frames: hopSize)

            vDSP_vmul(rawBuf, 1, windowBuf, 1, windowedBuf, 1, vDSP_Length(fftSize))
            windowedBuf.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                var split = DSPSplitComplex(realp: realp, imagp: imagp)
                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(fftSize / 2))
            }

            for (i, range) in bandBinRanges.enumerated() {
                var peakPower: Float = 0
                for bin in range.low...range.high { peakPower = max(peakPower, magnitudes[bin]) }
                let db = 10 * log10(max(peakPower, .leastNormalMagnitude) / referencePower)
                let target = min(0, max(internalFloorDb, Double(db)))
                bandLevelsDb[i] = LevelMeter.smoothed(prev: bandLevelsDb[i], target: target, attack: attackCoef, release: releaseCoef)
            }
            if stereoObserved {
                leftDb = LevelMeter.smoothed(prev: leftDb, target: newLeftDb, attack: attackCoef, release: releaseCoef)
                rightDb = LevelMeter.smoothed(prev: rightDb, target: newRightDb, attack: attackCoef, release: releaseCoef)
            }
            if peakHoldEnabled {
                for i in 0..<bandLevelsDb.count {
                    peakLevelsDb[i] = LevelMeter.advancePeak(
                        level: bandLevelsDb[i], peak: peakLevelsDb[i], holdRemaining: &peakHoldRemaining[i],
                        dt: hopDt, holdSeconds: peakHoldSeconds, decayDbPerSec: peakDecayDbPerSec
                    )
                }
                if stereoObserved {
                    leftPeakDb = LevelMeter.advancePeak(
                        level: leftDb, peak: leftPeakDb, holdRemaining: &leftPeakHoldRemaining,
                        dt: hopDt, holdSeconds: peakHoldSeconds, decayDbPerSec: peakDecayDbPerSec
                    )
                    rightPeakDb = LevelMeter.advancePeak(
                        level: rightDb, peak: rightPeakDb, holdRemaining: &rightPeakHoldRemaining,
                        dt: hopDt, holdSeconds: peakHoldSeconds, decayDbPerSec: peakDecayDbPerSec
                    )
                }
            }
            hopsAnalyzedForTesting += 1
        }
        os_unfair_lock_unlock(&levelsLock)

        return ClipObservation(
            left: stereoObserved && outputExceedsFullScale(peakAmplitude: frameLeftRoundPeak),
            right: stereoObserved && outputExceedsFullScale(peakAmplitude: frameRightRoundPeak)
        )
    }

    /// ホールド残り時間が尽きたら decayDbPerSec で表示レベルへ向けて下げる。decayDbPerSec=0 は
    /// ホールド終了後に瞬時に表示レベルまで落ちる。
    static func advancePeak(
        level: Double, peak: Double, holdRemaining: inout Double,
        dt: Double, holdSeconds: Double, decayDbPerSec: Double
    ) -> Double {
        if level >= peak {
            holdRemaining = holdSeconds
            return level
        }
        if holdRemaining > 0 {
            holdRemaining -= dt
            return peak
        }
        guard decayDbPerSec > 0 else { return level }
        return max(level, peak - decayDbPerSec * dt)
    }

    /// 目標が現在値より上 (立ち上がり) なら attack、下なら release の係数で寄せる。
    static func smoothed(prev: Double, target: Double, attack: Double, release: Double) -> Double {
        let coef = target > prev ? attack : release
        return prev + (target - prev) * coef
    }

    func rebuild(appliedSampleRate: Double) {
        let state = LevelMeter.makeSampleRateDependentState(bandFrequencies: bandFrequencies, appliedSampleRate: appliedSampleRate)

        os_unfair_lock_lock(&rebuildLock)
        vDSP_destroy_fftsetup(fftSetup)
        rawBuf.deallocate()
        windowBuf.deallocate()
        windowedBuf.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()

        self.appliedSampleRate = appliedSampleRate
        fftSize = state.fftSize
        hopSize = state.hopSize
        hopDt = state.hopDt
        log2n = state.log2n
        fftSetup = state.fftSetup
        captureRing = state.captureRing
        rawBuf = state.rawBuf
        windowBuf = state.windowBuf
        windowedBuf = state.windowedBuf
        realp = state.realp
        imagp = state.imagp
        magnitudes = state.magnitudes
        bandBinRanges = state.bandBinRanges
        referencePower = state.referencePower
        os_unfair_lock_unlock(&rebuildLock)
    }

    private struct SampleRateDependentState {
        let fftSize: Int
        let hopSize: Int
        let hopDt: Double
        let log2n: vDSP_Length
        let fftSetup: FFTSetup
        let captureRing: RingBuffer
        let rawBuf: UnsafeMutablePointer<Float>
        let windowBuf: UnsafeMutablePointer<Float>
        let windowedBuf: UnsafeMutablePointer<Float>
        let realp: UnsafeMutablePointer<Float>
        let imagp: UnsafeMutablePointer<Float>
        let magnitudes: UnsafeMutablePointer<Float>
        let bandBinRanges: [(low: Int, high: Int)]
        let referencePower: Float
    }

    private static func makeSampleRateDependentState(
        bandFrequencies: [Double], appliedSampleRate: Double
    ) -> SampleRateDependentState {
        let fftSize = deriveFFTSize(sampleRate: appliedSampleRate)
        let hopSize = deriveHopSize(fftSize: fftSize)
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }

        let rawBuf = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        rawBuf.initialize(repeating: 0, count: fftSize)
        let windowBuf = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        let windowedBuf = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        windowedBuf.initialize(repeating: 0, count: fftSize)
        let realp = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
        realp.initialize(repeating: 0, count: fftSize / 2)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
        imagp.initialize(repeating: 0, count: fftSize / 2)
        let magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
        magnitudes.initialize(repeating: 0, count: fftSize / 2)
        vDSP_hann_window(windowBuf, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let bandBinRanges = makeBandBinRanges(bandFrequencies: bandFrequencies, sampleRate: appliedSampleRate, fftSize: fftSize)
        let referencePower = Float(fftSize / 2) * Float(fftSize / 2)

        return SampleRateDependentState(
            fftSize: fftSize, hopSize: hopSize, hopDt: Double(hopSize) / appliedSampleRate, log2n: log2n, fftSetup: setup,
            captureRing: RingBuffer(capacityFrames: fftSize * 4, channels: 1),
            rawBuf: rawBuf, windowBuf: windowBuf, windowedBuf: windowedBuf, realp: realp, imagp: imagp, magnitudes: magnitudes,
            bandBinRanges: bandBinRanges, referencePower: referencePower
        )
    }

    // バンド境界 = 隣接バンド中心の幾何平均。最低バンドは 0Hz から、最高バンドは Nyquist まで。
    private static func makeBandBinRanges(
        bandFrequencies: [Double], sampleRate: Double, fftSize: Int
    ) -> [(low: Int, high: Int)] {
        let bins = fftSize / 2
        let binHz = sampleRate / Double(fftSize)
        var edges: [Double] = [0]
        for i in 0..<(bandFrequencies.count - 1) {
            edges.append((bandFrequencies[i] * bandFrequencies[i + 1]).squareRoot())
        }
        edges.append(sampleRate / 2)

        return (0..<bandFrequencies.count).map { i in
            let low = max(0, min(bins - 1, Int((edges[i] / binHz).rounded())))
            let high = max(low, min(bins - 1, Int((edges[i + 1] / binHz).rounded())))
            return (low: low, high: high)
        }
    }
}
