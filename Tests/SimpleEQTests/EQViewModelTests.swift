import AppKit
import Combine
import CoreAudio
import CryptoKit
import SimpleEQRingC
import SwiftUI
import XCTest
@testable import SimpleEQ

@MainActor
final class EQViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// 実クラスを駆動するテストが使う共有メモリフィクスチャの後始末対象。
    nonisolated private let tempURLs = Recorded<[URL]>([])

    // 非同期版の setUp を使う (同期版はこの検証が要る隔離を持たない)。
    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("EQViewModelTests")
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

    private func makeVM(_ store: SettingsStore) -> EQViewModel {
        EQViewModel(engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld())
    }

    private func makeVMWithWorld(_ store: SettingsStore) -> (vm: EQViewModel, audioWorld: AudioWorld) {
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        return (vm, audioWorld)
    }

    /// engine.levelMeter へ直接テスト値を書き込みたい (→ pull 経由で vm へ引き出す) 場合に使う。
    private func makeVMWithEngine(_ store: SettingsStore) -> (vm: EQViewModel, engine: AudioEngine) {
        let engine = AudioEngine()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld())
        return (vm, engine)
    }

    /// 同期実行の runMeasurement/deliver と、
    /// カーブ→応答の対応表を返す偽 measure を注入した AutoPreampCoordinator 付き ViewModel を作る。
    private func makeVMWithAutoPreamp(
        _ store: SettingsStore, responses: [[Double]: EQMagnitudeResponse],
        responsesByRate: [Double: [[Double]: EQMagnitudeResponse]] = [:]
    ) -> (vm: EQViewModel, engine: AudioEngine, audioWorld: AudioWorld) {
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let coordinator = AutoPreampCoordinator(
            measure: { curve, rate in responsesByRate[rate]?[curve] ?? responses[curve] },
            runMeasurement: { work in work() },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(settings: store),
            audioWorld: audioWorld, autoPreamp: coordinator
        )
        return (vm, engine, audioWorld)
    }

    /// 測定の完了タイミングを明示的に制御できる AutoPreampCoordinator 付き ViewModel を作る。
    /// runPending() を呼ぶまで、溜まった測定要求は完了しない。
    private func makeVMWithControllableAutoPreamp(
        _ store: SettingsStore, responses: [[Double]: EQMagnitudeResponse],
        measureCount: Recorded<Int> = Recorded(0),
        measuredCurves: Recorded<[[Double]]> = Recorded([])
    ) -> (vm: EQViewModel, runPending: () -> Void) {
        let pending = Recorded<[@Sendable () -> Void]>([])
        let coordinator = AutoPreampCoordinator(
            measure: { curve, _ in
                measureCount.update { $0 += 1 }
                measuredCurves.update { $0.append(curve) }
                return responses[curve]
            },
            runMeasurement: { work in pending.update { $0.append(work) } },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store),
            audioWorld: makeTestAudioWorld(), autoPreamp: coordinator
        )
        let runPending: () -> Void = {
            let jobs = pending.update { queued -> [@Sendable () -> Void] in
                let copy = queued
                queued = []
                return copy
            }
            jobs.forEach { $0() }
        }
        return (vm, runPending)
    }

    /// 有効な共有メモリヘッダのみを持つ最小のフィクスチャを開く。実クラスのまま駆動するテストが使う。
    nonisolated private static func openFreshSharedRingReader(
        registeringInto tempURLs: Recorded<[URL]>
    ) -> Result<SharedRingReader, SharedRingReader.OpenFailure> {
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
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EQViewModelTests-\(UUID().uuidString).shm")
        try! data.write(to: url)
        tempURLs.update { $0.append(url) }
        return SharedRingReader.open(path: url.path)
    }

    /// 選択可能な実デバイスを 1 つ探す。
    private func firstSelectableOutputDeviceForTesting() -> ResolvedOutputDevice? {
        for id in allDeviceIDs(testToken) {
            guard let uid = deviceUID(id, testToken) else { continue }
            if let resolved = resolveSelectableOutputDevice(uid: uid, needsOutput: true, driverDeviceUID: DriverConfig.deviceUID, testToken) {
                return resolved
            }
        }
        return nil
    }

    // 実デバイスの切替は済んでいるため、didSet 経由で再度切り替えたり巻き戻したりしてはならない。
    func testAdoptOutputDeviceUpdatesSelectionWithoutReapplying() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.sessionOutputDeviceUID = "before-uid"
        let savedUID = store.outputDeviceUID

        // 解決できない ID を渡す。didSet が走れば巻き戻るため、巻き戻っていないことが抑止の証拠になる。
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "adopted-uid", deviceID: 0), name: "adopted-name")

        XCTAssertEqual(vm.sessionOutputDeviceUID, "adopted-uid")
        XCTAssertEqual(store.outputDeviceUID, savedUID, "セッション限定の選択であり永続化しない")
    }

    func testSelectionSuppressionIsReleasedAfterAdopt() {
        let store = SettingsStore(defaults: defaults)
        let (vm, audioWorld) = makeVMWithWorld(store)
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "adopted-uid", deviceID: 0), name: "adopted-name")

        vm.sessionOutputDeviceUID = "unresolvable-uid"
        waitForAudioWorld(audioWorld) { vm.sessionOutputDeviceUID != "unresolvable-uid" }

        XCTAssertEqual(
            vm.sessionOutputDeviceUID, "adopted-uid",
            "解決できない選択は didSet が巻き戻す = 抑止は解除されている"
        )
    }

    private func makeOutputController(mock: MockAudioDeviceDirectory? = nil, settings: SettingsStore) -> OutputDeviceController {
        if let mock {
            return OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: "test-driver-uid")
        }
        return OutputDeviceController(settings: settings, targetDeviceUID: "test-driver-uid")
    }

    /// 描画の駆動を確かめる回では面を出さないため、ミキサーは行を持たない状態で足りる。
    private func makeMixer(settings: SettingsStore) -> MixerModel {
        MixerModel(settings: settings, coordinator: nil, levelStore: MixerLevelStore(slotCount: 4))
    }

    func testProcessingStateReflectsInitParam() {
        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            processingState: .suspended(.routeUnavailable)
        )
        XCTAssertEqual(vm.processingState, .suspended(.routeUnavailable))

        let vmActive = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            processingState: .active
        )
        XCTAssertEqual(vmActive.processingState, .active)
    }

    // View に判定を持たせない。
    func testCanSelectOutputDeviceDerivesFromDriverAvailabilityAndProcessingState() {
        let store = SettingsStore(defaults: defaults)

        func vm(driverAvailability: DriverAvailability, processingState: ProcessingState) -> EQViewModel {
            EQViewModel(
                engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
                driverAvailability: driverAvailability, processingState: processingState
            )
        }

        XCTAssertFalse(vm(driverAvailability: .notFound, processingState: .active).canSelectOutputDevice, "ドライバ未検出では常に偽")
        XCTAssertTrue(vm(driverAvailability: .ok, processingState: .active).canSelectOutputDevice, "稼働中は常に真")
        XCTAssertTrue(
            vm(driverAvailability: .ok, processingState: .suspended(.routeUnavailable)).canSelectOutputDevice,
            "選び直しで再開できる停止中は真"
        )
        XCTAssertFalse(
            vm(driverAvailability: .ok, processingState: .suspended(.driverOperation)).canSelectOutputDevice,
            "再起動を前提とする停止中は偽"
        )
        XCTAssertFalse(
            vm(driverAvailability: .ok, processingState: .suspended(.applicationTermination)).canSelectOutputDevice
        )
    }

    // engine 側の値を事前に既定へ戻し、遷移で ViewModel 側の値へ戻ることを観測する。
    func testUpdateProcessingStateReflowsSettingsOnActiveTransition() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        vm.overridePreamp(db: -6)
        vm.showLevelMeter = true
        engine.setPreamp(db: 0, testToken)
        engine.levelMeter.stereoCaptureEnabled = false

        vm.updateProcessingState(.suspended(.routeUnavailable), activeDevice: nil)
        vm.updateProcessingState(.active, activeDevice: nil)
        audioWorld.queue.sync {}

        XCTAssertEqual(engine.preampGain, preampLinearGain(db: -6), accuracy: 0.0001)
        XCTAssertTrue(engine.levelMeter.stereoCaptureEnabled)
    }

    // 配る対象が漏れたら落ちるテストにする。
    func testHandleAppliedSampleRateDidChangeKeepsLevelMeterTuningConsistentWithViewModel() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        // 既定と異なる段を書き込む (既定と同じ段は didSet のガードで弾かれ、反映が走らない)。
        vm.attackLevel = EQLayout.Tuning.attack.defaultLevel - 1
        vm.releaseLevel = EQLayout.Tuning.release.defaultLevel - 1
        vm.peakHoldEnabled = false
        vm.peakHoldSeconds = 0.75
        vm.peakDecayDbPerSec = 42
        vm.showLevelMeter = false
        audioWorld.queue.sync {}

        let levelMeterBeforeRebuild = engine.levelMeter
        let tolerance = 1e-9
        // レートが変わった回、内部を組み直す (参照は動かない)。組み直しは調整値をリセットしない。
        engine.levelMeter.rebuild(appliedSampleRate: 44100)
        XCTAssertTrue(engine.levelMeter === levelMeterBeforeRebuild, "前提: 参照は差し替わらない")
        XCTAssertEqual(engine.levelMeter.attackCoef, vm.attackCoef, accuracy: tolerance, "前提: rebuild は調整値をリセットしない")
        XCTAssertFalse(engine.levelMeter.peakHoldEnabled, "前提: rebuild は調整値をリセットしない")

        vm.handleAppliedSampleRateDidChange(AudioConfig.appliedSampleRate)
        audioWorld.queue.sync {}

        XCTAssertEqual(engine.levelMeter.attackCoef, vm.attackCoef, accuracy: tolerance)
        XCTAssertEqual(engine.levelMeter.releaseCoef, vm.releaseCoef, accuracy: tolerance)
        XCTAssertFalse(engine.levelMeter.peakHoldEnabled)
        XCTAssertEqual(engine.levelMeter.peakHoldSeconds, 0.75, accuracy: tolerance)
        XCTAssertEqual(engine.levelMeter.peakDecayDbPerSec, 42, accuracy: tolerance)
        XCTAssertFalse(engine.levelMeter.stereoCaptureEnabled, "showLevelMeter (L/R 集計の有効性) も再適用対象に含まれる")
    }

    // 同じ UID を選び直しても値が変わらず変更として検知されないため、停止への遷移時にプレースホルダーへ戻す。
    func testUpdateProcessingStateClearsSelectionAndDisplayNameOnSuspendedTransition() {
        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            resolvedOutputDeviceName: "VG280K", resolvedOutputDeviceUID: "vg280k-uid"
        )
        XCTAssertEqual(vm.sessionOutputDeviceUID, "vg280k-uid")

        vm.updateProcessingState(.suspended(.routeUnavailable), activeDevice: nil)

        XCTAssertNil(vm.sessionOutputDeviceUID)
        XCTAssertEqual(vm.resolvedOutputDeviceName, "未設定")
    }

    // 停止 → 停止 (同種別) の再通知で選択が再クリアされないことを、選び直しで再開した直後の値を保って確認する。
    func testUpdateProcessingStateIsNoOpWhenStateUnchanged() {
        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            processingState: .suspended(.routeUnavailable)
        )
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "adopted-uid", deviceID: 0), name: "adopted-name")

        vm.updateProcessingState(.suspended(.routeUnavailable), activeDevice: nil)

        XCTAssertEqual(vm.sessionOutputDeviceUID, "adopted-uid", "同じ状態への再通知で選択がクリアされてはならない")
    }

    // 停止中 (選び直しで再開できる種別) でも解決できない UID を渡された場合は、再開を試みずに選択を巻き戻す。
    func testSessionOutputDeviceUIDRevertsWhileSuspendedAndResumable() {
        let store = SettingsStore(defaults: defaults)
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld,
            processingState: .suspended(.routeUnavailable)
        )

        vm.sessionOutputDeviceUID = "vg280k-uid"
        waitForAudioWorld(audioWorld) { vm.sessionOutputDeviceUID == nil }
    }

    // MARK: - 実クラスでの出力先解決
    //
    // 協力オブジェクトは実物のまま組み合わせ、モックはデバイス台帳と音声エンジンの境界だけに限る。

    func testUpdateProcessingStateRestoresTopBarSelectionToActuallyAdoptedDeviceOnActiveTransition() throws {
        guard let device = firstSelectableOutputDeviceForTesting() else {
            throw XCTSkip("この環境で選択可能な実出力デバイスが無いため、実クラスでの assemble を駆動できない")
        }
        let engine = makeSilencedEngine()
        let ringReader = try Self.openFreshSharedRingReader(registeringInto: tempURLs).get()
        XCTAssertTrue(engine.assemble(outputDevice: device, ringReader: ringReader, testToken), "前提: 実デバイスへの組み立てが成立すること")

        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            processingState: .suspended(.routeUnavailable) // 停止状態を名乗る構築 (選択・表示名は未解決のまま)
        )
        XCTAssertNil(vm.sessionOutputDeviceUID, "前提: 停止を名乗る構築ではプレースホルダーのまま")

        let resolvedName = deviceName(device.deviceID, testToken)
        vm.updateProcessingState(.active, activeDevice: ActiveOutputDeviceInfo(device: device, name: resolvedName))

        XCTAssertEqual(vm.sessionOutputDeviceUID, device.uid, "実際に採用された出力デバイスへ選択が復元される")
        XCTAssertEqual(vm.resolvedOutputDeviceName, resolvedName)

        engine.suspend(cause: .applicationTermination, testToken) // 実資源 (AudioUnit) の後始末
    }

    func testApplyTopBarSelectionResumesAndUpdatesDisplayWhenResumeSucceedsWhileSuspended() throws {
        guard let device = firstSelectableOutputDeviceForTesting() else {
            throw XCTSkip("この環境で選択可能な実出力デバイスが無いため、実クラスでの resume を駆動できない")
        }
        let store = SettingsStore(defaults: defaults)
        let engine = makeSilencedEngine()
        let directory = MockAudioDeviceDirectory()
        let outputController = OutputDeviceController(directory: directory, settings: store, targetDeviceUID: "resume-test-driver-uid")
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: "resume-test-driver-uid")
        let coordinator = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: { [tempURLs] in Self.openFreshSharedRingReader(registeringInto: tempURLs) }
        )
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld,
            processingState: .suspended(.routeUnavailable), activationCoordinator: coordinator
        )

        vm.sessionOutputDeviceUID = device.uid
        waitForAudioWorld(audioWorld) { vm.resolvedOutputDeviceName == deviceName(device.deviceID, testToken) }

        XCTAssertEqual(vm.sessionOutputDeviceUID, device.uid, "再開成功時は選択を巻き戻さない")
        XCTAssertEqual(vm.resolvedOutputDeviceName, deviceName(device.deviceID, testToken))
        XCTAssertEqual(engine.processingState, .active, "resume が成立して稼働状態へ遷移する")

        engine.suspend(cause: .applicationTermination, testToken) // 実資源 (AudioUnit) の後始末
    }

    // 共有メモリを開けない状況を使い、実オーディオユニットに触れない決定的な失敗経路で確認する。
    func testApplyTopBarSelectionRevertsSelectionWhenResumeFailsWhileSuspended() throws {
        guard let device = firstSelectableOutputDeviceForTesting() else {
            throw XCTSkip("この環境で選択可能な実出力デバイスが無いため、実クラスでの resume を駆動できない")
        }
        let store = SettingsStore(defaults: defaults)
        let engine = makeSilencedEngine()
        let directory = MockAudioDeviceDirectory()
        let outputController = OutputDeviceController(directory: directory, settings: store, targetDeviceUID: "resume-test-driver-uid")
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: "resume-test-driver-uid")
        let coordinator = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: { .failure(.fileNotFound) }
        )
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld,
            processingState: .suspended(.routeUnavailable), activationCoordinator: coordinator
        )
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "baseline-uid", deviceID: 0), name: "baseline-name")

        vm.sessionOutputDeviceUID = device.uid
        waitForAudioWorld(audioWorld) { vm.sessionOutputDeviceUID == "baseline-uid" }

        XCTAssertEqual(vm.sessionOutputDeviceUID, "baseline-uid", "再開失敗時は選択を直前の値へ巻き戻す")
        XCTAssertEqual(engine.processingState, .suspended(.routeUnavailable), "稼働状態は遷移しない")
    }

    // ミラーは通知が main へ渡ってから更新されるため、実体と食い違う窓ではどちらの分岐を経由するか取り違えうる。
    func testApplyTopBarSelectionReadsLiveEngineStateNotTheLaggingMirror() throws {
        guard let device = firstSelectableOutputDeviceForTesting() else {
            throw XCTSkip("この環境で選択可能な実出力デバイスが無いため、実クラスでの assemble を駆動できない")
        }
        let engine = makeSilencedEngine()
        let ringReader = try Self.openFreshSharedRingReader(registeringInto: tempURLs).get()
        XCTAssertTrue(engine.assemble(outputDevice: device, ringReader: ringReader, testToken), "前提: 実デバイスへの組み立てが成立すること (engine.processingState は .active)")

        let store = SettingsStore(defaults: defaults)
        let audioWorld = makeTestAudioWorld()
        // VM のミラーはあえて実体と食い違う値で構築する。
        // ミラーで分岐する誤りが残っていれば必ず巻き戻り、実体を読んでいれば巻き戻らない。
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld,
            processingState: .suspended(.routeUnavailable)
        )

        vm.sessionOutputDeviceUID = device.uid
        waitForAudioWorld(audioWorld) { vm.resolvedOutputDeviceName == deviceName(device.deviceID, testToken) }

        XCTAssertEqual(vm.sessionOutputDeviceUID, device.uid, "engine の実体 (.active) を読んで switchOutputDevice 経由で成立し、巻き戻らない")
        XCTAssertEqual(vm.resolvedOutputDeviceName, deviceName(device.deviceID, testToken))

        engine.suspend(cause: .applicationTermination, testToken) // 実資源 (AudioUnit) の後始末
    }

    // 起動時に確定した値をそのまま保持する。
    func testDriverAvailabilityReflectsInitParam() {
        let store = SettingsStore(defaults: defaults)
        for state: DriverAvailability in [.ok, .notFound, .versionMismatch] {
            let vm = EQViewModel(
                engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
                driverAvailability: state
            )
            XCTAssertEqual(vm.driverAvailability, state)
        }
    }

    // 最初のスナップショットが届くまでドライバ可用性は「確認中」のままであること。
    func testDriverAvailabilityStaysCheckingUntilFirstSnapshotConfirms() {
        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            driverAvailability: .checking
        )
        XCTAssertEqual(vm.driverAvailability, .checking, "起動の組み立てが完了するまでは確認中のまま")

        vm.confirmDriverProbe(.versionsUnreadable(.ok))

        XCTAssertEqual(vm.driverAvailability, .ok, "最初のスナップショットが届いた時点で確定する")
    }

    // 判定は絶対時間比較で状態を持たないため、判定結果をそのまま反映する (ヒステリシスは持たない)。
    func testUpdateRingStalledReflectsValueAndSkipsRedundantUpdates() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        XCTAssertFalse(vm.ringStalled)

        vm.updateRingStalled(true)
        XCTAssertTrue(vm.ringStalled, "単発の観測をそのまま反映する")

        var changeCount = 0
        let cancellable = vm.$ringStalled.dropFirst().sink { _ in changeCount += 1 }
        vm.updateRingStalled(true)
        XCTAssertEqual(changeCount, 0, "同値の反映で @Published を再発行しない")

        vm.updateRingStalled(false)
        XCTAssertFalse(vm.ringStalled)
        XCTAssertEqual(changeCount, 1)
        _ = cancellable
    }

    // 停止判定はウィンドウ可視性に依存しない定期検算のため、
    // 可視化の再開のたびにリセットすると実際に停止している間の警告が消えてしまう。
    func testVisualizerActiveReactivationDoesNotResetRingStalled() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        vm.visualizerActive = true
        vm.updateRingStalled(true)
        XCTAssertTrue(vm.ringStalled)

        vm.visualizerActive = false
        vm.visualizerActive = true
        XCTAssertTrue(vm.ringStalled, "可視化の再開で正当な警告が消えてはならない")
    }

    // プリセット適用はプリアンプに触れない (プリセットはカーブとタイトルのみを持つ)。
    func testApplyPresetLeavesPreampUntouched() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        vm.overridePreamp(db: -3)
        vm.savePreset(.slot4, title: "Saved")
        vm.overridePreamp(db: -7)

        vm.applyPreset(.slot4)
        audioWorld.queue.sync {}

        XCTAssertEqual(vm.preampDb, -7)
        XCTAssertEqual(store.preampDb, -7)
        XCTAssertEqual(engine.preampGain, preampLinearGain(db: -7), accuracy: 0.0001, "音への適用も動かないこと")
    }

    // プリアンプは選択の継続条件に関与しないため、単独の変更で選択が外れることはない。
    func testChangingPreampAloneKeepsSelectedPreset() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot2)
        XCTAssertEqual(vm.selectedPreset, .slot2, "前提: プリセットが選択されていること")

        vm.overridePreamp(db: -7)

        XCTAssertEqual(vm.selectedPreset, .slot2)
    }

    // カーブが一致している限り、自動のトグル・目標変更・ハンドル操作のいずれも選択の継続条件に関与しない。
    func testPreampAutoToggleAndTargetChangeKeepSelectedPresetWhenCurveUnchanged() {
        let store = SettingsStore(defaults: defaults)
        let slot2Curve = EQSpec.builtInSeeds[.slot2]!.curve
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let (vm, _, _) = makeVMWithAutoPreamp(store, responses: [slot2Curve: response])
        vm.applyPreset(.slot2)
        XCTAssertEqual(vm.selectedPreset, .slot2, "前提")

        vm.setPreampAutoEnabled(false)
        XCTAssertEqual(vm.selectedPreset, .slot2, "自動 OFF で選択が外れない")

        vm.setPreampAutoEnabled(true)
        XCTAssertEqual(vm.selectedPreset, .slot2, "自動 ON への復帰で選択が外れない")

        vm.setPreampAutoTargetDb(AutoPreampSpec.targetDbRange.upperBound)
        XCTAssertEqual(vm.selectedPreset, .slot2, "目標変更で選択が外れない")

        vm.overridePreamp(db: -2)
        XCTAssertEqual(vm.selectedPreset, .slot2, "ハンドル操作で選択が外れない")
    }

    func testHandleDisplayPreampStaysAtTheLiveValueDuringPresetPreview() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let t0 = Date(timeIntervalSinceReferenceDate: 3000)

        vm.previewPreset = .slot2
        for k in 0...300 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }

        XCTAssertEqual(vm.handleDisplayPreamp, vm.preampDb)
    }

    // プリアンプがいくつであっても選択中プリセットは外れない。起動時の復元でも同じ。
    func testInitKeepsSelectionRegardlessOfLivePreamp() {
        let store = SettingsStore(defaults: defaults)
        store.preset = .slot2
        store.gains = EQSpec.builtInSeeds[.slot2]!.curve
        store.preampDb = -7

        let vm = makeVM(store)

        XCTAssertEqual(vm.selectedPreset, .slot2)
    }

    func testSavePresetOverwritesCurveTitleAndSelectsPreset() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.updateDrag(band: 0, db: 4)
        vm.endDrag()

        vm.savePreset(.slot4, title: "My Curve")

        XCTAssertEqual(vm.selectedPreset, .slot4)
        XCTAssertEqual(store.title(for: .slot4), "My Curve")
        XCTAssertEqual(store.curve(for: .slot4), vm.gains)
        XCTAssertEqual(store.preset, .slot4)
    }

    // 保存したプリセットにプリアンプは含まれない (カーブとタイトルのみ)。
    func testSavePresetDoesNotCapturePreamp() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.overridePreamp(db: -5)

        vm.savePreset(.slot4, title: "My Curve")
        vm.overridePreamp(db: 0)

        XCTAssertEqual(store.curve(for: .slot4), vm.gains)
    }

    // ダイアログ側の入力制限だけに頼らない防御的クランプ。
    func testSavePresetTruncatesHalfWidthTitleToMaxWidth() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        let longTitle = String(repeating: "A", count: EQLayout.presetTitleMaxWidth + 10)

        vm.savePreset(.slot4, title: longTitle)

        XCTAssertEqual(store.title(for: .slot4).count, EQLayout.presetTitleMaxWidth)
        XCTAssertEqual(store.title(for: .slot4), String(longTitle.prefix(EQLayout.presetTitleMaxWidth)))
    }

    func testSavePresetTruncatesFullWidthTitleToHalfMaxWidth() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        let longTitle = String(repeating: "あ", count: EQLayout.presetTitleMaxWidth / 2 + 10)

        vm.savePreset(.slot4, title: longTitle)

        XCTAssertEqual(store.title(for: .slot4).count, EQLayout.presetTitleMaxWidth / 2)
    }

    // 呼び出し元のダイアログ側バリデーションだけに頼らない。
    func testSavePresetIgnoresBlankTitle() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.savePreset(.slot4, title: "   ")
        XCTAssertEqual(store.title(for: .slot4), EQSpec.builtInSeeds[.slot4]?.title ?? "")
        XCTAssertNotEqual(vm.selectedPreset, .slot4)
    }

    func testDeletePresetClearsTitleCurveAndSelection() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.updateDrag(band: 0, db: 4)
        vm.endDrag()
        vm.savePreset(.slot4, title: "My Curve")

        vm.deletePreset(.slot4)

        XCTAssertEqual(vm.title(for: .slot4), "")
        XCTAssertNil(vm.selectedPreset)
        XCTAssertEqual(store.curve(for: .slot4), Array(repeating: 0, count: EQSpec.bandCount))
    }

    // カーブの値比較ではなく識別子比較で選択解除を判定する (値がたまたま一致する場合でも正しく解除される)。
    func testDeletePresetClearsSelectionEvenWhenDeletedCurveMatchesCurrentGains() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot1)
        XCTAssertEqual(vm.selectedPreset, .slot1)

        vm.deletePreset(.slot1)

        XCTAssertNil(vm.selectedPreset)
    }

    // @Published は同値の代入でも通知するため、無条件に代入するとドラッグ中の CPU を大きく押し上げる。
    func testUpdateDragNotifiesOnlyWhenItActuallyClearsThePresetSelection() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot2)
        XCTAssertEqual(vm.selectedPreset, .slot2, "前提: プリセットが選択されていること")

        var notifications = 0
        let subscription = vm.objectWillChange.sink { _ in notifications += 1 }
        defer { subscription.cancel() }

        vm.updateDrag(band: 0, db: 4)
        XCTAssertNil(vm.selectedPreset, "最初の 1 回で選択が外れる")
        let afterFirst = notifications
        XCTAssertGreaterThan(afterFirst, 0, "選択が実際に変わった回は通知が要る")

        for db in stride(from: 5.0, through: 12.0, by: 1.0) {
            vm.updateDrag(band: 0, db: db)
        }

        XCTAssertEqual(
            notifications, afterFirst,
            "選択が既に外れている間の updateDrag は通知を出さない (同値の代入を避ける)"
        )
    }

    // tick は @Published を動かさない (ビジュアライザ等の表示値は CALayer が直接読むため)。
    func testTickDoesNotInvalidateTheViewTree() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        // EQ が音に効いている状態にしないとハンドルが出ず、tick が進める表示値が無くなる。
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        vm.handlesRevealed = true     // ハンドルのフェードが動く状態で回す
        vm.tick(now: Date(timeIntervalSinceReferenceDate: 0))

        var notifications = 0
        let subscription = vm.objectWillChange.sink { _ in notifications += 1 }
        defer { subscription.cancel() }

        let alphaBefore = vm.handleAlpha
        for k in 1...120 {
            vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016))
        }

        XCTAssertNotEqual(vm.handleAlpha, alphaBefore, "前提: tick が実際に表示値を進めていること")
        XCTAssertEqual(notifications, 0, "毎フレームの反映は @Published を経由しない")
    }

    func testResetAllPresetsRestoresBuiltInDefaultsAndClearsStaleSelection() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.updateDrag(band: 0, db: 4)
        vm.endDrag()
        vm.savePreset(.slot2, title: "Renamed")

        vm.resetAllPresets()

        XCTAssertEqual(vm.title(for: .slot2), EQSpec.builtInSeeds[.slot2]?.title ?? "")
        XCTAssertEqual(store.curve(for: .slot2), EQSpec.builtInSeeds[.slot2]?.curve)
        XCTAssertNil(vm.selectedPreset)
    }

    func testPresetSurvivesRestart() {
        let store = SettingsStore(defaults: defaults)
        _ = { makeVM(store).applyPreset(.slot3) }()
        let reloaded = makeVM(SettingsStore(defaults: defaults))
        XCTAssertEqual(reloaded.selectedPreset, .slot3)
        XCTAssertEqual(reloaded.gains, EQSpec.builtInSeeds[.slot3]?.curve)
    }

    func testDragPersistsCustomGainAndClearsPreset() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot2)
        vm.updateDrag(band: 0, db: 6)
        vm.endDrag()
        XCTAssertNil(vm.selectedPreset)
        XCTAssertEqual(store.gains.first, 6)

        let reloaded = makeVM(SettingsStore(defaults: defaults))
        XCTAssertNil(reloaded.selectedPreset)
        XCTAssertEqual(reloaded.gains.first, 6)
    }

    func testApplyPresetSetsGainsImmediately() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot2)

        let target = EQSpec.builtInSeeds[.slot2]!.curve
        XCTAssertEqual(vm.gains, target)
        XCTAssertEqual(store.gains, target)
    }

    func testDragAfterApplyPresetPersistsTargetForUntouchedBands() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot2)

        vm.updateDrag(band: 0, db: 6)
        vm.endDrag()

        let target = EQSpec.builtInSeeds[.slot2]!.curve
        XCTAssertEqual(store.gains[0], 6)
        for i in 1..<EQSpec.bandCount {
            XCTAssertEqual(store.gains[i], target[i], "band \(i) は Perfect 確定値で永続化されるべき")
        }
    }

    func testUpdateDragSwitchesTargetBandAndAppliesEachBandGain() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        vm.updateDrag(band: 0, db: 3)
        vm.updateDrag(band: 5, db: -4)

        XCTAssertEqual(vm.dragIndex, 5, "dragIndex は最後に呼ばれたバンドを指す")
        XCTAssertEqual(vm.gains[0], 3, "切り替え前に触れたバンドのゲインもその時点の値で確定する")
        XCTAssertEqual(vm.gains[5], -4)
    }

    func testEndDragPersistsAllBandsTouchedDuringSwitch() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        vm.updateDrag(band: 0, db: 3)
        vm.updateDrag(band: 5, db: -4)
        vm.endDrag()

        XCTAssertEqual(store.gains[0], 3)
        XCTAssertEqual(store.gains[5], -4)
        XCTAssertNil(vm.dragIndex)
    }

    func testResetGainPersists() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.applyPreset(.slot2)
        vm.resetGain(band: 3)
        XCTAssertEqual(vm.gains[3], 0)
        XCTAssertEqual(store.gains[3], 0)
    }

    func testBypassPersists() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.bypass = true
        XCTAssertTrue(store.bypass)
    }

    func testUpdatePreampDragSetsDraggingAndClampsToRange() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        vm.updatePreampDrag(db: EQSpec.DB_MAX + 5)

        XCTAssertTrue(vm.draggingPreamp)
        XCTAssertEqual(vm.preampDb, EQSpec.DB_MAX)
    }

    func testEndPreampDragClearsDraggingFlag() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.updatePreampDrag(db: -4)
        XCTAssertTrue(vm.draggingPreamp, "前提: ドラッグ中であること")

        vm.endPreampDrag()

        XCTAssertFalse(vm.draggingPreamp)
    }

    func testResetPreampReturnsToAuto() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.updatePreampDrag(db: -4)
        vm.endPreampDrag()
        XCTAssertFalse(vm.preampAutoEnabled)

        vm.resetPreamp()
        XCTAssertTrue(vm.preampAutoEnabled)
    }

    func testDerivedPreampIsPersistedOnlyWhenTheBandDragEnds() {
        let store = SettingsStore(defaults: defaults)
        let curve = { () -> [Double] in var c = [Double](repeating: 0, count: EQSpec.bandCount); c[0] = 6; return c }()
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let (vm, _, _) = makeVMWithAutoPreamp(store, responses: [curve: response])
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let persistedBeforeDrag = store.preampDb

        vm.updateDrag(band: 0, db: 6)
        XCTAssertNotEqual(vm.preampDb, persistedBeforeDrag, "前提: ドラッグ中に導出値が動いている")
        XCTAssertEqual(store.preampDb, persistedBeforeDrag, "ドラッグ中は永続化しないこと")

        vm.endDrag()

        XCTAssertEqual(store.preampDb, vm.preampDb, "ドラッグ確定で永続化されること")
    }

    /// Settings とツールチップが共有する Binding。書き込みが overridePreamp を通ることを固定する。
    func testPreampSliderBindingWritesThroughOverrideAndDropsAuto() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let binding = preampSliderBinding(vm)
        XCTAssertTrue(vm.preampAutoEnabled, "前提: 既定は自動 ON")

        binding.wrappedValue = -5

        XCTAssertEqual(vm.preampDb, -5)
        XCTAssertFalse(vm.preampAutoEnabled, "スライダー経由の書き込みでも自動が外れること")
        XCTAssertEqual(binding.wrappedValue, vm.preampDb, "読みは現在値を返すこと")
    }

    /// 測定に失敗したまま自動 ON でいる状態から抜けられるよう、既に自動でも導出をやり直す。
    func testResetPreampReDerivesEvenWhenAlreadyAutomatic() {
        let store = SettingsStore(defaults: defaults)
        let measureCount = Recorded(0)
        let (vm, runPending) = makeVMWithControllableAutoPreamp(store, responses: [:], measureCount: measureCount)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        runPending()
        let afterInitial = measureCount.value
        XCTAssertTrue(vm.preampAutoEnabled, "前提: 既定は自動 ON")

        vm.resetPreamp()
        runPending()

        XCTAssertGreaterThan(measureCount.value, afterInitial, "既に自動でも導出をやり直すこと")
    }

    /// バイパス中は、プリアンプの値を動かしうる操作をどれも受け付けない。
    func testPreampControlsAreAllNoOpWhileBypassed() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.overridePreamp(db: -4)
        vm.bypass = true

        vm.updatePreampDrag(db: 6)
        XCTAssertEqual(vm.preampDb, -4, "ドラッグを無視すること")
        XCTAssertFalse(vm.draggingPreamp)

        vm.overridePreamp(db: -9)
        XCTAssertEqual(vm.preampDb, -4, "スライダー経由の書き込みを無視すること")

        vm.resetPreamp()
        XCTAssertFalse(vm.preampAutoEnabled, "自動へ戻す操作も無視すること")

        vm.setPreampAutoEnabled(true)
        XCTAssertFalse(vm.preampAutoEnabled, "AUTO トグルも無視すること")

        let target = vm.preampAutoTargetDb
        vm.setPreampAutoTargetDb(AutoPreampSpec.targetDbRange.upperBound)
        XCTAssertEqual(vm.preampAutoTargetDb, target, "許容ピークの変更も無視すること")
    }

    // MARK: - プリアンプ自動導出

    // ドラッグ・プリセット適用・目標変更・自動 OFF→ON のいずれの契機でも、プリアンプが導出値になる。
    func testAutoPreampDerivesOnCurveDragPresetApplyTargetChangeAndAutoToggle() {
        let store = SettingsStore(defaults: defaults)
        let slot2Curve = EQSpec.builtInSeeds[.slot2]!.curve
        // ドラッグは band 0 だけを書き換えるため、直前の状態 (slot2Curve) からの派生形になる。
        var dragCurve = slot2Curve
        dragCurve[0] = 4
        let slot2Response = EQMagnitudeResponse(energyWeightedGainDb: 5, worstCaseGainDb: 8)
        let dragResponse = EQMagnitudeResponse(energyWeightedGainDb: 2, worstCaseGainDb: 3)
        let (vm, _, _) = makeVMWithAutoPreamp(store, responses: [slot2Curve: slot2Response, dragCurve: dragResponse])

        vm.applyPreset(.slot2)
        XCTAssertEqual(
            vm.preampDb, AutoPreampSpec.derivedPreampDb(response: slot2Response, targetDb: vm.preampAutoTargetDb),
            "プリセット適用"
        )

        vm.updateDrag(band: 0, db: 4)
        vm.endDrag()
        XCTAssertEqual(
            vm.preampDb, AutoPreampSpec.derivedPreampDb(response: dragResponse, targetDb: vm.preampAutoTargetDb),
            "ドラッグ"
        )

        let newTarget = AutoPreampSpec.targetDbRange.upperBound
        vm.setPreampAutoTargetDb(newTarget)
        XCTAssertEqual(
            vm.preampDb, AutoPreampSpec.derivedPreampDb(response: dragResponse, targetDb: newTarget), "目標変更"
        )

        vm.overridePreamp(db: 0)
        XCTAssertFalse(vm.preampAutoEnabled, "前提: 手操作で自動が外れること")
        vm.setPreampAutoEnabled(true)
        XCTAssertEqual(
            vm.preampDb, AutoPreampSpec.derivedPreampDb(response: dragResponse, targetDb: newTarget), "自動 OFF→ON"
        )
    }

    // 手操作の入口はいずれも自動を外し、以後カーブが変わってもプリアンプは動かない。
    func testManualPreampOverrideDisablesAutoAndCurveChangesNoLongerMoveIt() {
        let store = SettingsStore(defaults: defaults)
        let slot2Curve = EQSpec.builtInSeeds[.slot2]!.curve
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let cases: [(String, (EQViewModel) -> Void)] = [
            ("updatePreampDrag", { $0.updatePreampDrag(db: -2) }),
            ("overridePreamp", { $0.overridePreamp(db: -3) }),
        ]
        for (name, action) in cases {
            store.preampAutoEnabled = true // 前のケースでの書き込みを引きずらない
            let (vm, _, _) = makeVMWithAutoPreamp(store, responses: [slot2Curve: response])
            XCTAssertTrue(vm.preampAutoEnabled, "前提: 既定は自動 ON (\(name))")

            action(vm)
            XCTAssertFalse(vm.preampAutoEnabled, name)

            let before = vm.preampDb
            vm.applyPreset(.slot2)
            XCTAssertEqual(vm.preampDb, before, "自動 OFF の間はカーブが変わってもプリアンプが動かない (\(name))")
        }
    }

    func testDisablingAutoPreservesTheLastDerivedValue() {
        let store = SettingsStore(defaults: defaults)
        let curve = EQSpec.builtInSeeds[.slot1]!.curve
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let (vm, _, _) = makeVMWithAutoPreamp(store, responses: [curve: response])
        vm.startAutoPreampDerivation()
        let derived = vm.preampDb
        XCTAssertNotEqual(derived, 0, "前提: 導出値が 0 でないこと")

        vm.setPreampAutoEnabled(false)

        XCTAssertEqual(vm.preampDb, derived, "自動 OFF で直前の導出値が残ること (0 に戻らない)")
    }

    func testApplyPresetSetsPreampToDerivedValueNotSavedValueAndKeepsSelection() {
        let store = SettingsStore(defaults: defaults)
        let slot2Curve = EQSpec.builtInSeeds[.slot2]!.curve
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let (vm, engine, _) = makeVMWithAutoPreamp(store, responses: [slot2Curve: response])

        vm.applyPreset(.slot2)

        let expected = AutoPreampSpec.derivedPreampDb(response: response, targetDb: vm.preampAutoTargetDb)
        XCTAssertEqual(vm.preampDb, expected)
        XCTAssertEqual(vm.selectedPreset, .slot2, "導出でプリアンプが動いても選択は外れない")
        XCTAssertEqual(engine.preampGain, preampLinearGain(db: expected), accuracy: 0.0001, "音への適用も追従する")
    }

    // 未キャッシュの間は現在値のまま、測定完了でキャッシュが埋まると導出値へ動き出す。
    func testPreviewPresetMovesHandleTargetToDerivedValueOnceCached() {
        let store = SettingsStore(defaults: defaults)
        let slot2Curve = EQSpec.builtInSeeds[.slot2]!.curve
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let (vm, runPending) = makeVMWithControllableAutoPreamp(store, responses: [slot2Curve: response])
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let liveValue = vm.preampDb
        let t0 = Date(timeIntervalSinceReferenceDate: 6000)

        vm.previewPreset = .slot2
        vm.tick(now: t0)
        XCTAssertEqual(vm.handleDisplayPreamp, liveValue, "未キャッシュの間は現在値のまま")

        runPending()
        for k in 1...300 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }

        let expected = AutoPreampSpec.derivedPreampDb(response: response, targetDb: vm.preampAutoTargetDb)
        XCTAssertEqual(vm.handleDisplayPreamp, expected, "キャッシュが埋まった後は導出値へ動き出す")
    }

    // hover 中は毎フレーム問い合わせが走るため、測定が失敗し続けても要求を積み直さないこと。
    func testFailingPreviewMeasurementIsRequestedOncePerHoveredPreset() {
        let store = SettingsStore(defaults: defaults)
        let measureCount = Recorded(0)
        // 対応表を空にして測定失敗 (nil) にする。
        let (vm, runPending) = makeVMWithControllableAutoPreamp(store, responses: [:], measureCount: measureCount)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let t0 = Date(timeIntervalSinceReferenceDate: 7000)

        vm.previewPreset = .slot2
        for k in 0...120 {
            vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016))
            runPending()   // 積まれていれば測定が走り、失敗する
        }

        XCTAssertEqual(measureCount.value, 1, "同じプリセットへの測定要求は 1 回に留まること")
    }

    /// hover 中にレートが変われば測り直す (キャッシュのキーがレートを含むため)。
    func testPreviewRemeasuresWhenTheRateChangesWhileHovering() {
        let store = SettingsStore(defaults: defaults)
        let measured = Recorded<[[Double]]>([])
        let (vm, runPending) = makeVMWithControllableAutoPreamp(store, responses: [:], measuredCurves: measured)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let hovered = store.curve(for: .slot2)
        let t0 = Date(timeIntervalSinceReferenceDate: 7800)

        vm.previewPreset = .slot2
        vm.tick(now: t0)
        runPending()
        let afterFirstHover = measured.value.filter { $0 == hovered }.count

        vm.handleAppliedSampleRateDidChange(96000)
        vm.tick(now: t0.addingTimeInterval(0.016))
        // 導出が先に処理され、プレビューはその完了後に積まれる。
        runPending()
        runPending()

        XCTAssertGreaterThan(
            measured.value.filter { $0 == hovered }.count, afterFirstHover, "レートが変われば測り直すこと"
        )
    }

    /// hover 中に同じ枠の内容が書き換わったら測り直す (抑止キーは枠ではなくカーブで見る)。
    func testPreviewRemeasuresWhenTheHoveredPresetCurveChanges() {
        let store = SettingsStore(defaults: defaults)
        let measured = Recorded<[[Double]]>([])
        let (vm, runPending) = makeVMWithControllableAutoPreamp(store, responses: [:], measuredCurves: measured)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let t0 = Date(timeIntervalSinceReferenceDate: 7500)

        vm.previewPreset = .slot2
        vm.tick(now: t0)
        runPending()

        var changed = [Double](repeating: 0, count: EQSpec.bandCount)
        changed[3] = 9
        store.savePreset(.slot2, curve: changed, title: "changed")
        vm.tick(now: t0.addingTimeInterval(0.016))
        runPending()

        XCTAssertTrue(measured.value.contains(changed), "書き換わった内容で測り直すこと")
    }

    // 自動 OFF ではプリセットを当てても動かないため、hover 中も現在値のまま。
    func testPreviewPresetStaysAtLiveValueWhenAutoDisabled() {
        let store = SettingsStore(defaults: defaults)
        let slot2Curve = EQSpec.builtInSeeds[.slot2]!.curve
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let (vm, _, _) = makeVMWithAutoPreamp(store, responses: [slot2Curve: response])
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.overridePreamp(db: -2)
        let liveValue = vm.preampDb
        let t0 = Date(timeIntervalSinceReferenceDate: 6500)

        vm.previewPreset = .slot2
        for k in 0...300 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }

        XCTAssertEqual(vm.handleDisplayPreamp, liveValue, "自動 OFF では当てても動かないため現在値のまま")
    }

    /// バイパス中も導出は止まらない。
    /// 人の操作はどれも受け付けないため、この状態で唯一変わりうる入力であるサンプルレートで確かめる。
    func testAutoPreampContinuesDerivingWhileBypassedAndAppliesOnBypassOff() {
        let store = SettingsStore(defaults: defaults)
        let curve = EQSpec.builtInSeeds[.slot1]!.curve
        let newRate = 96000.0
        let atNewRate = EQMagnitudeResponse(energyWeightedGainDb: 9, worstCaseGainDb: 9)
        let (vm, engine, audioWorld) = makeVMWithAutoPreamp(
            store,
            responses: [curve: EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)],
            responsesByRate: [newRate: [curve: atNewRate]]
        )
        vm.startAutoPreampDerivation()
        let firstDerived = vm.preampDb
        XCTAssertNotEqual(firstDerived, 0, "前提: 既に導出済みであること")

        vm.bypass = true
        vm.handleAppliedSampleRateDidChange(newRate)

        let expected = AutoPreampSpec.derivedPreampDb(response: atNewRate, targetDb: vm.preampAutoTargetDb)
        XCTAssertNotEqual(expected, firstDerived, "前提: レート変更で導出値が変わること")
        XCTAssertEqual(vm.preampDb, expected, "バイパス中も導出が継続すること")

        vm.bypass = false
        audioWorld.queue.sync {}
        XCTAssertEqual(engine.preampGain, preampLinearGain(db: expected), accuracy: 0.0001, "バイパス解除の瞬間に導出値が効くこと")
    }

    func testHandleAppliedSampleRateDidChangeUpdatesAutoPreampInput() {
        let store = SettingsStore(defaults: defaults)
        let curve = EQSpec.builtInSeeds[.slot1]!.curve
        let baseRateResponse = EQMagnitudeResponse(energyWeightedGainDb: 6, worstCaseGainDb: 6)
        let newRateResponse = EQMagnitudeResponse(energyWeightedGainDb: 3, worstCaseGainDb: 3)
        let newRate = AudioConfig.baseSampleRate * 2
        let coordinator = AutoPreampCoordinator(
            measure: { c, rate in
                guard c == curve else { return nil }
                return rate == newRate ? newRateResponse : baseRateResponse
            },
            runMeasurement: { work in work() },
            deliver: { work in MainActor.assumeIsolated { work() } }
        )
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store),
            audioWorld: makeTestAudioWorld(), autoPreamp: coordinator
        )
        vm.startAutoPreampDerivation()
        XCTAssertEqual(vm.preampDb, AutoPreampSpec.derivedPreampDb(response: baseRateResponse, targetDb: vm.preampAutoTargetDb))

        vm.handleAppliedSampleRateDidChange(newRate)

        XCTAssertEqual(vm.preampDb, AutoPreampSpec.derivedPreampDb(response: newRateResponse, targetDb: vm.preampAutoTargetDb))
    }

    // 調停役を注入しなければ導出は一切起きない。
    func testNoAutoPreampDerivationWithoutInjectedCoordinator() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        let initial = vm.preampDb
        XCTAssertEqual(initial, 0)

        vm.startAutoPreampDerivation()
        vm.applyPreset(.slot2)
        vm.setPreampAutoTargetDb(AutoPreampSpec.targetDbRange.upperBound)
        vm.handleAppliedSampleRateDidChange(AudioConfig.baseSampleRate * 2)

        XCTAssertEqual(vm.preampDb, initial, "調停役未注入では導出が一切起きない")
    }

    // 取り違えても型が同じで通るため、項目ごとに別の並び・別の段を使って対応を固定する。
    func testLevelDerivedValuesReadTheirOwnScaleAndLevel() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        let cases: [(name: String, level: Int, scale: EQLayout.Tuning.LevelScale)] = [
            ("attack", 1, EQLayout.Tuning.attack),
            ("release", 2, EQLayout.Tuning.release),
            ("handleFade", 4, EQLayout.Tuning.handleFade),
            ("handlePreview", 5, EQLayout.Tuning.handlePreview),
        ]
        for c in cases {
            XCTAssertTrue((1...c.scale.values.count).contains(c.level), "前提: \(c.name) の段 \(c.level) が並びに収まること")
            // 既定と同じ段だと didSet のガードで弾かれ、書き込まなくても値が一致してしまう。
            XCTAssertNotEqual(c.level, c.scale.defaultLevel, "前提: \(c.name) の段が既定と異なること")
        }
        // 段が重なっていると、段プロパティの取り違え (自分以外の段を読む形) が値として現れない。
        XCTAssertEqual(Set(cases.map(\.level)).count, cases.count, "前提: 4 つの段が互いに異なること")

        vm.attackLevel = cases[0].level
        vm.releaseLevel = cases[1].level
        vm.handleFadeLevel = cases[2].level
        vm.handlePreviewLevel = cases[3].level

        XCTAssertEqual(vm.attackCoef, cases[0].scale.value(at: cases[0].level))
        XCTAssertEqual(vm.releaseCoef, cases[1].scale.value(at: cases[1].level))
        XCTAssertEqual(vm.handleFadeTau, cases[2].scale.value(at: cases[2].level))
        XCTAssertEqual(vm.handlePreviewTau, cases[3].scale.value(at: cases[3].level))
    }

    func testAttackAndReleaseLevelDerivesCoefAndPropagatesToLevelMeterAndSettings() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)

        // 既定と同じ段だと didSet のガードで弾かれ、「既定のまま」を見るだけのテストになる。
        let attackLevel = EQLayout.Tuning.attack.defaultLevel - 1
        XCTAssertTrue(
            (1...EQLayout.Tuning.attack.values.count).contains(attackLevel),
            "前提: 既定の隣の段が並びに収まること (既定が下端だと段が消える)"
        )
        vm.attackLevel = attackLevel
        audioWorld.queue.sync {}
        XCTAssertEqual(vm.attackCoef, EQLayout.Tuning.attack.value(at: attackLevel))
        XCTAssertEqual(engine.levelMeter.attackCoef, EQLayout.Tuning.attack.value(at: attackLevel))
        XCTAssertEqual(store.attackLevel, attackLevel)

        let releaseLevel = EQLayout.Tuning.release.defaultLevel - 1
        XCTAssertTrue(
            (1...EQLayout.Tuning.release.values.count).contains(releaseLevel),
            "前提: 既定の隣の段が並びに収まること (既定が下端だと段が消える)"
        )
        vm.releaseLevel = releaseLevel
        audioWorld.queue.sync {}
        XCTAssertEqual(vm.releaseCoef, EQLayout.Tuning.release.value(at: releaseLevel))
        XCTAssertEqual(engine.levelMeter.releaseCoef, EQLayout.Tuning.release.value(at: releaseLevel))
        XCTAssertEqual(store.releaseLevel, releaseLevel)
    }

    func testPeakHoldTuningPropagatesToLevelMeterAndSettings() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)

        vm.peakHoldSeconds = 0.5
        audioWorld.queue.sync {}
        XCTAssertEqual(engine.levelMeter.peakHoldSeconds, 0.5)
        XCTAssertEqual(store.peakHoldSeconds, 0.5)

        vm.peakDecayDbPerSec = 50
        audioWorld.queue.sync {}
        XCTAssertEqual(engine.levelMeter.peakDecayDbPerSec, 50)
        XCTAssertEqual(store.peakDecayDbPerSec, 50)

        vm.peakCapBrightenAmount = 0.8
        XCTAssertEqual(store.peakCapBrightenAmount, 0.8)
    }

    func testPeakHoldEnabledTogglePropagatesAndResetsStalePeakOnReEnable() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)

        vm.peakHoldEnabled = false
        audioWorld.queue.sync {}
        XCTAssertFalse(engine.levelMeter.peakHoldEnabled)
        XCTAssertFalse(store.peakHoldEnabled)

        // 無効化中は peaks が更新されないため levels との乖離 (凍結状態) が生まれる。
        // visualizerActive を経由せず直接 capture() を呼ぶため、取り込みのゲートを明示的に開く。
        engine.levelMeter.captureEnabled = true
        let loud = [Float](repeating: 1.0, count: 8192)
        loud.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: 8192, channels: 1)
        }
        engine.levelMeter.analyzeAvailableHops()
        let whileDisabled = engine.levelMeter.snapshot()
        XCTAssertTrue(
            zip(whileDisabled.levels, whileDisabled.peaks).contains { level, peak in level > peak },
            "無効化中は peaks が更新されず levels との乖離が生まれるはず"
        )

        vm.peakHoldEnabled = true
        audioWorld.queue.sync {}
        XCTAssertTrue(engine.levelMeter.peakHoldEnabled)
        XCTAssertTrue(store.peakHoldEnabled)
        let afterReEnable = engine.levelMeter.snapshot()
        XCTAssertEqual(afterReEnable.peaks, afterReEnable.levels, "再有効化時に凍結ピークが現在レベルへリセットされるはず")
    }

    func testPreampDbPropagatesToEngineAndSettings() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)

        vm.overridePreamp(db: -3)
        audioWorld.queue.sync {}
        XCTAssertEqual(engine.preampGain, preampLinearGain(db: -3), accuracy: 0.0001)
        XCTAssertEqual(store.preampDb, -3)
    }

    // オーディオ世界へは依頼として値のコピーを送る (生きた参照を経由して都度読み直す形は取らない)。
    func testProcessingSettingsRequestCarriesValueSnapshotAtSubmissionTime() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let queue = DispatchQueue(label: "testProcessingSettingsRequestCarriesValueSnapshotAtSubmissionTime")
        let audioWorld = AudioWorld(queue: queue)
        queue.suspend()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)

        vm.overridePreamp(db: -3) // 依頼を投入 (キューは止まっているため、この時点ではまだ実行されない)。
        // viewModel を経由せず直接書き換える。生きた参照で再読込していれば、この書き換えが反映されてしまう。
        store.preampDb = 999

        queue.resume()
        queue.sync {}

        XCTAssertEqual(
            engine.preampGain, effectivePreampGain(preampDb: -3, bypassed: false), accuracy: 0.0001,
            "依頼投入時点の値がそのまま適用され、実行前に書き換えられた値の影響を受けない"
        )
    }

    // プリアンプ設定値自体はバイパス中も変わらず保持される (音への適用のみが止まる)。
    func testBypassTogglePreservesPreampSettingWhileMutingEffectiveGain() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)

        vm.overridePreamp(db: -3)
        vm.bypass = true
        audioWorld.queue.sync {}
        XCTAssertEqual(engine.preampGain, 1.0, accuracy: 0.0001, "バイパス中は実効ゲインがユニティ")
        XCTAssertEqual(store.preampDb, -3, "バイパス中もプリアンプ設定値の永続化は変わらない")

        vm.bypass = false
        audioWorld.queue.sync {}
        XCTAssertEqual(engine.preampGain, preampLinearGain(db: -3), accuracy: 0.0001, "バイパス解除で設定値由来のゲインが復帰する")
        XCTAssertEqual(store.preampDb, -3)
    }

    func testDirectValueTuningPersistsImmediately() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        // 既定値の隣の段を書き込む (既定値そのものだと、書き込まれていなくても一致してしまう)。
        let probeFps = EQLayout.Tuning.visualizerFpsChoices.first { $0 != EQLayout.Tuning.visualizerFpsDefault }!
        vm.visualizerFps = probeFps
        vm.floorDb = -90

        XCTAssertEqual(store.visualizerFps, probeFps)
        XCTAssertEqual(store.floorDb, -90)
    }

    func testSessionOutputDeviceUIDRevertsWhenEngineNotSetUp() {
        let store = SettingsStore(defaults: defaults)
        let (vm, audioWorld) = makeVMWithWorld(store)
        let initialName = vm.resolvedOutputDeviceName

        vm.sessionOutputDeviceUID = "vg280k-uid"
        waitForAudioWorld(audioWorld) { vm.sessionOutputDeviceUID == nil }

        XCTAssertEqual(vm.resolvedOutputDeviceName, initialName)
    }

    func testSessionOutputDeviceUIDNeverPersistsToSettings() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        vm.sessionOutputDeviceUID = "vg280k-uid"

        XCTAssertNil(store.outputDeviceUID)
    }

    // 追従の設定は永続化され、次の起動はその値から始まる。
    func testAdoptsSystemOutputSelectionPersistsAcrossLaunch() {
        let store = SettingsStore(defaults: defaults)
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store),
            audioWorld: audioWorld
        )
        XCTAssertTrue(vm.adoptsSystemOutputSelection, "既定は追従する")

        vm.adoptsSystemOutputSelection = false
        audioWorld.queue.sync {}

        XCTAssertFalse(store.adoptsSystemOutputSelection)
        let reloadedStore = SettingsStore(defaults: defaults)
        let relaunched = EQViewModel(
            engine: AudioEngine(), settings: reloadedStore, outputController: makeOutputController(settings: reloadedStore),
            audioWorld: makeTestAudioWorld()
        )
        XCTAssertFalse(relaunched.adoptsSystemOutputSelection)
    }

    // 同じ出力先を繰り返し反映しても通知を出さない (@Published は同値の代入でも通知するため)。
    func testAdoptingTheSameOutputDeviceEmitsNoChange() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        let device = ResolvedOutputDevice(uid: "speaker-uid", deviceID: 10)
        vm.adoptOutputDevice(device, name: "スピーカー")
        var changes = 0
        let subscription = vm.objectWillChange.sink { _ in changes += 1 }
        defer { subscription.cancel() }

        vm.adoptOutputDevice(device, name: "スピーカー")
        XCTAssertEqual(changes, 0, "同値なら通知しない")

        vm.adoptOutputDevice(device, name: "スピーカー (別名)")
        XCTAssertGreaterThan(changes, 0, "表示名が変われば通知する")
    }

    /// 解決できない UID を選ばせて巻き戻しを踏ませ、着地するまで待つ。
    private func settleRevertingOutputDeviceSelection(
        _ vm: EQViewModel, _ audioWorld: AudioWorld, file: StaticString = #filePath, line: UInt = #line
    ) {
        let unresolvableUID = "missing-uid"
        vm.sessionOutputDeviceUID = unresolvableUID
        waitForAudioWorld(audioWorld, file: file, line: line) { vm.sessionOutputDeviceUID != unresolvableUID }
    }

    // 表示名だけでは同値と判断できない (同じ名前のデバイスが同時に存在しうる)。
    func testAdoptingADeviceSharingItsNameStillMovesTheRevertTarget() {
        let store = SettingsStore(defaults: defaults)
        let (vm, audioWorld) = makeVMWithWorld(store)
        let sharedName = "同じ表示名"
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "device-a", deviceID: 10), name: sharedName)

        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "device-b", deviceID: 11), name: sharedName)
        settleRevertingOutputDeviceSelection(vm, audioWorld)

        XCTAssertEqual(vm.sessionOutputDeviceUID, "device-b", "巻き戻し先は直近に確定したデバイス")
    }

    // 確定値と同じデバイスでも、セッションの選択がずれていれば揃え直す。
    func testAdoptingTheAlreadyConfirmedDeviceStillFixesTheSessionSelection() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        let sharedName = "同じ表示名"
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "device-a", deviceID: 10), name: sharedName)
        vm.sessionOutputDeviceUID = "device-b"

        // ここで待ちを挟むと巻き戻しが先に着地し、以降は 3 節一致で弾かれても assert が通る (判別力が消える)。
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "device-a", deviceID: 10), name: sharedName)

        XCTAssertEqual(vm.sessionOutputDeviceUID, "device-a", "セッションの選択も確定値へ揃う")
    }

    // セッションの選択だけが先へ進んでいる状態でも、確定値は取り残されない。
    func testAdoptingTheDeviceAlreadySelectedInSessionStillMovesTheRevertTarget() {
        let store = SettingsStore(defaults: defaults)
        let (vm, audioWorld) = makeVMWithWorld(store)
        let sharedName = "同じ表示名"
        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "device-a", deviceID: 10), name: sharedName)
        vm.sessionOutputDeviceUID = "device-b"

        vm.adoptOutputDevice(ResolvedOutputDevice(uid: "device-b", deviceID: 11), name: sharedName)
        settleRevertingOutputDeviceSelection(vm, audioWorld)

        XCTAssertEqual(vm.sessionOutputDeviceUID, "device-b", "巻き戻し先は直近に確定したデバイス")
    }

    // トグルの切替が是正へ届き、切り戻しも効くこと (配線が抜けると設定が次の起動まで効かない)。
    func testAdoptsSystemOutputSelectionToggleReachesRouting() {
        let store = SettingsStore(defaults: defaults)
        let audioWorld = makeTestAudioWorld()
        let driverUID = DriverConfig.deviceUID
        let driverID: AudioDeviceID = 40
        let speakerID: AudioDeviceID = 10
        let hdmiID: AudioDeviceID = 11
        let directory = MockAudioDeviceDirectory()
        directory.hiddenDeviceIDsByUID[driverUID] = driverID
        directory.uidsByDeviceID[driverID] = driverUID
        directory.deviceIDsByUID["speaker-uid"] = speakerID
        directory.uidsByDeviceID[speakerID] = "speaker-uid"
        directory.deviceIDsByUID["hdmi-uid"] = hdmiID
        directory.uidsByDeviceID[hdmiID] = "hdmi-uid"
        // OS 側で出力先が自ドライバから離れた状態から始める。
        directory.currentDefaultOutputID = hdmiID

        let routingEngine = MockAudioRoutingEngine()
        routingEngine.processingState = .active
        routingEngine.intendedOutputDeviceUID = "speaker-uid"
        routingEngine.actualOutputDeviceID = speakerID
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
        let outputController = OutputDeviceController(directory: directory, settings: store, targetDeviceUID: driverUID)
        let reconciler = DeviceRoutingReconciler(
            directory: directory, engine: routingEngine, driverLifecycle: lifecycle,
            outputController: outputController,
            activationCoordinator: AudioActivationCoordinator(
                engine: routingEngine, driverLifecycle: lifecycle, outputController: outputController
            ),
            driverDeviceUID: driverUID,
            adoptsSystemOutputSelection: store.adoptsSystemOutputSelection,
            didAdoptOutputDevice: { _, _ in },
            audioWorld: audioWorld
        )
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: outputController,
            audioWorld: audioWorld, deviceRoutingReconciler: reconciler
        )

        vm.adoptsSystemOutputSelection = false
        audioWorld.queue.sync {}

        XCTAssertTrue(routingEngine.switchCalls.isEmpty, "切っている間は引き取らない")

        vm.adoptsSystemOutputSelection = true
        audioWorld.queue.sync {}

        XCTAssertEqual(routingEngine.switchCalls.last?.uid, "hdmi-uid", "切替が是正へ届く")
        XCTAssertEqual(directory.currentDefaultOutputID, driverID, "デフォルト出力を掴み直す")
    }

    // 次回起動時の既定値の永続化と、現在のセッションの出力先選択は独立している。
    func testPersistedDefaultOutputDeviceUIDNeverAffectsLiveState() {
        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(
            engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld(),
            resolvedOutputDeviceUID: "initial-uid"
        )
        let initialName = vm.resolvedOutputDeviceName

        vm.persistedDefaultOutputDeviceUID = "new-default-uid"

        XCTAssertEqual(store.outputDeviceUID, "new-default-uid")
        XCTAssertEqual(vm.sessionOutputDeviceUID, "initial-uid")
        XCTAssertEqual(vm.resolvedOutputDeviceName, initialName)
    }

    func testHandleAlphaFadesInWhenVisualizeAreaPreviewActiveAndOutOnDeactivate() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        // ハンドルは EQ が効いている間だけ出る。可用性の既定値は未検出のため、ここで確定させる。
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        vm.handlesRevealed = true
        for k in 0..<60 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }
        let alphaWhileHandlesRevealed = vm.handleAlpha
        XCTAssertGreaterThan(alphaWhileHandlesRevealed, 0.5)

        vm.handlesRevealed = false
        let tLeave = t0.addingTimeInterval(2)
        for k in 0..<120 { vm.tick(now: tLeave.addingTimeInterval(Double(k) * 0.016)) }
        XCTAssertLessThan(vm.handleAlpha, alphaWhileHandlesRevealed)
        XCTAssertLessThan(vm.handleAlpha, 0.1)
    }

    // 指数イージングは漸近するだけで終わらないため、静定後にちょうど目標値で止まる (吸着) ことを固定する。
    func testHandleAlphaMovesDuringFadeThenSettlesExactlyAtTheTarget() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        XCTAssertEqual(vm.handleAlpha, 0, "前提: 待機中は 0 で静止している")

        let t0 = Date(timeIntervalSinceReferenceDate: 2000)
        vm.handlesRevealed = true
        vm.tick(now: t0)
        XCTAssertGreaterThan(vm.handleAlpha, 0, "フェードインの最初の一歩で値が動くこと")

        // 十分な時間ぶんティックし、alpha が 1 へ吸着 (静定) するまで進める。
        for k in 1...240 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "静定の吸着により alpha がちょうど 1 になること")
        vm.tick(now: t0.addingTimeInterval(241 * 0.016))
        XCTAssertEqual(vm.handleAlpha, 1, "静定後にさらに tick してもそこから動かないこと")

        // フェードアウトでも同様に、開始直後は動き、静定後 (alpha=0) でちょうど止まる。
        let tLeave = t0.addingTimeInterval(10)
        vm.handlesRevealed = false
        vm.tick(now: tLeave)
        XCTAssertLessThan(vm.handleAlpha, 1, "フェードアウトの最初の一歩で値が動くこと")
        for k in 1...240 { vm.tick(now: tLeave.addingTimeInterval(Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 0, "静定の吸着により alpha がちょうど 0 になること")
        vm.tick(now: tLeave.addingTimeInterval(241 * 0.016))
        XCTAssertEqual(vm.handleAlpha, 0, "静定後にさらに tick してもそこから動かないこと")
    }

    // 遷移 (プリセットのプレビュー) の間は動き続け、静定後に目標カーブとちょうど一致する。
    func testHandleDisplayGainsMoveDuringPresetPreviewThenSettleExactlyAtTheCurve() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let t0 = Date(timeIntervalSinceReferenceDate: 3000)
        let initialDisplayGains = vm.handleDisplayGains

        vm.previewPreset = .slot2
        vm.tick(now: t0)
        XCTAssertNotEqual(vm.handleDisplayGains, initialDisplayGains, "プレビューカーブへ寄せ始めた最初の一歩で値が動くこと")

        for k in 1...300 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleDisplayGains, store.curve(for: .slot2), "静定の吸着により目標カーブへちょうど一致していること")
        vm.tick(now: t0.addingTimeInterval(301 * 0.016))
        XCTAssertEqual(vm.handleDisplayGains, store.curve(for: .slot2), "静定後にさらに tick してもそこから動かないこと")
    }

    func testCanvasPressRevealsHandlesAndPointerLeavingWhileTheButtonIsUpHidesThem() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.handleRevealGesture = .click

        vm.noteCanvasPointerDown()
        XCTAssertTrue(vm.handlesRevealed, "キャンバス内の押下で表示が ON になること")

        vm.refreshHandleReveal(pointerInsideCanvas: false, pointerButtonDown: true)
        XCTAssertTrue(vm.handlesRevealed, "ボタンを押している間ははみ出しても OFF にしないこと")

        vm.refreshHandleReveal(pointerInsideCanvas: true, pointerButtonDown: false)
        XCTAssertTrue(vm.handlesRevealed, "離した位置がキャンバス内なら OFF にしないこと")

        vm.refreshHandleReveal(pointerInsideCanvas: false, pointerButtonDown: false)
        XCTAssertFalse(vm.handlesRevealed, "ボタンを離していてキャンバス外なら OFF にすること")
    }

    func testCanvasPressDoesNotRevealHandlesWhileTheLongPressIsTheChosenGesture() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        XCTAssertEqual(vm.handleRevealGesture, .longPress, "前提: 既定は長押しであること")

        vm.noteCanvasPointerDown()
        XCTAssertFalse(vm.handlesRevealed, "押下しただけでは表示を ON にしないこと")

        vm.revealHandles()
        XCTAssertTrue(vm.handlesRevealed, "長押しの成立で表示が ON になること")
    }

    func testHandleRevealGestureRoundTripsThroughTheStore() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)

        vm.handleRevealGesture = .click
        XCTAssertEqual(store.handleRevealGesture, .click)
        XCTAssertEqual(makeVM(SettingsStore(defaults: defaults)).handleRevealGesture, .click)
    }

    func testHandleAlphaStaysVisibleWhileDraggingPreamp() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        let t0 = Date(timeIntervalSinceReferenceDate: 4000)

        vm.revealHandles()
        vm.updatePreampDrag(db: -4)
        for k in 0..<240 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }

        XCTAssertEqual(vm.handleAlpha, 1, "プリアンプのドラッグ中はハンドルが表示条件を満たし続けること")
    }

    // MARK: - メータの値は押し出しでのみ届く (取りに行く経路を持たない)

    // UI はオーディオ世界の最初の押し出しより先に構築されるため、
    // 初期値は下限ちょうどではなく厳密に下でなければならない (でないと最下部が点灯して見える)。
    func testInitialMeterValuesSitBelowTheDisplayFloor() {
        // 選べる下限のうち最も低い値より下であることが、この性質が成り立つ条件そのもの (下限候補をハードコードしない)。
        XCTAssertLessThan(
            LevelMeter.silentLevelDb, EQLayout.Tuning.floorDbRange.lowerBound,
            "無音時の値は、選べる下限のどれよりも下でなければならない"
        )

        for floorDb in [EQLayout.Tuning.floorDbRange.lowerBound, EQLayout.Tuning.floorDbRange.upperBound] {
            let store = SettingsStore(defaults: defaults)
            store.floorDb = floorDb
            let vm = makeVM(store)

            XCTAssertTrue(vm.levels.allSatisfy { $0 < floorDb }, "レベルが下限より下 (floor=\(floorDb))")
            XCTAssertTrue(vm.peaks.allSatisfy { $0 < floorDb }, "ピークが下限より下 (floor=\(floorDb))")
            XCTAssertLessThan(vm.stereoLevel.leftDb, floorDb, "L が下限より下 (floor=\(floorDb))")
            XCTAssertLessThan(vm.stereoLevel.rightDb, floorDb, "R が下限より下 (floor=\(floorDb))")
            XCTAssertLessThan(vm.stereoLevel.leftPeakDb, floorDb, "L ピークが下限より下 (floor=\(floorDb))")
            XCTAssertLessThan(vm.stereoLevel.rightPeakDb, floorDb, "R ピークが下限より下 (floor=\(floorDb))")
        }
    }

    func testTickPullsMeterValuesFromTheLevelMeter() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        let initialLevels = vm.levels

        for k in 0..<5 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.levels, initialLevels, "解析器に新しい観測が無ければ表示値も動かない")

        vm.visualizerActive = true
        let frameCount = 8192
        let loud = [Float](repeating: 1.0, count: frameCount)
        loud.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 1)
        }
        vm.tick(now: Date(timeIntervalSinceReferenceDate: 1))

        XCTAssertNotEqual(vm.levels, initialLevels, "tick が解析器から表示値を引き出すこと")
        XCTAssertEqual(vm.levels, engine.levelMeter.snapshot().levels, "引き出した値がそのまま反映されること")
        XCTAssertEqual(vm.peaks, engine.levelMeter.snapshot().peaks)
        XCTAssertEqual(vm.stereoLevel, engine.levelMeter.snapshot().stereo)
    }

    // 解析器を作り直しても表示値は次の tick まで残るため、再開の時点で捨てないと前回の絵が一瞬出る。
    func testActivatingTheVisualizerDropsTheValuesLeftFromTheLastActivation() {
        let store = SettingsStore(defaults: defaults)
        let (vm, engine) = makeVMWithEngine(store)
        let unobserved = LevelMeter.Snapshot.silent(bandCount: EQSpec.bandCount)

        vm.visualizerActive = true
        let frameCount = 8192
        let channels = Int(AudioConfig.channels)
        let interleaved = [Float](repeating: 1.0, count: frameCount * channels)
        interleaved.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: channels)
        }
        vm.tick(now: Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertNotEqual(vm.levels, unobserved.levels, "前提: 閉じる前に観測値が乗っていること")
        XCTAssertNotEqual(vm.peaks, unobserved.peaks, "前提: ピークにも観測値が乗っていること")
        XCTAssertNotEqual(vm.stereoLevel, unobserved.stereo, "前提: L/R にも観測値が乗っていること")

        vm.visualizerActive = false
        vm.visualizerActive = true

        XCTAssertEqual(vm.levels, unobserved.levels, "再開の時点で未観測へ戻ること")
        XCTAssertEqual(vm.peaks, unobserved.peaks)
        XCTAssertEqual(vm.stereoLevel, unobserved.stereo)
    }

    // MARK: - クリップ表示のホールド

    func testClipHoldKeepsLightingForTheHoldDurationThenDecaysByDrawTimeAlone() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        vm.visualizerActive = true

        let frameCount = 8192
        // ちょうどフルスケールは超過に含めないため、1 を上回る振幅を与える。
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for f in 0..<frameCount { interleaved[f * 2] = 1.2 }
        interleaved.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 2)
        }

        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        vm.tick(now: t0)
        XCTAssertTrue(vm.leftClipHolding, "前提: 超過を観測した回は点灯する")
        XCTAssertFalse(vm.rightClipHolding, "前提: 超過していないチャンネルは点灯しない")

        // 保持時間の途中 (解析回の hop 数ではなく描画の経過時間で数える)。新しい捕捉は与えない。
        vm.tick(now: t0.addingTimeInterval(EQLayout.Tuning.clipHoldSeconds * 0.5))
        XCTAssertTrue(vm.leftClipHolding, "保持時間の途中では点灯し続けること")

        // 保持時間を過ぎたら消える。
        vm.tick(now: t0.addingTimeInterval(EQLayout.Tuning.clipHoldSeconds + 0.01))
        XCTAssertFalse(vm.leftClipHolding, "保持時間を過ぎたら消えること (解析が止まった後も描画の経過時間だけで減衰する)")
    }

    func testClipHoldIsDiscardedOnRestart() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        vm.visualizerActive = true

        let frameCount = 8192
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for f in 0..<frameCount { interleaved[f * 2] = 1.2 }
        interleaved.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 2)
        }
        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        vm.tick(now: t0)
        XCTAssertTrue(vm.leftClipHolding, "前提: 保持が残っていること")

        engine.levelMeterRestartGeneration.add(1)
        vm.tick(now: t0.addingTimeInterval(0.001))
        XCTAssertFalse(vm.leftClipHolding, "作り直しの申告で保持が捨てられること")

        interleaved.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 2)
        }
        vm.tick(now: t0.addingTimeInterval(0.002))
        XCTAssertTrue(vm.leftClipHolding, "前提: 作り直し後も新しい超過は点灯すること")

        vm.visualizerActive = false
        vm.visualizerActive = true
        XCTAssertFalse(vm.leftClipHolding, "可視性の再開で保持が捨てられること")
    }

    // MARK: - 作り直しの申告

    func testRestartGenerationConsecutiveBumpsAreNotLost() {
        let store = SettingsStore(defaults: defaults)
        let (vm, engine) = makeVMWithEngine(store)
        let nonFloor = LevelMeter.Snapshot(
            levels: Array(repeating: -10, count: EQSpec.bandCount),
            peaks: Array(repeating: -10, count: EQSpec.bandCount),
            stereo: LevelMeter.Snapshot.Stereo(leftDb: -10, rightDb: -10, leftPeakDb: -10, rightPeakDb: -10)
        )
        pushMeterSnapshotForTesting(nonFloor, vm: vm, engine: engine)
        XCTAssertEqual(vm.levels.first, -10, "前提: 非フロアの表示値になっていること")

        // 連続した申告 (2 回) をまとめて 1 回の tick で観測させる。
        engine.levelMeterRestartGeneration.add(1)
        engine.levelMeterRestartGeneration.add(1)
        vm.tick(now: Date(timeIntervalSinceReferenceDate: 1))

        XCTAssertEqual(
            vm.levels.first, LevelMeter.silentLevelDb,
            "連続した申告でも取りこぼさず作り直しが実行されること"
        )
    }

    // MARK: - 描画パスへ渡す processingInEffect

    func testTickFollowsThePassedProcessingInEffectInsteadOfRederiving() {
        let store = SettingsStore(defaults: defaults)
        let vm = EQViewModel(engine: AudioEngine(), settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld())
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        vm.handlesRevealed = true
        XCTAssertTrue(vm.processingInEffect, "前提: 自前で導出すると効いている状態になる")

        // 自前の導出と逆の値を渡す。内部で読み直していれば、ハンドルは現れてしまう。
        var t = Date(timeIntervalSinceReferenceDate: 5000)
        for _ in 0..<300 {
            t = t.addingTimeInterval(0.016)
            vm.tick(now: t, processingInEffect: false)
        }
        XCTAssertEqual(vm.handleAlpha, 0, "渡された値に従い、ハンドルが現れないこと")

        for _ in 0..<300 {
            t = t.addingTimeInterval(0.016)
            vm.tick(now: t, processingInEffect: true)
        }
        XCTAssertEqual(vm.handleAlpha, 1, "渡された値に従い、ハンドルが現れること")
    }

    // 効きようが無い間に映すと、効いていない表示の中でバーとキャップだけが音を映し続けてしまう。
    // 押し出された値そのものは保つ。
    func testVisualizerShowsNoObservationWhileDisabled() {
        let unobserved = LevelMeter.Snapshot.silent(bandCount: EQSpec.bandCount)
        let pushed = LevelMeter.Snapshot(
            levels: Array(repeating: -12.5, count: EQSpec.bandCount),
            peaks: Array(repeating: -6.25, count: EQSpec.bandCount),
            stereo: LevelMeter.Snapshot.Stereo(leftDb: -3, rightDb: -4, leftPeakDb: -1, rightPeakDb: -2)
        )
        // 押し出しが止まる要因と、押し出しが続く要因の両方を通す。
        let disable: [(String, (EQViewModel) -> Void)] = [
            ("停止", { $0.updateProcessingState(.suspended(.routeUnavailable), activeDevice: nil) }),
            ("応答なし", { $0.updateAudioWorldUnresponsive(true) }),
            ("書き手停止", { $0.updateRingStalled(true) }),
            ("音が届かない", { $0.updateDefaultOutputReachesDriver(false) }),
        ]

        for (name, makeDisabled) in disable {
            let (vm, engine) = makeVMWithEngine(SettingsStore(defaults: defaults))
            vm.confirmDriverProbe(.versionsUnreadable(.ok))
            // 起動の最初の組み立てを終えるまでは停止が警告にならないため、終えた状態にしておく。
            vm.noteStartupActivationSettled()
            vm.updateProcessingState(.active, activeDevice: nil)
            pushMeterSnapshotForTesting(pushed, vm: vm, engine: engine)
            XCTAssertEqual(vm.displayedLevels, pushed.levels, "前提: 効いている間は観測を映す (\(name))")

            makeDisabled(vm)

            XCTAssertFalse(vm.canToggleBypass, "前提: 効きようが無い状態になっている (\(name))")
            XCTAssertEqual(vm.displayedLevels, unobserved.levels, name)
            XCTAssertEqual(vm.displayedPeaks, unobserved.peaks, name)
            XCTAssertEqual(vm.displayedStereoLevel, unobserved.stereo, name)
            XCTAssertEqual(vm.levels, pushed.levels, "押し出された値そのものは保つ (\(name))")

            pushMeterSnapshotForTesting(pushed, vm: vm, engine: engine)
            XCTAssertEqual(vm.displayedLevels, unobserved.levels, "効きようが無い間は押し出しても映さない (\(name))")
        }
    }

    // ミキサーの淡色化はこの導出を同じ地点で読む。アプリ別ゲインは EQ の前段にあるため、
    // バイパスの状態には一切依存しない。
    func testSettingsReachAudioIsIndependentOfBypass() {
        let (vm, _) = makeVMWithEngine(SettingsStore(defaults: defaults))
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.noteStartupActivationSettled()
        vm.updateProcessingState(.active, activeDevice: nil)
        XCTAssertTrue(vm.settingsReachAudio)

        vm.bypass = true
        XCTAssertTrue(vm.settingsReachAudio, "バイパスは届く経路の有無を変えない")
        XCTAssertFalse(vm.processingInEffect, "前提: バイパス中は EQ の加工が効いていない")

        vm.updateDefaultOutputReachesDriver(false)
        XCTAssertFalse(vm.settingsReachAudio, "音が届いていないときは落ちる")

        vm.updateDefaultOutputReachesDriver(true)
        vm.confirmDriverProbe(.versionsUnreadable(.checking))
        XCTAssertFalse(vm.settingsReachAudio, "確認中も落ちる")
    }

    // 音はアプリを通っており観測は本物であるため、灰色にするかどうかとは別の判定を使う。
    func testVisualizerShowsObservationWhileBypassed() {
        let store = SettingsStore(defaults: defaults)
        let (vm, engine) = makeVMWithEngine(store)
        let pushed = LevelMeter.Snapshot(
            levels: Array(repeating: -20, count: EQSpec.bandCount),
            peaks: Array(repeating: -10, count: EQSpec.bandCount),
            stereo: LevelMeter.Snapshot.Stereo(leftDb: -5, rightDb: -6, leftPeakDb: -2, rightPeakDb: -3)
        )
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        vm.bypass = true
        pushMeterSnapshotForTesting(pushed, vm: vm, engine: engine)

        XCTAssertFalse(vm.processingInEffect, "前提: 素通し中は灰色にする側の判定は偽")
        XCTAssertEqual(vm.displayedLevels, pushed.levels)
        XCTAssertEqual(vm.displayedStereoLevel, pushed.stereo)
    }

    // 動的 tick 発火の回帰テストがこのカウンタに依存するため、健全性をここで担保する。
    func testTickInvocationCountIncrementsOncePerCall() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        XCTAssertEqual(vm.tickInvocationCount, 0)

        let t0 = Date(timeIntervalSinceReferenceDate: 7000)
        for k in 0..<5 { vm.tick(now: t0.addingTimeInterval(Double(k) * 0.016)) }

        XCTAssertEqual(vm.tickInvocationCount, 5)
    }

    // init 時点の初期反映と、以後の didSet 経由の反映の両方を確認する。
    func testShowLevelMeterTogglePropagatesToLevelMeterStereoCaptureEnabled() {
        let store = SettingsStore(defaults: defaults)
        store.showLevelMeter = false
        let engine = AudioEngine()
        let audioWorld = makeTestAudioWorld()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: audioWorld)
        audioWorld.queue.sync {}

        XCTAssertFalse(vm.showLevelMeter)
        XCTAssertFalse(engine.levelMeter.stereoCaptureEnabled)

        vm.showLevelMeter = true
        audioWorld.queue.sync {}
        XCTAssertTrue(engine.levelMeter.stereoCaptureEnabled)

        vm.showLevelMeter = false
        audioWorld.queue.sync {}
        XCTAssertFalse(engine.levelMeter.stereoCaptureEnabled)
    }

    // 実際に画面へ表示して RunLoop を実時間で回し、Timer 駆動で tick が周期的に発火することを確認する。
    func testTickFiresDynamicallyViaTimerWhenVisualizerActive() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld())
        // fps が低いほど 1 発火あたりの実時間が長くなり、同じ期待発火数を緩い時間精度で満たせる。
        vm.visualizerFps = EQLayout.Tuning.visualizerFpsChoices.min()!

        let hosting = NSHostingView(rootView: RootView(
            viewModel: vm, mixer: makeMixer(settings: store), mixerClock: nil, onOpenWindow: { _ in }
        ))
        hosting.frame = CGRect(origin: .zero, size: EQLayout.windowDefaultSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        // アプリを activate はせず (他アプリからフォーカスを奪わない) orderFront のみ行う。
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // 観測窓は期待発火数から導出する (秒で固定すると、期待発火数が fps に比例して動いてしまう)。
        let expectedTicks = 6.0
        let windowSeconds = expectedTicks / vm.visualizerFps

        // tick 呼び出し箇所が 1 箇所に統合されていることの回帰確認。
        vm.visualizerActive = false
        Self.pumpRunLoop(for: windowSeconds)
        XCTAssertEqual(vm.tickInvocationCount, 0)

        vm.visualizerActive = true
        Self.pumpRunLoop(for: windowSeconds)

        // 実時間・実 RunLoop に依存するため、CI の負荷変動を吸収できるよう余裕を持たせた範囲で見る。
        // 「まったく発火しない」回帰は下限 0 で別途弾く。
        XCTAssertGreaterThan(vm.tickInvocationCount, 0, "visualizerActive=true で tick が一度も発火しなかった")
        XCTAssertGreaterThan(Double(vm.tickInvocationCount), expectedTicks * 0.4)
        XCTAssertLessThan(Double(vm.tickInvocationCount), expectedTicks * 1.6)
    }

    // 描画側は @Published を自分では数えず、SwiftUI が updateNSView を呼ぶことに頼っている。
    // 配線が切れると (かつ映る値が動いていないと) 絵が固まったまま残る。
    func testPublishedChangeReachesLayersThroughSwiftUIWhileTimerRuns() {
        let band = 3
        let store = SettingsStore(defaults: defaults)
        let (vm, engine) = makeVMWithEngine(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        // レベルを 1 度だけ押し出して静止させる (動いているとその変化に相乗りして反映されてしまう)。
        // Timer が繰り返し pull するため、engine.levelMeter へ書き込み値を保たせる。
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        levels[band] = -10
        pushMeterSnapshotForTesting(
            LevelMeter.Snapshot(levels: levels, peaks: levels, stereo: silentStereoSnapshot), vm: vm, engine: engine
        )

        let hosting = NSHostingView(rootView: RootView(
            viewModel: vm, mixer: makeMixer(settings: store), mixerClock: nil, onOpenWindow: { _ in }
        ))
        hosting.frame = CGRect(origin: .zero, size: EQLayout.windowDefaultSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        vm.visualizerActive = true

        // SwiftUI が階層を組み上げるまで待つ。
        var found: VisualizerHostView?
        pumpRunLoopUntil({
            found = Self.findVisualizerHostView(in: hosting)
            return found != nil
        })
        guard let hostView = found else {
            return XCTFail("SwiftUI の階層からビジュアライザのホストビューが見つからない")
        }
        let capLayer = hostView.eqColumns[band].capLayer
        pumpRunLoopUntil({ !capLayer.isHidden })
        XCTAssertFalse(capLayer.isHidden, "前提: ピークホールドが有効な間はキャップが出ていること")

        vm.peakHoldEnabled = false

        pumpRunLoopUntil({ capLayer.isHidden })
        XCTAssertTrue(capLayer.isHidden, "@Published の変更が SwiftUI 経由でレイヤへ届くこと")
    }

    // showLevelMeter/preampDb の変化が、
    // 実際の SwiftUI 経由の反映経路 (updateNSView) を通って L/R メーター上のプリアンプハンドル線まで届くことを確認する。
    func testPreampHandleLineLayerReflectsVisibilityAndPreampDbThroughSwiftUI() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)

        let hosting = NSHostingView(rootView: RootView(
            viewModel: vm, mixer: makeMixer(settings: store), mixerClock: nil, onOpenWindow: { _ in }
        ))
        hosting.frame = CGRect(origin: .zero, size: EQLayout.windowDefaultSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var found: VisualizerHostView?
        pumpRunLoopUntil({
            found = Self.findVisualizerHostView(in: hosting)
            return found != nil
        })
        guard let hostView = found else {
            return XCTFail("SwiftUI の階層からビジュアライザのホストビューが見つからない")
        }
        let preampLine = hostView.chromeLayers.preampHandleLineLayer
        XCTAssertTrue(preampLine.isHidden, "前提: 表示条件を満たさない間は隠れていること")

        vm.handlesRevealed = true
        vm.visualizerActive = true
        pumpRunLoopUntil({ !preampLine.isHidden })
        XCTAssertFalse(preampLine.isHidden, "表示条件を満たすとハンドル線が現れること")

        let yBefore = preampLine.frame.midY
        vm.overridePreamp(db: EQSpec.DB_MAX)
        pumpRunLoopUntil({ preampLine.frame.midY != yBefore })
        XCTAssertLessThan(preampLine.frame.midY, yBefore, "プリアンプを上げると線が上 (小さい y) へ動くこと")

        vm.showLevelMeter = false
        pumpRunLoopUntil({ preampLine.isHidden })
        XCTAssertTrue(preampLine.isHidden, "L/R レベルメーター非表示ではハンドル線も隠れること")
    }

    // EQ バンドとプリアンプの両方がドラッグ中になっても、バッジ・ドラッグ帯は EQ 側を優先して示す。
    func testDragBadgePrioritizesEQBandOverPreampWhenBothAreDragging() {
        let store = SettingsStore(defaults: defaults)
        let vm = makeVM(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)

        let hosting = NSHostingView(rootView: RootView(
            viewModel: vm, mixer: makeMixer(settings: store), mixerClock: nil, onOpenWindow: { _ in }
        ))
        hosting.frame = CGRect(origin: .zero, size: EQLayout.windowDefaultSize)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var found: VisualizerHostView?
        pumpRunLoopUntil({
            found = Self.findVisualizerHostView(in: hosting)
            return found != nil
        })
        guard let hostView = found else {
            return XCTFail("SwiftUI の階層からビジュアライザのホストビューが見つからない")
        }

        vm.visualizerActive = true
        vm.updatePreampDrag(db: -6)
        vm.updateDrag(band: 2, db: 5)
        XCTAssertTrue(vm.draggingPreamp, "前提: プリアンプもドラッグ中であること")
        XCTAssertEqual(vm.dragIndex, 2, "前提: EQ バンドもドラッグ中であること")

        pumpRunLoopUntil({ !hostView.chromeLayers.dragFillLayer.isHidden })
        XCTAssertFalse(hostView.chromeLayers.dragFillLayer.isHidden, "両方がドラッグ中でも EQ 側のドラッグ帯が出ること (EQ 優先)")
        XCTAssertFalse(hostView.chromeLayers.dragBadgeLayer.isHidden)
    }

    private static func findVisualizerHostView(in view: NSView) -> VisualizerHostView? {
        if let found = view as? VisualizerHostView {
            found.pinPointerInsideVisualizeArea()
            return found
        }
        for sub in view.subviews {
            if let found = findVisualizerHostView(in: sub) { return found }
        }
        return nil
    }

    /// RunLoop.current を指定秒数ぶん実時間で回す (Timer 等の実際の周期駆動を進めるため)。
    private static func pumpRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    // MARK: - 視覚等価性ハーネス (RootView 全体の golden hash)

    /// 全体をオフスクリーン描画し、ピクセルデータの SHA256 を返す。
    /// 単体ビューではなく画面全体を比較することで、意図しない波及も検知できる。
    private func captureRootViewVisual(showLevelMeter: Bool) -> (hash: String, pngData: Data?) {
        let suiteName = TestDefaults.makeName("EQViewModelTests.visual")
        let visualDefaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaults.remove(name: suiteName, defaults: visualDefaults) }
        let store = SettingsStore(defaults: visualDefaults)
        store.showLevelMeter = showLevelMeter
        let engine = AudioEngine()
        let vm = EQViewModel(engine: engine, settings: store, outputController: makeOutputController(settings: store), audioWorld: makeTestAudioWorld())
        // 可用性の既定値は未検出のため、確定させないと画面全体が効いていない表示になり描画差分が出ない。
        vm.confirmDriverProbe(.versionsUnreadable(.ok))

        // 無音のままだと lit/dim/peak の描画差分が現れず、検出力が下がるため既知振幅の信号を解析させる。
        let frameCount = 8192
        let channels = Int(AudioConfig.channels)
        var samples = [Float](repeating: 0, count: frameCount * channels)
        for i in 0..<samples.count {
            samples[i] = Float(sin(Double(i) * 0.05)) * 0.5
        }
        // アプリと同じ経路で受け取らせる。captureEnabled を開いてから取り込み、tick が引き出す。
        vm.visualizerActive = true
        samples.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: channels)
        }
        vm.tick(now: Date(timeIntervalSinceReferenceDate: 0))
        vm.visualizerActive = false

        let hosting = NSHostingView(rootView: RootView(
            viewModel: vm, mixer: makeMixer(settings: store), mixerClock: nil, onOpenWindow: { _ in }
        ))
        hosting.frame = CGRect(origin: .zero, size: EQLayout.windowDefaultSize)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("bitmapImageRepForCachingDisplay failed")
            return ("", nil)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let bitmapData = rep.bitmapData else {
            XCTFail("bitmapData unavailable")
            return ("", nil)
        }
        let byteCount = rep.bytesPerRow * rep.pixelsHigh
        let pixelData = Data(bytes: bitmapData, count: byteCount)
        let digest = SHA256.hash(data: pixelData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, rep.representation(using: .png, properties: [:]))
    }

    /// golden と不一致の場合、目視確認用に実際の描画結果を tmp/ へ書き出す (デバッグ手段の確保。
    /// 一致時は何も書き出さない)。
    private func assertMatchesGoldenVisualHash(
        _ golden: String, showLevelMeter: Bool, label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let capture = captureRootViewVisual(showLevelMeter: showLevelMeter)
        if capture.hash != golden, let pngData = capture.pngData {
            let dumpURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tmp/visual-equivalence-failure-\(label).png")
            try? pngData.write(to: dumpURL)
        }
        XCTAssertEqual(
            capture.hash, golden,
            "RootView (\(label)) のピクセルハッシュが golden と不一致 (tmp/visual-equivalence-failure-\(label).png に実際の描画結果を書き出した)",
            file: file, line: line
        )
    }

    // byte-identical のみ (閾値なし)。表示が変わる変更を入れたときは、画像を目視で確かめた上で採り直す。
    func testRootViewPixelHashMatchesGoldenWithLevelMeterShown() {
        assertMatchesGoldenVisualHash(Self.goldenRootViewHashLevelMeterShown, showLevelMeter: true, label: "shown")
    }

    // EQ 本体幅がメーター非表示時と同じ幅に戻ることも、この比較で機械的に担保される。
    func testRootViewPixelHashMatchesGoldenWithLevelMeterHidden() {
        assertMatchesGoldenVisualHash(Self.goldenRootViewHashLevelMeterHidden, showLevelMeter: false, label: "hidden")
    }

    /// フォント・アンチエイリアシングは環境間で変わりうるため、開発機・Xcode バージョンに固有の基準値。
    /// CI 環境やツールチェインを変えた場合は再採取が必要になりうる。
    private static let goldenRootViewHashLevelMeterShown =
        "6be19fc757fcbf3ba0456f5c71d7151431885df802ca3cd5ee6b05d6e5ed49fd"
    private static let goldenRootViewHashLevelMeterHidden =
        "5c85b392431b07a91fb7e05ceb4729ee3e1b8675ca7212191467177f657a58ea"

    // MARK: - installOrUpdateDriver / uninstallDriver

    // ガードは同期処理のため completion も同期的に呼ばれる。
    func testInstallOrUpdateDriverSkipsExecutionWhenOutputSwitchUnsafe() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = 99
        mock.uidsByDeviceID[99] = DriverConfig.deviceUID
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(mock: mock, settings: store), audioWorld: makeTestAudioWorld(),
            driverAvailability: .notFound
        )

        var result: Result<Void, DriverInstallCoordinator.ActionError>?
        let completed = expectation(description: "installOrUpdateDriver completion")
        vm.installOrUpdateDriver { result = $0; completed.fulfill() }
        wait(for: [completed], timeout: 1.0)

        guard case .failure(.outputDeviceSwitchFailed) = result else {
            XCTFail("Expected outputDeviceSwitchFailed, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(vm.driverAvailability, .notFound, "DriverInstaller は呼ばれていないため driverAvailability は変化しない (間接検証)")
        XCTAssertTrue(engine.suspensionHistory.isEmpty, "ガードで弾かれドライバに変更が加わらない場合、engine.suspend は呼ばれない")
    }

    func testUninstallDriverSkipsExecutionWhenOutputSwitchUnsafe() {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = 99
        mock.uidsByDeviceID[99] = DriverConfig.deviceUID
        let vm = EQViewModel(
            engine: engine, settings: store, outputController: makeOutputController(mock: mock, settings: store), audioWorld: makeTestAudioWorld(),
            driverAvailability: .ok
        )

        var result: Result<Void, DriverInstallCoordinator.ActionError>?
        let completed = expectation(description: "uninstallDriver completion")
        vm.uninstallDriver { result = $0; completed.fulfill() }
        wait(for: [completed], timeout: 1.0)

        guard case .failure(.outputDeviceSwitchFailed) = result else {
            XCTFail("Expected outputDeviceSwitchFailed, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(vm.driverAvailability, .ok, "DriverInstaller は呼ばれていないため .notFound へは確定しない (間接検証)")
        XCTAssertTrue(engine.suspensionHistory.isEmpty, "ガードで弾かれドライバに変更が加わらない場合、engine.suspend は呼ばれない")
    }

    // MARK: - DriverInstallCoordinator.resolveDriverProbeWithRetry

    func testResolveDriverProbeWithRetryReturnsImmediatelyWhenFirstProbeSucceeds() {
        var waitCount = 0
        let result = DriverInstallCoordinator.resolveDriverProbeWithRetry(
            maxAttempts: 5,
            probe: { .versionsUnreadable(.ok) },
            wait: { waitCount += 1 }
        )
        XCTAssertEqual(result.availability, .ok)
        XCTAssertEqual(waitCount, 0)
    }

    func testResolveDriverProbeWithRetryRetriesUntilProbeSucceeds() {
        let probeResults: [DriverProbe] = [.versionsUnreadable(.notFound), .versionsUnreadable(.versionMismatch), .versionsUnreadable(.ok)]
        var probeIndex = 0
        var waitCount = 0
        let result = DriverInstallCoordinator.resolveDriverProbeWithRetry(
            maxAttempts: probeResults.count,
            probe: {
                let value = probeResults[probeIndex]
                probeIndex += 1
                return value
            },
            wait: { waitCount += 1 }
        )
        XCTAssertEqual(result.availability, .ok)
        XCTAssertEqual(waitCount, 2, "可用でない観測を 2 回した後の 3 回目で成功するため wait は 2 回")
    }

    /// ドライバを入れ替えた直後は、新しいドライバが共有領域を作り直す前に旧版数のまま残ったファイルを読みうる。
    /// この経路だけは版ずれでも待つ。
    func testResolveDriverProbeWithRetryRetriesOnVersionMismatch() {
        var waitCount = 0
        let maxAttempts = 5
        let result = DriverInstallCoordinator.resolveDriverProbeWithRetry(
            maxAttempts: maxAttempts,
            probe: { .versionsUnreadable(.versionMismatch) },
            wait: { waitCount += 1 }
        )
        XCTAssertEqual(result.availability, .versionMismatch)
        XCTAssertEqual(waitCount, maxAttempts)
    }

    /// 起動経路の条件は変えない (起動時の版ずれは安定した実状態であり、待っても変わらない)。
    func testLaunchPathStillDoesNotRetryOnVersionMismatch() {
        var waitCount = 0
        let result = AudioActivationCoordinator.openRetryingHeaderInvalid(
            maxAttempts: 5,
            probe: { .failure(.versionMismatch(found: 1, expected: 2)) },
            wait: { waitCount += 1 }
        )
        guard case .failure(.versionMismatch) = result else { return XCTFail("versionMismatch を期待") }
        XCTAssertEqual(waitCount, 0)
    }

    func testResolveDriverProbeWithRetryGivesUpAfterMaxAttempts() {
        var waitCount = 0
        let maxAttempts = 5
        let result = DriverInstallCoordinator.resolveDriverProbeWithRetry(
            maxAttempts: maxAttempts,
            probe: { .versionsUnreadable(.notFound) },
            wait: { waitCount += 1 }
        )
        XCTAssertEqual(result.availability, .notFound)
        XCTAssertEqual(waitCount, maxAttempts)
    }

    // MARK: - topBarWarningIdentifier (上部バー警告の優先順位)

    // 稼働中・異常なしでは nil。
    func testTopBarWarningIdentifierPrioritizesDriverAvailabilityOverSuspensionOverRingStalled() {
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .notFound, processingState: .suspended(.driverOperation), ringStalled: true, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .driverNotFound, "ドライバ未検出が最優先"
        )
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .versionMismatch, processingState: .active, ringStalled: true, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .driverVersionMismatch
        )
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .ok, processingState: .suspended(.routeUnavailable), ringStalled: true, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .outputRouteSelectionRequired, "選び直しで再開できる停止は音声取得失敗より優先"
        )
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .ok, processingState: .suspended(.driverOperation), ringStalled: true, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .restartRequired
        )
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .ok, processingState: .suspended(.applicationTermination), ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .restartRequired
        )
        XCTAssertEqual(
            topBarWarningIdentifier(driverAvailability: .ok, processingState: .active, ringStalled: true, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true),
            .audioUnavailable
        )
        XCTAssertNil(topBarWarningIdentifier(driverAvailability: .ok, processingState: .active, ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true), "異常なしは nil")
    }

    // 占有が解けている間は書き手の IO が動かず、正常な無音と区別が付かないため停止の判定は立たない。
    // 利用者からは同じ状態に見えるため、停止と同じ識別子で伝える。
    func testTopBarWarningIdentifierReportsAudioUnavailableWhenDriverDoesNotOccupyDefaultOutput() {
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .ok, processingState: .active,
                ringStalled: false, defaultOutputReachesDriver: false, audioWorldUnresponsive: false, startupActivationSettled: true
            ),
            .audioUnavailable
        )
    }

    // まだ何も試していない状態と、試して決まらなかった状態の区別が付かないため。
    func testTopBarWarningIdentifierWithholdsOutputRouteUntilStartupActivationSettles() {
        XCTAssertNil(
            topBarWarningIdentifier(
                driverAvailability: .ok, processingState: .suspended(.routeUnavailable),
                ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false,
                startupActivationSettled: false
            )
        )
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .ok, processingState: .suspended(.routeUnavailable),
                ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false,
                startupActivationSettled: true
            ),
            .outputRouteSelectionRequired, "試した結果として決まらなかった場合は伝える"
        )
    }

    // ドライバ側の問題は稼働状態とは独立に確定するため。
    func testTopBarWarningIdentifierReportsDriverProblemsBeforeStartupActivationSettles() {
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .notFound, processingState: .suspended(.routeUnavailable),
                ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false,
                startupActivationSettled: false
            ),
            .driverNotFound
        )
    }

    func testTopBarWarningIdentifierPrioritizesSuspensionOverDefaultOutputOccupancy() {
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .ok, processingState: .suspended(.routeUnavailable),
                ringStalled: false, defaultOutputReachesDriver: false, audioWorldUnresponsive: false, startupActivationSettled: true
            ),
            .outputRouteSelectionRequired
        )
    }

    // 他の警告はいずれも値が更新され続けることを前提にしており、
    // 応答が無い間はどの値も古いまま静止するため、前提の崩れを先に伝える。
    func testTopBarWarningIdentifierPrioritizesAudioWorldUnresponsiveOverEverythingElse() {
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .notFound, processingState: .suspended(.driverOperation),
                ringStalled: true, defaultOutputReachesDriver: true, audioWorldUnresponsive: true, startupActivationSettled: true
            ),
            .audioWorldUnresponsive, "ドライバ未検出より前に出る"
        )
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .ok, processingState: .active,
                ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: true, startupActivationSettled: true
            ),
            .audioWorldUnresponsive, "他がすべて正常でも出る"
        )
    }

    // 可用性を根拠にした判定は「確認中」のままでは何も出せない。
    func testTopBarWarningIdentifierSurfacesUnresponsiveWhileDriverAvailabilityStillChecking() {
        XCTAssertNil(
            topBarWarningIdentifier(
                driverAvailability: .checking, processingState: .suspended(.routeUnavailable),
                ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: false, startupActivationSettled: true
            ),
            "確認中だけでは警告を出さない"
        )
        XCTAssertEqual(
            topBarWarningIdentifier(
                driverAvailability: .checking, processingState: .suspended(.routeUnavailable),
                ringStalled: false, defaultOutputReachesDriver: true, audioWorldUnresponsive: true, startupActivationSettled: true
            ),
            .audioWorldUnresponsive
        )
    }

    func testTopBarWarningIdentifierDoesNotSurfaceAudioUnavailableWhileSuspended() {
        let identifier = topBarWarningIdentifier(
            driverAvailability: .ok, processingState: .suspended(.routeUnavailable), ringStalled: true, defaultOutputReachesDriver: true,
            audioWorldUnresponsive: false, startupActivationSettled: true
        )
        XCTAssertEqual(identifier, .outputRouteSelectionRequired)
    }

    // MARK: - TopBarWarningPolicy.content (表示内容の対応表)

    // 選び直せるのは同じ画面のピッカーであり、別画面の設定は次回起動の既定値だけを変えるため。
    func testOutputRouteSelectionRequiredContentHasNoDestination() {
        let content = TopBarWarningPolicy.content(for: .outputRouteSelectionRequired)
        XCTAssertEqual(content.destination, .none)
    }

    func testDriverAndRestartWarningsDestinationIsSettings() {
        for identifier: TopBarWarningIdentifier in [.driverNotFound, .driverVersionMismatch, .restartRequired] {
            XCTAssertEqual(TopBarWarningPolicy.content(for: identifier).destination, .settings, "\(identifier)")
        }
    }

    // 音声取得失敗も誘導先を持たない (選び直しでは解決しない異常のため、他画面へは送らない)。
    func testAudioUnavailableContentHasNoDestination() {
        XCTAssertEqual(TopBarWarningPolicy.content(for: .audioUnavailable).destination, .none)
    }

    // 選び直しはそのキューの上でしか実行できず、応答が無い間に押しても黙って何も起きないため、
    // 受け付けない形にしてある。
    func testCannotSelectOutputDeviceWhileAudioWorldUnresponsive() {
        let store = SettingsStore(defaults: defaults)
        let (vm, _) = makeVMWithWorld(store)
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        XCTAssertTrue(vm.canSelectOutputDevice, "稼働中は選び直せる")

        vm.updateAudioWorldUnresponsive(true)
        XCTAssertFalse(vm.canSelectOutputDevice, "応答していない間は受け付けない")

        vm.updateAudioWorldUnresponsive(false)
        XCTAssertTrue(vm.canSelectOutputDevice, "応答が戻れば選び直せる")
    }

    // 応答なしも誘導先を持たない (是正手段がアプリの中に無く、送る先が存在しない)。
    func testAudioWorldUnresponsiveContentHasNoDestination() {
        XCTAssertEqual(TopBarWarningPolicy.content(for: .audioWorldUnresponsive).destination, .none)
    }

    // キューが塞がっている間に伝える値のため、音に関わる資源を持つキューは経由しない (値渡しにしてある)。
    func testUpdateAudioWorldUnresponsiveSurfacesWarningWithoutDrainingAudioWorld() {
        let store = SettingsStore(defaults: defaults)
        let (vm, _) = makeVMWithWorld(store)
        let before = vm.topBarWarning

        vm.updateAudioWorldUnresponsive(true)
        XCTAssertEqual(
            vm.topBarWarning, TopBarWarningPolicy.content(for: .audioWorldUnresponsive),
            "キューを回さずに、他の警告を押しのけて出る"
        )

        vm.updateAudioWorldUnresponsive(false)
        XCTAssertEqual(vm.topBarWarning, before, "応答が戻れば元の判定へ戻る")
    }

    // MARK: - resolvedOutputDevicePickerOptions (共有ピッカーの候補一覧)

    func testResolvedOutputDevicePickerOptionsReturnsOptionsUnchangedWhenSelectionIsPresent() {
        let options = [OutputDeviceOption(uid: "a", name: "A"), OutputDeviceOption(uid: "b", name: "B")]
        let resolved = resolvedOutputDevicePickerOptions(selection: "b", options: options, fallbackLabel: "fallback")
        XCTAssertEqual(resolved, options)
    }

    func testResolvedOutputDevicePickerOptionsPrependsFallbackWhenSelectionIsMissing() {
        let options = [OutputDeviceOption(uid: "a", name: "A")]
        let resolved = resolvedOutputDevicePickerOptions(selection: "missing", options: options, fallbackLabel: "Fallback Name")
        XCTAssertEqual(resolved, [OutputDeviceOption(uid: "missing", name: "Fallback Name"), OutputDeviceOption(uid: "a", name: "A")])
    }

    func testResolvedOutputDevicePickerOptionsReturnsOptionsUnchangedWhenSelectionIsNil() {
        let options = [OutputDeviceOption(uid: "a", name: "A")]
        XCTAssertEqual(resolvedOutputDevicePickerOptions(selection: nil, options: options, fallbackLabel: "fallback"), options)
    }
}
