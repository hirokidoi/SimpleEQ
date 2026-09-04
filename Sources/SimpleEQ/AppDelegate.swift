import AppKit
import CoreAudio

/// アプリのライフサイクル統括。起動時の出力デバイス復帰・ドライバ可視化と、クリーン終了時の
/// 復帰・非表示化を担う薄い配線層。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audioWorld = AudioWorld()
    private let settings = SettingsStore()
    private lazy var engine = AudioEngine(audioWorld: audioWorld)
    private lazy var outputController = OutputDeviceController(
        settings: settings,
        targetDeviceUID: DriverConfig.deviceUID,
        // オーディオ世界のキュー上から settings へ直接書かせず、メインスレッドへ渡してから書く。
        persistRestoreState: { [settings] uid, pending in
            DispatchQueue.main.async {
                settings.savedDefaultOutputUID = uid
                settings.switchPending = pending
            }
        }
    )
    private lazy var driverLifecycle = DriverLifecycleController(targetDeviceUID: DriverConfig.deviceUID)
    private lazy var activationCoordinator = AudioActivationCoordinator(
        engine: engine,
        driverLifecycle: driverLifecycle,
        outputController: outputController
    )
    private lazy var autoPreamp = AutoPreampCoordinator()
    private lazy var deviceRoutingReconciler: DeviceRoutingReconciler = DeviceRoutingReconciler(
        engine: engine,
        driverLifecycle: driverLifecycle,
        outputController: outputController,
        activationCoordinator: activationCoordinator,
        driverDeviceUID: DriverConfig.deviceUID,
        adoptsSystemOutputSelection: settings.adoptsSystemOutputSelection,
        didAdoptOutputDevice: { [weak self] device, token in
            let name = deviceName(device.deviceID, token)
            DispatchQueue.main.async { self?.viewModel.adoptOutputDevice(device, name: name ?? "未設定") }
        },
        didObserveDefaultOutputReach: { [weak self] reaches in
            DispatchQueue.main.async { self?.viewModel.updateDefaultOutputReachesDriver(reaches) }
        },
        didObserveRingStalled: { [weak self] stalled in
            DispatchQueue.main.async { self?.viewModel.updateRingStalled(stalled) }
        },
        audioWorld: audioWorld
    )
    private lazy var viewModel: EQViewModel = EQViewModel(
        engine: engine,
        settings: settings,
        outputController: outputController,
        audioWorld: audioWorld,
        driverAvailability: .checking,
        processingState: .suspended(.routeUnavailable),
        deviceRoutingReconciler: deviceRoutingReconciler,
        activationCoordinator: activationCoordinator,
        autoPreamp: autoPreamp
    )

    private lazy var diagnostics: DiagnosticsModel = DiagnosticsModel(engine: engine, audioWorld: audioWorld)

    private lazy var mixerCoordinator = MixerCoordinator(
        audioWorld: audioWorld, bridge: engine, levelStore: engine.mixerLevelStore
    )
    private lazy var mixer: MixerModel = MixerModel(
        settings: settings, coordinator: mixerCoordinator, levelStore: engine.mixerLevelStore
    )

    private var windowController: EQWindowController?
    private var statusItemController: StatusItemController?
    private var routingVerificationTimer: Timer?
    private var mixerPassTimer: Timer?
    private var audioWorldHeartbeatTimer: Timer?
    private var audioWorldLastResponse: TimeInterval?
    private var audioWorldHeartbeatWaitingSince: TimeInterval = 0
    private var audioWorldHeartbeatLastTick: TimeInterval?
    /// 技術的な待ち時間の暫定値。実機検証で調整すること。
    private static let audioWorldHeartbeatInterval: TimeInterval = 1
    private static let audioWorldUnresponsiveThreshold: TimeInterval = 5
    /// タイマーが飛ぶ (省電力による間引き・タイマーの合体) 区間は、ハートビートが投入されていないものとして判定に使わない。
    private static let audioWorldHeartbeatTickGapTolerance: Double = 3

    /// システムスリープ中に進まない時計 (秒)。壁時計だとスリープ復帰直後に必ず応答なしと判定される。
    nonisolated private static func uptimeSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / TimeInterval(NSEC_PER_SEC)
    }
    /// 技術的な待ち時間の暫定値。実機検証で調整すること。
    static let terminationWaitTimeout: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // アプリ全体の appearance を起動時に固定し、popover を含む AppKit ホスト面を一貫してダークにする。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        bootstrapApplication()
    }

    private func bootstrapApplication() {
        engine.outputDeviceDidConfirm = { [outputController] uid in outputController.noteOutputDeviceDidConfirm(uid: uid) }
        engine.processingStateDidChange = { [weak self] state, activeDevice in
            DispatchQueue.main.async { self?.viewModel.updateProcessingState(state, activeDevice: activeDevice) }
        }
        engine.appliedSampleRateDidChange = { [weak self] rate in
            DispatchQueue.main.async { self?.viewModel.handleAppliedSampleRateDidChange(rate) }
        }
        startAudioWorldHeartbeat()
        presentUI()
        beginStartupActivation()
    }

    /// ハートビートは何にも触らない。実行されたという事実だけが情報。
    private func startAudioWorldHeartbeat() {
        audioWorldHeartbeatWaitingSince = Self.uptimeSeconds()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.audioWorldHeartbeatInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioWorld.submit(coalescingKey: AudioRequestKey.heartbeat) { [weak self] _ in
                    let respondedAt = Self.uptimeSeconds()
                    DispatchQueue.main.async { self?.audioWorldLastResponse = respondedAt }
                }
                let now = Self.uptimeSeconds()
                defer { self.audioWorldHeartbeatLastTick = now }
                // tick が飛んだ区間はハートビートが投入されていないため、判定を飛ばし起点を引き直す。
                guard audioWorldHeartbeatTickIsContinuous(
                    now: now, lastTick: self.audioWorldHeartbeatLastTick,
                    interval: Self.audioWorldHeartbeatInterval,
                    tolerance: Self.audioWorldHeartbeatTickGapTolerance
                ) else {
                    self.audioWorldHeartbeatWaitingSince = now
                    return
                }
                self.viewModel.updateAudioWorldUnresponsive(isAudioWorldUnresponsive(
                    now: now,
                    lastResponse: self.audioWorldLastResponse,
                    waitingSince: self.audioWorldHeartbeatWaitingSince,
                    threshold: Self.audioWorldUnresponsiveThreshold
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioWorldHeartbeatTimer = timer
    }

    private func presentUI() {
        let windowController = EQWindowController(
            viewModel: viewModel, settings: settings, diagnostics: diagnostics, mixer: mixer
        )
        self.windowController = windowController
        statusItemController = StatusItemController(
            windowController: windowController, viewModel: viewModel, mixer: mixer,
            diagnostics: diagnostics
        )
        viewModel.startObservingOutputDevices()
        viewModel.startAutoPreampDerivation()
        startPeriodicRoutingVerification()
        startMixerCoordination()
        if viewModel.showWindowOnLaunch {
            windowController.show()
        }
    }

    /// ドライバ可用性はこの投入とは別に確定させる (CoreAudio の同期呼び出しと同じ列に並ばせると、
    /// coreaudiod が応答しない間は確定が届かなくなる)。
    private func beginStartupActivation() {
        confirmDriverProbeOffAudioWorld()
        let configuredOutputDeviceUID = settings.outputDeviceUID
        audioWorld.submitUncoalesced { [activationCoordinator, outputController, weak self] token in
            let outcome = activationCoordinator.activate(
                resolveOutputDevice: { t in
                    Self.resolveOutputDevice(
                        configuredUID: configuredOutputDeviceUID, outputController: outputController, t
                    )
                },
                attempt: .launch, token
            )
            DispatchQueue.main.async { self?.viewModel.noteStartupActivationSettled() }
            if outcome.processingState != .active {
                print("[warn] audio engine not started (output=\(configuredOutputDeviceUID ?? "nil"))")
            }
            // 出力先を選ぶのは利用者であり、ここでアプリが代わりに選ぶことはしない。
            if outcome.outputRouteNotEstablished {
                DispatchQueue.main.async { self?.windowController?.show() }
            }
        }
        audioWorld.submitUncoalesced { [deviceRoutingReconciler] token in
            deviceRoutingReconciler.startObserving(token)
        }
    }

    private func confirmDriverProbeOffAudioWorld() {
        Self.confirmDriverProbeOffAudioWorld(
            probeQueue: DispatchQueue.global(qos: .userInitiated),
            probe: { [activationCoordinator] in activationCoordinator.probeDriver() }
        ) { [weak self] probe in
            guard let self else { return }
            self.viewModel.confirmDriverProbe(probe)
            self.windowController?.recheckDriverInstallPromptAfterStartupConfirmed()
        }
    }

    /// 音に関わる資源を持つ直列キューを経由せずに確定させる配線。このキューを一切参照しないことが要点
    /// (キューには CoreAudio の同期呼び出しが並び、coreaudiod が応答しない間は確定が届かなくなる)。
    /// probe はメインスレッドで呼ばない。confirm は表示へ渡すためメインで呼ぶ。
    nonisolated static func confirmDriverProbeOffAudioWorld(
        probeQueue: DispatchQueue,
        probe: @escaping @Sendable () -> DriverProbe?,
        confirm: @escaping @MainActor (DriverProbe) -> Void
    ) {
        probeQueue.async {
            guard let probed = probe() else { return }
            DispatchQueue.main.async { confirm(probed) }
        }
    }

    /// ウィンドウの可視性から独立した低頻度タイマーで回す (EQ ウィンドウの描画は非表示中に
    /// 止まるため、そちらに載せるとウィンドウを閉じたままの是正が働かなくなる)。
    private func startPeriodicRoutingVerification() {
        let timer = Timer.scheduledTimer(
            withTimeInterval: DeviceRoutingReconciler.verificationInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioWorld.submit(
                    coalescingKey: AudioRequestKey.periodicVerification
                ) { [deviceRoutingReconciler = self.deviceRoutingReconciler, engine = self.engine] token in
                    deviceRoutingReconciler.reconcile(trigger: .periodicVerification, token)
                    engine.applyDriverSampleRateIfChanged(token)
                    engine.refreshDriverObservations(token)
                    // 停止中は自ドライバの ID やデバイスのレートを HAL へ問い合わせに行かない。
                    guard runsPeriodicDeviceQueries(processingState: engine.processingState) else { return }
                    engine.refreshDriverDeviceIDIfNeeded(token)
                    engine.refreshOutputDeviceSampleRate(token)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        routingVerificationTimer = timer
    }

    /// 面の可視性から独立して回る (面が出ていなくてもゲインは効いていなければならない)。
    /// 名簿の追従とリースの更新をこの 1 本が兼ねるため、更新のためだけの第 2 のタイマは持たない。
    private func startMixerCoordination() {
        mixerCoordinator.didUpdate = { [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.mixer.apply(update) } }
        }
        let timer = Timer.scheduledTimer(
            withTimeInterval: MixerCoordinator.passInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mixerCoordinator.runPass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mixerPassTimer = timer
        mixerCoordinator.runPass()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.persistWindowOrigin()
        routingVerificationTimer?.invalidate()
        routingVerificationTimer = nil
        mixerPassTimer?.invalidate()
        mixerPassTimer = nil
        audioWorldHeartbeatTimer?.invalidate()
        audioWorldHeartbeatTimer = nil
        let completed = Self.performCleanExitSequence(
            audioWorld: audioWorld, engine: engine, outputController: outputController,
            driverLifecycle: driverLifecycle, settings: settings, timeout: Self.terminationWaitTimeout
        )
        if !completed {
            print("[warn] termination cleanup did not complete within \(Self.terminationWaitTimeout)s; exiting anyway")
        }
    }

    /// クリーン終了時の後始末本体。
    /// 終了時に限り、完了を同期で待つ (待たないとデフォルト出力が非表示のデバイスを指したまま残る)。
    /// - Returns: 上限内に完了したか。
    @discardableResult
    static func performCleanExitSequence(
        audioWorld: AudioWorld, engine: AudioEngine, outputController: OutputDeviceController,
        driverLifecycle: DriverLifecycleController, settings: SettingsStore, timeout: TimeInterval
    ) -> Bool {
        let restoreStateOnQueue = audioWorld.submitUncoalescedAndWait(timeout: timeout) { token -> (uid: String?, pending: Bool) in
            engine.suspend(cause: .applicationTermination, token)
            driverLifecycle.restoreDisplayNameForCleanExit(token)
            // 先に復帰し、その後で非表示化する (逆順にすると復帰対象の解決前に一覧から消える)。
            if outputController.restore(token) {
                driverLifecycle.hideForCleanExit(token)
            }
            return outputController.currentRestoreState(token)
        }
        guard let restoreState = restoreStateOnQueue else { return false }
        settings.savedDefaultOutputUID = restoreState.uid
        settings.switchPending = restoreState.pending
        return true
    }

    /// 手動固定が現在解決できない場合は自動選択へフォールバックする。ユーザが選んだ固定先自体は
    /// この解決の成否に関わらず変更しない。
    nonisolated private static func resolveOutputDevice(
        configuredUID: String?, outputController: OutputDeviceController, _ token: AudioWorldToken
    ) -> ResolvedOutputDevice? {
        let configuredDevice = configuredUID.flatMap { selectableOutputDevice(uid: $0, token) }
        switch outputDeviceResolutionPolicy(configuredUID: configuredUID, configuredUIDResolvable: configuredDevice != nil) {
        case .configured:
            return configuredDevice
        case .auto:
            return outputController.resolvedRestoreTargetID.flatMap { deviceUID($0, token) }.flatMap { selectableOutputDevice(uid: $0, token) }
        }
    }

    nonisolated private static func selectableOutputDevice(uid: String, _ token: AudioWorldToken) -> ResolvedOutputDevice? {
        resolveSelectableOutputDevice(uid: uid, needsOutput: true, driverDeviceUID: DriverConfig.deviceUID, token)
    }
}
