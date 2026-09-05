import XCTest
@testable import SimpleEQ

/// トップレベルの非 isolated 関数にしてあるのは、
/// @Sendable な measure クロージャ (MainActor から隔離された測定キュー上で呼ばれる想定) から
/// actor 隔離を跨がずに呼べるようにするため。
private func autoPreampTestCurve(_ tag: Double) -> [Double] {
    Array(repeating: tag, count: EQSpec.bandCount)
}

private func autoPreampTestResponse(_ gain: Double) -> EQMagnitudeResponse {
    EQMagnitudeResponse(energyWeightedGainDb: gain, worstCaseGainDb: gain)
}

@MainActor
final class AutoPreampCoordinatorTests: XCTestCase {
    /// runMeasurement/deliver がともに即実行 (同期完了) する調停役。
    /// 対応表に無い curve は測定失敗 (nil) として扱われる。
    private func makeSyncCoordinator(
        measureCount: Recorded<Int> = Recorded(0), responses: [[Double]: EQMagnitudeResponse] = [:],
        cacheCapacity: Int = AutoPreampCoordinator.defaultCacheCapacity
    ) -> AutoPreampCoordinator {
        AutoPreampCoordinator(
            measure: { c, _ in
                measureCount.update { $0 += 1 }
                return responses[c]
            },
            runMeasurement: { work in work() },
            deliver: { work in MainActor.assumeIsolated { work() } },
            cacheCapacity: cacheCapacity
        )
    }

    /// runMeasurement が即実行せず溜めるだけの調停役。テストが runNext() を呼んだ回だけ、
    /// 溜まった測定要求のうち最も古いものが 1 件完了する (非同期実行を模す)。
    private func makeQueuedCoordinator(
        measureCount: Recorded<Int> = Recorded(0), responses: [[Double]: EQMagnitudeResponse] = [:],
        cacheCapacity: Int = AutoPreampCoordinator.defaultCacheCapacity
    ) -> (coordinator: AutoPreampCoordinator, runNext: () -> Bool) {
        let pending = Recorded<[@Sendable () -> Void]>([])
        let coordinator = AutoPreampCoordinator(
            measure: { c, _ in
                measureCount.update { $0 += 1 }
                return responses[c]
            },
            runMeasurement: { work in pending.update { $0.append(work) } },
            deliver: { work in MainActor.assumeIsolated { work() } },
            cacheCapacity: cacheCapacity
        )
        let runNext: () -> Bool = {
            let job = pending.update { queued -> (@Sendable () -> Void)? in
                guard !queued.isEmpty else { return nil }
                return queued.removeFirst()
            }
            job?()
            return job != nil
        }
        return (coordinator, runNext)
    }

    // MARK: - アイドルゼロ

    func testIdleRefreshWithSameInputMeasuresAndDerivesOnlyOnce() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let coordinator = makeSyncCoordinator(measureCount: measureCount, responses: [c: autoPreampTestResponse(6)])
        var derivedCount = 0
        var last: Double = 0
        coordinator.didDerive = { last = $0; derivedCount += 1 }

        for _ in 0..<10 {
            coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        }

        XCTAssertEqual(measureCount.value, 1, "同じ入力の再入は不変条件の一致ガードで即 return する")
        XCTAssertEqual(derivedCount, 1)
    }

    // MARK: - キャッシュ

    func testRefreshWithRepeatedCurvesOnlyMeasuresDistinctOnes() {
        let measureCount = Recorded(0)
        let c1 = autoPreampTestCurve(1), c2 = autoPreampTestCurve(2), c3 = autoPreampTestCurve(3)
        let coordinator = makeSyncCoordinator(
            measureCount: measureCount,
            responses: [c1: autoPreampTestResponse(1), c2: autoPreampTestResponse(2), c3: autoPreampTestResponse(3)]
        )
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        for c in [c1, c2, c1, c3, c2] {
            coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        }

        XCTAssertEqual(measureCount.value, 3, "5 回のうち相異なるカーブは 3 種")
    }

    // MARK: - 目標のみ変更

    func testTargetOnlyChangeUsesCacheAndUpdatesDerivedValue() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let coordinator = makeSyncCoordinator(measureCount: measureCount, responses: [c: autoPreampTestResponse(6)])
        var last: Double = 0
        coordinator.didDerive = { last = $0 }
        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 1, "前提")
        let firstDerived = last

        coordinator.refresh(enabled: true, curve: c, targetDb: 4, sampleRate: 48000, currentPreampDb: last)

        XCTAssertEqual(measureCount.value, 1, "測定は増えない")
        XCTAssertNotEqual(last, firstDerived)
        XCTAssertEqual(last, AutoPreampSpec.derivedPreampDb(response: autoPreampTestResponse(6), targetDb: 4))
    }

    // MARK: - 自動 OFF

    func testDisabledRefreshNeverMeasuresOrDerives() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let coordinator = makeSyncCoordinator(measureCount: measureCount, responses: [c: autoPreampTestResponse(6)])
        var derivedCount = 0
        coordinator.didDerive = { _ in derivedCount += 1 }

        coordinator.refresh(enabled: false, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: 0)

        XCTAssertEqual(measureCount.value, 0)
        XCTAssertEqual(derivedCount, 0)
    }

    // MARK: - 自動 ON への復帰

    func testReEnablingWithCachedCurveReappliesDerivedValueWithoutMeasuring() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let coordinator = makeSyncCoordinator(measureCount: measureCount, responses: [c: autoPreampTestResponse(6)])
        var last: Double = 0
        coordinator.didDerive = { last = $0 }
        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 1, "前提")
        let derived = last

        coordinator.refresh(enabled: false, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: derived)
        let movedWhileOff = derived - 2 // OFF 中に外から動かされた想定値
        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: movedWhileOff)

        XCTAssertEqual(measureCount.value, 1, "キャッシュ命中のため測定は増えない")
        XCTAssertEqual(last, derived, "導出値が再適用される")
    }

    // MARK: - 外部書き込みの検出

    func testExternalPreampWriteWithUnchangedInputIsReappliedViaMemo() {
        let c = autoPreampTestCurve(1)
        let coordinator = makeSyncCoordinator(responses: [c: autoPreampTestResponse(6)])
        var last: Double = 0
        var derivedCount = 0
        coordinator.didDerive = { last = $0; derivedCount += 1 }
        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(derivedCount, 1, "前提")
        let derived = last

        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: derived - 1)

        XCTAssertEqual(derivedCount, 2, "memo に含めた適用済み preamp との不一致で再適用される")
        XCTAssertEqual(last, derived)
    }

    // MARK: - レート変更

    func testRateChangeIsANewMeasurementAndReturningRateDoesNotReMeasure() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let newRate = 96000.0
        let coordinator = AutoPreampCoordinator(
            measure: { _, rate in
                measureCount.update { $0 += 1 }
                return rate == newRate ? autoPreampTestResponse(3) : autoPreampTestResponse(6)
            },
            runMeasurement: { work in work() },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 1)
        let at48k = last

        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: newRate, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 2, "レートが違えば別の測定になる")
        XCTAssertNotEqual(last, at48k)

        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 2, "元のレートへ戻すと測定は増えない")
        XCTAssertEqual(last, at48k)
    }

    // MARK: - 畳み込み

    func testCoalescingKeepsMeasurementsRunningPlusLatestOnly() {
        let measureCount = Recorded(0)
        let c1 = autoPreampTestCurve(1), c2 = autoPreampTestCurve(2), c3 = autoPreampTestCurve(3)
        let (coordinator, runNext) = makeQueuedCoordinator(
            measureCount: measureCount,
            responses: [c1: autoPreampTestResponse(1), c2: autoPreampTestResponse(2), c3: autoPreampTestResponse(3)]
        )
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        coordinator.refresh(enabled: true, curve: c1, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 実行中
        coordinator.refresh(enabled: true, curve: c2, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 保留
        coordinator.refresh(enabled: true, curve: c3, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 保留を上書き
        XCTAssertEqual(measureCount.value, 0, "前提: まだ何も完了していない")

        XCTAssertTrue(runNext(), "c1 完了 → 保留 (c3) の測定が続けて積まれる")
        XCTAssertEqual(measureCount.value, 1)

        XCTAssertTrue(runNext(), "c3 完了")
        XCTAssertEqual(measureCount.value, 2, "実行中の 1 + 最新 1 の計 2 回に収まる (c2 は捨てられている)")

        XCTAssertFalse(runNext(), "以降は積まれない")
    }

    // MARK: - 測定失敗

    func testFailedMeasurementSkipsDeriveAndDoesNotSelfRetry() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let coordinator = AutoPreampCoordinator(
            measure: { _, _ in measureCount.update { $0 += 1 }; return nil },
            runMeasurement: { work in work() },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        var derivedCount = 0
        coordinator.didDerive = { _ in derivedCount += 1 }

        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: 0)

        XCTAssertEqual(measureCount.value, 1, "1 回の refresh に対し測定は 1 回だけ (自走しない)")
        XCTAssertEqual(derivedCount, 0, "失敗時は didDerive を呼ばない")
    }

    // MARK: - キャッシュ容量

    func testCacheEvictsOldestEntryBeyondCapacityAndReMeasuresIt() {
        let measureCount = Recorded(0)
        let c1 = autoPreampTestCurve(1), c2 = autoPreampTestCurve(2), c3 = autoPreampTestCurve(3)
        let coordinator = makeSyncCoordinator(
            measureCount: measureCount,
            responses: [c1: autoPreampTestResponse(1), c2: autoPreampTestResponse(2), c3: autoPreampTestResponse(3)],
            cacheCapacity: 2
        )
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        coordinator.refresh(enabled: true, curve: c1, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        coordinator.refresh(enabled: true, curve: c2, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        coordinator.refresh(enabled: true, curve: c3, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 3, "前提")

        coordinator.refresh(enabled: true, curve: c1, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 4, "容量超過で押し出された c1 は再測定される")

        coordinator.refresh(enabled: true, curve: c3, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(measureCount.value, 4, "c3 はまだキャッシュに残っている")
    }

    // MARK: - previewPreampDb
    func testPreviewPreampDbDoesNotTouchMemoOrCallDidDerive() {
        let c = autoPreampTestCurve(1)
        let coordinator = makeSyncCoordinator(responses: [c: autoPreampTestResponse(6)])
        var derivedCount = 0
        coordinator.didDerive = { _ in derivedCount += 1 }

        let firstResult = coordinator.previewPreampDb(curve: c, targetDb: 0, sampleRate: 48000, measureIfMissing: true)
        XCTAssertNil(firstResult, "未キャッシュの間は nil を返し、測定を要求する")
        XCTAssertEqual(derivedCount, 0, "previewPreampDb は didDerive を呼ばない")

        let secondResult = coordinator.previewPreampDb(curve: c, targetDb: 0, sampleRate: 48000, measureIfMissing: true)
        XCTAssertEqual(
            secondResult, AutoPreampSpec.derivedPreampDb(response: autoPreampTestResponse(6), targetDb: 0),
            "測定完了後はキャッシュから直接返す"
        )
        XCTAssertEqual(derivedCount, 0, "previewPreampDb はどの経路でも didDerive を呼ばない")
    }

    /// memo は「確立してから壊れていないこと」で判じる。未確立のまま呼んでも壊れようがない。
    func testPreviewPreampDbLeavesAnEstablishedMemoIntact() {
        let derived = autoPreampTestCurve(1), previewed = autoPreampTestCurve(2)
        let coordinator = makeSyncCoordinator(
            responses: [derived: autoPreampTestResponse(6), previewed: autoPreampTestResponse(3)]
        )
        var last: Double = 0
        var derivedCount = 0
        coordinator.didDerive = { last = $0; derivedCount += 1 }

        coordinator.refresh(enabled: true, curve: derived, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        XCTAssertEqual(derivedCount, 1)

        _ = coordinator.previewPreampDb(curve: previewed, targetDb: 0, sampleRate: 48000, measureIfMissing: true)
        coordinator.refresh(enabled: true, curve: derived, targetDb: 0, sampleRate: 48000, currentPreampDb: last)

        XCTAssertEqual(derivedCount, 1, "問い合わせ後も同じ入力での再入は memo で弾かれること")
    }
    func testPendingDerivationRequestTakesPriorityOverPendingPreviewRequest() {
        let measuredOrder = Recorded<[[Double]]>([])
        let curveA = autoPreampTestCurve(1), curveB = autoPreampTestCurve(2), curveC = autoPreampTestCurve(3)
        let pending = Recorded<[@Sendable () -> Void]>([])
        let coordinator = AutoPreampCoordinator(
            measure: { c, _ in
                measuredOrder.update { $0.append(c) }
                return autoPreampTestResponse(c.first ?? 0)
            },
            runMeasurement: { work in pending.update { $0.append(work) } },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let runNext: () -> Void = {
            let job = pending.update { queued -> (@Sendable () -> Void)? in
                guard !queued.isEmpty else { return nil }
                return queued.removeFirst()
            }
            job?()
        }
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        coordinator.refresh(enabled: true, curve: curveA, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 実行中
        coordinator.refresh(enabled: true, curve: curveB, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 保留 (導出用)
        _ = coordinator.previewPreampDb(curve: curveC, targetDb: 0, sampleRate: 48000, measureIfMissing: true) // 保留 (プレビュー用)

        runNext() // curveA 完了 → 導出用の保留 (curveB) の測定が続けて積まれる
        runNext() // curveB 完了

        XCTAssertEqual(measuredOrder.value, [curveA, curveB], "プレビューの保留が導出の保留を押し出さない")
    }

    /// 人が手で置いた直後に、実行中だった測定の結果で値が戻らないこと。
    func testMeasurementCompletingAfterDisableIsNotApplied() {
        let curve = autoPreampTestCurve(1)
        let (coordinator, runNext) = makeQueuedCoordinator(responses: [curve: autoPreampTestResponse(6)])
        var derivedCount = 0
        coordinator.didDerive = { _ in derivedCount += 1 }

        coordinator.refresh(enabled: true, curve: curve, targetDb: 0, sampleRate: 48000, currentPreampDb: 0) // 測定中
        coordinator.refresh(enabled: false, curve: curve, targetDb: 0, sampleRate: 48000, currentPreampDb: -2)

        XCTAssertTrue(runNext(), "前提: 実行中だった測定が完了する")

        XCTAssertEqual(derivedCount, 0, "自動 OFF 後に届いた測定結果は適用しないこと")
    }

    /// 保留が古くなる経路。実行中の測定を待つ間に入力がキャッシュ命中側へ動いたら、
    /// 途中の入力の測定はもう要らない。
    func testPendingRequestIsDroppedWhenTheInputMovesToACachedCurve() {
        let measuredOrder = Recorded<[[Double]]>([])
        let curveA = autoPreampTestCurve(1), curveB = autoPreampTestCurve(2), curveC = autoPreampTestCurve(3)
        let pending = Recorded<[@Sendable () -> Void]>([])
        let coordinator = AutoPreampCoordinator(
            measure: { c, _ in
                measuredOrder.update { $0.append(c) }
                return autoPreampTestResponse(c.first ?? 0)
            },
            runMeasurement: { work in pending.update { $0.append(work) } },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let runNext: () -> Void = {
            let job = pending.update { queued -> (@Sendable () -> Void)? in
                guard !queued.isEmpty else { return nil }
                return queued.removeFirst()
            }
            job?()
        }
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        // curveC を先に測ってキャッシュへ入れておく。
        coordinator.refresh(enabled: true, curve: curveC, targetDb: 0, sampleRate: 48000, currentPreampDb: last)
        runNext()
        measuredOrder.update { $0 = [] }

        coordinator.refresh(enabled: true, curve: curveA, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 実行中
        coordinator.refresh(enabled: true, curve: curveB, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 保留
        coordinator.refresh(enabled: true, curve: curveC, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // キャッシュ命中

        runNext() // curveA 完了
        runNext()

        XCTAssertEqual(measuredOrder.value, [curveA], "古くなった保留 (curveB) を測り直さないこと")
    }

    func testDisablingDiscardsThePendingDerivationRequest() {
        let measuredOrder = Recorded<[[Double]]>([])
        let curveA = autoPreampTestCurve(1), curveB = autoPreampTestCurve(2)
        let pending = Recorded<[@Sendable () -> Void]>([])
        let coordinator = AutoPreampCoordinator(
            measure: { c, _ in
                measuredOrder.update { $0.append(c) }
                return autoPreampTestResponse(c.first ?? 0)
            },
            runMeasurement: { work in pending.update { $0.append(work) } },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let runNext: () -> Void = {
            let job = pending.update { queued -> (@Sendable () -> Void)? in
                guard !queued.isEmpty else { return nil }
                return queued.removeFirst()
            }
            job?()
        }

        coordinator.refresh(enabled: true, curve: curveA, targetDb: 0, sampleRate: 48000, currentPreampDb: 0) // 実行中
        coordinator.refresh(enabled: true, curve: curveB, targetDb: 0, sampleRate: 48000, currentPreampDb: 0) // 保留
        coordinator.refresh(enabled: false, curve: curveB, targetDb: 0, sampleRate: 48000, currentPreampDb: 0)

        runNext() // curveA 完了。保留が残っていれば curveB がここで積まれる
        runNext()

        XCTAssertEqual(measuredOrder.value, [curveA], "自動 OFF で保留の測定要求が捨てられること")
    }

    func testDisablingDiscardsThePendingPreviewRequest() {
        let measuredOrder = Recorded<[[Double]]>([])
        let curveA = autoPreampTestCurve(1), curveB = autoPreampTestCurve(2)
        let pending = Recorded<[@Sendable () -> Void]>([])
        let coordinator = AutoPreampCoordinator(
            measure: { c, _ in
                measuredOrder.update { $0.append(c) }
                return autoPreampTestResponse(c.first ?? 0)
            },
            runMeasurement: { work in pending.update { $0.append(work) } },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let runNext: () -> Void = {
            let job = pending.update { queued -> (@Sendable () -> Void)? in
                guard !queued.isEmpty else { return nil }
                return queued.removeFirst()
            }
            job?()
        }

        coordinator.refresh(enabled: true, curve: curveA, targetDb: 0, sampleRate: 48000, currentPreampDb: 0) // 実行中
        _ = coordinator.previewPreampDb(curve: curveB, targetDb: 0, sampleRate: 48000, measureIfMissing: true) // 保留
        coordinator.refresh(enabled: false, curve: curveA, targetDb: 0, sampleRate: 48000, currentPreampDb: 0)

        runNext() // curveA 完了。保留が残っていれば curveB がここで積まれる
        runNext()

        XCTAssertEqual(measuredOrder.value, [curveA], "自動 OFF でプレビューの保留も捨てられること")
    }
    func testPendingRequestAlreadyCachedByTheTimeItIsTakenIsNotMeasuredAgain() {
        let measureCount = Recorded(0)
        let c = autoPreampTestCurve(1)
        let (coordinator, runNext) = makeQueuedCoordinator(
            measureCount: measureCount, responses: [c: autoPreampTestResponse(6)]
        )
        var last: Double = 0
        coordinator.didDerive = { last = $0 }

        coordinator.refresh(enabled: true, curve: c, targetDb: 0, sampleRate: 48000, currentPreampDb: last) // 実行中 (導出用)
        _ = coordinator.previewPreampDb(curve: c, targetDb: 0, sampleRate: 48000, measureIfMissing: true) // 同じカーブを保留 (プレビュー用)

        XCTAssertTrue(runNext(), "導出用の測定が完了しキャッシュへ入る")
        XCTAssertEqual(measureCount.value, 1, "保留 (プレビュー用) は取り出し時点で既にキャッシュ命中しており測定されない")
        XCTAssertFalse(runNext(), "追加の測定は積まれない")
    }
}
