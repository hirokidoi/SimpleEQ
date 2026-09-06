import Foundation

/// 期限や観測窓を実時間に頼らず動かすための時計。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    init(now: Double = 0) {
        self.value = now
    }

    var now: Double { lock.withLock { value } }

    func advance(by seconds: Double) { lock.withLock { value += seconds } }

    /// 一定間隔の n 回目を絶対時刻で置く。間隔を足し込むと丸め誤差が溜まり、窓の境界に届かないことがある。
    func setToTick(_ n: Int, fps: Double, from base: Double) {
        lock.withLock { value = base + Double(n) / fps }
    }
}
