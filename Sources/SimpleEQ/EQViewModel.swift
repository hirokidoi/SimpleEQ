import Combine
import CoreAudio
import Foundation
import Synchronization

/// EQ 画面の状態ハブ。UI ↔ 音声エンジン ↔ 設定の永続化の橋渡しを一元化する。
@MainActor
final class EQViewModel: ObservableObject {
    /// 各バンドの EQ ゲイン (dB) の表示値。高頻度に変わるため @Published にしない。
    private(set) var gains: [Double] { didSet { displayRevision += 1; refreshAutoPreamp() } }
    /// EQ バイパス (true = 素通し)。
    @Published var bypass: Bool {
        didSet {
            guard oldValue != bypass else { return }
            applyProcessingSettingsToEngine()
            settings.bypass = bypass
        }
    }
    /// EQ ウィンドウを常に最前面 (floating) に保つか。
    @Published var alwaysOnTop: Bool {
        didSet {
            guard oldValue != alwaysOnTop else { return }
            settings.alwaysOnTop = alwaysOnTop
        }
    }
    /// 起動時に EQ ウィンドウを自動表示するか。
    @Published var showWindowOnLaunch: Bool {
        didSet {
            guard oldValue != showWindowOnLaunch else { return }
            settings.showWindowOnLaunch = showWindowOnLaunch
        }
    }
    @Published var viewMode: ViewMode {
        didSet {
            guard oldValue != viewMode else { return }
            settings.viewMode = viewMode
        }
    }
    /// L/R レベルメーターの表示/非表示。
    @Published var showLevelMeter: Bool {
        didSet {
            guard oldValue != showLevelMeter else { return }
            settings.showLevelMeter = showLevelMeter
            applyProcessingSettingsToEngine()
        }
    }

    // MARK: - 出力デバイス選択 (Settings = 既定値の永続化のみ、それ以外 = セッション限定・即時反映)

    /// Settings 画面で選ぶ、次回起動時に使う既定の出力デバイス UID。未設定 (nil) は起動時の自動選択を意味する。
    @Published var persistedDefaultOutputDeviceUID: String? {
        didSet {
            guard oldValue != persistedDefaultOutputDeviceUID else { return }
            settings.outputDeviceUID = persistedDefaultOutputDeviceUID
        }
    }
    @Published var adoptsSystemOutputSelection: Bool {
        didSet {
            guard oldValue != adoptsSystemOutputSelection else { return }
            settings.adoptsSystemOutputSelection = adoptsSystemOutputSelection
            applySystemOutputAdoptionSetting()
        }
    }
    /// セッション限定 (非永続) の出力デバイス UID。
    @Published var sessionOutputDeviceUID: String? {
        didSet {
            guard !isApplyingOutputDeviceSelection, oldValue != sessionOutputDeviceUID, sessionOutputDeviceUID != nil else { return }
            applySessionOutputDeviceSelection()
        }
    }
    /// 出力先を選び直せるか。
    var canSelectOutputDevice: Bool {
        guard !audioWorldUnresponsive else { return false }
        guard driverAvailability == .ok else { return false }
        switch processingState {
        case .active: return true
        case .suspended(let cause): return SuspensionPolicy.allowsSelectionResume(cause)
        }
    }
    /// 設定が音へ届く経路があるか。バイパスの状態には依存しない。
    var settingsReachAudio: Bool {
        topBarWarning == nil && driverAvailability != .checking
    }
    /// EQ の ON/OFF を切り替えられるか。
    var canToggleBypass: Bool { settingsReachAudio }
    /// EQ の加工が今この瞬間に音へ効いているか。
    var processingInEffect: Bool { !bypass && canToggleBypass }
    var primingSilenceCountSinceLaunch: UInt64 { engine.runtimeMetrics.primingSilenceCountSinceLaunch }
    /// プリアンプ (EQ ブースト後のクリップ防止用の広帯域ゲイン、dB)。
    @Published private(set) var preampDb: Double {
        didSet {
            guard oldValue != preampDb else { return }
            applyProcessingSettingsToEngine()
            if dragIndex == nil { settings.preampDb = preampDb }
        }
    }
    /// 人がプリアンプを置き直したことを表す唯一の入口。
    func overridePreamp(db: Double) {
        guard !bypass else { return }
        preampAutoEnabled = false
        preampDb = EQSpec.clampDb(db)
    }
    private func applyDerivedPreamp(_ db: Double) { preampDb = db }
    @Published private(set) var preampAutoEnabled: Bool {
        didSet {
            guard oldValue != preampAutoEnabled else { return }
            settings.preampAutoEnabled = preampAutoEnabled
            refreshAutoPreamp()
        }
    }
    @Published private(set) var preampAutoTargetDb: Double {
        didSet {
            guard oldValue != preampAutoTargetDb else { return }
            settings.preampAutoTargetDb = preampAutoTargetDb
            refreshAutoPreamp()
        }
    }

    func setPreampAutoTargetDb(_ db: Double) {
        guard !bypass else { return }
        preampAutoTargetDb = AutoPreampSpec.normalizedTargetDb(db)
    }

    // MARK: - Settings 画面: ビジュアライザ・UI 演出 (変更は即時反映)

    /// ビジュアライザの再描画上限フレームレート (fps)。
    @Published var visualizerFps: Double {
        didSet {
            guard oldValue != visualizerFps else { return }
            settings.visualizerFps = visualizerFps
        }
    }
    /// ビジュアライザ (バーレベル) の dBFS 下限。
    @Published var floorDb: Double {
        didSet {
            guard oldValue != floorDb else { return }
            settings.floorDb = floorDb
        }
    }
    /// レベルメーターの立ち上がり速度の段。
    @Published var attackLevel: Int {
        didSet {
            guard oldValue != attackLevel else { return }
            settings.attackLevel = attackLevel
            applyProcessingSettingsToEngine()
        }
    }
    /// レベルメーターの下がり速度の段。
    @Published var releaseLevel: Int {
        didSet {
            guard oldValue != releaseLevel else { return }
            settings.releaseLevel = releaseLevel
            applyProcessingSettingsToEngine()
        }
    }
    /// ハンドル表示アルファのフェード速度の段。
    @Published var handleFadeLevel: Int {
        didSet {
            guard oldValue != handleFadeLevel else { return }
            settings.handleFadeLevel = handleFadeLevel
        }
    }
    /// ハンドルのプリセットプレビュー追従速度の段。
    @Published var handlePreviewLevel: Int {
        didSet {
            guard oldValue != handlePreviewLevel else { return }
            settings.handlePreviewLevel = handlePreviewLevel
        }
    }
    /// ピークホールド表示の有効/無効。
    @Published var peakHoldEnabled: Bool {
        didSet {
            guard oldValue != peakHoldEnabled else { return }
            settings.peakHoldEnabled = peakHoldEnabled
            applyProcessingSettingsToEngine()
        }
    }
    /// ピーク到達後、減衰を始めるまで保持する時間 (秒)。
    @Published var peakHoldSeconds: Double {
        didSet {
            guard oldValue != peakHoldSeconds else { return }
            settings.peakHoldSeconds = peakHoldSeconds
            applyProcessingSettingsToEngine()
        }
    }
    /// ホールド終了後にピークが下がっていく速度 (dB/秒)。
    @Published var peakDecayDbPerSec: Double {
        didSet {
            guard oldValue != peakDecayDbPerSec else { return }
            settings.peakDecayDbPerSec = peakDecayDbPerSec
            applyProcessingSettingsToEngine()
        }
    }
    /// ピークホールド LED を白へ寄せる度合い (0=通常点灯と同色、1=白)。
    @Published var peakCapBrightenAmount: Double {
        didSet {
            guard oldValue != peakCapBrightenAmount else { return }
            settings.peakCapBrightenAmount = peakCapBrightenAmount
        }
    }

    var attackCoef: Double { EQLayout.Tuning.attack.value(at: attackLevel) }
    var releaseCoef: Double { EQLayout.Tuning.release.value(at: releaseLevel) }
    var handleFadeTau: Double { EQLayout.Tuning.handleFade.value(at: handleFadeLevel) }
    var handlePreviewTau: Double { EQLayout.Tuning.handlePreview.value(at: handlePreviewLevel) }
    /// 専用ドライバの利用可否。
    @Published private(set) var driverProbe: DriverProbe

    /// 分岐に使う可用性。
    var driverAvailability: DriverAvailability { driverProbe.availability }
    /// 音声処理の稼働状態。
    @Published private(set) var processingState: ProcessingState
    /// 共有メモリへの書き込みが直近で停止しているか。
    @Published private(set) var ringStalled: Bool = false
    /// システムのデフォルト出力から自ドライバへ音が届く経路になっているか。
    @Published private(set) var defaultOutputReachesDriver: Bool = true
    /// 音に関わる資源を持つ直列キューが応答していないか。
    @Published private(set) var audioWorldUnresponsive: Bool = false
    /// 起動の最初の組み立てを終えたか。
    @Published private(set) var startupActivationSettled: Bool = false
    /// 上部バーの警告チップの表示内容 (文言と誘導先)。該当なしは nil。
    var topBarWarning: TopBarWarningContent? {
        topBarWarningIdentifier(
            driverAvailability: driverAvailability, processingState: processingState,
            ringStalled: ringStalled, defaultOutputReachesDriver: defaultOutputReachesDriver,
            audioWorldUnresponsive: audioWorldUnresponsive, startupActivationSettled: startupActivationSettled
        ).map(TopBarWarningPolicy.content(for:))
    }
    @Published var visualizerActive: Bool = false {
        didSet {
            guard oldValue != visualizerActive else { return }
            if visualizerActive {
                engine.levelMeter.resetForRestart()
                resetDisplayedMeter()
                resetClipHold()
                engine.levelMeter.captureEnabled = true
            } else {
                engine.levelMeter.captureEnabled = false
            }
        }
    }
    var handlesRevealed: Bool = false
    var hoveringPresetGroup: Bool = false
    var hoveringPreset: Bool {
        PresetHoverPreview.showsHandles(hoveringGroup: hoveringPresetGroup, previewing: previewPreset != nil)
    }
    /// プリセット保存ダイアログを表示中か。ハンドル表示条件の一つ。
    var savingPreset: Bool = false
    /// hover 中のプリセット (プレビュー対象)。設定中はハンドル線をこのプリセットの内容で表示する。
    var previewPreset: EQPreset?
    /// ドラッグ中のバンド index (未ドラッグ時 nil)。
    private(set) var dragIndex: Int? { didSet { displayRevision += 1 } }
    /// プリアンプハンドルをドラッグ中か。
    private(set) var draggingPreamp: Bool = false { didSet { displayRevision += 1 } }
    /// 選択中のプリセット。現在の状態がプリセットの内容と一致しなくなったら nil。
    @Published private(set) var selectedPreset: EQPreset?
    /// プリセットの内容が変わるたびに増分する信号。
    @Published private(set) var presetRevision: Int = 0
    /// per-band dBFS ビジュアライザレベル。post-EQ の実 FFT から押し出される。
    private(set) var levels: [Double] { didSet { displayRevision += 1 } }
    /// per-band ピークホールド値 (dBFS)。levels 以上を保ち、一定時間の保持後にゆっくり減衰する。
    private(set) var peaks: [Double] { didSet { displayRevision += 1 } }
    /// L/R マスターレベル (dBFS)。
    private(set) var stereoLevel: LevelMeter.Snapshot.Stereo { didSet { displayRevision += 1 } }
    private var leftClipHoldRemaining: Double = 0
    private var rightClipHoldRemaining: Double = 0
    var leftClipHolding: Bool { leftClipHoldRemaining > 0 }
    var rightClipHolding: Bool { rightClipHoldRemaining > 0 }
    private var lastSeenLevelMeterRestartGeneration: UInt64 = 0
    /// 観測が届いていない状態を表す値。
    private static let unobservedMeter = LevelMeter.Snapshot.silent(bandCount: EQSpec.bandCount)
    /// ビジュアライザが実際に映す値 (描画はこちらだけを読む)。
    var displayedLevels: [Double] { canToggleBypass ? levels : Self.unobservedMeter.levels }
    var displayedPeaks: [Double] { canToggleBypass ? peaks : Self.unobservedMeter.peaks }
    var displayedStereoLevel: LevelMeter.Snapshot.Stereo {
        canToggleBypass ? stereoLevel : Self.unobservedMeter.stereo
    }
    /// ハンドル群 (設定ライン/軸の記号/0dB 基準線) の表示アルファ (0...1)。フェードイン/アウト込み。
    private(set) var handleAlpha: Double = 0 { didSet { displayRevision += 1 } }
    /// ハンドル線の表示に使うゲイン値。
    private(set) var handleDisplayGains: [Double] { didSet { displayRevision += 1 } }
    /// ハンドル線の表示に使うプリアンプ値。
    private(set) var handleDisplayPreamp: Double { didSet { displayRevision += 1 } }

    /// 描画側が映す値が変わるたびに増分する。
    private(set) var displayRevision: Int = 0

    /// 実際に採用されている出力デバイス名。
    @Published private(set) var resolvedOutputDeviceName: String
    /// 出力候補一覧。
    @Published private(set) var availableOutputDeviceOptions: [OutputDeviceOption] = []
    /// sessionOutputDeviceUID の巻き戻し (再代入) 中、didSet の再入を防ぐガード。
    private var isApplyingOutputDeviceSelection = false
    /// 直近に確定した出力デバイス UID。選択の失敗時、戻す先として使う。
    private var confirmedOutputDeviceUID: String?
    /// Settings 画面の「取り込み口」行表示用。
    var driverDeviceName: String { DriverConfig.deviceName }
    /// 出力先が解決できない間の表示用プレースホルダー。
    private static let unresolvedOutputDeviceName = "未設定"

    private let engine: AudioEngine
    private let settings: SettingsStore
    private let audioWorld: AudioWorld
    /// ドライバのインストール/更新/アンインストールフロー。
    private let driverInstallCoordinator: DriverInstallCoordinator
    /// デバイス構成とあるべき状態の突き合わせ。テストからの構築では未注入 (nil) で、その場合は是正を呼ばない。
    private let deviceRoutingReconciler: DeviceRoutingReconciler?
    /// 起動と再開が共有する手順。テストからの構築では未注入 (nil) で、その場合は停止中の選択は再開を試みず巻き戻る。
    private let activationCoordinator: AudioActivationCoordinator?
    /// プリアンプ自動導出の調停役。テストからの構築では未注入 (nil) で、その場合は導出が一切起きない。
    private let autoPreamp: AutoPreampCoordinator?
    private var appliedSampleRate: Double = AudioConfig.baseSampleRate
    /// 出力候補一覧の再列挙をトリガーする通知を登録済みか (二重登録防止)。
    nonisolated private let deviceListListenerRegistered = Mutex<Bool>(false)

    /// tick(now:) が呼ばれた累計回数。描画・状態計算には使わない。
    private(set) var tickInvocationCount = 0
    private var lastTick: Date?

    init(
        engine: AudioEngine, settings: SettingsStore, outputController: OutputDeviceController,
        audioWorld: AudioWorld,
        driverAvailability: DriverAvailability = .notFound,
        processingState: ProcessingState = .active, resolvedOutputDeviceName: String? = nil,
        resolvedOutputDeviceUID: String? = nil,
        deviceRoutingReconciler: DeviceRoutingReconciler? = nil,
        activationCoordinator: AudioActivationCoordinator? = nil,
        autoPreamp: AutoPreampCoordinator? = nil
    ) {
        self.engine = engine
        self.settings = settings
        self.audioWorld = audioWorld
        self.driverInstallCoordinator = DriverInstallCoordinator(outputController: outputController, audioWorld: audioWorld)
        self.deviceRoutingReconciler = deviceRoutingReconciler
        self.activationCoordinator = activationCoordinator
        self.autoPreamp = autoPreamp

        let initialGains = settings.gains
        gains = initialGains
        handleDisplayGains = initialGains
        levels = Self.unobservedMeter.levels
        peaks = Self.unobservedMeter.peaks
        stereoLevel = Self.unobservedMeter.stereo
        bypass = settings.bypass
        alwaysOnTop = settings.alwaysOnTop
        showWindowOnLaunch = settings.showWindowOnLaunch
        viewMode = settings.viewMode
        showLevelMeter = settings.showLevelMeter
        self.driverProbe = .versionsUnreadable(driverAvailability)
        self.processingState = processingState
        self.resolvedOutputDeviceName = resolvedOutputDeviceName ?? Self.unresolvedOutputDeviceName

        persistedDefaultOutputDeviceUID = settings.outputDeviceUID
        adoptsSystemOutputSelection = settings.adoptsSystemOutputSelection
        sessionOutputDeviceUID = resolvedOutputDeviceUID
        confirmedOutputDeviceUID = resolvedOutputDeviceUID
        preampDb = settings.preampDb
        handleDisplayPreamp = settings.preampDb
        preampAutoEnabled = settings.preampAutoEnabled
        preampAutoTargetDb = settings.preampAutoTargetDb
        visualizerFps = settings.visualizerFps
        floorDb = settings.floorDb
        attackLevel = settings.attackLevel
        releaseLevel = settings.releaseLevel
        handleFadeLevel = settings.handleFadeLevel
        handlePreviewLevel = settings.handlePreviewLevel
        peakHoldEnabled = settings.peakHoldEnabled
        peakHoldSeconds = settings.peakHoldSeconds
        peakDecayDbPerSec = settings.peakDecayDbPerSec
        peakCapBrightenAmount = settings.peakCapBrightenAmount

        selectedPreset = settings.preset
        syncSelectedPresetIfInvalid()

        engine.levelMeter.captureEnabled = visualizerActive
        applyProcessingSettingsToEngine()
        autoPreamp?.didDerive = { [weak self] db in self?.applyDerivedPreamp(db) }
    }

    // MARK: - 出力デバイス

    /// sessionOutputDeviceUID の変更を実デバイスへ反映する。settings への書き込みは一切行わない。
    private func applySessionOutputDeviceSelection() {
        guard let uid = sessionOutputDeviceUID else { return }
        audioWorld.submit(
            coalescingKey: AudioRequestKey.outputDeviceSelection
        ) { [engine, activationCoordinator, deviceRoutingReconciler, weak self] token in
            guard let target = resolveSelectableOutputDevice(uid: uid, needsOutput: true, driverDeviceUID: DriverConfig.deviceUID, token) else {
                return DispatchQueue.main.async { self?.revertOutputDeviceSelection() }
            }
            let succeeded: Bool
            // UI 世界のミラー (processingState) ではなく、オーディオ世界の実体を直接読む。
            switch engine.processingState {
            case .active:
                succeeded = engine.switchOutputDevice(to: target, token)
            case .suspended:
                succeeded = activationCoordinator?.resume(outputDevice: target, trigger: .userSelection, token).processingState == .active
            }
            guard succeeded else {
                return DispatchQueue.main.async { self?.revertOutputDeviceSelection() }
            }
            let name = deviceName(target.deviceID, token)
            deviceRoutingReconciler?.reconcile(trigger: .explicit, token)
            DispatchQueue.main.async { self?.adoptOutputDevice(target, name: name ?? Self.unresolvedOutputDeviceName) }
        }
    }

    /// 有効化の時点で既に離れている出力先も引き取れるよう、設定の反映に続けて是正を回す。
    private func applySystemOutputAdoptionSetting() {
        let adopts = adoptsSystemOutputSelection
        audioWorld.submit(
            coalescingKey: AudioRequestKey.systemOutputAdoption
        ) { [deviceRoutingReconciler] token in
            deviceRoutingReconciler?.setAdoptsSystemOutputSelection(adopts, token)
            deviceRoutingReconciler?.reconcile(trigger: .explicit, token)
        }
    }

    /// 選択の巻き戻し。戻す先は直近に確定した値 (confirmedOutputDeviceUID)。
    private func revertOutputDeviceSelection() {
        isApplyingOutputDeviceSelection = true
        sessionOutputDeviceUID = confirmedOutputDeviceUID
        isApplyingOutputDeviceSelection = false
    }

    /// 出力候補一覧の監視を開始する。EQViewModel の生成自体は CoreAudio に触れないため、
    /// この副作用は init に置かず起動シーケンスで明示的に呼ぶ。
    func startObservingOutputDevices() {
        audioWorld.submitUncoalesced { [weak self] token in
            self?.refreshAvailableOutputDeviceOptions(token)
            self?.registerDeviceListListener(token)
        }
    }

    nonisolated private func refreshAvailableOutputDeviceOptions(_ token: AudioWorldToken) {
        let options = enumerateOutputDeviceOptions(needsOutput: true, driverDeviceUID: DriverConfig.deviceUID, token)
        DispatchQueue.main.async { self.availableOutputDeviceOptions = options }
    }

    /// システムのデバイス構成変更 (接続/切断) のたびに availableOutputDeviceOptions を再列挙する。
    nonisolated private func registerDeviceListListener(_ token: AudioWorldToken) {
        let alreadyRegistered = deviceListListenerRegistered.withLock { registered -> Bool in
            defer { registered = true }
            return registered
        }
        guard !alreadyRegistered else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self, audioWorld] _, _ in
            audioWorld.submit(coalescingKey: AudioRequestKey.outputDeviceOptions) { [weak self] token in
                self?.refreshAvailableOutputDeviceOptions(token)
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, audioWorld.queue, block)
    }

    // MARK: - ドラッグ操作

    /// ドラッグ中の目標バンドを band へ更新し、その dB を適用する。band の決め方は呼び出し側の責務。
    func updateDrag(band: Int, db: Double) {
        guard !bypass else { return }
        dragIndex = band
        setGain(band: band, db: db)
        if selectedPreset != nil { selectedPreset = nil }
    }

    /// ドラッグ確定。永続化はここで行う。
    func endDrag() {
        guard dragIndex != nil else { return }
        settings.setGainsAndPreamp(gains, preampDb)
        dragIndex = nil
    }

    /// ダブルクリックでバンドをリセットする。
    func resetGain(band: Int) {
        guard !bypass else { return }
        setGain(band: band, db: 0)
        selectedPreset = nil
        settings.gains = gains
    }

    private func setGain(band: Int, db: Double) {
        let clamped = EQSpec.clampDb(db)
        gains[band] = clamped
        audioWorld.submit(coalescingKey: AudioRequestKey.eqBandGain(band)) { [engine] token in
            engine.setGain(band: band, db: clamped, token)
        }
    }

    func noteCanvasPointerDown() {
        handlesRevealed = true
    }

    func refreshHandleReveal(pointerInsideCanvas: Bool, pointerButtonDown: Bool) {
        guard handlesRevealed else { return }
        guard !HandleRevealPolicy.staysRevealed(
            pointerButtonDown: pointerButtonDown, pointerInsideCanvas: pointerInsideCanvas
        ) else { return }
        handlesRevealed = false
    }

    /// ドラッグ中のプリアンプ更新。値の決め方 (y→dB) は呼び出し側の責務。
    func updatePreampDrag(db: Double) {
        guard !bypass else { return }
        draggingPreamp = true
        overridePreamp(db: db)
    }

    func endPreampDrag() {
        guard draggingPreamp else { return }
        draggingPreamp = false
    }

    func setPreampAutoEnabled(_ enabled: Bool) {
        guard !bypass else { return }
        let wasEnabled = preampAutoEnabled
        preampAutoEnabled = enabled
        // 既に自動なら didSet が走らないため、測定に失敗したままの状態から抜ける契機をここで作る。
        if enabled, wasEnabled { refreshAutoPreamp() }
    }

    func resetPreamp() {
        setPreampAutoEnabled(true)
    }

    private func matchesCurrentState(_ preset: EQPreset) -> Bool {
        settings.curve(for: preset) == gains
    }

    private func syncSelectedPresetIfInvalid() {
        if let selected = selectedPreset, !matchesCurrentState(selected) {
            selectedPreset = nil
        }
    }

    // MARK: - プリセット

    func applyPreset(_ preset: EQPreset) {
        guard !bypass else { return }
        let target = settings.curve(for: preset)
        gains = target
        selectedPreset = preset
        settings.preset = preset
        settings.gains = target
        applyProcessingSettingsToEngine()
    }

    /// プリセットボタンに表示するタイトル。
    func title(for preset: EQPreset) -> String {
        settings.title(for: preset)
    }

    func deletePreset(_ preset: EQPreset) {
        settings.deletePreset(preset)
        if selectedPreset == preset {
            selectedPreset = nil
        }
        presetRevision += 1
    }

    /// 全プリセットの上書き保存内容を消し、組み込みの既定値へ戻す。
    func resetAllPresets() {
        settings.resetAllPresets()
        syncSelectedPresetIfInvalid()
        presetRevision += 1
    }

    func savePreset(_ preset: EQPreset, title: String) {
        let trimmedTitle = EQLayout.clampToPresetTitleMaxWidth(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmedTitle.isEmpty else { return }
        settings.savePreset(preset, curve: gains, title: trimmedTitle)
        settings.gains = gains
        selectedPreset = preset
        settings.preset = preset
        presetRevision += 1
    }

    // MARK: - 毎フレーム更新

    func tick(now: Date, processingInEffect: Bool? = nil) {
        tickInvocationCount += 1
        let dtCap = EQLayout.Tuning.visualizerTickIntervalCap
        let dt = lastTick.map { max(0, min(dtCap, now.timeIntervalSince($0))) } ?? (1.0 / visualizerFps)
        lastTick = now
        let inEffect = processingInEffect ?? self.processingInEffect
        pullMeter(dt: dt, processingInEffect: inEffect)
        advanceHandlePreview(dt: dt)
        updateHandleAlphas(dt: dt, processingInEffect: inEffect)
    }

    private func pullMeter(dt: Double, processingInEffect: Bool) {
        let generation = engine.levelMeterRestartGeneration.value
        if generation != lastSeenLevelMeterRestartGeneration {
            lastSeenLevelMeterRestartGeneration = generation
            engine.levelMeter.resetForRestart()
            resetClipHold()
        }
        let clip = engine.levelMeter.analyzeAvailableHops()
        let snap = engine.levelMeter.snapshot()
        if levels != snap.levels { levels = snap.levels }
        if peaks != snap.peaks { peaks = snap.peaks }
        if stereoLevel != snap.stereo { stereoLevel = snap.stereo }
        advanceClipHold(dt: dt, observation: clip)
    }

    private func resetDisplayedMeter() {
        levels = Self.unobservedMeter.levels
        peaks = Self.unobservedMeter.peaks
        stereoLevel = Self.unobservedMeter.stereo
    }

    private func resetClipHold() {
        leftClipHoldRemaining = 0
        rightClipHoldRemaining = 0
    }

    private func advanceClipHold(dt: Double, observation: LevelMeter.ClipObservation) {
        leftClipHoldRemaining = observation.left ? EQLayout.Tuning.clipHoldSeconds : max(0, leftClipHoldRemaining - dt)
        rightClipHoldRemaining = observation.right ? EQLayout.Tuning.clipHoldSeconds : max(0, rightClipHoldRemaining - dt)
    }

    /// ドライバのプローブ結果を確定させる単一の入口。
    func confirmDriverProbe(_ probe: DriverProbe) {
        driverProbe = probe
    }

    /// 稼働状態へ遷移した時点で、設定の流し込みと表示の復元を順に行う。停止状態へ遷移した時点では、
    /// 出力先の選択と表示名を空へ戻す。
    func updateProcessingState(_ state: ProcessingState, activeDevice: ActiveOutputDeviceInfo?) {
        guard processingState != state else { return }
        processingState = state
        switch state {
        case .active:
            applyProcessingSettingsToEngine()
            if let activeDevice {
                adoptOutputDevice(activeDevice.device, name: activeDevice.name ?? Self.unresolvedOutputDeviceName)
            }
        case .suspended:
            clearOutputDeviceSelection()
        }
    }

    /// エンジン側設定を再適用する。
    func handleAppliedSampleRateDidChange(_ rate: Double) {
        appliedSampleRate = rate
        applyProcessingSettingsToEngine()
        refreshAutoPreamp()
    }

    /// 起動時の初回導出。起動シーケンスの明示のステップから呼ぶこと (init には置かない)。
    func startAutoPreampDerivation() {
        refreshAutoPreamp()
    }

    private func refreshAutoPreamp() {
        autoPreamp?.refresh(
            enabled: preampAutoEnabled, curve: gains, targetDb: preampAutoTargetDb,
            sampleRate: appliedSampleRate, currentPreampDb: preampDb
        )
    }

    private func applyProcessingSettingsToEngine() {
        let gains = self.gains
        let bypass = self.bypass
        let preampDb = self.preampDb
        audioWorld.submit(coalescingKey: AudioRequestKey.processingSettings) { [engine] token in
            engine.setAllGains(gains, token)
            engine.setBypass(bypass, token)
            engine.setPreamp(db: preampDb, token)
        }
        engine.applyLevelMeterTuning(
            stereoCaptureEnabled: showLevelMeter, attackCoef: attackCoef, releaseCoef: releaseCoef,
            peakHoldEnabled: peakHoldEnabled, peakHoldSeconds: peakHoldSeconds, peakDecayDbPerSec: peakDecayDbPerSec
        )
    }

    /// 停止状態への遷移時に、出力先の選択と表示名をプレースホルダーへ戻す。
    private func clearOutputDeviceSelection() {
        isApplyingOutputDeviceSelection = true
        sessionOutputDeviceUID = nil
        isApplyingOutputDeviceSelection = false
        confirmedOutputDeviceUID = nil
        resolvedOutputDeviceName = Self.unresolvedOutputDeviceName
    }

    /// 是正パスが出力先の実体を差し替えたこと、またはユーザの選び直しが成功した
    /// ことを表示へ反映する単一の入口。
    func adoptOutputDevice(_ device: ResolvedOutputDevice, name: String) {
        guard sessionOutputDeviceUID != device.uid
            || confirmedOutputDeviceUID != device.uid
            || resolvedOutputDeviceName != name else { return }
        isApplyingOutputDeviceSelection = true
        sessionOutputDeviceUID = device.uid
        isApplyingOutputDeviceSelection = false
        confirmedOutputDeviceUID = device.uid
        resolvedOutputDeviceName = name
    }

    func updateRingStalled(_ stalled: Bool) {
        guard ringStalled != stalled else { return }
        ringStalled = stalled
    }

    func updateDefaultOutputReachesDriver(_ reaches: Bool) {
        guard defaultOutputReachesDriver != reaches else { return }
        defaultOutputReachesDriver = reaches
    }

    /// 起動の最初の組み立てが終わったことを伝える単一の入口。以後は戻らない。
    func noteStartupActivationSettled() {
        guard !startupActivationSettled else { return }
        startupActivationSettled = true
    }

    /// ハートビートの判定結果をそのまま反映する。
    func updateAudioWorldUnresponsive(_ unresponsive: Bool) {
        guard audioWorldUnresponsive != unresponsive else { return }
        audioWorldUnresponsive = unresponsive
    }

    /// ハンドル線の表示値 (ゲイン・プリアンプ) を目標へ指数イージングで寄せる。
    private func advanceHandlePreview(dt: Double) {
        let factor = 1 - exp(-dt / handlePreviewTau)
        advanceHandleGainPreview(factor: factor)
        advanceHandlePreampPreview(factor: factor)
    }

    private func advanceHandleGainPreview(factor: Double) {
        if dragIndex != nil {
            if handleDisplayGains != gains { handleDisplayGains = gains }
            return
        }
        let target = previewPreset.map { settings.curve(for: $0) } ?? gains
        guard target != handleDisplayGains else { return }
        var next = handleDisplayGains
        for i in 0..<next.count {
            next[i] += (target[i] - next[i]) * factor
            if abs(target[i] - next[i]) < EQLayout.handleDisplaySettleThresholdDb {
                next[i] = target[i]
            }
        }
        if next != handleDisplayGains { handleDisplayGains = next }
    }

    private func advanceHandlePreampPreview(factor: Double) {
        if draggingPreamp {
            if handleDisplayPreamp != preampDb { handleDisplayPreamp = preampDb }
            return
        }
        let target = previewTargetPreampDb()
        guard target != handleDisplayPreamp else { return }
        var next = handleDisplayPreamp + (target - handleDisplayPreamp) * factor
        if abs(target - next) < EQLayout.handleDisplaySettleThresholdDb {
            next = target
        }
        if next != handleDisplayPreamp { handleDisplayPreamp = next }
    }

    private var requestedPreview: (curve: [Double], sampleRate: Double)?

    private func previewTargetPreampDb() -> Double {
        guard preampAutoEnabled, let preset = previewPreset else {
            requestedPreview = nil
            return preampDb
        }
        // 毎フレーム呼ばれるため、同じ対象への要求は 1 回に留める (測定が失敗し続けても回り続けない)。
        let curve = settings.curve(for: preset)
        let asksForMeasurement = requestedPreview?.curve != curve
            || requestedPreview?.sampleRate != appliedSampleRate
        requestedPreview = (curve, appliedSampleRate)
        return autoPreamp?.previewPreampDb(
            curve: curve, targetDb: preampAutoTargetDb, sampleRate: appliedSampleRate,
            measureIfMissing: asksForMeasurement
        ) ?? preampDb
    }

    private func updateHandleAlphas(dt: Double, processingInEffect: Bool) {
        let wantsVisible = processingInEffect && (handlesRevealed || hoveringPreset || savingPreset)
        let next = fadedAlpha(handleAlpha, toward: wantsVisible ? 1 : 0, dt: dt)
        if next != handleAlpha { handleAlpha = next }
    }

    /// 減衰はフレームレート非依存 (dt 基準)。
    private func fadedAlpha(_ current: Double, toward want: Double, dt: Double) -> Double {
        guard want != current else { return current }
        let next = current + (want - current) * (1 - exp(-dt / handleFadeTau))
        if next < EQLayout.handleVisibilityThreshold { return 0 }
        if 1 - next < EQLayout.handleVisibilityThreshold { return 1 }
        return next
    }

    // MARK: - 専用ドライバの操作 (Settings からのインストール/更新/アンインストール)

    /// Settings の「インストール/更新」ボタンから呼ぶ。安全性ガードが通り実行が確定した直後に、
    /// ドライバ操作を停止種別として専用ドライバに対する自身の状態を解放してから、実行を委譲する。
    /// この停止は選び直しでは再開せず、アプリの再起動を要する。
    func installOrUpdateDriver(completion: @escaping (Result<Void, DriverInstallCoordinator.ActionError>) -> Void) {
        driverInstallCoordinator.installOrUpdate(
            beforeExecuting: { [weak self] token in self?.engine.suspend(cause: .driverOperation, token) },
            afterReprobe: { [weak self] token in self?.deviceRoutingReconciler?.reconcile(trigger: .explicit, token) }
        ) { [weak self] result in
            switch result {
            case .success(let probe):
                self?.confirmDriverProbe(probe)
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Settings の「アンインストール」ボタンから呼ぶ。成功時は driverAvailability を未検出へ確定させる。
    func uninstallDriver(completion: @escaping (Result<Void, DriverInstallCoordinator.ActionError>) -> Void) {
        driverInstallCoordinator.uninstall(
            beforeExecuting: { [weak self] token in self?.engine.suspend(cause: .driverOperation, token) },
            afterReprobe: { [weak self] token in self?.deviceRoutingReconciler?.reconcile(trigger: .explicit, token) }
        ) { [weak self] result in
            switch result {
            case .success(let probe):
                self?.confirmDriverProbe(probe)
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
