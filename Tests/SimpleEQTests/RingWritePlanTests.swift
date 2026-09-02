import XCTest
import SimpleEQRingC

/// 書き込み位置を決定する純関数を、ドライバ本体を経由せず試験ターゲットから直接叩いて検証する。
/// アンカー・絶対位置の算術は符号なし 64bit の巻き戻りを前提にしており、Swift の既定の算術演算子は
/// オーバーフローで trap するため、この関数と同じ意味を保つには wrapping 演算子 (`&-`/`&+`) を使う。
final class RingWritePlanTests: XCTestCase {
    private func computePlan(
        anchor: UInt64, anchorValid: Bool,
        previousPresented: UInt64, previousValid: Bool,
        presentationTime: Double,
        counter: UInt64, ringFrames: UInt32, framesThisCycle: UInt32
    ) -> SimpleEQRingWritePlanResult {
        simpleeq_ring_compute_write_plan(
            anchor, anchorValid, previousPresented, previousValid, presentationTime,
            counter, ringFrames, framesThisCycle
        )
    }

    // MARK: - 連続提示

    func testContinuousPresentationKeepsPositionContinuousAndCounterAdvancesByFrameCount() {
        let ringFrames: UInt32 = 8192
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 10_000

        var counter = anchor
        var previousPresented: UInt64 = 0
        var previousValid = false
        var presentationTime: Double = 0

        for cycle in 0..<5 {
            let plan = computePlan(
                anchor: anchor, anchorValid: true,
                previousPresented: previousPresented, previousValid: previousValid,
                presentationTime: presentationTime,
                counter: counter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
            )
            let expectedPosition = anchor &+ UInt64(presentationTime)
            XCTAssertEqual(plan.absolutePosition, expectedPosition, "cycle \(cycle): 位置が連続すること")
            XCTAssertEqual(plan.publishedCounter, expectedPosition &+ UInt64(framesPerCycle), "cycle \(cycle)")
            XCTAssertEqual(plan.anchor, anchor, "cycle \(cycle): 範囲内では据え直されない")
            XCTAssertFalse(plan.presentationTimeUnexpected, "cycle \(cycle)")

            previousPresented = plan.presentedFrames
            previousValid = true
            counter = plan.publishedCounter
            presentationTime += Double(framesPerCycle)
        }
    }

    // MARK: - 再提示の冪等性

    func testIdempotentRepresentationKeepsSamePositionAndDoesNotAdvanceCounter() {
        let ringFrames: UInt32 = 8192
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 5_000
        let presentationTime: Double = 512

        let plan1 = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 256, previousValid: true,
            presentationTime: presentationTime, counter: anchor &+ 512, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        // 同じ提示時刻を 2 回目として渡す (HAL からの再提示を模す)。
        let plan2 = computePlan(
            anchor: plan1.anchor, anchorValid: true, previousPresented: plan1.presentedFrames, previousValid: true,
            presentationTime: presentationTime, counter: plan1.publishedCounter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )

        XCTAssertEqual(plan2.absolutePosition, plan1.absolutePosition, "同じ提示時刻は同じ位置になる")
        XCTAssertEqual(plan2.publishedCounter, plan1.publishedCounter, "カウンタは進まない")
        XCTAssertTrue(plan2.presentationTimeStalled, "差分 0 のため進まなかった印が立つ")
    }

    // MARK: - IO 開始の据え直し

    func testIOStartReanchorsSoPositionStartsRightAfterTheCurrentCounter() {
        let ringFrames: UInt32 = 8192
        let framesPerCycle: UInt32 = 256
        // 前の稼働からの累積 (coreaudiod 再起動等でアンカーが未観測になった状態)。
        let existingCounter: UInt64 = 9_000

        let plan = computePlan(
            anchor: 0, anchorValid: false, previousPresented: 0, previousValid: false,
            presentationTime: 0, counter: existingCounter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )

        XCTAssertEqual(plan.absolutePosition, existingCounter, "その時点のカウンタの直後から連続する")
        XCTAssertEqual(plan.anchor, existingCounter, "presentedFrames=0 のためアンカーはカウンタと一致する")
        XCTAssertEqual(plan.publishedCounter, existingCounter &+ UInt64(framesPerCycle))
        XCTAssertFalse(plan.presentationTimeUnexpected, "アンカー無効による据え直しだけでは想定外にしない")
    }

    // MARK: - 範囲の上限による防御

    func testForwardRangeViolationReanchorsAndFlagsUnexpected() {
        let ringFrames: UInt32 = 4096
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 1_000
        let counter: UInt64 = 2_000
        // 絶対位置 (anchor+50_000=51_000) がカウンタ (2_000) からリング容量を超えて前方になる。
        let presentationTime: Double = 50_000

        let plan = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: false,
            presentationTime: presentationTime, counter: counter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )

        XCTAssertEqual(plan.absolutePosition, counter, "範囲外は据え直されカウンタの直後から連続する")
        XCTAssertEqual(plan.anchor, counter &- UInt64(presentationTime))
        XCTAssertTrue(plan.presentationTimeUnexpected)
    }

    func testBackwardRangeViolationAndNegativePresentationTimeBothReanchor() {
        let ringFrames: UInt32 = 4096
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 100_000

        // 後方: 絶対位置 (anchor 起点=100_000) がカウンタからリング容量を超えて後方にある。
        let farAheadCounter: UInt64 = anchor &+ UInt64(ringFrames) * 10
        let backwardPlan = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: false,
            presentationTime: 0, counter: farAheadCounter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertEqual(backwardPlan.absolutePosition, farAheadCounter, "後方への大幅な乖離も据え直される")
        XCTAssertTrue(backwardPlan.presentationTimeUnexpected)

        // 負の提示時刻: 範囲内であっても常に据え直しの側へ倒す。
        let counter: UInt64 = anchor
        let negativePlan = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 10, previousValid: true,
            presentationTime: -5, counter: counter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertEqual(negativePlan.presentedFrames, 0, "負の値は 0 フレームとして扱う")
        XCTAssertEqual(negativePlan.absolutePosition, counter, "据え直されカウンタの直後から連続する")
        XCTAssertTrue(negativePlan.presentationTimeUnexpected)
    }

    // MARK: - 「進まなかった」印

    func testStalledFlagIsSetOnlyWhenPresentationTimeDoesNotAdvance() {
        let ringFrames: UInt32 = 8192
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 1_000
        let counter: UInt64 = anchor &+ 256

        let advancing = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: true,
            presentationTime: 256, counter: counter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertFalse(advancing.presentationTimeStalled, "前サイクルから進んでいれば立たない")

        let stalled = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 256, previousValid: true,
            presentationTime: 256, counter: counter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertTrue(stalled.presentationTimeStalled, "差分が 0 のとき立つ")

        // 比較対象 (前サイクル) が無い回はどちらの印も判定しない。
        let noPrevious = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: false,
            presentationTime: 256, counter: counter, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertFalse(noPrevious.presentationTimeStalled, "比較対象が無ければ進まなかった印は立たない")
    }

    // MARK: - 「想定外」印

    func testUnexpectedFlagCoversNegativeDeltaAndNonMultipleDeltaButNotOrdinaryOrDeadlineJumps() {
        let ringFrames: UInt32 = 8192
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 1_000

        // 通常の連続提示: 差分がフレーム数ちょうど (1 サイクルぶん) は想定外ではない。
        let ordinary = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: true,
            presentationTime: 256, counter: anchor &+ 256, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertFalse(ordinary.presentationTimeUnexpected)

        // 締切超過ぶんの飛び越し: 差分が framesThisCycle の整数倍 (2 サイクルぶん) は想定外ではない。
        let deadlineJump = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: true,
            presentationTime: 512, counter: anchor &+ 512, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertFalse(deadlineJump.presentationTimeUnexpected, "整数倍の飛び越しは想定外にしない")

        // 差分が負。
        let negativeDelta = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 512, previousValid: true,
            presentationTime: 256, counter: anchor &+ 256, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertTrue(negativeDelta.presentationTimeUnexpected, "差分が負")

        // 差分が framesThisCycle の整数倍でない。
        let nonMultiple = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: 0, previousValid: true,
            presentationTime: 100, counter: anchor &+ 100, ringFrames: ringFrames, framesThisCycle: framesPerCycle
        )
        XCTAssertTrue(nonMultiple.presentationTimeUnexpected, "整数倍でない差分")
    }

    // MARK: - 書き始めの手前の未書き込み区間

    /// 位置が後方にある回に、桁違いの長さを前方の隙間と見なしてはならない。
    func testWritePlanReportsNoGapWhenPositionSitsBehindTheCounter() {
        let ringFrames: UInt32 = 1024
        let framesThisCycle: UInt32 = 256
        let counter: UInt64 = 512
        let presentedFrames: Double = 256
        let anchor = counter &- UInt64(presentedFrames) &- UInt64(framesThisCycle)

        let plan = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: UInt64(presentedFrames), previousValid: true,
            presentationTime: presentedFrames, counter: counter, ringFrames: ringFrames, framesThisCycle: framesThisCycle
        )

        XCTAssertLessThan(plan.absolutePosition, counter, "前提: 位置がカウンタより後方にあること")
        XCTAssertEqual(plan.gapFrames, 0, "後方にある回は前方の隙間を持たない")
    }

    /// 位置が前方にある回は、その差がそのまま埋めるべき長さになる。
    func testWritePlanReportsForwardGapAsTheDistanceFromTheCounter() {
        let ringFrames: UInt32 = 1024
        let framesThisCycle: UInt32 = 256
        let counter: UInt64 = 4096
        let gap: UInt64 = 128
        let presentedFrames: Double = 512
        let anchor = counter &+ gap &- UInt64(presentedFrames)

        let plan = computePlan(
            anchor: anchor, anchorValid: true, previousPresented: UInt64(presentedFrames), previousValid: true,
            presentationTime: presentedFrames, counter: counter, ringFrames: ringFrames, framesThisCycle: framesThisCycle
        )

        XCTAssertEqual(plan.absolutePosition, counter &+ gap, "前提: 位置が前方にあること")
        XCTAssertEqual(UInt64(plan.gapFrames), gap, "前方の差がそのまま埋めるべき長さになる")
    }

    // MARK: - 有限でない提示時刻

    /// 有限でない提示時刻 (NaN・無限大) は、負値と同じく範囲外として扱う。
    func testNonFinitePresentationTimesAreTreatedAsOutOfRange() {
        let ringFrames: UInt32 = 4096
        let framesPerCycle: UInt32 = 256
        let anchor: UInt64 = 1_000
        let counter: UInt64 = 2_000

        for presentationTime in [Double.nan, .infinity, -.infinity, Double(UInt64.max) * 2] {
            let plan = computePlan(
                anchor: anchor, anchorValid: true, previousPresented: 10, previousValid: true,
                presentationTime: presentationTime, counter: counter,
                ringFrames: ringFrames, framesThisCycle: framesPerCycle
            )
            XCTAssertEqual(plan.presentedFrames, 0, "0 フレームとして扱う (\(presentationTime))")
            XCTAssertEqual(plan.absolutePosition, counter, "据え直されカウンタの直後から連続する (\(presentationTime))")
            XCTAssertTrue(plan.presentationTimeUnexpected, "想定外として数える (\(presentationTime))")
        }
    }

    /// 据え直した回は停滞として数えない。据え直しは書き始めを未書き込みの領域へ移すため、
    /// 「前回と同じ位置へ再提示された」という停滞の意味が成り立たない。
    func testReanchoredCycleIsNotCountedAsStalledEvenWhenThePresentedTimeDidNotAdvance() {
        let plan = computePlan(
            anchor: 0, anchorValid: true, previousPresented: 256, previousValid: true,
            presentationTime: 256, counter: 1_000_000, ringFrames: 4096, framesThisCycle: 256
        )

        XCTAssertTrue(plan.presentationTimeUnexpected, "前提: 範囲外として据え直された回であること")
        XCTAssertEqual(plan.absolutePosition, 1_000_000, "前提: 書き始めがカウンタの直後へ移ること")
        XCTAssertFalse(plan.presentationTimeStalled, "据え直した回は停滞として数えない")
    }

    // MARK: - バージョン

    /// レイアウトを変えたらレイアウトバージョンも動かす必要があることに、この比較で気づけるようにする。
    /// 期待値を導出で書くとレイアウト変更へ黙って追従してしまい、番人にならない。
    func testLayoutVersionMatchesTheValueThisFixtureTableWasWrittenAgainst() {
        XCTAssertEqual(simpleeq_ring_expected_layout_version(), 2)
    }
}
