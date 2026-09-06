import XCTest
@testable import SimpleEQ

@MainActor
final class RenderMetricsTests: XCTestCase {

    private let settingFps = EQLayout.Tuning.visualizerFpsDefault

    private func visualizer(_ metrics: RenderMetrics) -> RenderMetrics.Snapshot.Visualizer {
        metrics.snapshot(visualizerFps: settingFps, visualizerFpsCeiling: settingFps).visualizer
    }

    private func mixer(_ metrics: RenderMetrics) -> RenderMetrics.Snapshot.Mixer {
        metrics.snapshot(visualizerFps: settingFps, visualizerFpsCeiling: settingFps).mixer
    }

    /// 窓が確定するのに要る発火数。
    private func firingsToFillWindow(fps: Double) -> Int {
        Int((RenderMetrics.windowSeconds * fps).rounded(.up))
    }

    /// 刻み fps の間隔で count 回だけ発火させる。
    private func fireSteadily(
        _ metrics: RenderMetrics, clock: TestClock, fps: Double, count: Int, applied: (Int) -> Bool = { _ in true }
    ) {
        let base = clock.now
        for i in 1...count {
            clock.setToTick(i, fps: fps, from: base)
            metrics.visualizerDidFire(applied: applied(i))
        }
    }

    // MARK: - 窓と頻度

    func testFrequencyIsUnreadableUntilTheWindowIsFilled() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)

        fireSteadily(metrics, clock: clock, fps: 30, count: firingsToFillWindow(fps: 30) - 1)

        XCTAssertNil(visualizer(metrics).firedFps, "窓が満ちる前に頻度を出してはならない")
        XCTAssertTrue(visualizer(metrics).running, "窓が満ちる前でも駆動していることは出る")
    }

    /// 窓の端点の定義を固定する。起点を窓の最初の発火時刻に取る実装なら 1/窓長 ぶん過大になり、
    /// 発火数から 1 を引く実装なら同じだけ過小になる。
    func testSteadyFiringMeasuresExactlyTheScheduledRate() throws {
        for fps in EQLayout.Tuning.visualizerFpsChoices {
            let (metrics, clock) = makeMetricsWithTestClock()
            metrics.visualizerDidStart(scheduledFps: fps)
            fireSteadily(metrics, clock: clock, fps: fps, count: firingsToFillWindow(fps: fps))

            let measured = try XCTUnwrap(visualizer(metrics).firedFps, "刻み \(fps) fps で窓が確定していない")
            XCTAssertEqual(measured, fps, accuracy: 0.001, "刻み \(fps) fps で一定発火したのに実測が一致しない")
        }
    }

    func testWindowsAreContiguousSoTheSecondWindowAlsoMeasuresTheRate() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)
        let needed = firingsToFillWindow(fps: 30)

        fireSteadily(metrics, clock: clock, fps: 30, count: needed)
        fireSteadily(metrics, clock: clock, fps: 30, count: needed)

        XCTAssertEqual(visualizer(metrics).firedFps ?? 0, 30, accuracy: 0.001, "窓が繋がっていれば 2 窓目も刻みと一致する")
    }

    func testUnappliedFramesAreNotCountedIntoTheAppliedRate() {
        let (metrics, clock) = makeMetricsWithTestClock()
        // 窓に収まる発火数が偶数になる刻みを選び、1 回おきの反映がちょうど半分になるようにする。
        let fps: Double = 20
        metrics.visualizerDidStart(scheduledFps: fps)

        fireSteadily(metrics, clock: clock, fps: fps, count: firingsToFillWindow(fps: fps)) { $0.isMultiple(of: 2) }

        let clockValues = visualizer(metrics)
        XCTAssertEqual(clockValues.firedFps ?? 0, fps, accuracy: 0.001)
        XCTAssertEqual(clockValues.appliedFps ?? 0, fps / 2, accuracy: 0.001, "反映しなかったフレームが反映側に数えられている")
    }

    func testSparseFiringMeasuresTheSparseRateRatherThanTheScheduledOne() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)

        // 刻みは 30 のまま、実際には窓長ぶん空けて 1 回だけ発火する。
        clock.advance(by: RenderMetrics.windowSeconds)
        metrics.visualizerDidFire(applied: true)

        XCTAssertEqual(
            visualizer(metrics).firedFps ?? 0, 1 / RenderMetrics.windowSeconds, accuracy: 0.001,
            "経過だけが伸びた窓は、刻みではなく実際の頻度を出す"
        )
    }

    // MARK: - 駆動状態と停止

    func testStopClearsTheSettledValueSoAStaleRateIsNeverShown() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)
        fireSteadily(metrics, clock: clock, fps: 30, count: firingsToFillWindow(fps: 30))
        XCTAssertNotNil(visualizer(metrics).firedFps)

        metrics.visualizerDidStop()

        let clockValues = visualizer(metrics)
        XCTAssertFalse(clockValues.running)
        XCTAssertNil(clockValues.scheduledFps, "停止したら適用中の刻みは残さない")
        XCTAssertNil(clockValues.firedFps, "停止したら直前の頻度は残さない")
        XCTAssertNil(clockValues.appliedFps)
    }

    func testFiringAfterStopIsIgnored() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)
        metrics.visualizerDidStop()

        fireSteadily(metrics, clock: clock, fps: 30, count: firingsToFillWindow(fps: 30) * 2)

        XCTAssertNil(visualizer(metrics).firedFps, "停止中の発火から頻度が立ってはならない")
        XCTAssertFalse(visualizer(metrics).running)
    }

    func testRestartDropsTheRateMeasuredAtThePreviousScheduling() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)
        fireSteadily(metrics, clock: clock, fps: 30, count: firingsToFillWindow(fps: 30))

        clock.advance(by: 10)
        metrics.visualizerDidStart(scheduledFps: EQLayout.Tuning.idleFps)

        let clockValues = visualizer(metrics)
        XCTAssertEqual(clockValues.scheduledFps, EQLayout.Tuning.idleFps)
        XCTAssertNil(clockValues.firedFps, "刻みが変われば、前の刻みで測った値は現在の状態ではない")
    }

    // MARK: - 2 系統の独立

    func testTheTwoClocksDoNotShareState() {
        let (metrics, clock) = makeMetricsWithTestClock()
        metrics.visualizerDidStart(scheduledFps: 30)
        metrics.mixerDidStart()

        let base = clock.now
        for i in 1...firingsToFillWindow(fps: 15) {
            clock.setToTick(i, fps: 15, from: base)
            metrics.mixerDidFire()
        }

        XCTAssertEqual(mixer(metrics).firedFps ?? 0, 15, accuracy: 0.001)
        XCTAssertNil(visualizer(metrics).firedFps, "Mixer の発火がビジュアライザ側に数えられている")

        metrics.mixerDidStop()
        XCTAssertTrue(visualizer(metrics).running, "片方の停止がもう片方を止めている")
    }

    // MARK: - 窓長と画面の更新周期の関係

    /// 窓が更新周期以上に長いと、1 周期取り逃しただけで行が読めなくなる。
    /// 片方だけを動かしても気づけるよう、関係そのものを固定する。
    func testTheWindowIsShorterThanTheIntervalTheScreenRefreshesItselfAt() {
        XCTAssertLessThan(RenderMetrics.windowSeconds, DiagnosticsView.refreshInterval)
    }

    // MARK: - 設定値

    func testMixerSettingRateComesFromTheSameExpressionTheClockUses() {
        let metrics = RenderMetrics()
        for fps in EQLayout.Tuning.visualizerFpsChoices {
            let snapshot = metrics.snapshot(visualizerFps: fps, visualizerFpsCeiling: fps)
            XCTAssertEqual(snapshot.visualizerSettingFps, fps)
            XCTAssertEqual(snapshot.mixerEffectiveFps, MixerRenderClock.fps(visualizerFpsCeiling: fps))
        }
    }

    // 設定の行は利用者が選んだ値を、Mixer の行はクロックが実際に上限として読む値を出す。
    // Mixer 側は自分の頭打ちを持つため、上限がそれを下回る組でないと取り違えが表に出ない。
    func testTheSettingRowAndTheMixerRowReadDifferentInputs() {
        let setting = EQLayout.Tuning.visualizerFpsChoices.last!
        let ceiling = EQLayout.Tuning.visualizerFpsChoices.first!
        XCTAssertLessThan(ceiling, EQLayout.Mixer.meterFpsCap, "前提: 上限が Mixer 自身の頭打ちより下")
        XCTAssertNotEqual(
            MixerRenderClock.fps(visualizerFpsCeiling: setting),
            MixerRenderClock.fps(visualizerFpsCeiling: ceiling),
            "前提: この組なら設定と上限の取り違えが値の違いとして出る"
        )

        let snapshot = RenderMetrics().snapshot(visualizerFps: setting, visualizerFpsCeiling: ceiling)

        XCTAssertEqual(snapshot.visualizerSettingFps, setting, "設定の行は選んだ値のまま")
        XCTAssertEqual(
            snapshot.mixerEffectiveFps, MixerRenderClock.fps(visualizerFpsCeiling: ceiling),
            "Mixer の行は上限から導く"
        )
    }
}
