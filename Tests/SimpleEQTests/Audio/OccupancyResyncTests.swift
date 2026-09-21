import XCTest
@testable import SimpleEQ

/// 上限超過を原因で 2 経路に分ける判定を検証する。決定論的な入力だけを与える純粋関数のテストであり、実時間の待機は行わない。
final class OccupancyResyncTests: XCTestCase {
    private let appliedSampleRate = AudioConfig.appliedSampleRate
    private let writerBlockFrames = 256
    private let clientRequestFrames = 256

    private var target: Int {
        OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: appliedSampleRate
        )
    }
    private var maxOccupancy: Int {
        OccupancyPolicy.maxOccupancyFrames(targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: appliedSampleRate)
    }
    private var trimHoldDuration: TimeInterval {
        OccupancyPolicy.trimHoldDuration(
            targetOccupancyFrames: target, maxOccupancyFrames: maxOccupancy,
            sampleRate: appliedSampleRate, driftCorrectionMaxRateFraction: AudioConfig.driftCorrectionMaxRateFraction
        )
    }

    // (a) 大きな段差は、不連続として検知されていれば経過時間を待たず即座に再同期する。
    func testDiscontinuityWithBigStepOvershootResyncsImmediately() {
        let response = OccupancyPolicy.classifyOverflow(
            discontinuityDetected: true, available: maxOccupancy * 8, maxOccupancyFrames: maxOccupancy,
            overshootElapsed: 0, trimHoldDuration: trimHoldDuration
        )
        XCTAssertEqual(response, .immediateResync)
    }

    // (b) ドリフト起因の緩やかな超過 (不連続ではない) は T_trim に達するまで発火しない。
    func testGradualDriftOverflowDoesNotFireBeforeTrimHoldDuration() {
        let response = OccupancyPolicy.classifyOverflow(
            discontinuityDetected: false, available: maxOccupancy + 1, maxOccupancyFrames: maxOccupancy,
            overshootElapsed: trimHoldDuration * 0.5, trimHoldDuration: trimHoldDuration
        )
        XCTAssertEqual(response, .withinBounds)
    }

    // (c) T_trim に達したドリフト起因の超過は、目標バッファ量までのトリムとして発火する。
    func testGradualDriftOverflowFiresAfterTrimHoldDurationElapses() {
        let response = OccupancyPolicy.classifyOverflow(
            discontinuityDetected: false, available: maxOccupancy + 1, maxOccupancyFrames: maxOccupancy,
            overshootElapsed: trimHoldDuration, trimHoldDuration: trimHoldDuration
        )
        XCTAssertEqual(response, .sustainedDriftTrim)
    }

    // (d) 内部事象 (出力先/段の切替) による不連続は、上限超過さえしていれば待たずに再同期する。
    func testInternalEventDiscontinuityResyncsWithoutWaitingForTrimHoldDuration() {
        let response = OccupancyPolicy.classifyOverflow(
            discontinuityDetected: true, available: maxOccupancy + 1, maxOccupancyFrames: maxOccupancy,
            overshootElapsed: 0, trimHoldDuration: trimHoldDuration
        )
        XCTAssertEqual(response, .immediateResync)
    }

    // (e) 上限以下では、不連続の通知や経過時間に関わらず何も発火しない。
    func testWithinMaxOccupancyNeverFiresRegardlessOfDiscontinuityOrElapsed() {
        XCTAssertEqual(
            OccupancyPolicy.classifyOverflow(
                discontinuityDetected: true, available: maxOccupancy, maxOccupancyFrames: maxOccupancy,
                overshootElapsed: trimHoldDuration, trimHoldDuration: trimHoldDuration
            ),
            .withinBounds
        )
        XCTAssertEqual(
            OccupancyPolicy.classifyOverflow(
                discontinuityDetected: false, available: target + 1, maxOccupancyFrames: maxOccupancy,
                overshootElapsed: nil, trimHoldDuration: trimHoldDuration
            ),
            .withinBounds
        )
    }

    // 破棄量は目標バッファ量までの差分に一致する。
    func testDiscardedFramesLandExactlyOnTarget() {
        let available = maxOccupancy * 8
        let discard = OccupancyPolicy.framesToDiscard(available: available, targetOccupancyFrames: target)
        XCTAssertEqual(available - discard, target)
    }

    // MARK: - hasMixableSource (混ぜる相手が定義できるか)

    // (f) バッファ量がリング容量を超えていれば旧カーソル位置のデータは上書き済みであり、混ぜる相手が無いと判定する。
    func testHasMixableSourceIsFalseWhenAvailableExceedsRingCapacity() {
        XCTAssertFalse(
            OccupancyPolicy.hasMixableSource(available: 100_001, ringFrames: 100_000, writerBlockFrames: 512)
        )
    }

    // (g) 猶予が書き込み粒度ちょうどであれば、次の 1 バーストは旧カーソル側へ届かないため混ぜる相手が残る。
    func testHasMixableSourceIsTrueWhenMarginExactlyCoversOneWriteBurst() {
        let ringFrames = 100_000
        let writerBlockFrames = 512
        XCTAssertTrue(
            OccupancyPolicy.hasMixableSource(
                available: ringFrames - writerBlockFrames,
                ringFrames: ringFrames, writerBlockFrames: writerBlockFrames
            )
        )
    }

    // (h) 猶予が書き込み粒度に 1 フレーム足りない回は混ぜる相手が無いと判定する。
    func testHasMixableSourceIsFalseWhenMarginIsOneFrameShortOfOneWriteBurst() {
        let ringFrames = 100_000
        let writerBlockFrames = 512
        XCTAssertFalse(
            OccupancyPolicy.hasMixableSource(
                available: ringFrames - writerBlockFrames + 1,
                ringFrames: ringFrames, writerBlockFrames: writerBlockFrames
            )
        )
    }
}
