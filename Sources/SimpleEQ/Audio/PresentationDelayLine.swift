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
    static func declaredFrames(
        deviceLatency: UInt32, streamLatency: UInt32, safetyOffset: UInt32,
        deviceSampleRate: Double, appliedSampleRate: Double
    ) -> Int {
        let declaredDeviceFrames = Int(deviceLatency) + Int(streamLatency) + Int(safetyOffset)
        return Int((Double(declaredDeviceFrames) * appliedSampleRate / deviceSampleRate).rounded())
    }

    static func delayFrames(declaredFrames: Int, appliedSampleRate: Double) -> Int {
        min(max(declaredFrames, 0), capFrames(appliedSampleRate: appliedSampleRate))
    }

    private static func capFrames(appliedSampleRate: Double) -> Int {
        Int((maxPresentationDelaySeconds * appliedSampleRate).rounded(.down))
    }

    let delayFrames: Int
    private let channels: Int
    private let ringFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var position = 0

    init(delayFrames: Int, channels: Int) {
        self.delayFrames = max(0, delayFrames)
        self.channels = channels
        ringFrames = self.delayFrames + 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * channels)
        storage.initialize(repeating: 0, count: ringFrames * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// 1 周期ぶんを書き込み、遅延フレーム数前の同じ長さを output へ出す。遅延 0 では input をそのまま写す。
    func process(_ input: UnsafePointer<Float>, frames: Int, into output: UnsafeMutablePointer<Float>) {
        let delay = delayFrames
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
