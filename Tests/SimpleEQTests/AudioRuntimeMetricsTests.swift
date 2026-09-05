import XCTest
@testable import SimpleEQ

/// 記録 API を直接呼び、スナップショットに正しく反映されることを見る (CoreAudio・共有メモリには触れない)。
final class AudioRuntimeMetricsTests: XCTestCase {

    // MARK: - ドライバの書き込み位置決定の観測量 (基準値の張り直し)

    /// ドライバが再ロードされると共有側の累積カウンタは 0 から数え直しになる。
    /// 基準値を据え置くとドライバ自身の失敗が見えなくなる。
    func testDriverWritePositionObservationsReanchorWhenTheSharedCountersRestartFromZero() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 100,
            presentationDeltaUnexpectedCount: 300, writeDeadlineMissedCount: 400,
            silenceFilledGapCount: 500
        )
        metrics.reset()
        XCTAssertEqual(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate).presentationStallCount, 0, "前提: リセット直後は 0 起点になること")

        // ドライバ再ロード相当。共有側が 0 から数え直しになる。
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 0,
            presentationDeltaUnexpectedCount: 0, writeDeadlineMissedCount: 0,
            silenceFilledGapCount: 0
        )
        XCTAssertEqual(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate).writeDeadlineMissedCount, 0, "数え直しの直後は 0")

        // 数え直し後の最初の事象が、そのまま見えること (古い基準値に飲まれない)。
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 1,
            presentationDeltaUnexpectedCount: 3, writeDeadlineMissedCount: 4,
            silenceFilledGapCount: 5
        )
        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        XCTAssertEqual(snapshot.presentationStallCount, 1)
        XCTAssertEqual(snapshot.presentationDeltaUnexpectedCount, 3)
        XCTAssertEqual(snapshot.writeDeadlineMissedCount, 4)
        XCTAssertEqual(snapshot.silenceFilledGapCount, 5, "5 本目も同じ扱いであること")
    }

    // MARK: - available の窓統計

    func testAvailableWindowStatsIsNilBeforeFirstObservation() {
        XCTAssertNil(AudioRuntimeMetrics().availableWindowStats)
    }

    func testAvailableWindowStatsComputesMinMaxMedianBeforeWindowFills() throws {
        let metrics = AudioRuntimeMetrics()
        for value in [10, 30, 20] { metrics.recordAvailable(value) }
        let stats = try XCTUnwrap(metrics.availableWindowStats)
        XCTAssertEqual(stats.minFrames, 10)
        XCTAssertEqual(stats.maxFrames, 30)
        XCTAssertEqual(stats.medianFrames, 20)
    }

    func testAvailableWindowStatsDropsOldestSampleOnceWindowWraps() {
        let metrics = AudioRuntimeMetrics()
        // 窓容量を超えて書き込むと、最も古い観測値が捨てられる。
        for value in 0...64 { metrics.recordAvailable(value) }
        let stats = try! XCTUnwrap(metrics.availableWindowStats)
        XCTAssertEqual(stats.minFrames, 1, "窓が一巡すると最古の観測値 (0) は捨てられる")
        XCTAssertEqual(stats.maxFrames, 64)
    }

    // MARK: - 再プライミング回数 (判別フラグ)

    func testRecordReprimeSplitsCountByCause() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordReprime(dueToWriterStall: true)
        metrics.recordReprime(dueToWriterStall: true)
        metrics.recordReprime(dueToWriterStall: false)
        XCTAssertEqual(metrics.reprimeDueToWriterStallCount, 2)
        XCTAssertEqual(metrics.reprimeDueToTargetGrowthCount, 1)
    }

    // MARK: - 部分読み (本当のアンダーラン) とプライミング中の無音の判別

    func testRecordReadCountsOnlyTrueShortfallsAsPartialReads() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordRead(requestedFrames: 256, deliveredFrames: 256)
        XCTAssertEqual(metrics.partialReadCount, 0, "要求どおり届いた回は数えない")

        // 配信が 0 より多く要求未満: 本当のアンダーラン (部分読み) のみがここに数えられる。
        metrics.recordRead(requestedFrames: 256, deliveredFrames: 200)
        XCTAssertEqual(metrics.partialReadCount, 1)
        XCTAssertEqual(metrics.missingFrameCount, 56)
        XCTAssertEqual(metrics.primingSilenceCount, 0, "配信が 0 より多い回はプライミング待機に数えない")
    }

    func testRecordReadCountsZeroDeliveryAsPrimingSilenceNotPartialRead() {
        let metrics = AudioRuntimeMetrics()
        // 配信 0 は、音の欠落を意味する部分読みとは別の観測量として数える。
        metrics.recordRead(requestedFrames: 256, deliveredFrames: 0)
        metrics.recordRead(requestedFrames: 128, deliveredFrames: 0)
        XCTAssertEqual(metrics.primingSilenceCount, 2)
        XCTAssertEqual(metrics.primingSilenceFrameCount, 256 + 128)
        XCTAssertEqual(metrics.partialReadCount, 0, "配信 0 の回は部分読みに数えない")
        XCTAssertEqual(metrics.missingFrameCount, 0)
    }

    // MARK: - 再同期・ドリフトトリム・初回同期 (経路別)

    func testRecordResyncAndDriftTrimAccumulateIndependently() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordResync(discardedFrames: 100)
        metrics.recordResync(discardedFrames: 50)
        metrics.recordDriftTrim(discardedFrames: 10)
        XCTAssertEqual(metrics.resyncEventCount, 2)
        XCTAssertEqual(metrics.resyncDiscardedFrameCount, 150)
        XCTAssertEqual(metrics.driftTrimEventCount, 1)
        XCTAssertEqual(metrics.driftTrimDiscardedFrameCount, 10)
    }

    func testRecordInitialSyncAccumulatesSeparatelyFromResync() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordOccupancyReset(
            cause: .initialSync, discardedFrames: 1000, targetOccupancyFrames: 768
        )
        metrics.recordResync(discardedFrames: 5)
        XCTAssertEqual(metrics.occupancyResetDueToInitialSyncCount, 1)
        XCTAssertEqual(metrics.occupancyResetDueToInitialSyncDiscardedFrameCount, 1000)
        XCTAssertEqual(metrics.resyncEventCount, 1, "初回同期は通常の再同期の計上に混ざらない")
        XCTAssertEqual(metrics.resyncDiscardedFrameCount, 5)
    }

    // MARK: - バッファ量のリセット (契機別の回数・破棄量・直近イベントの値)

    /// リセット 1 回の記録。既定の引数は「値そのものに意味が無い」ことを表す。
    private func recordReset(
        _ metrics: AudioRuntimeMetrics, cause: AudioRuntimeMetrics.OccupancyResetCause,
        discardedFrames: Int = 0, targetOccupancyFrames: Int = 0
    ) {
        metrics.recordOccupancyReset(
            cause: cause, discardedFrames: discardedFrames, targetOccupancyFrames: targetOccupancyFrames
        )
    }

    func testRecordOccupancyResetSplitsCountsByCauseWhileAccumulatingDiscardedFramesInOneTotal() {
        let metrics = AudioRuntimeMetrics()
        recordReset(metrics, cause: .outputRestart, discardedFrames: 100)
        recordReset(metrics, cause: .outputRestart, discardedFrames: 200)
        recordReset(metrics, cause: .silence, discardedFrames: 30)
        recordReset(metrics, cause: .unmixableSeam, discardedFrames: 40)
        recordReset(metrics, cause: .initialSync, discardedFrames: 7, targetOccupancyFrames: 2048)

        XCTAssertEqual(metrics.occupancyResetDueToOutputRestartCount, 2)
        XCTAssertEqual(metrics.occupancyResetDueToSilenceCount, 1)
        XCTAssertEqual(metrics.occupancyResetDueToUnmixableSeamCount, 1)
        XCTAssertEqual(metrics.occupancyResetDueToInitialSyncCount, 1, "接続時の初回同期は専用の回数として残る")
        XCTAssertEqual(metrics.occupancyResetDueToInitialSyncDiscardedFrameCount, 7)
        XCTAssertEqual(metrics.occupancyResetDiscardedFrameCountTotal, 100 + 200 + 30 + 40 + 7, "破棄量は契機を問わず 1 本")
        XCTAssertEqual(
            metrics.lastOccupancyResetAvailableFrames, 7,
            "直近イベントの破棄直前のバッファ量。リセットは全て捨てるため呼び出し側が渡した破棄量と一致する"
        )
        XCTAssertEqual(metrics.lastOccupancyResetTargetOccupancyFrames, 2048, "直近イベントのその回の目標バッファ量")
    }

    // 直近イベントの 2 値は累積ではないため、リセットでは値そのものを 0 へ戻す。
    func testResetClearsTheLastOccupancyResetValues() {
        let metrics = AudioRuntimeMetrics()
        recordReset(metrics, cause: .silence, discardedFrames: 5000, targetOccupancyFrames: 2048)

        metrics.reset()

        XCTAssertEqual(metrics.lastOccupancyResetAvailableFrames, 0)
        XCTAssertEqual(metrics.lastOccupancyResetTargetOccupancyFrames, 0)
    }

    // 契機別の回数・累計破棄量は基準値方式に載る。
    func testResetKeepsOccupancyResetCountsFromBeforeItOutOfTheReportedValues() {
        let metrics = AudioRuntimeMetrics()
        recordReset(metrics, cause: .outputRestart, discardedFrames: 500)

        metrics.reset()
        XCTAssertEqual(metrics.occupancyResetDueToOutputRestartCount, 0, "前提: リセット直後は 0 起点になること")

        recordReset(metrics, cause: .outputRestart, discardedFrames: 60)
        XCTAssertEqual(metrics.occupancyResetDueToOutputRestartCount, 1, "リセット以降の発火だけが見える")
        XCTAssertEqual(metrics.occupancyResetDiscardedFrameCountTotal, 60)
    }

    // MARK: - 目標バッファ量の走行最大値

    // 現在値だけでは跳ねた事実が次の変化で上書きされて残らないため、走行最大値を別に持つ。
    func testTargetOccupancyRunningMaximumSurvivesLaterShrinkage() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordOccupancyBounds(targetFrames: 2048, maxFrames: 4224)
        metrics.recordOccupancyBounds(targetFrames: 1024, maxFrames: 2176)

        XCTAssertEqual(metrics.targetOccupancyFrames, 1024, "現在値は最新の観測")
        XCTAssertEqual(metrics.targetOccupancyFramesMax, 2048, "走行最大値は縮小しても保たれる")
    }

    // 走行最大値は「現在値 − 基準値」に意味が無いため、リセットは値そのものを書き直す。
    func testResetMakesTargetOccupancyMaximumTrackObservationsAfterward() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordReaderObserved(true)
        metrics.recordOccupancyBounds(targetFrames: 2048, maxFrames: 4224)
        metrics.recordOccupancyBounds(targetFrames: 1024, maxFrames: 2176)

        metrics.reset()
        XCTAssertEqual(metrics.targetOccupancyFramesMax, 1024, "リセット直後は現在値まで下がる")

        metrics.recordOccupancyBounds(targetFrames: 1536, maxFrames: 2688)
        XCTAssertEqual(metrics.targetOccupancyFramesMax, 1536, "以後の最大値へ更新される")
    }

    // MARK: - 実効書き手ブロック長・目標／上限バッファ量・リング容量 (現在の状態)

    func testEffectiveWriterBlockFramesReflectsLastRecordedValue() {
        let metrics = AudioRuntimeMetrics()
        XCTAssertEqual(metrics.effectiveWriterBlockFrames, 0)
        metrics.recordEffectiveWriterBlockFrames(512)
        XCTAssertEqual(metrics.effectiveWriterBlockFrames, 512)
    }

    func testOccupancyBoundsAndRingCapacityReflectLastRecordedValue() {
        let metrics = AudioRuntimeMetrics()
        XCTAssertEqual(metrics.targetOccupancyFrames, 0)
        XCTAssertEqual(metrics.maxOccupancyFrames, 0)
        XCTAssertEqual(metrics.ringCapacityFrames, 0)
        metrics.recordOccupancyBounds(targetFrames: 768, maxFrames: 1536)
        metrics.recordRingCapacity(16384)
        XCTAssertEqual(metrics.targetOccupancyFrames, 768)
        XCTAssertEqual(metrics.maxOccupancyFrames, 1536)
        XCTAssertEqual(metrics.ringCapacityFrames, 16384)
    }

    // MARK: - ドライバの書き込み位置決定の観測量 (共有ヘッダから転記)

    func testDriverWritePositionObservationsReflectLastRecordedValue() {
        let metrics = AudioRuntimeMetrics()
        XCTAssertEqual(metrics.presentationStallCount, 0)
        XCTAssertEqual(metrics.presentationDeltaUnexpectedCount, 0)
        XCTAssertEqual(metrics.writeDeadlineMissedCount, 0)

        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 3,
            presentationDeltaUnexpectedCount: 2, writeDeadlineMissedCount: 4, silenceFilledGapCount: 104
        )

        XCTAssertEqual(metrics.presentationStallCount, 3)
        XCTAssertEqual(metrics.presentationDeltaUnexpectedCount, 2)
        XCTAssertEqual(metrics.writeDeadlineMissedCount, 4)
    }

    // 転記は共有ヘッダの値をそのまま写し取る store であり、呼び出しのたびに上書きされる。
    func testDriverWritePositionObservationsAreOverwrittenNotAccumulated() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 3,
            presentationDeltaUnexpectedCount: 2, writeDeadlineMissedCount: 4, silenceFilledGapCount: 104
        )
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 3,
            presentationDeltaUnexpectedCount: 2, writeDeadlineMissedCount: 4, silenceFilledGapCount: 104
        )
        XCTAssertEqual(metrics.presentationStallCount, 3, "同じ値を繰り返し転記しても積み上がらない")
        XCTAssertEqual(metrics.writeDeadlineMissedCount, 4, "同じ値を繰り返し転記しても積み上がらない")
    }

    // MARK: - ピーク (走行最大値)

    func testRecordPeakTracksRunningMaximumAcrossCalls() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordPeak(0.125)
        XCTAssertEqual(metrics.peak, 0.125)
        metrics.recordPeak(0.5)
        XCTAssertEqual(metrics.peak, 0.5)
        // 過去の最大値を下回る観測は走行最大値を下げない。
        metrics.recordPeak(0.2)
        XCTAssertEqual(metrics.peak, 0.5, "走行最大値は下がらない")
    }

    func testRecordPeakBeforeVolumeTracksItsOwnRunningMaximum() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordPeakBeforeVolume(1.5)
        metrics.recordPeak(0.5)
        XCTAssertEqual(metrics.peakBeforeVolume, 1.5)
        XCTAssertEqual(metrics.peak, 0.5, "音量適用後の走行最大値とは別に持つ")

        metrics.recordPeakBeforeVolume(0.9)
        XCTAssertEqual(metrics.peakBeforeVolume, 1.5, "走行最大値は下がらない")

        metrics.reset()
        XCTAssertEqual(metrics.peakBeforeVolume, 0, "リセット直後はまだ観測が無い")
    }

    // MARK: - リセット (基準値方式)

    func testResetHasNoBaselineUntilCalled() {
        XCTAssertNil(AudioRuntimeMetrics().lastResetAt)
    }

    func testResetRecordsTimestamp() {
        let metrics = AudioRuntimeMetrics()
        let before = Date()
        metrics.reset()
        let after = Date()
        let resetAt = try! XCTUnwrap(metrics.lastResetAt)
        XCTAssertGreaterThanOrEqual(resetAt, before)
        XCTAssertLessThanOrEqual(resetAt, after)
    }

    func testResetShowsZeroForCumulativeCountersWithoutClearingUnderlyingCounters() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordRead(requestedFrames: 256, deliveredFrames: 200)
        metrics.recordRead(requestedFrames: 256, deliveredFrames: 0)
        metrics.recordResync(discardedFrames: 100)
        metrics.recordDriftTrim(discardedFrames: 10)
        recordReset(metrics, cause: .initialSync, discardedFrames: 1000)
        recordReset(metrics, cause: .outputRestart, discardedFrames: 20)
        recordReset(metrics, cause: .silence, discardedFrames: 30)
        recordReset(metrics, cause: .unmixableSeam, discardedFrames: 40)
        metrics.recordReprime(dueToWriterStall: true)
        metrics.recordReprime(dueToWriterStall: false)
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 11,
            presentationDeltaUnexpectedCount: 33, writeDeadlineMissedCount: 44, silenceFilledGapCount: 144
        )

        metrics.reset()

        XCTAssertEqual(metrics.partialReadCount, 0)
        XCTAssertEqual(metrics.missingFrameCount, 0)
        XCTAssertEqual(metrics.primingSilenceCount, 0)
        XCTAssertEqual(metrics.primingSilenceFrameCount, 0)
        XCTAssertEqual(metrics.resyncEventCount, 0)
        XCTAssertEqual(metrics.resyncDiscardedFrameCount, 0)
        XCTAssertEqual(metrics.driftTrimEventCount, 0)
        XCTAssertEqual(metrics.driftTrimDiscardedFrameCount, 0)
        XCTAssertEqual(metrics.occupancyResetDueToInitialSyncCount, 0)
        XCTAssertEqual(metrics.occupancyResetDueToInitialSyncDiscardedFrameCount, 0)
        XCTAssertEqual(metrics.occupancyResetDueToOutputRestartCount, 0)
        XCTAssertEqual(metrics.occupancyResetDueToSilenceCount, 0)
        XCTAssertEqual(metrics.occupancyResetDueToUnmixableSeamCount, 0)
        XCTAssertEqual(metrics.occupancyResetDiscardedFrameCountTotal, 0)
        XCTAssertEqual(metrics.reprimeDueToWriterStallCount, 0)
        XCTAssertEqual(metrics.reprimeDueToTargetGrowthCount, 0)
        XCTAssertEqual(metrics.presentationStallCount, 0, "ドライバの書き込み位置決定の観測量も基準値方式で 0 起点になる")
        XCTAssertEqual(metrics.presentationDeltaUnexpectedCount, 0)
        XCTAssertEqual(metrics.writeDeadlineMissedCount, 0)
    }

    // 基準値方式の「現在値 − 基準値」が、リセット後にドライバ側でさらに進んだ差分だけを表すことを見る。
    func testResetOfDriverWritePositionObservationsContinuesToReflectLaterValues() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 100,
            presentationDeltaUnexpectedCount: 5, writeDeadlineMissedCount: 2, silenceFilledGapCount: 102
        )
        metrics.reset()
        // 共有ヘッダ側の累計値がさらに進んだことを模す (転記は store であり、常に最新の累計値が渡る)。
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 130,
            presentationDeltaUnexpectedCount: 5, writeDeadlineMissedCount: 9, silenceFilledGapCount: 109
        )
        XCTAssertEqual(metrics.presentationStallCount, 30, "基準値以降に進んだ分だけが表示される")
        XCTAssertEqual(metrics.presentationDeltaUnexpectedCount, 0)
        XCTAssertEqual(metrics.writeDeadlineMissedCount, 7)
    }

    func testResetContinuesToReflectRecordingsMadeAfterward() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordResync(discardedFrames: 100)
        metrics.reset()
        metrics.recordResync(discardedFrames: 30)
        XCTAssertEqual(metrics.resyncEventCount, 1, "基準値以降に記録した分だけが表示される")
        XCTAssertEqual(metrics.resyncDiscardedFrameCount, 30)
    }

    func testResetDoesNotAffectCurrentStateValues() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordEffectiveWriterBlockFrames(512)
        metrics.recordOccupancyBounds(targetFrames: 768, maxFrames: 1536)

        metrics.reset()

        XCTAssertEqual(metrics.effectiveWriterBlockFrames, 512, "現在の推定値はリセット対象ではない")
        XCTAssertEqual(metrics.targetOccupancyFrames, 768)
        XCTAssertEqual(metrics.maxOccupancyFrames, 1536)
    }

    // ピークはリセット以降の走行最大値を表すため、リセットは値そのものを 0 へ戻す形で行う。
    func testResetMakesPeakTrackTheMaximumObservedAfterward() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordPeak(0.8)
        metrics.reset()
        XCTAssertEqual(metrics.peak, 0, "リセット直後はまだ観測が無い")

        metrics.recordPeak(0.3)
        XCTAssertEqual(metrics.peak, 0.3, accuracy: 1e-6, "リセット前の最大を下回る観測もそのまま表示される")

        metrics.recordPeak(0.2)
        XCTAssertEqual(metrics.peak, 0.3, accuracy: 1e-6, "走行最大値なので下回る観測では下がらない")

        metrics.recordPeak(0.95)
        XCTAssertEqual(metrics.peak, 0.95, accuracy: 1e-6, "以後の最大値へ更新される")
    }

    func testResetLimitsAvailableWindowStatsToWritesRecordedAfterward() {
        let metrics = AudioRuntimeMetrics()
        for value in [1000, 2000, 3000] { metrics.recordAvailable(value) }
        metrics.reset()
        XCTAssertNil(metrics.availableWindowStats, "リセット直後、基準値以降の書き込みはまだ無い")

        metrics.recordAvailable(10)
        metrics.recordAvailable(20)
        let stats = try! XCTUnwrap(metrics.availableWindowStats)
        XCTAssertEqual(stats.minFrames, 10)
        XCTAssertEqual(stats.maxFrames, 20)
    }

    func testResetDropsAvailableWindowStatsRecordedBeforeItEvenWhenWindowHasNotWrappedSince() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordAvailable(999) // リセット以前の観測。以後の集計に含まれてはならない。
        metrics.reset()
        for value in [5, 15, 25] { metrics.recordAvailable(value) }
        let stats = try! XCTUnwrap(metrics.availableWindowStats)
        XCTAssertEqual(stats.minFrames, 5, "リセット以前の観測 (999) が min に混ざっていない")
        XCTAssertEqual(stats.maxFrames, 25)
    }

    // MARK: - スナップショット・書き出しレポート

    func testSnapshotAggregatesAllObservations() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordAvailable(42)
        metrics.recordReprime(dueToWriterStall: true)
        metrics.recordRead(requestedFrames: 128, deliveredFrames: 100)
        metrics.recordRead(requestedFrames: 128, deliveredFrames: 0)
        metrics.recordResync(discardedFrames: 5)
        metrics.recordDriftTrim(discardedFrames: 3)
        metrics.recordPrimingTrim(discardedFrames: 19)
        recordReset(metrics, cause: .initialSync, discardedFrames: 7, targetOccupancyFrames: 768)
        recordReset(metrics, cause: .outputRestart, discardedFrames: 11)
        recordReset(metrics, cause: .silence, discardedFrames: 13)
        recordReset(metrics, cause: .unmixableSeam, discardedFrames: 17)
        metrics.recordEffectiveWriterBlockFrames(256)
        metrics.recordOccupancyBounds(targetFrames: 768, maxFrames: 1536)
        metrics.recordRingCapacity(16384)
        metrics.recordPeak(0.5)
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 9,
            presentationDeltaUnexpectedCount: 7, writeDeadlineMissedCount: 6, silenceFilledGapCount: 106
        )

        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        XCTAssertEqual(snapshot.availableWindow?.minFrames, 42)
        XCTAssertEqual(snapshot.reprimeDueToWriterStallCount, 1)
        XCTAssertEqual(snapshot.partialReadCount, 1)
        XCTAssertEqual(snapshot.missingFrameCount, 28)
        XCTAssertEqual(snapshot.primingSilenceCount, 1)
        XCTAssertEqual(snapshot.primingSilenceFrameCount, 128)
        XCTAssertEqual(snapshot.resyncEventCount, 1)
        XCTAssertEqual(snapshot.driftTrimEventCount, 1)
        XCTAssertEqual(snapshot.primingTrimEventCount, 1)
        XCTAssertEqual(snapshot.primingTrimDiscardedFrameCount, 19)
        XCTAssertEqual(snapshot.occupancyResetDueToInitialSyncCount, 1)
        XCTAssertEqual(snapshot.occupancyResetDueToInitialSyncDiscardedFrameCount, 7)
        XCTAssertEqual(snapshot.occupancyResetDueToOutputRestartCount, 1)
        XCTAssertEqual(snapshot.occupancyResetDueToSilenceCount, 1)
        XCTAssertEqual(snapshot.occupancyResetDueToUnmixableSeamCount, 1)
        XCTAssertEqual(snapshot.occupancyResetDiscardedFrameCountTotal, 7 + 11 + 13 + 17)
        XCTAssertEqual(snapshot.lastOccupancyResetAvailableFrames, 17, "最後のリセットの破棄直前のバッファ量が残る")
        XCTAssertEqual(snapshot.lastOccupancyResetTargetOccupancyFrames, 0, "最後のリセットは目標バッファ量を渡していない")
        XCTAssertEqual(snapshot.effectiveWriterBlockFrames, 256)
        XCTAssertEqual(snapshot.targetOccupancyFrames, 768)
        XCTAssertEqual(snapshot.targetOccupancyFramesMax, 768)
        XCTAssertEqual(snapshot.maxOccupancyFrames, 1536)
        XCTAssertEqual(snapshot.ringCapacityFrames, 16384)
        XCTAssertEqual(snapshot.peak, 0.5)
        XCTAssertEqual(snapshot.presentationStallCount, 9)
        XCTAssertEqual(snapshot.presentationDeltaUnexpectedCount, 7)
        XCTAssertEqual(snapshot.writeDeadlineMissedCount, 6)
        XCTAssertNil(snapshot.lastResetAt)
    }
}
