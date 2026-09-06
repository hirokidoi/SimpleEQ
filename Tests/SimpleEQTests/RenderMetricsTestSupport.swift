import Foundation
@testable import SimpleEQ

/// 窓は時刻で区切られるため、実時計のままだと呼び出しを並べただけでは満ちない。
@MainActor
func makeMetricsWithTestClock(now: TimeInterval = 0) -> (RenderMetrics, TestClock) {
    let clock = TestClock(now: now)
    return (RenderMetrics(now: { clock.now }), clock)
}

/// 観測量の読み出しは設定と上限の 2 値を要するため、テストからはこの口を通す。
@MainActor
func renderSnapshot(_ vm: EQViewModel) -> RenderMetrics.Snapshot {
    vm.renderMetrics.snapshot(visualizerFps: vm.visualizerFps, visualizerFpsCeiling: vm.visualizerFpsCeiling)
}
