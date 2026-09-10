import AppKit
import CoreAudio
import Synchronization

/// アプリのライフサイクル統括。
/// 起動時の出力デバイス復帰・ドライバ可視化と、クリーン終了時の復帰・非表示化を担う薄い配線層。
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
    // 以下 3 つは、調停役がそれぞれの専用キューから読む値。UI 世界の状態を直に渡せないため Mutex 越しに置く。
    private let onConsoleBox = Mutex<Bool>(true)
    private let lastKnownOwnsAudioPathBox = Mutex<Bool>(false)
    private let configuredOutputDeviceUIDBox = Mutex<String?>(nil)
    /// console の供給源と描画の門を兼ねる。OS の実状態は 1 つなので、購読も 1 つに保つ。
    private lazy var screenVisibility: ScreenVisibility = {
        let visibility = ScreenVisibility()
        visibility.addObserver { [weak self] in
            guard let self else { return }
            let onConsole = self.screenVisibility.onConsole
            self.onConsoleBox.withLock { $0 = onConsole }
            self.viewModel.updateOnConsole(onConsole)
        }
        onConsoleBox.withLock { $0 = visibility.onConsole }
        return visibility
    }()
    private lazy var ownershipCoordinator = OwnershipCoordinator(
        audioWorld: audioWorld, engine: engine, activationCoordinator: activationCoordinator,
        driverLifecycle: driverLifecycle, outputController: outputController,
        configuredOutputDeviceUID: { [weak self] in self?.configuredOutputDeviceUIDBox.withLock { $0 } ?? nil },
        requestRouteReconciliation: { [reconciler = deviceRoutingReconciler] token in
            reconciler.reconcile(trigger: .explicit, token)
        },
        isOnConsole: { [weak self] in self?.onConsoleBox.withLock { $0 } ?? true }
    )
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
        // 所有権が確定するまでは持たない側から始める。既存の門はこの初期値で働く。
        isOwner: false,
        deviceRoutingReconciler: deviceRoutingReconciler,
        activationCoordinator: activationCoordinator,
        autoPreamp: autoPreamp,
        ownershipCoordinator: ownershipCoordinator
    )

    private lazy var diagnostics: DiagnosticsModel = DiagnosticsModel(
        engine: engine, audioWorld: audioWorld,
        renderSnapshot: { [viewModel] in viewModel.renderMetricsSnapshot() }
    )

    private lazy var mixerCoordinator = MixerCoordinator(
        audioWorld: audioWorld, bridge: engine, levelStore: engine.mixerLevelStore,
        lastKnownOwnsAudioPath: { [weak self] in self?.lastKnownOwnsAudioPathBox.withLock { $0 } ?? false }
    )
    private lazy var mixer: MixerModel = MixerModel(
        settings: settings, coordinator: mixerCoordinator, levelStore: engine.mixerLevelStore
    )

    private var windowController: EQWindowController?
    private var statusItemController: StatusItemController?
    private var routingVerificationTimer: Timer?
    private var mixerPassTimer: Timer?
    private var ownershipPassTimer: Timer?
    private var audioWorldHeartbeatTimer: Timer?
    private var audioWorldLastResponse: TimeInterval?
    private var audioWorldHeartbeatWaitingSince: TimeInterval = 0
    private var audioWorldHeartbeatLastTick: TimeInterval?
    /// 技術的な待ち時間の暫定値。実機検証で調整すること。
    private static let audioWorldHeartbeatInterval: TimeInterval = 1
    private static let audioWorldUnresponsiveThreshold: TimeInterval = 5
    /// タイマーが飛ぶ (省電力による間引き・タイマーの合体) 区間は、ハートビートが投入されていないものとして判定に使わない。
    private static let audioWorldHeartbeatTickGapTolerance: Double = 3

    /// 技術的な待ち時間の暫定値。実機検証で調整すること。
    static let terminationWaitTimeout: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // アプリ全体の appearance を起動時に固定し、popover を含む AppKit ホスト面を一貫してダークにする。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        bootstrapApplication()
    }

    private func bootstrapApplication() {
        // この参照が console の監視を開始する。変化コールバックは変わったときしか来ないため、初期値はここで渡す。
        viewModel.updateOnConsole(screenVisibility.onConsole)
        configuredOutputDeviceUIDBox.withLock { $0 = settings.outputDeviceUID }
        viewModel.persistedDefaultOutputDeviceUIDDidChange = { [weak self] uid in
            self?.configuredOutputDeviceUIDBox.withLock { $0 = uid }
        }
        engine.outputDeviceDidConfirm = { [outputController] uid in outputController.noteOutputDeviceDidConfirm(uid: uid) }
        engine.processingStateDidChange = { [weak self] state, activeDevice in
            DispatchQueue.main.async { self?.viewModel.updateProcessingState(state, activeDevice: activeDevice) }
        }
        engine.appliedSampleRateDidChange = { [weak self] rate in
            DispatchQueue.main.async { self?.viewModel.handleAppliedSampleRateDidChange(rate) }
        }
        ownershipCoordinator.didUpdate = { [weak self, mixer = mixerCoordinator] update in
            guard let self else { return }
            let gained = self.lastKnownOwnsAudioPathBox.withLock { box -> Bool in
                let gained = !box && update.lastKnownSelfOwner
                box = update.lastKnownSelfOwner
                return gained
            }
            // 取り戻した契機で打たないと、次の周まで保存済みのミュートがドライバへ届かない。
            if gained { mixer.runPass() }
            DispatchQueue.main.async { self.viewModel.updateOwnership(update) }
        }
        startAudioWorldHeartbeat()
        presentUI()
        beginStartupActivation()
    }

    /// ハートビートは何にも触らない。実行されたという事実だけが情報。
    private func startAudioWorldHeartbeat() {
        audioWorldHeartbeatWaitingSince = uptimeSeconds()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.audioWorldHeartbeatInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioWorld.submit(coalescingKey: AudioRequestKey.heartbeat) { [weak self] _ in
                    let respondedAt = uptimeSeconds()
                    DispatchQueue.main.async { self?.audioWorldLastResponse = respondedAt }
                }
                let now = uptimeSeconds()
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
            viewModel: viewModel, settings: settings, diagnostics: diagnostics, mixer: mixer,
            screenVisibility: screenVisibility
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
        startOwnershipCoordination()
        // 表示可否は所有権が確定してから決める (→ beginStartupActivation)。
    }

    /// 所有権の周期パス。面の出し入れに関係なく回る (音声経路の可否は面が出ていなくても効いていなければならない)。
    private func startOwnershipCoordination() {
        let timer = Timer.scheduledTimer(
            withTimeInterval: OwnershipCoordinator.passInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ownershipCoordinator.runPass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ownershipPassTimer = timer
    }

    /// ドライバ可用性はこの投入とは別に確定させる (CoreAudio の同期呼び出しと同じ列に並ばせると、
    /// coreaudiod が応答しない間は確定が届かなくなる)。
    /// 出力段の組み立ては所有権が確定してから行う (未所有のまま組み立てると既定出力を横取りしうる)。
    private func beginStartupActivation() {
        // 所有権が確定するまでは経路を作らせない。既定の停止種別のままだと、照合が自動再開で
        // 出力段を組み、既定出力の占有・可視化・表示名の書き込みまで進んでしまう。
        audioWorld.submitUncoalesced { [engine] token in engine.suspend(cause: .ownershipUnavailable, token) }
        confirmDriverProbeOffAudioWorld()
        audioWorld.submitUncoalesced { [deviceRoutingReconciler] token in
            deviceRoutingReconciler.startObserving(token)
        }
        ownershipCoordinator.resolveAtLaunch { [weak self] isSelfOwner in
            DispatchQueue.main.async { self?.finishStartupActivation(isSelfOwner: isSelfOwner) }
        }
    }

    private func finishStartupActivation(isSelfOwner: Bool) {
        guard isSelfOwner else {
            viewModel.noteStartupActivationSettled()
            // 開かないのは他セッションが使用中のときだけ。所有権が読めない状態はドライバ未導入と同じ見え方で、
            // 導入を促す導線はウィンドウの中にしかない。
            if viewModel.showWindowOnLaunch, !viewModel.anotherSessionHoldsAudioPath {
                windowController?.show()
            }
            return
        }
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
        if viewModel.showWindowOnLaunch {
            windowController?.show()
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

    /// ウィンドウの可視性から独立した低頻度タイマーで回す
    /// (EQ ウィンドウの描画は非表示中に止まるため、そちらに載せるとウィンドウを閉じたままの是正が働かなくなる)。
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
        ownershipPassTimer?.invalidate()
        ownershipPassTimer = nil
        audioWorldHeartbeatTimer?.invalidate()
        audioWorldHeartbeatTimer = nil
        let completed = Self.performCleanExitSequence(
            audioWorld: audioWorld, engine: engine, outputController: outputController,
            driverLifecycle: driverLifecycle, ownershipCoordinator: ownershipCoordinator,
            settings: settings, timeout: Self.terminationWaitTimeout
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
        driverLifecycle: DriverLifecycleController, ownershipCoordinator: OwnershipCoordinator,
        settings: SettingsStore, timeout: TimeInterval
    ) -> Bool {
        let restoreStateOnQueue = audioWorld.submitUncoalescedAndWait(timeout: timeout) { token -> (uid: String?, pending: Bool) in
            engine.suspend(cause: .applicationTermination, token)
            ownershipCoordinator.prepareForTermination(token)
            // 所有していない側はここを素通りする (義務も可視性も所有権と一体で降りている)。
            driverLifecycle.restoreDisplayNameForCleanExit(token)
            // 先に復帰し、その後で非表示化する (逆順にすると復帰対象の解決前に一覧から消える)。
            if outputController.restore(token) {
                driverLifecycle.hideForCleanExit(token)
            }
            // 席を空けるのは最後。先に空けると待っている要求者へその場で移り、
            // 以降の後始末が新しい所有者の使っているデバイスへ及ぶ。
            ownershipCoordinator.releaseForCleanExit(token)
            return outputController.currentRestoreState(token)
        }
        guard let restoreState = restoreStateOnQueue else { return false }
        settings.savedDefaultOutputUID = restoreState.uid
        settings.switchPending = restoreState.pending
        return true
    }

    /// 手動固定が現在解決できない場合は自動選択へフォールバックする。
    /// ユーザが選んだ固定先自体はこの解決の成否に関わらず変更しない。
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
