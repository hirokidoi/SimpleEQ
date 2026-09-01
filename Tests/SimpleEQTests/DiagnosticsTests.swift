import XCTest
@testable import SimpleEQ

@MainActor
final class DiagnosticsTests: XCTestCase {

    // MARK: - 保持側 (観測量の取り込み)

    func testStartsFromInitialSnapshotWithoutReadingAudioWorld() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.snapshot, .initial(appliedSampleRate: AudioConfig.appliedSampleRate))
    }

    func testRefreshPullsFreshSnapshotFromEngine() {
        let (model, engine, audioWorld) = makeModelWithEngine()
        engine.runtimeMetrics.recordRead(requestedFrames: 100, deliveredFrames: 40)

        model.refresh()
        waitForAudioWorld(audioWorld) { model.snapshot.partialReadCount == 1 }

        XCTAssertEqual(model.snapshot.partialReadCount, 1, "定期更新のたびにエンジン側の最新値へ更新される")
    }

    func testResetDelegatesToEngineRuntimeMetricsReset() {
        let (model, audioWorld) = makeModel()
        XCTAssertNil(model.snapshot.lastResetAt)

        model.reset()
        waitForAudioWorld(audioWorld) { model.snapshot.lastResetAt != nil }

        XCTAssertNotNil(model.snapshot.lastResetAt)
    }

    // 表示と書き出しが同じ出所のレートを読む。
    func testSnapshotCarriesAppliedSampleRateForConversion() {
        let (model, audioWorld) = makeModel()
        model.refresh()
        drainAudioWorld(audioWorld)

        XCTAssertEqual(model.snapshot.appliedSampleRate, AudioConfig.appliedSampleRate)
    }

    // 記録しないと直前の値が現在の状態として残り、止まっているのに稼働中と見える。
    func testWriterStateBecomesUnobservedWhileNoReaderIsAttached() {
        let (model, engine, audioWorld) = makeModelWithEngine()
        engine.runtimeMetrics.recordWriterState(epoch: 1, ioIsRunning: true, ioCycleFrames: 512)

        model.refresh()
        drainAudioWorld(audioWorld)

        XCTAssertFalse(model.snapshot.readerObserved)
    }

    // 直前のデバイスの値を、今のデバイスの公称値として見せない。
    func testOutputDeviceSampleRateBecomesUnobservedWhileNoOutputIsAttached() {
        let (model, engine, audioWorld) = makeModelWithEngine()
        engine.runtimeMetrics.recordOutputDeviceSampleRate(96000)

        audioWorld.queue.sync { engine.refreshOutputDeviceSampleRate(testToken) }
        model.refresh()
        drainAudioWorld(audioWorld)

        XCTAssertEqual(model.snapshot.outputDeviceSampleRate, 0)
    }

    // MARK: - バージョン

    // 証跡を後から読んで、どのバージョンで取ったものかを判別できるようにする。
    func testVersionRowsCarryTheObservedValues() {
        let metrics = AudioRuntimeMetrics(appVersion: "9.9")
        metrics.recordReaderObserved(true)
        metrics.recordDriverVersions(driverVersion: DriverVersion(major: 7, minor: 3), layoutVersion: 42)
        let text = DiagnosticsReport.text(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate), exportedAt: Date())

        XCTAssertTrue(text.contains("アプリ version"))
        XCTAssertTrue(text.contains("9.9"))
        XCTAssertTrue(text.contains("ドライバ version"))
        XCTAssertTrue(text.contains("7.3"))
        XCTAssertTrue(text.contains("レイアウト version"))
        XCTAssertTrue(text.contains("42"))
    }

    // アプリバージョンは観測ではないため、読み手が居ない間も出る。
    func testDriverVersionRowsBecomeUnobservedWhileNoReaderIsAttached() {
        let metrics = AudioRuntimeMetrics(appVersion: "9.9")
        metrics.recordDriverVersions(driverVersion: DriverVersion(major: 7, minor: 3), layoutVersion: 42)
        metrics.recordReaderObserved(false)
        let rows = DiagnosticsReport.sections(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate))
            .flatMap(\.rows)

        XCTAssertEqual(rows.first { $0.title == "ドライバ version" }?.values, [unreadableValue])
        XCTAssertEqual(rows.first { $0.title == "レイアウト version" }?.values, [unreadableValue])
        XCTAssertEqual(rows.first { $0.title == "アプリ version" }?.values, ["9.9"])
    }

    func testAppVersionFallsBackToASpelledOutValue() {
        XCTAssertEqual(AppVersion.text(infoDictionary: nil), AppVersion.unavailableText)
        XCTAssertEqual(AppVersion.text(infoDictionary: ["CFBundleShortVersionString": "2.1"]), "2.1")
    }

    // MARK: - 項目定義

    // 画面と書き出しは同じ定義から作られるため、書き出しには全ての面と行の見出しが載る。
    func testExportTextCoversEveryRowOfEverySection() {
        let snapshot = AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        let text = DiagnosticsReport.text(snapshot, exportedAt: Date())

        for section in DiagnosticsReport.sections(snapshot) {
            XCTAssertTrue(text.contains(section.title), "面の見出しが書き出しに載る: \(section.title)")
            for row in section.rows {
                XCTAssertTrue(text.contains(row.title), "行が書き出しに載る: \(row.title)")
            }
        }
    }

    func testExportTextAnnotatesRowsWithTheirSubtitle() {
        let snapshot = AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        let text = DiagnosticsReport.text(snapshot, exportedAt: Date())

        XCTAssertTrue(text.contains("再プライミング (書き込みの停止 / 目標拡大)"))
    }

    func testOccupancyRowCarriesRawFramesForItsGauge() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordReaderObserved(true)
        metrics.recordOccupancyBounds(targetFrames: 1536, maxFrames: 4096)
        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)

        let gauges = DiagnosticsReport.sections(snapshot).flatMap { $0.rows }.compactMap { $0.gauge }
        XCTAssertEqual(gauges.count, 1, "ゲージを持つ行は 1 つ")
        XCTAssertEqual(gauges.first?.targetFrames, 1536)
        XCTAssertEqual(gauges.first?.maxFrames, 4096)
    }

    func testUnobservedRateIsShownAsUnobservedRatherThanZero() {
        let snapshot = AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        let identity = DiagnosticsReport.sections(snapshot).first { $0.title == "状態" }
        let outputRate = identity?.rows.first { $0.title == "出力デバイスの実レート" }

        XCTAssertEqual(outputRate?.values, [unreadableValue], "0 Hz と見せない")
    }

    // 保持はビットパターン往復のため、往復が壊れると無言で 0 のままになる。
    func testOutputDeviceSampleRateSurvivesTheRoundTripToTheSnapshot() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordOutputDeviceSampleRate(96000)
        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)

        XCTAssertEqual(snapshot.outputDeviceSampleRate, 96000)

        let identity = DiagnosticsReport.sections(snapshot).first { $0.title == "状態" }
        XCTAssertEqual(identity?.rows.first { $0.title == "出力デバイスの実レート" }?.values, ["96000 Hz"])
    }

    // 止まっているのに動いていると読めると、切り分けの前提を誤る。
    func testReaderWrittenValuesAreShownAsUnobservedWhileNoReaderIsAttached() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordWriterState(epoch: 2, ioIsRunning: true, ioCycleFrames: 1024)
        metrics.recordEffectiveWriterBlockFrames(512)
        metrics.recordOccupancyBounds(targetFrames: 1024, maxFrames: 2688)
        metrics.recordRingCapacity(32768)
        metrics.recordAvailable(900)
        metrics.recordReaderObserved(false)

        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        for title in [
            "ドライバの IO 稼働", "ドライバの世代カウンタ (epoch)", "ドライバの IO サイクル長",
            "ドライバのブロック長", "リング容量",
        ] {
            XCTAssertEqual(valuesOfRow(title, in: metrics), [unreadableValue], title)
        }
        XCTAssertEqual(valuesOfRow("目標バッファ量 / 上限バッファ量", in: metrics), [unreadableValue, unreadableValue])
        XCTAssertEqual(valuesOfRow("バッファ量", in: metrics), ["現在: " + unreadableValue, "目標: " + unreadableValue, "上限: " + unreadableValue])
        XCTAssertEqual(
            valuesOfRow("バッファ量 (窓統計)", in: metrics), ["最小: " + unreadableValue, "中央: " + unreadableValue, "最大: " + unreadableValue]
        )

        // 痕跡・累積はそのまま残す (読み手の生存に関わらず、それまでに起きたことを表すため)。
        XCTAssertEqual(snapshot.writerEpochAdvanceCount, 0)
        XCTAssertNotEqual(valuesOfRow("目標バッファ量の走行最大値", in: metrics), [unreadableValue])
    }

    // ファイル名と同じ現地時刻で書く。ずれると証跡の並びを読み違える。
    func testExportTimestampSharesTheWallClockWithTheFileName() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let text = DiagnosticsReport.text(
            AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate), exportedAt: date
        )

        let localClock = DateFormatter()
        localClock.locale = Locale(identifier: "en_US_POSIX")
        localClock.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        XCTAssertTrue(text.contains(localClock.string(from: date)))
    }

    // 時差の表記が落ちると、別の時間帯の証跡と前後を比べられなくなる。
    func testExportTimestampCarriesTheUTCOffset() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let text = DiagnosticsReport.text(
            AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate), exportedAt: date
        )

        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime]
        expected.timeZone = .current
        XCTAssertTrue(
            text.contains(expected.string(from: date)),
            "日付・時刻・時差までを一続きで書く"
        )
    }

    func testOutputDeviceSampleRateIsClearedWhenTheQueryFails() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordOutputDeviceSampleRate(96000)
        metrics.recordOutputDeviceSampleRate(0)

        let identity = DiagnosticsReport.sections(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate))
            .first { $0.title == "状態" }
        XCTAssertEqual(identity?.rows.first { $0.title == "出力デバイスの実レート" }?.values, [unreadableValue])
    }

    // バッファ量の行は観測の有無で行数が変わらない (変わると、その下の並び全体が動く)。
    func testBufferRowsKeepTheSameNumberOfValuesBeforeAndAfterObservation() {
        let unobserved = AudioRuntimeMetrics()
        unobserved.recordReaderObserved(true)
        let observed = AudioRuntimeMetrics()
        observed.recordReaderObserved(true)
        observed.recordAvailable(1200)

        for title in ["バッファ量", "バッファ量 (窓統計)"] {
            let before = valuesOfRow(title, in: unobserved)
            let after = valuesOfRow(title, in: observed)
            XCTAssertEqual(before?.count, after?.count, "\(title) の行数が観測の前後で変わらない")
        }
    }

    private func valuesOfRow(_ title: String, in metrics: AudioRuntimeMetrics) -> [String]? {
        DiagnosticsReport.sections(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate))
            .flatMap { $0.rows }.first { $0.title == title }?.values
    }

    func testExportTextIncludesPrimingSilenceDurationDerivedFromFrameCount() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordRead(requestedFrames: Int(AudioConfig.appliedSampleRate), deliveredFrames: 0)

        let report = DiagnosticsReport.text(
            metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate), exportedAt: Date()
        )

        let expectedDuration = OccupancyPolicy.formattedDuration(
            seconds: OccupancyPolicy.durationSeconds(frames: Int(AudioConfig.appliedSampleRate), sampleRate: AudioConfig.appliedSampleRate)
        )
        XCTAssertTrue(report.contains(expectedDuration), "無音の継続時間がフレーム数から導出されて載る")
    }

    func testExportTextShowsUnobservedAvailableWindowExplicitly() {
        let snapshot = AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        XCTAssertTrue(DiagnosticsReport.text(snapshot, exportedAt: Date()).contains(unreadableValue), "観測前は読めていないことを明示する (0 で偽装しない)")
    }

    func testExportTextShowsNoResetWhenNeverResetAndTimestampAfterReset() {
        let neverReset = DiagnosticsReport.text(
            AudioRuntimeMetrics().snapshot(appliedSampleRate: AudioConfig.appliedSampleRate), exportedAt: Date()
        )
        XCTAssertTrue(neverReset.contains("リセット: なし"))

        let metrics = AudioRuntimeMetrics()
        metrics.reset()
        let afterReset = DiagnosticsReport.text(
            metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate), exportedAt: Date()
        )
        XCTAssertFalse(afterReset.contains("リセット: なし"))
        XCTAssertTrue(afterReset.contains("経過時間:"))
    }

    // 振幅 0 は対数が定義できないため、数値ではなく下限で示す。
    func testPeakShowsAmplitudeWithItsDbfsAndHandlesSilence() {
        let silent = AudioRuntimeMetrics()
        XCTAssertEqual(
            valuesOfRow("ピーク", in: silent),
            ["音量適用前: 0.0000 (-inf. dBFS)", "音量適用後: 0.0000 (-inf. dBFS)"]
        )

        let loud = AudioRuntimeMetrics()
        loud.recordPeakBeforeVolume(2)
        loud.recordPeak(1)
        XCTAssertEqual(
            valuesOfRow("ピーク", in: loud),
            ["音量適用前: 2.0000 (6.0 dBFS)", "音量適用後: 1.0000 (0.0 dBFS)"]
        )
    }

    // 読み手が外れても、それまでの走行最大値の痕跡は縮まない。
    func testTargetOccupancyMaximumTakesItsBaselineFromWhetherTheReaderWasObservedAtReset() {
        let observedThenDetached = AudioRuntimeMetrics()
        observedThenDetached.recordReaderObserved(true)
        observedThenDetached.recordOccupancyBounds(targetFrames: 1024, maxFrames: 2688)
        observedThenDetached.reset()
        observedThenDetached.recordReaderObserved(false)
        XCTAssertEqual(
            observedThenDetached.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate).targetOccupancyFramesMax, 1024
        )

        // 読めていない間にリセットした回は、今の値でない目標を起点に置かない。
        let detachedAtReset = AudioRuntimeMetrics()
        detachedAtReset.recordReaderObserved(true)
        detachedAtReset.recordOccupancyBounds(targetFrames: 1024, maxFrames: 2688)
        detachedAtReset.recordReaderObserved(false)
        detachedAtReset.reset()
        XCTAssertEqual(detachedAtReset.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate).targetOccupancyFramesMax, 0)
    }

    // MARK: - 音量経路

    func testVolumeRouteRowShowsModeAndDeviceScalar() {
        let metrics = AudioRuntimeMetrics()
        let snapshot = metrics.snapshot(
            appliedSampleRate: AudioConfig.appliedSampleRate,
            volumeRoute: VolumeRouteObservation(
                volumeMode: .device, volumeDowngraded: false, volume: 0.5,
                muteMode: .app, muteDowngraded: false, muted: true
            )
        )

        let values = DiagnosticsReport.sections(snapshot).flatMap(\.rows).first { $0.title == "音量経路" }?.values
        XCTAssertEqual(values, ["デバイス 0.500 / アプリ ON"])
    }

    func testVolumeRouteRowFlagsDowngrade() {
        let metrics = AudioRuntimeMetrics()
        let snapshot = metrics.snapshot(
            appliedSampleRate: AudioConfig.appliedSampleRate,
            volumeRoute: VolumeRouteObservation(
                volumeMode: .app, volumeDowngraded: true, volume: 0.25,
                muteMode: .device, muteDowngraded: false, muted: false
            )
        )

        let values = DiagnosticsReport.sections(snapshot).flatMap(\.rows).first { $0.title == "音量経路" }?.values
        XCTAssertEqual(values, ["アプリ (降格) 0.250 / デバイス OFF"])
    }

    func testVolumeRouteRowMarksValueUnreadableWhileModeIsKnown() {
        let metrics = AudioRuntimeMetrics()
        let snapshot = metrics.snapshot(
            appliedSampleRate: AudioConfig.appliedSampleRate,
            volumeRoute: VolumeRouteObservation(
                volumeMode: .device, volumeDowngraded: false, volume: nil,
                muteMode: .device, muteDowngraded: false, muted: nil
            )
        )

        let values = DiagnosticsReport.sections(snapshot).flatMap(\.rows).first { $0.title == "音量経路" }?.values
        XCTAssertEqual(values, ["デバイス \(unreadableValue) / デバイス \(unreadableValue)"])
    }

    func testVolumeRouteRowIsUnreadableWhileUnbound() {
        let metrics = AudioRuntimeMetrics()
        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)

        let values = DiagnosticsReport.sections(snapshot).flatMap(\.rows).first { $0.title == "音量経路" }?.values
        XCTAssertEqual(values, ["\(unreadableValue) / \(unreadableValue)"])
    }

    // MARK: - ドライバの世代カウンタ

    func testWriterEpochKeepsCurrentValueAndAdvanceSinceReset() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordWriterState(epoch: 4, ioIsRunning: true, ioCycleFrames: 1024)
        metrics.reset()
        metrics.recordWriterState(epoch: 6, ioIsRunning: true, ioCycleFrames: 1024)

        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        XCTAssertEqual(snapshot.writerEpoch, 6, "現在値はそのまま出す")
        XCTAssertEqual(snapshot.writerEpochAdvanceCount, 2, "リセット以降に進んだ回数を出す")
    }

    // アプリ起動前にドライバが進めていたぶんを痕跡として数えない。
    func testWriterEpochAdvanceStartsFromTheFirstObservationBeforeAnyReset() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordWriterState(epoch: 9, ioIsRunning: true, ioCycleFrames: 1024)

        XCTAssertEqual(
            metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate).writerEpochAdvanceCount, 0,
            "観測し始めた時点では進んでいない"
        )

        metrics.recordWriterState(epoch: 10, ioIsRunning: true, ioCycleFrames: 1024)
        XCTAssertEqual(metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate).writerEpochAdvanceCount, 1)
    }

    // epoch は共有領域の用意し直しで 0 から始まり得るため、基準値を立て直す。
    func testWriterEpochReanchorsBaselineWhenDriverStartsOver() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordWriterState(epoch: 9, ioIsRunning: true, ioCycleFrames: 1024)
        metrics.reset()
        metrics.recordWriterState(epoch: 1, ioIsRunning: true, ioCycleFrames: 1024)

        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        XCTAssertEqual(snapshot.writerEpochAdvanceCount, 1, "0 から始まり直した後の進みが読める")
    }

    func testDriverWritePositionObservationsAllReachTheSnapshot() {
        let metrics = AudioRuntimeMetrics()
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: 11, presentationDeltaUnexpectedCount: 22,
            writeDeadlineMissedCount: 33, silenceFilledGapCount: 44
        )

        let snapshot = metrics.snapshot(appliedSampleRate: AudioConfig.appliedSampleRate)
        XCTAssertEqual(snapshot.presentationStallCount, 11)
        XCTAssertEqual(snapshot.presentationDeltaUnexpectedCount, 22)
        XCTAssertEqual(snapshot.writeDeadlineMissedCount, 33)
        XCTAssertEqual(snapshot.silenceFilledGapCount, 44)
    }

    // MARK: - 書き出し (窓を開かずに撃つ経路)

    // 画面が閉じていても、その場で取り直したスナップショットを書き出す。
    func testExportWritesSnapshotTakenAtThatMomentWithoutRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleeq-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, engine, audioWorld) = makeModelWithEngine(exportDirectory: directory)

        engine.runtimeMetrics.recordRead(requestedFrames: 100, deliveredFrames: 40)
        model.export()
        waitForAudioWorld(audioWorld, timeout: 3) { model.lastExport != nil }

        guard case .written(let fileName) = model.lastExport else { return XCTFail("書き出しの結果が残らない") }
        let written = try String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8)
        XCTAssertTrue(written.contains("部分読み"), "書き出しは項目定義から作られる")
        XCTAssertTrue(written.contains("1 回 / 60 frames"), "撃った時点の観測量が載る")
    }

    // 置き場の選び直しは永続化されない。
    func testExportDirectoryCanBeReplaced() {
        let (model, _) = makeModel()
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent("別の置き場")

        model.setExportDirectory(replacement)

        XCTAssertEqual(model.exportDirectory, replacement)
    }

    // 連番の探索には上限がある (常に存在すると答える状況でも返る)。
    func testAvailableURLStopsSearchingInsteadOfLoopingForever() {
        let directory = URL(fileURLWithPath: "/tmp/simpleeq-diagnostics-test")
        let url = DiagnosticsExport.availableURL(in: directory, at: Date(timeIntervalSince1970: 0)) { _ in true }

        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
    }

    // 用意できなければ渡さない (失敗は次の書き出しの結果として伝わる)。
    func testRevealExportDirectoryPreparesThePlaceBeforeHandingItOver() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleeq-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _, _) = makeModelWithEngine(exportDirectory: directory)

        var handed: URL?
        model.revealExportDirectory { handed = $0 }
        waitUntilSettled(timeout: 3) { handed != nil }

        XCTAssertEqual(handed?.path, directory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "用意してから渡す")
    }

    func testRevealExportDirectoryHandsNothingOverWhenThePlaceCannotBePrepared() {
        // 既存ファイルと同じ場所にはディレクトリを作れない。
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleeq-diagnostics-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let (model, _, _) = makeModelWithEngine(exportDirectory: file.appendingPathComponent("下"))

        var handed: URL?
        model.revealExportDirectory { handed = $0 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertNil(handed)
    }

    // MARK: - 書き出し先

    func testAvailableURLAvoidsOverwritingExistingEvidence() {
        let directory = URL(fileURLWithPath: "/tmp/simpleeq-diagnostics-test")
        let date = Date(timeIntervalSince1970: 0)
        let first = DiagnosticsExport.availableURL(in: directory, at: date) { _ in false }
        let second = DiagnosticsExport.availableURL(in: directory, at: date) { $0 == first }

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, DiagnosticsExport.fileName(at: date, sequence: 1))
    }

    func testDefaultDirectoryLivesUnderTheGivenLibraryDirectory() {
        let library = URL(fileURLWithPath: "/tmp/library")
        let directory = DiagnosticsExport.defaultDirectory(libraryDirectory: library)

        XCTAssertEqual(directory.deletingLastPathComponent().path, library.appendingPathComponent("Logs").path)
    }

    func testWriteReportsWrittenFileName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleeq-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = DiagnosticsExport.write("本文", into: directory, at: Date())

        guard case .written(let fileName) = outcome else { return XCTFail("書き出しが成功として返らない") }
        let written = try String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8)
        XCTAssertEqual(written, "本文")
    }

    func testWriteReportsFailureWhenDirectoryCannotBeCreated() {
        // 既存ファイルと同じ場所にはディレクトリを作れない。
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleeq-diagnostics-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }

        let outcome = DiagnosticsExport.write("本文", into: file.appendingPathComponent("下"), at: Date())

        guard case .failed = outcome else { return XCTFail("失敗が失敗として返らない") }
    }

    // MARK: - 組み立て

    private func makeModel() -> (DiagnosticsModel, AudioWorld) {
        let (model, _, audioWorld) = makeModelWithEngine()
        return (model, audioWorld)
    }

    private func makeModelWithEngine(
        exportDirectory: URL = FileManager.default.temporaryDirectory
    ) -> (DiagnosticsModel, AudioEngine, AudioWorld) {
        let audioWorld = makeTestAudioWorld()
        let engine = AudioEngine(audioWorld: audioWorld)
        let model = DiagnosticsModel(engine: engine, audioWorld: audioWorld, exportDirectory: exportDirectory)
        return (model, engine, audioWorld)
    }
}
