import Foundation
@testable import SimpleEQ

/// 窓は時刻で区切られるため、実時計のままだと呼び出しを並べただけでは満ちない。
@MainActor
func makeMetricsWithTestClock(now: TimeInterval = 0) -> (RenderMetrics, TestClock) {
    let clock = TestClock(now: now)
    return (RenderMetrics(now: { clock.now }), clock)
}
