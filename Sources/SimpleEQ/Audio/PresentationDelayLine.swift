import Foundation

/// 診断の入力。
struct PresentationDelayObservation: Equatable {
    let declaredFrames: Int?
    let appliedFrames: Int
}

/// 事前確保の interleaved 遅延線。realtime 経路で割り当て・ロック・ログをしない。
final class PresentationDelayLine {
    /// 申告値が壊れていても確保量を抑えるための上限 (設計値)。
    static let maxPresentationDelaySeconds: TimeInterval = 4
    /// ユーザオフセットの範囲 (ミリ秒、設計値)。
    static let userOffsetMillisecondsRange: ClosedRange<Int> = -200...300
    /// ユーザオフセットの刻み (ミリ秒、設計値)。
    static let userOffsetMillisecondsStep = 10
    static let userOffsetMillisecondsDefault = 0

    static func normalizedUserOffsetMilliseconds(_ milliseconds: Int) -> Int {
        let clamped = min(max(milliseconds, userOffsetMillisecondsRange.lowerBound), userOffsetMillisecondsRange.upperBound)
        let steps = (Double(clamped) / Double(userOffsetMillisecondsStep)).rounded()
        return Int(steps) * userOffsetMillisecondsStep
    }

    static func declaredFrames(
        deviceLatency: UInt32, streamLatency: UInt32, safetyOffset: UInt32,
        deviceSampleRate: Double, appliedSampleRate: Double
    ) -> Int {
        let declaredDeviceFrames = Int(deviceLatency) + Int(streamLatency) + Int(safetyOffset)
        return Int((Double(declaredDeviceFrames) * appliedSampleRate / deviceSampleRate).rounded())
    }

    static func capacityFrames(declaredFrames: Int, appliedSampleRate: Double) -> Int {
        min(declaredFrames + frames(milliseconds: userOffsetMillisecondsRange.upperBound, sampleRate: appliedSampleRate),
            capFrames(appliedSampleRate: appliedSampleRate))
    }

    static func delayFrames(declaredFrames: Int, offsetMilliseconds: Int, appliedSampleRate: Double) -> Int {
        let total = declaredFrames + frames(milliseconds: offsetMilliseconds, sampleRate: appliedSampleRate)
        return min(max(total, 0), capFrames(appliedSampleRate: appliedSampleRate))
    }

    private static func frames(milliseconds: Int, sampleRate: Double) -> Int {
        Int((Double(milliseconds) / 1000 * sampleRate).rounded())
    }

    private static func capFrames(appliedSampleRate: Double) -> Int {
        Int((maxPresentationDelaySeconds * appliedSampleRate).rounded(.down))
    }

    let capacityFrames: Int
    private let delayFramesStorage: AtomicUInt64
    private let channels: Int
    private let ringFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var position = 0

    var delayFrames: Int { Int(delayFramesStorage.value) }

    init(capacityFrames: Int, delayFrames: Int, channels: Int) {
        self.capacityFrames = max(0, capacityFrames)
        self.channels = channels
        ringFrames = self.capacityFrames + 1
        delayFramesStorage = AtomicUInt64(UInt64(min(max(0, delayFrames), self.capacityFrames)))
        storage = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * channels)
        storage.initialize(repeating: 0, count: ringFrames * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// オーディオ世界のキューからだけ呼ぶ。
    func setDelayFrames(_ frames: Int) {
        delayFramesStorage.store(UInt64(min(max(0, frames), capacityFrames)))
    }

    /// 1 周期ぶんを書き込み、遅延フレーム数前の同じ長さを output へ出す。遅延 0 では input をそのまま写す。
    func process(_ input: UnsafePointer<Float>, frames: Int, into output: UnsafeMutablePointer<Float>) {
        let delay = Int(delayFramesStorage.value)
        var write = position
        for f in 0..<frames {
            let frameBase = f * channels
            let writeBase = write * channels
            for c in 0..<channels { storage[writeBase + c] = input[frameBase + c] }
            var read = write - delay
            if read < 0 { read += ringFrames }
            let readBase = read * channels
            for c in 0..<channels { output[frameBase + c] = storage[readBase + c] }
            write += 1
            if write == ringFrames { write = 0 }
        }
        position = write
    }
}
