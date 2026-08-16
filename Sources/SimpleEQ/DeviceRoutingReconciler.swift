import AudioToolbox
import CoreAudio
import Foundation

enum DeviceRoutingTrigger: Equatable {
    case configurationChange
    case periodicVerification
    case explicit
}

enum DeviceRoutingScope: Equatable {
    case verifyOutputOnly
    case full
}

/// 定期の検算だけを読み出しのみに絞る (可視性の再適用は毎回打ってよい書き込みではないため)。
func deviceRoutingScope(trigger: DeviceRoutingTrigger) -> DeviceRoutingScope {
    switch trigger {
    case .periodicVerification: return .verifyOutputOnly
    case .configurationChange, .explicit: return .full
    }
}

/// 可視性の実値を優先し、読めなかった場合のみ解決 ID の変化を代理指標にする。
/// - Parameter isHidden: 可視性の実値。読めなかった場合は nil。
func driverVisibilityReapplyNeeded(
    previousID: AudioDeviceID?, resolvedID: AudioDeviceID, isHidden: Bool?
) -> Bool {
    guard let isHidden else { return resolvedID != previousID }
    return isHidden
}

/// 専用ドライバのデバイスが OS の一覧やボリューム表示で名乗る表示名。
enum DriverDisplayName {
    private static let outputSeparator = " - "

    /// - Parameter maxLength: UTF-16 単位。超える分は出力先名の末尾を落とす。
    static func compose(outputDeviceName: String?, fallback: String, maxLength: Int) -> String {
        guard let outputDeviceName, !outputDeviceName.isEmpty else { return fallback }
        return truncating(fallbackBrand(fallback) + outputSeparator + outputDeviceName, toUTF16Length: maxLength)
    }

    private static func fallbackBrand(_ fallback: String) -> String {
        String(fallback.prefix { !$0.isWhitespace })
    }

    private static func truncating(_ text: String, toUTF16Length limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var truncated = ""
        for character in text {
            guard truncated.utf16.count + character.utf16.count <= limit else { break }
            truncated.append(character)
        }
        return truncated
    }
}

struct ReconciledOutputDevice {
    let observedDeviceID: AudioDeviceID?
    let nameSourceDeviceID: AudioDeviceID?

    static func nameSource(_ id: AudioDeviceID?) -> ReconciledOutputDevice {
        ReconciledOutputDevice(observedDeviceID: id, nameSourceDeviceID: id)
    }
    static func observedOnly(_ id: AudioDeviceID?) -> ReconciledOutputDevice {
        ReconciledOutputDevice(observedDeviceID: id, nameSourceDeviceID: nil)
    }
}

func driverDeviceNameHandoffTarget(
    outputDeviceID: AudioDeviceID?, defaultOutputConfirmedAsDriver: Bool
) -> AudioDeviceID? {
    defaultOutputConfirmedAsDriver ? outputDeviceID : nil
}

func driverListenerRebindNeeded(previousID: AudioDeviceID?, resolvedID: AudioDeviceID) -> Bool {
    resolvedID != previousID
}

func aliveListenerRebindActions(
    registered: Set<AudioDeviceID>, desired: Set<AudioDeviceID>
) -> (remove: Set<AudioDeviceID>, add: Set<AudioDeviceID>) {
    (remove: registered.subtracting(desired), add: desired.subtracting(registered))
}

protocol AudioRoutingEngine: AnyObject, Sendable {
    var intendedOutputDeviceUID: String? { get }
    var intendedOutputDeviceUIDAtSuspension: String? { get }
    var processingState: ProcessingState { get }
    func currentOutputDeviceID(_ token: AudioWorldToken) -> AudioDeviceID?
    @discardableResult
    func switchOutputDevice(to device: ResolvedOutputDevice, _ token: AudioWorldToken) -> Bool
    func updateDriverDeviceID(_ id: AudioDeviceID?, _ token: AudioWorldToken)
    var driverDeviceListenerDeviceID: AudioDeviceID? { get }
    func suspend(cause: SuspensionCause, _ token: AudioWorldToken)
    func evaluateRingStalled(_ token: AudioWorldToken) -> Bool
    func reoccupyOutputVolumeRoute(_ token: AudioWorldToken)
}

extension AudioEngine: AudioRoutingEngine {}

typealias DeviceRoutingScheduler = @Sendable (_ after: TimeInterval, _ work: @escaping @Sendable (AudioWorldToken) -> Void) -> Void

typealias AdoptedOutputDeviceReporter = @Sendable (ResolvedOutputDevice, AudioWorldToken) -> Void

typealias DefaultOutputReachReporter = @Sendable (Bool) -> Void

typealias RingStallReporter = @Sendable (Bool) -> Void

/// アプリが持つあるべき状態 (UID) と、デバイス構成の実状態を突き合わせて是正する単一の入口。
/// reconcile(trigger:) は冪等で、実状態があるべき状態と一致していれば何も書き込まない。
final class DeviceRoutingReconciler: @unchecked Sendable {
    /// 日常操作からの自動復帰が、ユーザに気づかれずに済む上限時間。
    static let recoveryDeadline: TimeInterval = 30
    static let verificationInterval: TimeInterval = recoveryDeadline / 2
    /// 構成変更通知の合流窓。ディスプレイスリープ復帰では通知が連続発火するため束ねる。設計値。
    static let coalescingWindow: TimeInterval = 0.2

    private static let aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let directory: AudioDeviceDirectory
    private let engine: AudioRoutingEngine
    private let driverLifecycle: DriverLifecycleController
    private let outputController: OutputDeviceController
    private let activationCoordinator: AudioActivationCoordinator
    private let driverDeviceUID: String
    private let audioWorld: AudioWorld
    private let schedule: DeviceRoutingScheduler
    private let didAdoptOutputDevice: AdoptedOutputDeviceReporter
    private let didObserveDefaultOutputReach: DefaultOutputReachReporter
    private let didObserveRingStalled: RingStallReporter
    private let now: @Sendable () -> Date

    private var adoptsSystemOutputSelection: Bool
    private var lastDriverDeviceID: AudioDeviceID?
    private var coalescingPending = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var aliveListenerDeviceIDs: Set<AudioDeviceID> = []
    private var consecutiveAutomaticResumeFailures = 0
    private var lastAutomaticResumeAttempt: Date?

    /// 通知の再入で試行が自分自身を駆動し続けないよう、定期検算と同じ周期に揃える。
    static let automaticResumeRetryInterval: TimeInterval = verificationInterval

    static let automaticResumeMaxConsecutiveFailures =
        Int((recoveryDeadline / automaticResumeRetryInterval).rounded(.up)) + 1

    init(
        directory: AudioDeviceDirectory = CoreAudioDeviceDirectory(),
        engine: AudioRoutingEngine,
        driverLifecycle: DriverLifecycleController,
        outputController: OutputDeviceController,
        activationCoordinator: AudioActivationCoordinator,
        driverDeviceUID: String,
        initialDriverDeviceID: AudioDeviceID? = nil,
        adoptsSystemOutputSelection: Bool,
        didAdoptOutputDevice: @escaping AdoptedOutputDeviceReporter,
        didObserveDefaultOutputReach: @escaping DefaultOutputReachReporter = { _ in },
        didObserveRingStalled: @escaping RingStallReporter = { _ in },
        audioWorld: AudioWorld,
        schedule: DeviceRoutingScheduler? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.now = now
        self.directory = directory
        self.engine = engine
        self.driverLifecycle = driverLifecycle
        self.outputController = outputController
        self.activationCoordinator = activationCoordinator
        self.driverDeviceUID = driverDeviceUID
        self.lastDriverDeviceID = initialDriverDeviceID
        self.adoptsSystemOutputSelection = adoptsSystemOutputSelection
        self.didAdoptOutputDevice = didAdoptOutputDevice
        self.didObserveDefaultOutputReach = didObserveDefaultOutputReach
        self.didObserveRingStalled = didObserveRingStalled
        self.audioWorld = audioWorld
        self.schedule = schedule ?? { after, work in
            audioWorld.queue.asyncAfter(deadline: .now() + after) {
                work(audioWorld.assumingOnQueue())
            }
        }
    }

    /// 構成変更・検算・明示操作のいずれからも通る単一の入口。冪等。
    func reconcile(trigger: DeviceRoutingTrigger, _ token: AudioWorldToken) {
        // 是正の前ではなく後で観測する (是正が出力先を取り戻しうるため)。
        defer {
            didObserveDefaultOutputReach(outputController.defaultOutputReachesDriver(token))
            didObserveRingStalled(engine.evaluateRingStalled(token))
        }
        if engine.processingState == .active {
            consecutiveAutomaticResumeFailures = 0
            lastAutomaticResumeAttempt = nil
        }
        switch deviceRoutingScope(trigger: trigger) {
        case .verifyOutputOnly:
            guard !stateMatchesIntent(token) else { return }
            reconcileAll(token)
        case .full:
            reconcileAll(token)
        }
    }

    func setAdoptsSystemOutputSelection(_ adopts: Bool, _ token: AudioWorldToken) {
        adoptsSystemOutputSelection = adopts
    }

    func startObserving(_ token: AudioWorldToken) {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.scheduleConfigurationChangeReconcile(self.audioWorld.assumingOnQueue())
        }
        listenerBlock = block
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, audioWorld.queue, block)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, audioWorld.queue, block)
        reconcile(trigger: .configurationChange, token)
    }

    /// 構成変更通知からの起動口。合流窓の間に届いた通知は 1 回のパスへ束ねる。
    func scheduleConfigurationChangeReconcile(_ token: AudioWorldToken) {
        guard !coalescingPending else { return }
        coalescingPending = true
        schedule(Self.coalescingWindow) { [weak self] scheduledToken in
            guard let self else { return }
            self.coalescingPending = false
            self.reconcile(trigger: .configurationChange, scheduledToken)
        }
    }

    /// 検算パス。読み出しのみで、実状態があるべき状態と一致していれば何も書き込まない。
    private func stateMatchesIntent(_ token: AudioWorldToken) -> Bool {
        let resolvedDriverDeviceID = directory.resolveHiddenDeviceID(forUID: driverDeviceUID, token)
        guard driverVisibilityMatchesIntent(resolvedDriverDeviceID: resolvedDriverDeviceID, token) else { return false }
        guard systemOutputAdoptionTarget(token) == nil else { return false }
        guard !outputController.restoreObligationNeedsReconcile(token) else { return false }
        guard driverListenerRegistrationMatchesIntent(resolvedDriverDeviceID: resolvedDriverDeviceID) else { return false }
        switch engine.processingState {
        case .active:
            return activeOutputRouteMatchesIntent(token)
        case .suspended(let cause):
            guard SuspensionPolicy.allowsAutomaticResume(cause) else { return true }
            return resolveAutomaticResumeTarget(token) == nil
        }
    }

    private func driverListenerRegistrationMatchesIntent(resolvedDriverDeviceID: AudioDeviceID?) -> Bool {
        guard engine.processingState == .active else { return true }
        guard let resolvedDriverDeviceID else { return true }
        return !driverListenerRebindNeeded(
            previousID: engine.driverDeviceListenerDeviceID, resolvedID: resolvedDriverDeviceID
        )
    }

    private func activeOutputRouteMatchesIntent(_ token: AudioWorldToken) -> Bool {
        guard let intendedUID = engine.intendedOutputDeviceUID else { return true }
        guard let currentID = engine.currentOutputDeviceID(token),
              let currentUID = directory.uid(forDeviceID: currentID, token) else { return false }
        guard outputSwitchDecision(intendedUID: intendedUID, currentUID: currentUID) == .notNeeded else { return false }
        let containsDriver = directory.containsDriverDevice(currentID, driverDeviceUID: driverDeviceUID, token)
        return !isExcludedFromOutputPicker(
            uid: currentUID, driverDeviceUID: driverDeviceUID,
            containsDriver: containsDriver, isAirPlay: directory.isAirPlayDevice(currentID, token)
        )
    }

    private func driverVisibilityMatchesIntent(resolvedDriverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        guard driverLifecycle.isVisibilityOwnedBySession,
              SuspensionPolicy.maintainsDriverVisibility(engine.processingState) else { return true }
        guard let resolvedDriverDeviceID else { return true }
        return directory.isHidden(forDeviceID: resolvedDriverDeviceID, token) != true
    }

    private func reconcileAll(_ token: AudioWorldToken) {
        let driverDeviceID = reconcileDriverDevice(token)
        adoptSystemOutputSelection(driverDeviceID: driverDeviceID, token)
        let outputDevice = reconcileOutputDevice(token)
        outputController.reconcileRestoreObligation(token)
        rebindAliveListeners(driverDeviceID: driverDeviceID, outputDeviceID: outputDevice.observedDeviceID)
        engine.reoccupyOutputVolumeRoute(token)
        reconcileDriverDeviceName(driverDeviceID: driverDeviceID, outputDeviceID: outputDevice.nameSourceDeviceID, token)
    }

    /// 出力先が確定したあとに呼ぶ (表示名が出力先の名前から決まるため)。
    private func reconcileDriverDeviceName(
        driverDeviceID: AudioDeviceID?, outputDeviceID: AudioDeviceID?, _ token: AudioWorldToken
    ) {
        guard let driverDeviceID else { return }
        guard applyDriverDeviceName(driverDeviceID: driverDeviceID, outputDeviceID: outputDeviceID, token) else { return }
        guard let handoffDeviceID = driverDeviceNameHandoffTarget(
            outputDeviceID: outputDeviceID,
            defaultOutputConfirmedAsDriver: outputController.defaultOutputConfirmedAsDriver(token)
        ) else { return }
        republishDriverDeviceNameToSystemUI(handoffDeviceID: handoffDeviceID, driverDeviceID: driverDeviceID, token)
    }

    /// - Returns: 表示名を書き換えたか。
    @discardableResult
    private func applyDriverDeviceName(
        driverDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID?, _ token: AudioWorldToken
    ) -> Bool {
        let intended = DriverDisplayName.compose(
            outputDeviceName: outputDeviceID.flatMap { directory.name(forDeviceID: $0, token) },
            fallback: DriverConfig.deviceName,
            maxLength: DriverConfig.nameOverrideMaxLength
        )
        // 読めない間は書かない。読めないまま書くと一致で止まれず、往復が合流窓ごとに続く。
        guard let currentName = directory.name(forDeviceID: driverDeviceID, token), currentName != intended else { return false }
        return directory.setName(intended, forDeviceID: driverDeviceID, token)
    }

    private func republishDriverDeviceNameToSystemUI(
        handoffDeviceID: AudioDeviceID, driverDeviceID: AudioDeviceID, _ token: AudioWorldToken
    ) {
        // 滞在時間を置くと EQ 未適用の音が漏れる。
        guard directory.setDefaultOutputDeviceID(handoffDeviceID, token) else { return }
        directory.setDefaultOutputDeviceID(driverDeviceID, token)
        guard !outputController.defaultOutputConfirmedAsDriver(token) else { return }
        // 掴み直せなかった理由が ID の陳腐化でありうるため、ここでは UID から解決し直させる。
        outputController.occupyDefaultOutputForDriver(token)
    }

    private func systemOutputAdoptionTarget(_ token: AudioWorldToken) -> ResolvedOutputDevice? {
        guard adoptsSystemOutputSelection, engine.processingState == .active else { return nil }
        guard !outputController.defaultOutputReachesDriver(token) else { return nil }
        guard let currentID = directory.defaultOutputDeviceID(token),
              let currentUID = directory.uid(forDeviceID: currentID, token) else { return nil }
        return directory.selectableOutputDevice(forUID: currentUID, driverDeviceUID: driverDeviceUID, token)
    }

    /// 掴み直しを先に行うと、出力先が切り替わるまでの間、引き継ぐ前の出力先から音が出る。
    private func adoptSystemOutputSelection(driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) {
        guard let target = systemOutputAdoptionTarget(token) else { return }
        guard engine.switchOutputDevice(to: target, token) else { return }
        if let driverDeviceID {
            applyDriverDeviceName(driverDeviceID: driverDeviceID, outputDeviceID: target.deviceID, token)
        }
        outputController.occupyDefaultOutputForDriver(driverDeviceID: driverDeviceID, token)
        didAdoptOutputDevice(target, token)
    }

    private func reconcileDriverDevice(_ token: AudioWorldToken) -> AudioDeviceID? {
        let resolvedID = directory.resolveHiddenDeviceID(forUID: driverDeviceUID, token)
        let previousID = lastDriverDeviceID
        lastDriverDeviceID = resolvedID
        guard let resolvedID else { return nil }

        if driverLifecycle.isVisibilityOwnedBySession, SuspensionPolicy.maintainsDriverVisibility(engine.processingState) {
            let isHidden = directory.isHidden(forDeviceID: resolvedID, token)
            if driverVisibilityReapplyNeeded(previousID: previousID, resolvedID: resolvedID, isHidden: isHidden) {
                driverLifecycle.reapplyVisibility(deviceID: resolvedID, token)
            }
        }
        if driverListenerRebindNeeded(
            previousID: engine.driverDeviceListenerDeviceID, resolvedID: resolvedID
        ) {
            engine.updateDriverDeviceID(resolvedID, token)
        }
        return resolvedID
    }

    private func reconcileOutputDevice(_ token: AudioWorldToken) -> ReconciledOutputDevice {
        switch engine.processingState {
        case .active:
            return reconcileActiveOutputDevice(token)
        case .suspended(let cause):
            guard SuspensionPolicy.allowsAutomaticResume(cause) else { return .nameSource(nil) }
            return .nameSource(attemptAutomaticResume(token))
        }
    }

    /// あるべき状態と一致していても、自ドライバ内包の Aggregate/Multi-Output になっていれば是正対象にする。
    private func reconcileActiveOutputDevice(_ token: AudioWorldToken) -> ReconciledOutputDevice {
        guard let intendedUID = engine.intendedOutputDeviceUID else {
            return .observedOnly(engine.currentOutputDeviceID(token))
        }
        guard let currentID = engine.currentOutputDeviceID(token), let currentUID = directory.uid(forDeviceID: currentID, token) else {
            return .nameSource(correctOutputDevice(intendedUID: intendedUID, token))
        }
        let containsDriver = directory.containsDriverDevice(currentID, driverDeviceUID: driverDeviceUID, token)
        let currentIsUnsafe = isExcludedFromOutputPicker(
            uid: currentUID, driverDeviceUID: driverDeviceUID,
            containsDriver: containsDriver, isAirPlay: directory.isAirPlayDevice(currentID, token)
        )
        if outputSwitchDecision(intendedUID: intendedUID, currentUID: currentUID) == .notNeeded, !currentIsUnsafe {
            return .nameSource(currentID)
        }
        if let corrected = correctOutputDevice(intendedUID: intendedUID, token) {
            return .nameSource(corrected)
        }
        guard currentIsUnsafe else {
            return .nameSource(currentID)
        }
        if let evacuated = evacuateFromUnsafeOutputRoute(token) {
            return .nameSource(evacuated)
        }
        return .observedOnly(currentID)
    }

    private func correctOutputDevice(intendedUID: String, _ token: AudioWorldToken) -> AudioDeviceID? {
        guard let target = directory.selectableOutputDevice(forUID: intendedUID, driverDeviceUID: driverDeviceUID, token) else {
            return nil
        }
        guard engine.switchOutputDevice(to: target, token) else { return nil }
        return target.deviceID
    }

    /// 危険な出力経路 (自ドライバ自身・自ドライバを内包する Aggregate/Multi-Output) からの退避。
    /// 退避先も解決できない場合は音声処理そのものを停止する。
    /// - Returns: 退避できた場合の出力デバイス ID。退避先が無ければ nil。
    private func evacuateFromUnsafeOutputRoute(_ token: AudioWorldToken) -> AudioDeviceID? {
        guard let restoreUID = outputController.restoreTargetUID,
              let target = directory.selectableOutputDevice(forUID: restoreUID, driverDeviceUID: driverDeviceUID, token),
              engine.switchOutputDevice(to: target, token) else {
            engine.suspend(cause: .routeUnavailable, token)
            return nil
        }
        didAdoptOutputDevice(target, token)
        return target.deviceID
    }

    private func attemptAutomaticResume(_ token: AudioWorldToken) -> AudioDeviceID? {
        guard let target = resolveAutomaticResumeTarget(token) else { return nil }
        guard automaticResumeAttemptAllowed() else { return nil }
        lastAutomaticResumeAttempt = now()
        let outcome = activationCoordinator.resume(outputDevice: target, trigger: .automatic, token)
        guard outcome.processingState == .active else {
            consecutiveAutomaticResumeFailures += 1
            return nil
        }
        consecutiveAutomaticResumeFailures = 0
        return outcome.activeOutputDevice?.deviceID
    }

    /// 間隔と回数の両方で抑える (失敗が構成変更通知を生んで自分自身を駆動し続けるため)。
    private func automaticResumeAttemptAllowed() -> Bool {
        guard consecutiveAutomaticResumeFailures < Self.automaticResumeMaxConsecutiveFailures else {
            return false
        }
        guard let last = lastAutomaticResumeAttempt else { return true }
        return now().timeIntervalSince(last) >= Self.automaticResumeRetryInterval
    }

    /// 停止直前のあるべき出力先 → 復帰対象の順に、厳密解決のみを試みる。
    private func resolveAutomaticResumeTarget(_ token: AudioWorldToken) -> ResolvedOutputDevice? {
        let candidates = [engine.intendedOutputDeviceUIDAtSuspension, outputController.restoreTargetUID].compactMap { $0 }
        for uid in candidates {
            if let target = directory.selectableOutputDevice(forUID: uid, driverDeviceUID: driverDeviceUID, token) {
                return target
            }
        }
        return nil
    }

    private func rebindAliveListeners(driverDeviceID: AudioDeviceID?, outputDeviceID: AudioDeviceID?) {
        guard let block = listenerBlock else { return }
        let desired = Set([driverDeviceID, outputDeviceID].compactMap { $0 })
        let actions = aliveListenerRebindActions(registered: aliveListenerDeviceIDs, desired: desired)
        for id in actions.remove {
            var addr = Self.aliveAddress
            AudioObjectRemovePropertyListenerBlock(id, &addr, audioWorld.queue, block)
        }
        for id in actions.add {
            var addr = Self.aliveAddress
            AudioObjectAddPropertyListenerBlock(id, &addr, audioWorld.queue, block)
        }
        aliveListenerDeviceIDs = desired
    }
}
