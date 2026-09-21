import Foundation

/// 測定用のピンクノイズ。応答測定がピンク加重で要約するため、入力の側で同じ分布を与える。
/// 乱数は種で決まるので、同じ種なら同じ列が出る。
struct PinkNoise {
    private var state: UInt32
    private var b = [Double](repeating: 0, count: 7)

    init(seed: UInt32) {
        state = seed | 1
    }

    /// チャンネルごとに非相関の列を作るための種。相関があると Side 成分が消える。
    static func seed(forChannel channel: Int) -> UInt32 {
        0x5EED &+ UInt32(channel) &* 0x9E37
    }

    private mutating func white() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(state) / Double(UInt32.max) * 2 - 1
    }

    /// 係数は設計値。
    mutating func next() -> Float {
        let w = white()
        b[0] = 0.99886 * b[0] + w * 0.0555179
        b[1] = 0.99332 * b[1] + w * 0.0750759
        b[2] = 0.96900 * b[2] + w * 0.1538520
        b[3] = 0.86650 * b[3] + w * 0.3104856
        b[4] = 0.55000 * b[4] + w * 0.5329522
        b[5] = -0.7616 * b[5] - w * 0.0168980
        let pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
        b[6] = w * 0.115926
        return Float(pink)
    }

    /// 単位 RMS へ正規化したインターリーブの列を作る。
    static func makeInterleaved(sampleCount: Int, channels: Int) -> [Float] {
        var generators = (0..<channels).map { PinkNoise(seed: seed(forChannel: $0)) }
        var out = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            out[i] = generators[i % channels].next()
        }
        var sum = 0.0
        for v in out { sum += Double(v) * Double(v) }
        let rms = sqrt(sum / Double(sampleCount))
        guard rms > 0 else { return out }
        let norm = Float(1 / rms)
        for i in 0..<sampleCount { out[i] *= norm }
        return out
    }
}
