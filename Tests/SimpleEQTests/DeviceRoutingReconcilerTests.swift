import XCTest
import CoreAudio
import Foundation
import SimpleEQRingC
@testable import SimpleEQ

/// 有効な共有メモリヘッダのみを持つ最小のフィクスチャファイルを作る。呼び出し元がテスト終了時に削除すること。
private func makeMinimalSharedRingReaderFixture() -> URL {
    let headerBytes = UInt32(simpleeq_ring_header_size())
    let ringFrames: UInt32 = 64
    let channels: UInt32 = 1
    let totalSize = Int(headerBytes) + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size
    var data = Data(count: totalSize)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        raw.storeBytes(of: simpleeq_ring_expected_magic(), toByteOffset: 0, as: UInt32.self)
        raw.storeBytes(of: simpleeq_ring_expected_layout_version(), toByteOffset: 4, as: UInt32.self)
        raw.storeBytes(of: headerBytes, toByteOffset: 12, as: UInt32.self)
        raw.storeBytes(of: ringFrames, toByteOffset: 16, as: UInt32.self)
        raw.storeBytes(of: channels, toByteOffset: 20, as: UInt32.self)
        // 0 のままだと FFT サイズの導出等が破綻するため、基準レートを既定にしておく。
        raw.storeBytes(of: AudioConfig.baseSampleRate, toByteOffset: 24, as: Double.self)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceRoutingReconcilerTests-\(UUID().uuidString).shm")
    try! data.write(to: url)
    return url
}

/// 「あるべき出力先の UID」と「実際に指しているデバイス ID」を独立に設定でき、
/// 内蔵フォールバックによる張り替えと ID の入れ替わりを再現する。
/// この代役へ触れる経路は直列キューが順序を作るため、同時に触れることが無い。
final class MockAudioRoutingEngine: AudioRoutingEngine, ActivatableAudioEngine, @unchecked Sendable {
    var intendedOutputDeviceUID: String?
    var intendedOutputDeviceUIDAtSuspension: String?
    var processingState: ProcessingState = .active
    /// AUHAL が実際に指しているデバイス ID (読み返しの結果)。
    var actualOutputDeviceID: AudioDeviceID?
    var switchShouldSucceed = true
    var assembleShouldSucceed = true

    /// 書き手停止の判定結果。停止で真・組み立てで偽へ動かして実体の対応を再現する。
    var ringStalled = false

    private(set) var currentOutputDeviceIDCallCount = 0
    private(set) var switchCalls: [ResolvedOutputDevice] = []
    private(set) var driverDeviceIDUpdates: [AudioDeviceID?] = []
    private(set) var suspendCalls: [SuspensionCause] = []
    private(set) var assembleCalls: [ResolvedOutputDevice] = []

    func currentOutputDeviceID(_ token: AudioWorldToken) -> AudioDeviceID? {
        currentOutputDeviceIDCallCount += 1
        return actualOutputDeviceID
    }

    @discardableResult
    func switchOutputDevice(to device: ResolvedOutputDevice, _ token: AudioWorldToken) -> Bool {
        switchCalls.append(device)
        guard switchShouldSucceed else { return false }
        actualOutputDeviceID = device.deviceID
        intendedOutputDeviceUID = device.uid
        return true
    }

    /// リスナー群の登録先。実体と同じく、張替えで追従し、停止で解除され、組み立てで登録される。
    var driverDeviceListenerDeviceID: AudioDeviceID?

    func updateDriverDeviceID(_ id: AudioDeviceID?, _ token: AudioWorldToken) {
        driverDeviceIDUpdates.append(id)
        // 実体は監視のあるべき状態でゲートしており、それが立っていなければ ID を受け取っても登録しない。
        driverDeviceListenerDeviceID = processingState == .active ? id : nil
    }

    func evaluateRingStalled(_ token: AudioWorldToken) -> Bool { ringStalled }

    func suspend(cause: SuspensionCause, _ token: AudioWorldToken) {
        suspendCalls.append(cause)
        ringStalled = true
        guard processingState != .suspended(cause) else { return }
        intendedOutputDeviceUIDAtSuspension = intendedOutputDeviceUID ?? intendedOutputDeviceUIDAtSuspension
        intendedOutputDeviceUID = nil
        actualOutputDeviceID = nil
        // 実体は資源の解放でリスナーも解除する。
        driverDeviceListenerDeviceID = nil
        processingState = .suspended(cause)
    }

    @discardableResult
    func assemble(outputDevice: ResolvedOutputDevice, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        assembleCalls.append(outputDevice)
        guard assembleShouldSucceed else {
            processingState = .suspended(.routeUnavailable)
            return false
        }
        actualOutputDeviceID = outputDevice.deviceID
        intendedOutputDeviceUID = outputDevice.uid
        intendedOutputDeviceUIDAtSuspension = nil
        ringStalled = false
        // 実体は組み立ての中でリスナーを張る。
        driverDeviceListenerDeviceID = driverDeviceID
        processingState = .active
        return true
    }

    private(set) var reoccupyOutputVolumeRouteCallCount = 0

    func reoccupyOutputVolumeRoute(_ token: AudioWorldToken) {
        reoccupyOutputVolumeRouteCallCount += 1
    }
}

/// 合流窓の待ち合わせを実時間なしで駆動するスケジューラ。読み書きをロックの内側で行う。
final class ManualRoutingScheduler: Sendable {
    private let pending = Recorded<[@Sendable (AudioWorldToken) -> Void]>([])
    private let callCount = Recorded<Int>(0)

    var scheduleCallCount: Int { callCount.value }

    @Sendable func schedule(after: TimeInterval, work: @escaping @Sendable (AudioWorldToken) -> Void) {
        callCount.update { $0 += 1 }
        pending.update { $0.append(work) }
    }

    /// 溜まった待ちをすべて実行する。
    func fire() {
        let work = pending.update { taken -> [@Sendable (AudioWorldToken) -> Void] in
            defer { taken = [] }
            return taken
        }
        work.forEach { $0(testToken) }
    }
}

@MainActor
final class DeviceRoutingReconcilerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    nonisolated private let tempURLs = Recorded<[URL]>([])

    private let driverUID = "driver-device-uid"
    private let driverDeviceID: AudioDeviceID = 40
    private let speakerUID = "speaker-uid"
    private let speakerID: AudioDeviceID = 10
    private let speakerName = "スピーカー"
    private let hdmiUID = "hdmi-uid"
    private let hdmiID: AudioDeviceID = 11
    private let hdmiName = "HDMI"
    private let restoreTargetUID = "restore-target-uid"
    private let restoreTargetID: AudioDeviceID = 12

    // 同期版は隔離を持たず、この検証が保持する状態 (メイン隔離) を触れない。
    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("DeviceRoutingReconcilerTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        for url in tempURLs.value { try? FileManager.default.removeItem(at: url) }
        tempURLs.update { $0.removeAll() }
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// 是正パスが表示へ反映させた出力デバイスの履歴。
    private final class AdoptedDevices: Sendable {
        private let storage = Recorded<[ResolvedOutputDevice]>([])
        var last: ResolvedOutputDevice? { storage.value.last }
        func append(_ value: ResolvedOutputDevice) { storage.update { $0.append(value) } }
    }

    /// 是正パスが表示へ伝えた観測値の履歴。
    private final class ObservedFlags: Sendable {
        private let storage = Recorded<[Bool]>([])
        var last: Bool? { storage.value.last }
        func append(_ value: Bool) { storage.update { $0.append(value) } }
    }

    /// テスト対象と、その協力オブジェクト一式。
    private struct Fixture {
        let reconciler: DeviceRoutingReconciler
        let directory: MockAudioDeviceDirectory
        let engine: MockAudioRoutingEngine
        let lifecycle: DriverLifecycleController
        let outputController: OutputDeviceController
        let scheduler: ManualRoutingScheduler
        let adoptedDevices: AdoptedDevices
        let observedRingStalled: ObservedFlags
        let observedDefaultOutputReach: ObservedFlags

        var switchTargets: [ResolvedOutputDevice] { engine.switchCalls }
    }

    /// 「起動が完了し、スピーカーへ出力していて、ドライバは可視化済み」という定常状態を組み立てる。
    private func makeFixture(
        initialDriverDeviceID: AudioDeviceID? = nil,
        driverOwnedBySession: Bool = true,
        adoptsSystemOutputSelection: Bool = true,
        processingState: ProcessingState? = nil,
        openSharedMemory: @escaping @Sendable () -> Result<SharedRingReader, SharedRingReader.OpenFailure> = { .failure(.fileNotFound) },
        now: @escaping @Sendable () -> Date = Date.init
    ) -> Fixture {
        let directory = MockAudioDeviceDirectory()
        directory.hiddenDeviceIDsByUID[driverUID] = driverDeviceID
        directory.uidsByDeviceID[driverDeviceID] = driverUID
        directory.isHiddenByDeviceID[driverDeviceID] = false
        directory.deviceIDsByUID[speakerUID] = speakerID
        directory.uidsByDeviceID[speakerID] = speakerUID
        directory.deviceIDsByUID[hdmiUID] = hdmiID
        directory.uidsByDeviceID[hdmiID] = hdmiUID
        directory.deviceIDsByUID[restoreTargetUID] = restoreTargetID
        directory.uidsByDeviceID[restoreTargetID] = restoreTargetUID
        directory.namesByDeviceID[driverDeviceID] = DriverConfig.deviceName
        directory.namesByDeviceID[speakerID] = speakerName
        directory.namesByDeviceID[hdmiID] = hdmiName

        let engine = MockAudioRoutingEngine()
        let resolvedState = processingState ?? (driverOwnedBySession ? .active : .suspended(.routeUnavailable))
        engine.processingState = resolvedState
        if case .active = resolvedState {
            engine.intendedOutputDeviceUID = speakerUID
            engine.actualOutputDeviceID = speakerID
            engine.driverDeviceListenerDeviceID = driverDeviceID
        }

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = restoreTargetUID
        settings.switchPending = true

        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
        // 可視性の掌握は稼働状態とは別の軸として明示的に立てる。
        if driverOwnedBySession { lifecycle.reapplyVisibility(deviceID: driverDeviceID, testToken) }
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: driverUID)
        // 起動シーケンスが済んだ状態に合わせ、復帰対象の ID を解決済みにする。
        if driverOwnedBySession { outputController.refreshRestoreTarget(testToken) }
        directory.resetCallRecords()
        let scheduler = ManualRoutingScheduler()
        let adopted = AdoptedDevices()
        let observedRingStalled = ObservedFlags()
        let observedDefaultOutputReach = ObservedFlags()
        let activationCoordinator = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: openSharedMemory
        )
        let reconciler = DeviceRoutingReconciler(
            directory: directory, engine: engine, driverLifecycle: lifecycle,
            outputController: outputController, activationCoordinator: activationCoordinator,
            driverDeviceUID: driverUID, initialDriverDeviceID: initialDriverDeviceID,
            adoptsSystemOutputSelection: adoptsSystemOutputSelection,
            didAdoptOutputDevice: { device, _ in adopted.append(device) },
            didObserveDefaultOutputReach: { observedDefaultOutputReach.append($0) },
            didObserveRingStalled: { observedRingStalled.append($0) },
            audioWorld: makeTestAudioWorld(),
            schedule: scheduler.schedule,
            now: now
        )
        return Fixture(
            reconciler: reconciler, directory: directory, engine: engine, lifecycle: lifecycle,
            outputController: outputController, scheduler: scheduler, adoptedDevices: adopted,
            observedRingStalled: observedRingStalled, observedDefaultOutputReach: observedDefaultOutputReach
        )
    }

    /// 自動再開が実際に成立するよう、有効な共有メモリフィクスチャを開く openSharedMemory を作る。
    nonisolated private static func openValidSharedRingReader(
        registeringInto tempURLs: Recorded<[URL]>
    ) -> Result<SharedRingReader, SharedRingReader.OpenFailure> {
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        return SharedRingReader.open(path: url.path)
    }

    // MARK: - 契機と実施範囲 (純粋関数)

    func testScopeIsVerifyOnlyForPeriodicVerificationAndFullOtherwise() {
        XCTAssertEqual(deviceRoutingScope(trigger: .periodicVerification), .verifyOutputOnly)
        XCTAssertEqual(deviceRoutingScope(trigger: .configurationChange), .full)
        XCTAssertEqual(deviceRoutingScope(trigger: .explicit), .full)
    }

    func testVisibilityReapplyFollowsActualHiddenValue() {
        XCTAssertTrue(
            driverVisibilityReapplyNeeded(previousID: 40, resolvedID: 40, isHidden: true),
            "ID が変わらなくても非表示なら再適用する (ドライバ再ロードのみの経路)"
        )
        XCTAssertFalse(
            driverVisibilityReapplyNeeded(previousID: nil, resolvedID: 40, isHidden: false),
            "可視なら ID が変わっていても再適用しない"
        )
    }

    func testVisibilityReapplyFallsBackToIDChangeWhenHiddenValueUnreadable() {
        XCTAssertTrue(driverVisibilityReapplyNeeded(previousID: nil, resolvedID: 40, isHidden: nil))
        XCTAssertTrue(driverVisibilityReapplyNeeded(previousID: 40, resolvedID: 41, isHidden: nil))
        XCTAssertFalse(driverVisibilityReapplyNeeded(previousID: 40, resolvedID: 40, isHidden: nil))
    }

    func testListenerRebindNeededOnlyWhenResolvedIDChanged() {
        XCTAssertTrue(driverListenerRebindNeeded(previousID: nil, resolvedID: 40))
        XCTAssertTrue(driverListenerRebindNeeded(previousID: 40, resolvedID: 41))
        XCTAssertFalse(driverListenerRebindNeeded(previousID: 40, resolvedID: 40), "変化が無ければ打たない")
    }

    func testAliveListenerRebindActionsAreSetDifferences() {
        let actions = aliveListenerRebindActions(registered: [10, 40], desired: [11, 40])
        XCTAssertEqual(actions.remove, [10])
        XCTAssertEqual(actions.add, [11])
    }

    /// 固定名は切り詰めを通らない。上限を超えるとドライバが弾き、固定名への復帰が無言で失敗し続ける。
    func testFixedNameFitsWithinTheOverrideLimit() {
        XCTAssertLessThanOrEqual(DriverConfig.deviceName.utf16.count, DriverConfig.nameOverrideMaxLength)
    }

    func testDisplayNameFallsBackWhileTheOutputDestinationIsUnresolved() {
        XCTAssertEqual(
            DriverDisplayName.compose(outputDeviceName: nil, fallback: "Brand Audio 2ch", maxLength: 64),
            "Brand Audio 2ch",
            "出力先が解決できない間は固定名を名乗ること"
        )
        XCTAssertEqual(
            DriverDisplayName.compose(outputDeviceName: "", fallback: "Brand Audio 2ch", maxLength: 64),
            "Brand Audio 2ch",
            "空の名前は解決できていないのと同じ扱いにすること"
        )
    }

    /// ブランド部は固定名の先頭語から導く。固定名の表記が変わるとユーザに見える名前が黙って変わる。
    func testComposedNamePresentsTheProductBrandFirst() {
        XCTAssertTrue(
            DriverDisplayName.compose(
                outputDeviceName: "スピーカー", fallback: DriverConfig.deviceName,
                maxLength: DriverConfig.nameOverrideMaxLength
            ).hasPrefix("SimpleEQ - "),
            "OS 上で名乗る名前の先頭は製品名であること"
        )
    }

    func testDisplayNameCarriesTheOutputDestinationAfterTheBrand() {
        XCTAssertEqual(
            DriverDisplayName.compose(outputDeviceName: "スピーカー", fallback: "Brand Audio 2ch", maxLength: 64),
            "Brand - スピーカー"
        )
    }

    /// ドライバは上限を超える長さを弾く。切り詰めずに投げると書き込み自体が失敗する。
    func testDisplayNameIsTruncatedToTheLimitWithoutSplittingCharacters() {
        let composed = DriverDisplayName.compose(
            outputDeviceName: String(repeating: "あ", count: 100), fallback: "Brand Audio 2ch", maxLength: 16
        )
        XCTAssertEqual(composed.utf16.count, 16)
        XCTAssertTrue(composed.hasPrefix("Brand - "))

        let surrogates = DriverDisplayName.compose(
            outputDeviceName: String(repeating: "🎧", count: 10), fallback: "B", maxLength: 7
        )
        XCTAssertEqual(surrogates, "B - 🎧", "サロゲートペアを割らずに手前で止めること")
    }

    // MARK: - ドライバのデバイスの表示名

    func testDriverDeviceNameFollowsTheOutputDestination() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.directory.setNameCalls.last?.id, driverDeviceID)
        let applied = f.directory.setNameCalls.last?.name
        XCTAssertEqual(applied?.contains(speakerName), true, "実際に音を出しているデバイスの名前を含めること")
        XCTAssertNotEqual(applied, DriverConfig.deviceName)
    }

    func testDriverDeviceNameReturnsToTheFixedNameWhileProcessingIsStopped() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, processingState: .suspended(.driverOperation))
        f.directory.namesByDeviceID[driverDeviceID] = "残っている名前"

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(
            f.directory.setNameCalls.last?.name, DriverConfig.deviceName,
            "出力先が無い間は実態と食い違う名前を残さないこと"
        )
    }

    func testDriverDeviceNameIsNotRewrittenWhenItAlreadyMatches() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(
            f.directory.nameByDeviceIDCalls.contains(driverDeviceID),
            "2 巡目が表示名の判定へ到達していること (到達せず抜けた場合と区別する)"
        )
        XCTAssertTrue(f.directory.setNameCalls.isEmpty, "一致していれば書き込まないこと")
    }

    // MARK: - 表示名の波及 (デフォルト出力の往復)

    func testHandoffTargetRequiresBothAResolvedOutputAndAConfirmedOccupation() {
        XCTAssertEqual(
            driverDeviceNameHandoffTarget(outputDeviceID: speakerID, defaultOutputConfirmedAsDriver: true),
            speakerID
        )
        XCTAssertNil(
            driverDeviceNameHandoffTarget(outputDeviceID: nil, defaultOutputConfirmedAsDriver: true),
            "渡し先が無ければ打たないこと"
        )
        XCTAssertNil(
            driverDeviceNameHandoffTarget(outputDeviceID: speakerID, defaultOutputConfirmedAsDriver: false),
            "占有を確認できなければ打たないこと"
        )
    }

    /// 占有判定が読み取り不能を真へ倒すと、占有していないデフォルト出力を奪う。
    func testDefaultOutputOccupationJudgementsFallOppositeWaysWhenUnreadable() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = nil

        XCTAssertTrue(f.outputController.occupiesDefaultOutput(testToken), "切り戻す側は読めなければ占有とみなす")
        XCTAssertFalse(
            f.outputController.defaultOutputConfirmedAsDriver(testToken),
            "書き込む側は読めなければ占有とみなさない"
        )
    }

    func testDriverDeviceNameChangeHandsTheDefaultOutputOverAndTakesItBack() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(
            f.directory.setDefaultOutputCalls, [speakerID, driverDeviceID],
            "実出力先へ渡してから専用ドライバへ掴み直すこと"
        )
        XCTAssertEqual(f.directory.currentDefaultOutputID, driverDeviceID)
    }

    func testDefaultOutputIsNotTouchedWhenTheNameAlreadyMatches() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(
            f.directory.nameByDeviceIDCalls.contains(driverDeviceID),
            "2 巡目が表示名の判定へ到達していること (到達せず抜けた場合と区別する)"
        )
        XCTAssertTrue(f.directory.setNameCalls.isEmpty, "一致で止まっていること")
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "後続のパスで往復を繰り返さないこと")
    }

    /// 読めないまま書くと一致で止まれず、往復が合流窓ごとに終端せず続く。
    func testNothingIsWrittenWhileTheCurrentNameCannotBeRead() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.directory.namesByDeviceID[driverDeviceID] = nil
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(
            f.directory.nameByDeviceIDCalls.contains(driverDeviceID),
            "読み出しは試みること"
        )
        XCTAssertTrue(f.directory.setNameCalls.isEmpty, "読めない間は書かないこと")
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "往復も打たないこと")
    }

    func testDefaultOutputIsNotTouchedWhenTheNameCannotBeWritten() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.directory.setNameShouldSucceed = false
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertFalse(f.directory.setNameCalls.isEmpty, "書き込みは試みること")
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "書けていない名前を波及させないこと")
    }

    func testDefaultOutputIsNotTouchedWhenTheDriverDoesNotHoldItWhileAdoptionIsOff() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, adoptsSystemOutputSelection: false)
        f.directory.currentDefaultOutputID = speakerID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertFalse(f.directory.setNameCalls.isEmpty, "表示名の適用自体は行われること")
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "占有していなければ奪わないこと")
    }

    func testDefaultOutputIsNotTouchedWhenItCannotBeRead() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = nil
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "読み取れなければ奪わないこと")
    }

    func testTakeBackIsSkippedWhenTheHandoffItselfFails() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.directory.setDefaultOutputFailingDeviceIDs = [speakerID]
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(
            f.directory.setDefaultOutputCalls, [speakerID],
            "渡せていないなら掴み直す対象が無いこと"
        )
        XCTAssertEqual(f.directory.currentDefaultOutputID, driverDeviceID)
    }

    func testFailedTakeBackFallsBackToTheOccupyEntryPoint() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.directory.setDefaultOutputFailingDeviceIDs = [driverDeviceID]
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(
            f.directory.setDefaultOutputCalls, [speakerID, driverDeviceID, driverDeviceID],
            "掴み直せなければ占有の入口へ落とすこと"
        )
        let restoreState = f.outputController.currentRestoreState(testToken)
        XCTAssertEqual(restoreState.uid, speakerUID, "占有の入口を通ると復帰対象が現在のデフォルト出力へ移ること")
        XCTAssertTrue(restoreState.pending, "義務が立つこと")
    }

    func testRestoreObligationSurvivesASuccessfulRepublish() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        let before = f.outputController.currentRestoreState(testToken)
        XCTAssertTrue(before.pending, "義務が立った状態から始めること")
        XCTAssertEqual(before.uid, restoreTargetUID, "復帰対象が渡し先とは別のデバイスであること")

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(
            f.directory.setDefaultOutputCalls, [speakerID, driverDeviceID],
            "往復が実際に起きたうえで主張すること (打たれなければ当然動かない)"
        )
        let after = f.outputController.currentRestoreState(testToken)
        XCTAssertEqual(after.uid, restoreTargetUID, "往復で復帰対象が渡し先に書き換わらないこと")
        XCTAssertTrue(after.pending, "往復で義務が畳まれないこと")
    }

    func testCleanExitReturnsTheDriverDeviceToTheFixedName() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertNotEqual(
            f.directory.namesByDeviceID[driverDeviceID], DriverConfig.deviceName,
            "固定名とは違う名前を名乗った状態から始めること"
        )
        f.directory.resetCallRecords()

        f.lifecycle.restoreDisplayNameForCleanExit(testToken)

        XCTAssertEqual(f.directory.setNameCalls.last?.name, DriverConfig.deviceName)
    }

    func testDisplayNameIsNotComposedFromAnUnsafeRouteLeftAsALastResort() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = driverDeviceID
        // 出力先が自ドライバ自身になり、是正先も退避先も解決できない状態にする。
        f.engine.actualOutputDeviceID = driverDeviceID
        f.directory.deviceIDsByUID[speakerUID] = nil
        f.directory.deviceIDsByUID[restoreTargetUID] = nil
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.engine.suspendCalls, [.routeUnavailable], "退避に失敗して停止していること")
        XCTAssertTrue(
            f.directory.nameByDeviceIDCalls.contains(driverDeviceID),
            "表示名の判定へ到達していること"
        )
        XCTAssertTrue(
            f.directory.setNameCalls.isEmpty,
            "危険と判定した出力先から表示名を組み立てないこと (自分自身から合成すると名前が伸び続ける)"
        )
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "危険な経路へデフォルト出力を書き込まないこと")
    }

    // MARK: - (a)(c) 自ドライバのデバイス: ID 入れ替わりと可視性の復帰

    // AudioDeviceID が変わった場合、UID から解決し直した新 ID に対して可視化を打ち直し、リスナーも張り替える。
    func testDriverIsReresolvedAndMadeVisibleAgainAfterDeviceIDsChange() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        let renumberedDriverID: AudioDeviceID = 41
        f.directory.hiddenDeviceIDsByUID[driverUID] = renumberedDriverID
        f.directory.uidsByDeviceID[renumberedDriverID] = driverUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.directory.setHiddenCalls.map(\.hidden), [false])
        XCTAssertEqual(f.directory.setHiddenCalls.map(\.id), [renumberedDriverID])
        XCTAssertEqual(f.engine.driverDeviceIDUpdates, [renumberedDriverID])
        XCTAssertEqual(f.lifecycle.resolvedDeviceID, renumberedDriverID)
    }

    // ドライバが一旦解決できなくなり、同じ ID・非表示で戻ってきた場合も可視化を打ち直す。
    func testDriverVisibilityIsReappliedWhenDriverReappearsWithSameDeviceID() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.hiddenDeviceIDsByUID[driverUID] = nil
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty, "解決できない間は可視化を打たない")

        f.directory.hiddenDeviceIDsByUID[driverUID] = driverDeviceID
        f.directory.isHiddenByDeviceID[driverDeviceID] = true
        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.directory.setHiddenCalls.map(\.id), [driverDeviceID])
    }

    // 稼働中に自ドライバのデバイスを解決できない場合、検算はリスナー登録先の不一致として扱わず全実施へ昇格しない。
    func testPeriodicVerificationDoesNotEscalateWhenDriverDeviceUnresolvableWhileActive() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.hiddenDeviceIDsByUID[driverUID] = nil

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.directory.resolveHiddenDeviceIDCalls.count, 1, "全実施へ昇格していない")
    }

    // ID が一度も変わらないまま非表示へ戻された場合も復帰する。
    func testDriverVisibilityIsReappliedWhenHiddenWithoutIDChange() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.isHiddenByDeviceID[driverDeviceID] = true

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.directory.setHiddenCalls.map(\.id), [driverDeviceID])
    }

    // 本セッションが可視性を掌握していない起動では、是正パスも可視化しない。
    func testDriverIsNotMadeVisibleWhenSessionDoesNotOwnVisibility() {
        let f = makeFixture(driverOwnedBySession: false)
        f.directory.isHiddenByDeviceID[driverDeviceID] = true

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty)
    }

    // 掌握済みでも、現在の停止種別が可視性の維持を伴わない場合は再適用しない。
    func testVisibilityIsNotReappliedWhenSuspendedForDriverOperation() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, processingState: .suspended(.driverOperation))
        f.directory.isHiddenByDeviceID[driverDeviceID] = true

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty)
    }

    // 停止中でも「音声経路を構成できない」種別は可視性の維持を伴うため、掌握済みなら再適用が働く。
    func testVisibilityIsReappliedWhileSuspendedForRouteUnavailable() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable))
        f.directory.isHiddenByDeviceID[driverDeviceID] = true

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.directory.setHiddenCalls.map(\.id), [driverDeviceID])
    }

    // 復帰の義務が無い間は、打ち直しでも復帰対象を持たせない。
    func testRestoreTargetStaysUnsetWhenNothingToRestore() {
        let f = makeFixture(driverOwnedBySession: false)
        XCTAssertTrue(f.outputController.restore(testToken))

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertNil(f.outputController.resolvedRestoreTargetID)
    }

    // MARK: - (b)(d) 出力先: UID 起点の検証と是正 (稼働中)

    // 内蔵フォールバックが出力先を自ドライバのデバイスへ張り替えた場合、あるべき出力先の UID から解決し直して戻す。
    func testOutputIsRestoredWhenAUHALSwitchedToDriverDevice() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.actualOutputDeviceID = driverDeviceID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.switchTargets, [ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)])
    }

    // 別のデバイスが以前の ID を取ったケース。ID 比較では検出できないが、UID の食い違いで是正される。
    func testOutputIsCorrectedWhenAnotherDeviceTookTheSameDeviceID() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        // 出力先の ID は speakerID のままだが、その ID は HDMI を指すようになった。
        f.directory.uidsByDeviceID[speakerID] = hdmiUID
        f.directory.deviceIDsByUID[speakerUID] = 99
        f.directory.uidsByDeviceID[99] = speakerUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.switchTargets, [ResolvedOutputDevice(uid: speakerUID, deviceID: 99)])
    }

    // ID が総入れ替えになっても、読み返した出力先の UID があるべき状態と同じなら切替を起こさない。
    func testOutputIsNotSwitchedWhenDeviceIDChangedButUIDStillMatches() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        let renumberedSpeakerID: AudioDeviceID = 88
        f.engine.actualOutputDeviceID = renumberedSpeakerID
        f.directory.uidsByDeviceID[renumberedSpeakerID] = speakerUID
        f.directory.deviceIDsByUID[speakerUID] = renumberedSpeakerID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty)
    }

    // 出力先の UID があるべき状態と一致していても、そのデバイスが自ドライバを内包する構成に変わった場合は復帰対象へ退避する。
    func testOutputEvacuatesToRestoreTargetWhenIntendedDeviceStartedContainingDriver() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.containsDriverDeviceIDs = [speakerID]

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(
            f.directory.selectableOutputDeviceCalls, [speakerUID, restoreTargetUID],
            "あるべき出力先の UID の解決をやり直し、駄目なら復帰対象を試す"
        )
        XCTAssertEqual(f.switchTargets.map(\.uid), [restoreTargetUID])
        XCTAssertTrue(f.engine.suspendCalls.isEmpty, "退避できたので停止しない")
        XCTAssertEqual(
            f.adoptedDevices.last?.uid, restoreTargetUID,
            "退避先はあるべき出力先と別のデバイスなので、表示も実体へ合わせる必要がある"
        )
    }

    // 退避先も安全な経路として解決できない場合、是正パスは音声処理そのものを停止する。
    func testEngineIsSuspendedWhenNoEvacuationTargetExists() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.containsDriverDeviceIDs = [speakerID, restoreTargetID]

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty, "安全な退避先が無ければ出力先は変えない")
        XCTAssertEqual(f.engine.suspendCalls, [.routeUnavailable])
    }

    // あるべきデバイスが不在なだけで現在の出力先自体が安全なら、停止しない。
    func testEngineIsNotSuspendedWhenCurrentRouteIsSafe() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.deviceIDsByUID[speakerUID] = nil
        f.engine.actualOutputDeviceID = hdmiID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty)
        XCTAssertTrue(f.engine.suspendCalls.isEmpty)
    }

    // MARK: - 停止中の是正パス

    // 停止中 (自動再開の対象外の種別) は出力経路に一切触れない。
    func testSuspendedOutputRouteIsUntouchedWhenAutomaticResumeNotAllowed() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, processingState: .suspended(.driverOperation))

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty)
        XCTAssertEqual(f.engine.currentOutputDeviceIDCallCount, 0, "出力先を読み返さない")
        XCTAssertEqual(f.engine.processingState, .suspended(.driverOperation), "状態を書き換えない")
    }

    // MARK: - 復帰対象の打ち直しと実態追従

    // 復帰対象の AudioDeviceID が入れ替わっても、保存済み UID から解決し直して ID キャッシュを打ち直す。
    func testRestoreTargetIsReresolvedFromSavedUID() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        let renumberedRestoreID: AudioDeviceID = 66
        f.directory.deviceIDsByUID[restoreTargetUID] = renumberedRestoreID
        f.directory.uidsByDeviceID[renumberedRestoreID] = restoreTargetUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, renumberedRestoreID)
    }

    // 義務が残っているのに占有が既に解けている場合、定期の検算がこの食い違いを検出して義務を畳む。
    func testPeriodicVerificationEscalatesWhenRestoreObligationDivergesFromOccupancy() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, adoptsSystemOutputSelection: false)
        XCTAssertNotNil(f.outputController.resolvedRestoreTargetID, "前提: 復帰対象を解決済みの定常状態から始める")
        f.directory.currentDefaultOutputID = hdmiID
        f.directory.uidsByDeviceID[hdmiID] = hdmiUID

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertNil(f.outputController.resolvedRestoreTargetID, "占有が解けているので義務が畳まれる")
    }

    // MARK: - OS 側の出力先切替への追従

    // デフォルト出力が自ドライバ以外へ移ったら、その出力先を引き取ってデフォルト出力を掴み直す。
    func testAdoptionTakesOverTheNewDefaultOutputAndReoccupiesTheDriver() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.switchTargets.last, ResolvedOutputDevice(uid: hdmiUID, deviceID: hdmiID), "出力先を引き取る")
        XCTAssertEqual(f.directory.currentDefaultOutputID, driverDeviceID, "デフォルト出力を掴み直す")
        XCTAssertEqual(f.adoptedDevices.last, ResolvedOutputDevice(uid: hdmiUID, deviceID: hdmiID), "表示へ伝える")
        XCTAssertEqual(f.outputController.restoreTargetUID, hdmiUID, "復帰先が引き取った先になる")
        XCTAssertEqual(f.observedDefaultOutputReach.last, true, "音の届かない状態が解消したと観測される")
    }

    // 出力先を引き取れなかったら掴み直さない (掴み直しだけ済むと、引き継ぐ前の出力先から音が出続ける)。
    func testAdoptionDoesNotReclaimWhenTheOutputSwitchFails() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID
        f.engine.switchShouldSucceed = false
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "デフォルト出力を掴み直さない")
        XCTAssertEqual(f.directory.currentDefaultOutputID, hdmiID)
        XCTAssertNil(f.adoptedDevices.last, "表示へ採用を伝えない")
    }

    // 引き取り先が復帰の対象になり、クリーン終了でそこへ戻ること。
    func testAdoptionMakesTheTakenOverDestinationTheRestoreTargetThroughCleanExit() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.outputController.currentRestoreState(testToken).pending, "復帰の義務が立つ")
        XCTAssertEqual(f.outputController.restoreTargetUID, hdmiUID)

        XCTAssertTrue(f.outputController.restore(testToken), "占有が解ける")
        XCTAssertEqual(f.directory.currentDefaultOutputID, hdmiID, "引き取り先へ戻る")
        XCTAssertFalse(f.outputController.currentRestoreState(testToken).pending)
    }

    // 掴み直しの時点では、出力先が既に引き取り先へ移っていること
    // (順序が逆だと、出力先が切り替わるまでの間、引き継ぐ前の出力先から音が出る)。
    func testAdoptionSwitchesTheOutputBeforeReclaimingTheDefaultOutput() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID
        let intendedAtReclaim = Recorded<[String?]>([])
        let engine = f.engine
        let driverID = driverDeviceID
        f.directory.willSetDefaultOutput = { id in
            guard id == driverID else { return }
            intendedAtReclaim.update { $0.append(engine.intendedOutputDeviceUID) }
        }

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(intendedAtReclaim.value, [hdmiUID], "掴み直しの瞬間には出力先が引き取り先へ移っている")
    }

    // 掴み直し自体が新しい表示名を OS の表示へ運ぶため、名前を知らせるためのデフォルト出力の往復は起きない。
    func testAdoptionCarriesTheDriverNameWithoutRepublishingTheDefaultOutput() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID
        let nameAtReclaim = Recorded<[String?]>([])
        let directory = f.directory
        let driverID = driverDeviceID
        f.directory.willSetDefaultOutput = { id in
            guard id == driverID else { return }
            nameAtReclaim.update { $0.append(directory.namesByDeviceID[driverID]) }
        }
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.directory.setDefaultOutputCalls, [driverDeviceID], "デフォルト出力への書き込みは掴み直しの 1 回だけ")
        XCTAssertEqual(
            nameAtReclaim.value, [DriverDisplayName.compose(
                outputDeviceName: hdmiName, fallback: DriverConfig.deviceName, maxLength: DriverConfig.nameOverrideMaxLength
            )],
            "掴み直しの瞬間には表示名が引き取り先を指している"
        )
    }

    // 引き取れない相手に移ったままでも、定期の検算が是正へ昇格し続けない
    // (復帰対象を追随させる 1 回で収まり、以後は読み出しのみで済む)。
    func testPeriodicVerificationSettlesWhenTheNewDefaultOutputCannotBeAdopted() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.airPlayDeviceIDs = [hdmiID]
        f.directory.currentDefaultOutputID = hdmiID
        f.reconciler.reconcile(trigger: .periodicVerification, testToken)
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "デフォルト出力へ書き込まない")
        XCTAssertTrue(f.directory.setNameCalls.isEmpty, "表示名へ書き込まない")
        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty, "可視性へ書き込まない")
        XCTAssertTrue(f.engine.switchCalls.isEmpty, "出力先を切り替えない")
    }

    // 掴み直したあとは実状態があるべき状態と一致するため、書き込みを増やさない。
    func testAdoptionStopsOnceTheDriverHoldsTheDefaultOutputAgain() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        let switchCountAfterAdoption = f.switchTargets.count
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.switchTargets.count, switchCountAfterAdoption, "出力先を切り替え直さない")
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty, "デフォルト出力へ書き込まない")
    }

    // 定期の検算は読み出しのみだが、追従が要る状態は一致していないものとして是正へ昇格する。
    func testPeriodicVerificationEscalatesToAdoption() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.currentDefaultOutputID = hdmiID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.switchTargets.last, ResolvedOutputDevice(uid: hdmiUID, deviceID: hdmiID))
        XCTAssertEqual(f.directory.currentDefaultOutputID, driverDeviceID)
    }

    // AirPlay は出力候補にならないため引き取らない。
    func testAdoptionIsSkippedWhenTheNewDefaultOutputIsAirPlay() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.airPlayDeviceIDs = [hdmiID]
        f.directory.currentDefaultOutputID = hdmiID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty, "出力先を引き取らない")
        XCTAssertEqual(f.directory.currentDefaultOutputID, hdmiID, "デフォルト出力を奪わない")
    }

    // 自ドライバを内包する Aggregate/Multi-Output は、音がドライバへ届いているため引き取りの対象にならない。
    func testAdoptionIsSkippedWhenTheNewDefaultOutputContainsTheDriver() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.containsDriverDeviceIDs = [hdmiID]
        f.directory.currentDefaultOutputID = hdmiID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty, "出力先を引き取らない")
        XCTAssertEqual(f.directory.currentDefaultOutputID, hdmiID, "デフォルト出力を奪わない")
    }

    // 停止中は引き取らない (出力先は再開の経路が決める)。
    func testAdoptionIsSkippedWhileProcessingIsSuspended() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, processingState: .suspended(.driverOperation))
        f.directory.currentDefaultOutputID = hdmiID
        f.directory.resetCallRecords()

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.switchCalls.isEmpty, "出力先を引き取らない")
        XCTAssertEqual(f.directory.currentDefaultOutputID, hdmiID, "デフォルト出力を奪わない")
    }

    // 設定の切替は、その後の是正から効く。
    func testAdoptionFollowsTheSettingSwitchedWhileRunning() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, adoptsSystemOutputSelection: false)
        f.directory.currentDefaultOutputID = hdmiID
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertTrue(f.engine.switchCalls.isEmpty, "前提: 切っている間は引き取らない")

        f.reconciler.setAdoptsSystemOutputSelection(true, testToken)
        f.reconciler.reconcile(trigger: .explicit, testToken)

        XCTAssertEqual(f.switchTargets.last, ResolvedOutputDevice(uid: hdmiUID, deviceID: hdmiID))
        XCTAssertEqual(f.directory.currentDefaultOutputID, driverDeviceID)
    }

    // MARK: - (e) 冪等性

    // 実状態があるべき状態と一致していれば、何度呼んでも書き込み (可視化・切替) を増やさない。
    func testRepeatedReconcileDoesNotAccumulateSideEffects() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)

        f.reconciler.reconcile(trigger: .explicit, testToken)
        f.reconciler.reconcile(trigger: .explicit, testToken)
        f.reconciler.reconcile(trigger: .explicit, testToken)

        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty, "解決 ID が変わっていなければ可視化は打たない")
        XCTAssertTrue(f.engine.switchCalls.isEmpty)
    }

    // ID 入れ替わりを 1 度是正した後は、続けて呼んでも再度の是正は起きない。
    func testCorrectionIsAppliedOnceAndNotRepeated() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.actualOutputDeviceID = driverDeviceID

        f.reconciler.reconcile(trigger: .explicit, testToken)
        f.reconciler.reconcile(trigger: .explicit, testToken)

        XCTAssertEqual(f.engine.switchCalls.count, 1)
    }

    // MARK: - (f) 契機別のコスト上限

    // 定期の検算は読み出しのみで、実状態があるべき状態と一致していれば書き込みも UID 解決も行わない。
    func testPeriodicVerificationOnlyReadsWhenEverythingMatches() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.engine.currentOutputDeviceIDCallCount, 1)
        XCTAssertEqual(f.directory.uidByDeviceIDCalls, [speakerID])
        // ID 解決を読むのは復帰対象の食い違いチェックのみ。
        XCTAssertEqual(f.directory.deviceIDByUIDCalls, [restoreTargetUID])
        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty)
        XCTAssertTrue(f.engine.switchCalls.isEmpty)
        XCTAssertTrue(f.directory.setDefaultOutputCalls.isEmpty)
        XCTAssertEqual(f.engine.reoccupyOutputVolumeRouteCallCount, 0)
    }

    // 音量経路の束ね直しは、書き込みを伴う是正へ到達したときにだけ起こす。
    func testWriteBearingReconcileRebindsOutputVolumeRoute() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.engine.reoccupyOutputVolumeRouteCallCount, 1)
    }

    func testPeriodicVerificationRebindsOutputVolumeRouteOnlyAfterEscalation() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.actualOutputDeviceID = hdmiID

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.engine.reoccupyOutputVolumeRouteCallCount, 1)
    }

    // リスナーの登録先が失効している状態を、定期検算が不一致として検出し、張り直しに至る。
    func testPeriodicVerificationDetectsStaleDriverListenerRegistration() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        let reassignedDriverDeviceID: AudioDeviceID = 41

        // coreaudiod の再起動などで ID が振り直され、ドライバは非表示へ戻っている状態。
        f.directory.hiddenDeviceIDsByUID[driverUID] = reassignedDriverDeviceID
        f.directory.uidsByDeviceID[reassignedDriverDeviceID] = driverUID
        f.directory.isHiddenByDeviceID[reassignedDriverDeviceID] = true
        f.directory.deviceIDsByUID[driverUID] = nil

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(
            f.engine.driverDeviceIDUpdates.last, reassignedDriverDeviceID,
            "失効した登録先を検出し、新しい ID でリスナーを張り直す"
        )
    }

    // 停止中はリスナーを張らないことがあるべき状態であり、登録先が空であることを不一致として扱わない。
    func testPeriodicVerificationDoesNotEscalateForAbsentListenerWhileSuspended() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID,
            processingState: .suspended(.driverOperation)
        )
        f.engine.driverDeviceListenerDeviceID = nil

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertTrue(f.engine.driverDeviceIDUpdates.isEmpty, "全実施へ昇格せず、張り直しも行わない")
        XCTAssertTrue(f.directory.setHiddenCalls.isEmpty, "書き込みも行わない")
    }

    // 検算で不一致を見つけたときだけ全実施へ昇格する。
    func testPeriodicVerificationEscalatesToFullPassOnMismatch() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.actualOutputDeviceID = hdmiID

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.switchTargets, [ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)])
        XCTAssertFalse(f.directory.resolveHiddenDeviceIDCalls.isEmpty, "全実施ではドライバの解決も行う")
    }

    // 復帰対象の ID キャッシュが現在の解決結果と食い違っていれば検算が全実施へ昇格する。
    func testPeriodicVerificationEscalatesWhenRestoreTargetIsStale() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        let renumberedRestoreTargetID: AudioDeviceID = 99
        f.directory.deviceIDsByUID[restoreTargetUID] = renumberedRestoreTargetID
        f.directory.uidsByDeviceID[renumberedRestoreTargetID] = restoreTargetUID

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, renumberedRestoreTargetID)
    }

    // 出力先があるべき状態と一致する UID でも、その経路自体が危険側へ変わっていれば検算が全実施へ昇格する。
    func testPeriodicVerificationEscalatesWhenIntendedRouteBecameUnsafe() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.containsDriverDeviceIDs = [speakerID]

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.switchTargets.map(\.uid), [restoreTargetUID])
    }

    // 音を消費している間にドライバが非表示へ戻されたら検算が全実施へ昇格する。
    func testPeriodicVerificationEscalatesWhenDriverBecameHidden() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.directory.isHiddenByDeviceID[driverDeviceID] = true

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.directory.setHiddenCalls.map(\.id), [driverDeviceID])
    }

    // 音声処理が止まった後も、デフォルト出力が自ドライバへ向いている限り復帰対象の打ち直しは続く。
    func testRestoreTargetIsStillRefreshedAfterProcessingSuspended() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.processingState = .suspended(.driverOperation)
        let renumberedRestoreTargetID: AudioDeviceID = 99
        f.directory.deviceIDsByUID[restoreTargetUID] = renumberedRestoreTargetID
        f.directory.uidsByDeviceID[renumberedRestoreTargetID] = restoreTargetUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, renumberedRestoreTargetID)
    }

    // MARK: - 停止中の自動再開

    // 停止中にあるべき出力先の UID (停止直前に保持した値) が解決できるようになると自動再開する。
    func testAutomaticResumeUsesIntendedOutputDeviceUIDAtSuspension() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = speakerUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.engine.assembleCalls, [ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)])
        XCTAssertEqual(f.engine.processingState, .active)
    }

    // あるべき出力先の UID が解決できず、復帰対象 UID が解決できる場合も自動再開する。
    func testAutomaticResumeFallsBackToRestoreTargetUID() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = nil // 起動時に一度も稼働していない停止を模す

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.engine.assembleCalls, [ResolvedOutputDevice(uid: restoreTargetUID, deviceID: restoreTargetID)])
        XCTAssertEqual(f.engine.processingState, .active)
    }

    // どちらの UID も解決できない場合、起動時の自動選択のように別のデバイスを選んで再開することはない。
    func testAutomaticResumeDoesNotFallBackToAutomaticSelection() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = "missing-uid"
        f.directory.deviceIDsByUID[restoreTargetUID] = nil // 復帰対象も解決できなくする

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.assembleCalls.isEmpty)
        XCTAssertEqual(f.engine.processingState, .suspended(.routeUnavailable))
    }

    // 再起動を前提とする停止種別では、あるべき出力先が戻っても自動再開しない。
    func testAutomaticResumeDoesNotHappenForRestartRequiredCauses() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.driverOperation),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = speakerUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.engine.assembleCalls.isEmpty)
        XCTAssertEqual(f.engine.processingState, .suspended(.driverOperation))
    }

    func testPeriodicVerificationEscalatesAndResumesWhenAutomaticResumeBecomesPossible() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = speakerUID

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertEqual(f.engine.assembleCalls, [ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)])
        XCTAssertEqual(f.engine.processingState, .active)
    }

    // 停止中にどちらの UID も解決できない間は、検算が一致を返し全実施へ昇格しない。
    func testPeriodicVerificationDoesNotEscalateWhenAutomaticResumeTargetUnresolvable() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = "missing-uid"
        f.directory.containsDriverDeviceIDs = [restoreTargetID]

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertTrue(f.engine.assembleCalls.isEmpty)
        XCTAssertEqual(f.directory.resolveHiddenDeviceIDCalls.count, 1, "全実施へ昇格していない")
    }

    // MARK: - 書き手停止の観測

    // 是正パスを終えた時点の値を観測する。同じパスの中で再開が成立した場合、観測されるのは再開後の値。
    func testRingStallIsObservedAfterResumeWithinTheSamePass() {
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = speakerUID
        f.engine.ringStalled = true

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertEqual(f.engine.processingState, .active, "前提: このパスの中で再開が成立している")
        XCTAssertEqual(f.observedRingStalled.last, false, "再開後の値を観測する")
    }

    // 出力先の選び直しによる再開は明示操作の契機からこのパスへ入る。
    func testRingStallIsObservedOnExplicitTrigger() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.ringStalled = false

        f.reconciler.reconcile(trigger: .explicit, testToken)

        XCTAssertEqual(f.observedRingStalled.last, false)
    }

    // 検算が実状態をあるべき状態と一致していると判断して早期に戻る経路でも観測する。
    func testRingStallIsObservedEvenWhenVerificationReturnsEarly() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.ringStalled = true

        f.reconciler.reconcile(trigger: .periodicVerification, testToken)

        XCTAssertTrue(f.engine.assembleCalls.isEmpty, "前提: 是正は行われていない")
        XCTAssertEqual(f.observedRingStalled.last, true)
    }

    // MARK: - 自動再開の抑制 (試行間隔・連続失敗の上限)

    // 注入した時刻源で試行の回数と間隔を固定する。試行の発生は openSharedMemory の呼び出し回数で数える。
    func testAutomaticResumeIsThrottledByRetryIntervalAndCappedAtMaxConsecutiveFailures() {
        let currentTime = Recorded<Date>(Date(timeIntervalSince1970: 0))
        let attemptCount = Recorded<Int>(0)
        let f = makeFixture(
            initialDriverDeviceID: driverDeviceID, processingState: .suspended(.routeUnavailable),
            openSharedMemory: { attemptCount.update { $0 += 1 }; return .failure(.fileNotFound) },
            now: { currentTime.value }
        )
        f.engine.intendedOutputDeviceUIDAtSuspension = speakerUID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertEqual(attemptCount.value, 1, "初回は即座に試行される")

        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertEqual(attemptCount.value, 1, "再試行間隔内は試行を重ねない")

        currentTime.update { $0 = $0.addingTimeInterval(DeviceRoutingReconciler.automaticResumeRetryInterval) }
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertEqual(attemptCount.value, 2, "間隔が空けば再試行する")

        let remainingAttemptsUntilCap = DeviceRoutingReconciler.automaticResumeMaxConsecutiveFailures - attemptCount.value
        for _ in 0..<remainingAttemptsUntilCap {
            currentTime.update { $0 = $0.addingTimeInterval(DeviceRoutingReconciler.automaticResumeRetryInterval) }
            f.reconciler.reconcile(trigger: .configurationChange, testToken)
        }
        XCTAssertEqual(attemptCount.value, DeviceRoutingReconciler.automaticResumeMaxConsecutiveFailures, "前提: 上限まで連続失敗させた")

        currentTime.update { $0 = $0.addingTimeInterval(DeviceRoutingReconciler.automaticResumeRetryInterval) }
        f.reconciler.reconcile(trigger: .configurationChange, testToken)
        XCTAssertEqual(
            attemptCount.value, DeviceRoutingReconciler.automaticResumeMaxConsecutiveFailures,
            "連続失敗が上限に達すると、間隔が空いても試行しなくなる"
        )
    }

    // MARK: - (g) 構成変更通知の合流

    // ディスプレイスリープ復帰では通知が連続発火する。合流窓の間に届いた通知は 1 回のパスへ束ねる。
    func testBurstOfConfigurationChangeNotificationsCollapsesIntoSinglePass() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        f.engine.actualOutputDeviceID = driverDeviceID

        f.reconciler.scheduleConfigurationChangeReconcile(testToken)
        f.reconciler.scheduleConfigurationChangeReconcile(testToken)
        f.reconciler.scheduleConfigurationChangeReconcile(testToken)

        XCTAssertEqual(f.scheduler.scheduleCallCount, 1, "窓が開いている間の通知は既存の待ちへ束ねる")
        XCTAssertTrue(f.engine.switchCalls.isEmpty, "窓が閉じるまでは是正しない")

        f.scheduler.fire()
        XCTAssertEqual(f.engine.switchCalls.count, 1)

        // 窓が閉じた後の通知は次のパスとして受け付ける。
        f.reconciler.scheduleConfigurationChangeReconcile(testToken)
        XCTAssertEqual(f.scheduler.scheduleCallCount, 2)
    }

    // MARK: - シナリオとして通す検証
    //
    // 協力オブジェクトを実物のまま組み合わせ、モックはデバイス台帳と音声エンジンの境界だけに限り、
    // 単発の呼び出しではなく一連の遷移として駆動する。

    // 稼働中 → 出力デバイスが消える → 退避に失敗 → 停止 → 別デバイスを選択 → 再開 → 出力経路が安全で復帰対象が解決済みであること。
    // あるべき出力先を台帳から除き、退避先候補も退避不能にして駆動する。
    func testScenarioK2StopThenResumeToAnotherDeviceAfterEvacuationFails() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID)
        XCTAssertEqual(f.engine.processingState, .active, "前提: 稼働中")
        XCTAssertNotNil(f.outputController.resolvedRestoreTargetID, "前提: 復帰対象は解決済み")

        // 出力デバイスが消える (あるべき出力先が解決できなくなり、退避先も退避不能になる)
        // → AUHAL 内蔵のフォールバックで実際の出力先が自ドライバ自身へ切り替わる。
        f.directory.deviceIDsByUID[speakerUID] = nil
        f.directory.containsDriverDeviceIDs = [restoreTargetID]
        f.engine.actualOutputDeviceID = driverDeviceID

        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        // 退避に失敗 → 停止。
        XCTAssertTrue(f.engine.switchCalls.isEmpty, "安全な退避先が無いので出力先は変えない")
        XCTAssertEqual(f.engine.suspendCalls, [.routeUnavailable])
        XCTAssertEqual(f.engine.processingState, .suspended(.routeUnavailable))
        // 警告の識別子が「出力先の選び直し要」。
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .ok, processingState: f.engine.processingState, ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .outputRouteSelectionRequired
        )
        // 復帰対象は (退避には使えなくても) UID→ID の解決自体は保たれ続ける。
        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, restoreTargetID)

        // 別デバイス (hdmi、退避不能にした restoreTargetID とは別) を選択 → 再開。
        let coordinator = AudioActivationCoordinator(
            engine: f.engine, driverLifecycle: f.lifecycle, outputController: f.outputController,
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        let chosen = ResolvedOutputDevice(uid: hdmiUID, deviceID: hdmiID)
        let resumeOutcome = coordinator.resume(outputDevice: chosen, trigger: .userSelection, testToken)
        XCTAssertEqual(resumeOutcome.processingState, .active)
        XCTAssertEqual(f.engine.assembleCalls, [chosen])

        // 選択成功後に呼ぶのと同じ経路 (是正の再突き合わせ)。
        f.reconciler.reconcile(trigger: .explicit, testToken)

        // 出力経路が安全 (選び直した先が是正の対象にならない = 追加の switch が発生しない)。
        XCTAssertTrue(f.engine.switchCalls.isEmpty)
        // ドライバの可視性が維持される。
        XCTAssertTrue(f.lifecycle.isVisibilityOwnedBySession)
        XCTAssertTrue(f.directory.setHiddenCalls.allSatisfy { !$0.hidden }, "非表示化はされない")
        // 復帰対象が解決済みであること。
        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, restoreTargetID)
    }

    // 起動切替で占有 → ユーザが別デバイスへ移す → 義務が畳まれる → 自ドライバへ戻す → 義務が再び立つ → クリーン終了で元のデバイスへ復帰し、ドライバが非表示化されること。
    func testScenarioK1RestoreObligationFollowsOccupancyThroughCleanExit() {
        let f = makeFixture(initialDriverDeviceID: driverDeviceID, adoptsSystemOutputSelection: false)
        // 起動切替がまだ行われていないクリーンな状態へ戻してから、このシナリオの手順で組み立て直す。
        let settings = SettingsStore(defaults: defaults)
        settings.switchPending = false
        settings.savedDefaultOutputUID = nil
        f.directory.currentDefaultOutputID = restoreTargetID // 起動前のユーザの選択。
        f.directory.resetCallRecords()

        // 起動切替で占有。
        XCTAssertTrue(f.outputController.occupyDefaultOutputForDriver(driverDeviceID: driverDeviceID, testToken))
        XCTAssertTrue(f.outputController.currentRestoreState(testToken).pending)
        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, restoreTargetID)
        XCTAssertEqual(f.directory.currentDefaultOutputID, driverDeviceID)

        // ユーザがデフォルト出力を別デバイス (hdmi) へ移す。
        f.directory.currentDefaultOutputID = hdmiID
        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertFalse(f.outputController.currentRestoreState(testToken).pending, "占有が解けたので義務が畳まれる")
        XCTAssertNil(f.outputController.resolvedRestoreTargetID)
        XCTAssertEqual(f.outputController.restoreTargetUID, hdmiUID, "離脱時点のデフォルト出力が次の復帰先になる")

        // 自ドライバへ戻す (本セッションが切替を行ったことがあるため義務が再び立つ対象になる)。
        f.directory.currentDefaultOutputID = driverDeviceID
        f.reconciler.reconcile(trigger: .configurationChange, testToken)

        XCTAssertTrue(f.outputController.currentRestoreState(testToken).pending, "占有が戻ったので義務が再び立つ")
        XCTAssertEqual(f.outputController.resolvedRestoreTargetID, hdmiID)

        // クリーン終了: 元のデバイス (hdmi) へ復帰し、ドライバを非表示化する。
        XCTAssertTrue(f.outputController.restore(testToken))
        XCTAssertEqual(f.directory.currentDefaultOutputID, hdmiID)
        f.lifecycle.hideForCleanExit(testToken)
        XCTAssertEqual(f.directory.setHiddenCalls.last?.hidden, true)
        XCTAssertEqual(f.directory.setHiddenCalls.last?.id, driverDeviceID)
    }

    // 出力先を解決できない起動 → 停止状態で立ち上がり、ピッカーが操作可能 → 選択 → 占有の再確立を含めて再開されること。
    // 起動・再開の手順そのものを見るため、この 1 件だけは makeFixture を経由しない。
    func testScenarioRestartRecoversViaSelectionAfterUnresolvedStartup() {
        let directory = MockAudioDeviceDirectory()
        directory.hiddenDeviceIDsByUID[driverUID] = driverDeviceID
        directory.uidsByDeviceID[driverDeviceID] = driverUID
        directory.deviceIDsByUID[hdmiUID] = hdmiID
        directory.uidsByDeviceID[hdmiID] = hdmiUID
        directory.deviceIDsByUID[restoreTargetUID] = restoreTargetID
        directory.uidsByDeviceID[restoreTargetID] = restoreTargetUID
        directory.currentDefaultOutputID = restoreTargetID // 起動前のユーザの選択。
        let settings = SettingsStore(defaults: defaults)
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: driverUID)
        let engine = MockActivatableAudioEngine()
        let coordinator = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )

        // 出力先を解決できない起動。
        let startupOutcome = coordinator.activate(resolveOutputDevice: { _ in nil }, attempt: .launch, testToken)

        XCTAssertEqual(startupOutcome.processingState, .suspended(.routeUnavailable), "停止状態で立ち上がる")
        XCTAssertNil(startupOutcome.activeOutputDevice)
        XCTAssertTrue(engine.assembleCalls.isEmpty, "出力先が解決できないため組み立てには進まない")
        XCTAssertNotNil(lifecycle.resolvedDeviceID, "可視化はされ、選び直しの手がかりが残る")
        XCTAssertEqual(directory.currentDefaultOutputID, restoreTargetID, "使う予定の無い占有は残さず元のデフォルト出力へ戻る")
        XCTAssertFalse(outputController.currentRestoreState(testToken).pending, "義務は残らない")
        // ピッカーが操作可能: 選び直しで再開できる種別であること。
        XCTAssertTrue(SuspensionPolicy.allowsSelectionResume(.routeUnavailable))

        // 選択 → 占有の再確立を含めて再開される。
        directory.resetCallRecords()
        let target = ResolvedOutputDevice(uid: hdmiUID, deviceID: hdmiID)
        let resumeOutcome = coordinator.resume(outputDevice: target, trigger: .userSelection, testToken)

        XCTAssertEqual(resumeOutcome.processingState, .active)
        XCTAssertEqual(resumeOutcome.activeOutputDevice, target)
        XCTAssertEqual(directory.setDefaultOutputCalls, [driverDeviceID], "占有 (デフォルト出力の自ドライバへの切替) を再確立してから再開する")
        XCTAssertEqual(engine.assembleCalls.count, 1)
        XCTAssertEqual(engine.assembleCalls.first?.outputDevice, target)
    }
}
