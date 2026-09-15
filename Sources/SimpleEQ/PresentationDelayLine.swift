import Foundation

/// 事前確保の interleaved 遅延線。realtime 経路で割り当て・ロック・ログをしない。
final class PresentationDelayLine {
    /// 申告値が壊れていても確保量を抑えるための上限 (設計値)。
    static let maxPresentationDelaySeconds: TimeInterval = 4

    static func presentationDelayFrames(
        deviceLatency: UInt32, streamLatency: UInt32, safetyOffset: UInt32, sampleRate: Double
    ) -> Int {
        let declared = Int(deviceLatency) + Int(streamLatency) + Int(safetyOffset)
        return min(declared, Int((maxPresentationDelaySeconds * sampleRate).rounded(.down)))
    }

    let delayFrames: Int
    private let channels: Int
    private let storage: UnsafeMutablePointer<Float>
    private var position = 0

    init(delayFrames: Int, channels: Int) {
        self.delayFrames = max(0, delayFrames)
        self.channels = channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: max(1, self.delayFrames) * channels)
        storage.initialize(repeating: 0, count: max(1, self.delayFrames) * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// 1 周期ぶんを書き込み、遅延フレーム数前の同じ長さを output へ出す。遅延 0 では input をそのまま写す。
    func process(_ input: UnsafePointer<Float>, frames: Int, into output: UnsafeMutablePointer<Float>) {
        guard delayFrames > 0 else {
            output.update(from: input, count: frames * channels)
            return
        }
        for f in 0..<frames {
            let base = position * channels
            let frameBase = f * channels
            for c in 0..<channels {
                output[frameBase + c] = storage[base + c]
                storage[base + c] = input[frameBase + c]
            }
            position += 1
            if position == delayFrames { position = 0 }
        }
    }
}
