import CoreAudio
import Dispatch
import Foundation

/// 所有権の状態遷移の判定本体。CoreAudio にも共有メモリにも触れない純粋関数の集約先。
enum OwnershipPolicy {
    /// 満了を無視すると、死んだ相手を席の主として数え、誰も掴みにいかなくなる。
    private static func holdsSeat(processID: UInt32, leaseRemainingSeconds: Double?) -> Bool {
        guard processID != 0, let leaseRemainingSeconds else { return false }
        return leaseRemainingSeconds > 0
    }

    static func isOwned(_ snapshot: OwnershipSnapshot) -> Bool {
        holdsSeat(processID: snapshot.ownerProcessID, leaseRemainingSeconds: snapshot.ownershipLeaseRemainingSeconds)
    }

    /// リース残量は問わない。自分の席が満了しただけなら、降りるのではなく取り直す。
    static func isSelfOwner(_ snapshot: OwnershipSnapshot, selfProcessID: UInt32) -> Bool {
        snapshot.ownerProcessID == selfProcessID
    }

    /// 自分が出した要求は明け渡しの相手にならない。
    static func isRequestedByOther(_ snapshot: OwnershipSnapshot, selfProcessID: UInt32) -> Bool {
        guard snapshot.requestProcessID != selfProcessID else { return false }
        return holdsSeat(processID: snapshot.requestProcessID, leaseRemainingSeconds: snapshot.requestLeaseRemainingSeconds)
    }

    /// console を条件に選ぶのは、同時に 1 つであることが先着争いを防ぐため。
    static func shouldClaimWhileUnowned(ownerPresent: Bool, isOnConsole: Bool, wasSelfOwner: Bool) -> Bool {
        !ownerPresent && (isOnConsole || wasSelfOwner)
    }

    /// 席が空いている間は取り直しの権利を保つ。観測値で潰すと、claim が 1 回空振りしただけで
    /// console を持たないセッションが二度と取りにいけなくなる。他者が座った時点で落とす。
    static func retainedSelfOwnership(isSelfOwner: Bool, ownerPresent: Bool, previous: Bool) -> Bool {
        isSelfOwner || (previous && !ownerPresent)
    }

    /// 読めない窓では前回値を保つ。失った側へ倒すと、取り直しの根拠を失い、
    /// ミキサーは音が鳴ったままゲイン表だけを空にして、絞っていたアプリを中立へ戻す。
    static func lastKnownSelfOwnership(observed: Bool, isSelfOwner: Bool, previous: Bool) -> Bool {
        observed ? isSelfOwner : previous
    }

    /// 所有者が居なければ要求に応える相手が居ないため、その場で取る。
    static func handoverOperation(ownerPresent: Bool) -> OwnershipOperation {
        ownerPresent ? .request : .claim
    }

    /// 画面が凍る側 (非 console) が、見えている側から音を奪える経路を作らない。
    static func allowsHandoverAction(ownerPresent: Bool, isOnConsole: Bool) -> Bool {
        !ownerPresent || isOnConsole
    }

    /// ドライバの可用性は条件に入れない。入れると、まさに導入が必要な状態で操作できなくなる。
    static func allowsDriverOperation(ownerPresent: Bool, isSelfOwner: Bool) -> Bool {
        !ownerPresent || isSelfOwner
    }

    static func shouldRenewOwnership(isSelfOwner: Bool) -> Bool { isSelfOwner }

    static func shouldRenewRequest(isRequestingOwnership: Bool, isSelfOwner: Bool) -> Bool {
        isRequestingOwnership && !isSelfOwner
    }

    static func shouldReleaseForRequest(isSelfOwner: Bool, requestPresent: Bool) -> Bool {
        isSelfOwner && requestPresent
    }

    static func shouldSuspendForLackOfOwnership(isSelfOwner: Bool, ownerPresent: Bool) -> Bool {
        !isSelfOwner && ownerPresent
    }

    static func shouldResumeEngine(isSelfOwner: Bool, processingState: ProcessingState) -> Bool {
        isSelfOwner && processingState == .suspended(.ownershipUnavailable)
    }

    static func detectedReplacement(previousInode: UInt64?, currentInode: UInt64) -> Bool {
        guard let previousInode else { return false }
        return previousInode != currentInode
    }

    /// 満了した席の pid を渡すと、空席が使用中と読まれ、掴む導線まで閉じる。
    static func publishedOwnerIdentity(_ snapshot: OwnershipSnapshot) -> (processID: UInt32, uid: UInt32) {
        isOwned(snapshot) ? (snapshot.ownerProcessID, snapshot.ownerUID) : (0, 0)
    }

    /// pid 0 は不在 (共有ヘッダの取り決め)。UID は表示専用の申告値。
    static func ownerDisplayText(processID: UInt32, uid: UInt32) -> String {
        guard processID != 0 else { return "なし" }
        return "pid \(processID) / uid \(uid)"
    }
}

/// 所有権調停役が UI 世界へ押し出す結果。
struct OwnershipCoordinatorUpdate: Sendable {
    let isSelfOwner: Bool
    /// 不在は 0 (自分が所有者のときは自分の値)。
    let ownerProcessID: UInt32
    let ownerUID: UInt32
    /// 自分が要求中か。
    let isRequestingOwnership: Bool
    /// 所有権の状態を実際に読めたか。読めないときの isSelfOwner は安全側へ倒した値であり、所有者の不在を意味しない。
    let isObserved: Bool
    /// 読めない窓では前回値を保った所有の記憶。安全側へ倒した isSelfOwner とは別の問いに答える。
    let lastKnownSelfOwner: Bool
    /// この周で自分が空席を掴むと決めたか。掴んだ結果が出るまで、空席であることを表に出さない。
    let isClaimingSeat: Bool

    init(
        isSelfOwner: Bool, ownerProcessID: UInt32 = 0, ownerUID: UInt32 = 0,
        isRequestingOwnership: Bool = false, isObserved: Bool = true, lastKnownSelfOwner: Bool? = nil,
        isClaimingSeat: Bool = false
    ) {
        self.isSelfOwner = isSelfOwner
        self.ownerProcessID = ownerProcessID
        self.ownerUID = ownerUID
        self.isRequestingOwnership = isRequestingOwnership
        self.isObserved = isObserved
        self.lastKnownSelfOwner = lastKnownSelfOwner ?? isSelfOwner
        self.isClaimingSeat = isClaimingSeat
    }
}

/// セッション横断の所有権の取得・更新・解放・監視を担う調停役。
final class OwnershipCoordinator: @unchecked Sendable {

    /// 周期も更新間隔もリース長から導く (両者が一致していなければならない値のため)。
    static var passInterval: TimeInterval {
        min(DriverConfig.ownershipLeaseSeconds, DriverConfig.ownershipRequestLeaseSeconds) / 3
    }

    var didUpdate: (@Sendable (OwnershipCoordinatorUpdate) -> Void)?

    private let audioWorld: AudioWorld
    private let engine: AudioEngine
    private let activationCoordinator: AudioActivationCoordinator
    private let driverLifecycle: DriverLifecycleController
    private let outputController: OutputDeviceController
    private let directory: AudioDeviceDirectory
    private let driverDeviceUID: String
    private let sharedMemoryPath: String
    private let queue: DispatchQueue
    private let configuredOutputDeviceUID: @Sendable () -> String?
    private let isOnConsole: @Sendable () -> Bool
    /// 書き込みを伴う経路の照合を打つ入口。
    private let requestRouteReconciliation: @Sendable (AudioWorldToken) -> Void
    private let abandonAirPlayMode: @Sendable (AudioWorldToken) -> Void

    // 以下は queue 上だけが読み書きする。
    private var wasSelfOwner = false
    private var isRequestingOwnership = false
    private var lastKnownInode: UInt64?
    private var isTerminating = false

    // 以下は audio world のキュー上だけが読み書きする。
    private var listenerDeviceID: AudioDeviceID?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init(
        audioWorld: AudioWorld,
        engine: AudioEngine,
        activationCoordinator: AudioActivationCoordinator,
        driverLifecycle: DriverLifecycleController,
        outputController: OutputDeviceController,
        directory: AudioDeviceDirectory = CoreAudioDeviceDirectory(),
        driverDeviceUID: String = DriverConfig.deviceUID,
        sharedMemoryPath: String = DriverConfig.sharedMemoryPath,
        queue: DispatchQueue = DispatchQueue(label: "com.simpleeq.ownership", qos: .utility),
        configuredOutputDeviceUID: @escaping @Sendable () -> String? = { nil },
        requestRouteReconciliation: @escaping @Sendable (AudioWorldToken) -> Void = { _ in },
        abandonAirPlayMode: @escaping @Sendable (AudioWorldToken) -> Void = { _ in },
        isOnConsole: @escaping @Sendable () -> Bool
    ) {
        self.audioWorld = audioWorld
        self.engine = engine
        self.activationCoordinator = activationCoordinator
        self.driverLifecycle = driverLifecycle
        self.outputController = outputController
        self.directory = directory
        self.driverDeviceUID = driverDeviceUID
        self.sharedMemoryPath = sharedMemoryPath
        self.queue = queue
        self.configuredOutputDeviceUID = configuredOutputDeviceUID
        self.requestRouteReconciliation = requestRouteReconciliation
        self.abandonAirPlayMode = abandonAirPlayMode
        self.isOnConsole = isOnConsole
    }

    // MARK: - 外部からの入口

    /// 起動シーケンス専用。
    func resolveAtLaunch(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in evaluate(launchCompletion: completion) }
    }

    func runPass() {
        queue.async { [self] in evaluate(launchCompletion: nil) }
    }

    /// 「こちらで使う」の入口。
    func requestOwnership() {
        queue.async { [self] in
            guard !isRequestingOwnership else { return }
            let ownerPresent = classifyCurrentState()?.ownerPresent ?? true
            guard OwnershipPolicy.allowsHandoverAction(ownerPresent: ownerPresent, isOnConsole: isOnConsole()) else { return }
            let operation = OwnershipPolicy.handoverOperation(ownerPresent: ownerPresent)
            // 要求は所有者の解放を待つ状態なので、その場で取る側では立てない。
            if operation == .request { isRequestingOwnership = true }
            audioWorld.submitUncoalesced { [weak self] token in
                guard let self else { return }
                let applied = self.performWrite(operation, token)
                if operation == .claim, applied { self.runPass() }
                // 書けなかった要求を立てたまま残すと、届かない要求を更新し続け、表示も要求中のまま残る。
                if operation == .request, !applied { self.queue.sync { self.isRequestingOwnership = false } }
            }
        }
    }

    func cancelRequest() {
        queue.async { [self] in
            guard isRequestingOwnership else { return }
            isRequestingOwnership = false
            audioWorld.submitUncoalesced { [weak self] token in self?.performWrite(.cancel, token) }
        }
    }

    /// クリーン終了専用。解放より前に呼ぶ。
    /// 解放の通知で自分の購読が発火すると、取り直しの条件が揃って終了中に掴み直してしまう。
    func prepareForTermination(_ token: AudioWorldToken) {
        removeListener(token)
        queue.sync { isTerminating = true }
    }

    /// クリーン終了専用。
    func releaseForCleanExit(_ token: AudioWorldToken) {
        guard queue.sync(execute: { classifyCurrentState()?.isSelfOwner ?? false }) else { return }
        performWrite(.release, token)
    }

    // MARK: - 本体

    private struct Classification {
        let snapshot: OwnershipSnapshot
        let ownerPresent: Bool
        let isSelfOwner: Bool
        let requestPresent: Bool
    }

    private func evaluate(launchCompletion: (@Sendable (Bool) -> Void)?) {
        guard !isTerminating else {
            launchCompletion?(false)
            return
        }
        let observedInode = Self.currentInode(path: sharedMemoryPath)
        guard let classified = classifyCurrentState() else {
            // 記憶を進めない。進めると、読めなかった回で差し替えの立ち上がりを消費してしまう。
            wasSelfOwner = OwnershipPolicy.lastKnownSelfOwnership(observed: false, isSelfOwner: false, previous: wasSelfOwner)
            engine.runtimeMetrics.recordOwnershipObservation(OwnershipObservationSnapshot(), observed: false)
            publish(isSelfOwner: false, ownerProcessID: 0, ownerUID: 0, isObserved: false)
            launchCompletion?(false)
            return
        }
        let replaced = consumeReplacement(inode: observedInode)
        if let launchCompletion {
            resolveLaunch(classified, completion: launchCompletion)
            return
        }
        act(on: classified, replaced: replaced)
    }

    /// 差し替えを消費するのはこの経路だけ。観測だけを取り出す入口が記憶を進めると、
    /// 立ち上がりがその周で消え、実体が差し替わったことを知る経路が無くなる。
    private func consumeReplacement(inode: UInt64?) -> Bool {
        guard let inode else { return false }
        let replaced = OwnershipPolicy.detectedReplacement(previousInode: lastKnownInode, currentInode: inode)
        lastKnownInode = inode
        return replaced
    }

    /// 起動シーケンスは claim の一手のみを扱う。結果はこの Set 呼び出しの成否で確定させる。
    private func resolveLaunch(_ classified: Classification, completion: @escaping @Sendable (Bool) -> Void) {
        recordObservation(classified)
        guard OwnershipPolicy.shouldClaimWhileUnowned(
            ownerPresent: classified.ownerPresent, isOnConsole: isOnConsole(), wasSelfOwner: wasSelfOwner
        ) else {
            wasSelfOwner = classified.isSelfOwner
            // 前回の異常終了で永続化された義務を抱えたまま起動しうる。降ろさないまま終了すると、
            // 後始末が現所有者の使っているデバイスへ及ぶ。
            if !classified.isSelfOwner { abandonOwnerResponsibilities() }
            publish(classified)
            completion(classified.isSelfOwner)
            return
        }
        audioWorld.submitUncoalesced { [weak self] token in
            guard let self else { return }
            let claimed = self.performWrite(.claim, token)
            // 掴めなかった回も所有していない側であり、抱えている責務を降ろす条件は上の経路と同じ。
            if !claimed {
                OwnershipCoordinator.abandonOwnerResponsibilities(
                    driverLifecycle: self.driverLifecycle, outputController: self.outputController, token
                )
            }
            self.queue.async { [self] in
                self.wasSelfOwner = claimed
                if claimed {
                    self.publish(isSelfOwner: true, ownerProcessID: SharedRingReader.selfProcessID, ownerUID: getuid())
                } else {
                    self.publish(classified)
                }
                completion(claimed)
            }
        }
    }

    private func act(on classified: Classification, replaced: Bool) {
        recordObservation(classified)
        if classified.isSelfOwner { isRequestingOwnership = false }

        let renews = OwnershipPolicy.shouldRenewOwnership(isSelfOwner: classified.isSelfOwner)
            || OwnershipPolicy.shouldRenewRequest(isRequestingOwnership: isRequestingOwnership, isSelfOwner: classified.isSelfOwner)
        let criticalOperation = decideCriticalOperation(classified)

        audioWorld.submitUncoalesced { [weak self] token in
            guard let self else { return }
            let deviceID = self.directory.resolveHiddenDeviceID(forUID: self.driverDeviceUID, token)
            self.applyEngineTransition(classified, replaced: replaced, token)
            let applied = criticalOperation.map { self.performWrite($0, deviceID: deviceID, token) } ?? false
            self.ensureListener(deviceID: deviceID, token)
            // 席を取れた回に打ち直さないと、出力段の再開が次の周まで待たされる。
            if criticalOperation == .claim, applied { self.runPass() }
        }
        if renews {
            audioWorld.submit(coalescingKey: AudioRequestKey.ownershipRenew) { [weak self] token in
                self?.performWrite(.renew, token)
            }
        }

        wasSelfOwner = OwnershipPolicy.retainedSelfOwnership(
            isSelfOwner: classified.isSelfOwner,
            ownerPresent: classified.ownerPresent,
            previous: wasSelfOwner
        )
        publish(classified, isClaimingSeat: criticalOperation == .claim)
    }

    /// 束ねてはならない操作のうち、この周でどれを打つか。
    private func decideCriticalOperation(_ classified: Classification) -> OwnershipOperation? {
        if OwnershipPolicy.shouldReleaseForRequest(isSelfOwner: classified.isSelfOwner, requestPresent: classified.requestPresent) {
            return .release
        }
        if OwnershipPolicy.shouldClaimWhileUnowned(
            ownerPresent: classified.ownerPresent, isOnConsole: isOnConsole(), wasSelfOwner: wasSelfOwner
        ) {
            return .claim
        }
        return nil
    }

    private func applyEngineTransition(_ classified: Classification, replaced: Bool, _ token: AudioWorldToken) {
        if OwnershipPolicy.shouldReleaseForRequest(isSelfOwner: classified.isSelfOwner, requestPresent: classified.requestPresent) {
            standDownFromOwnership(token)
            return
        }
        if replaced, engine.processingState == .active {
            engine.suspend(cause: .ownershipUnavailable, token)
            return
        }
        if OwnershipPolicy.shouldResumeEngine(isSelfOwner: classified.isSelfOwner, processingState: engine.processingState) {
            guard let target = resolveResumeTarget(token) else {
                // 所有しているのに経路が作れないのは経路の問題。所有権の停止種別のまま置くと、
                // 警告も出ず操作できる見た目のまま音が出ず、自動再開の対象にもならない。
                engine.suspend(cause: .routeUnavailable, token)
                requestRouteReconciliation(token)
                return
            }
            activationCoordinator.resume(outputDevice: target, trigger: .ownershipAcquired, token)
            // 所有者の責務は組み立てが引き受ける。打ち直さないと、次の定期点検まで表示名も出力先も現実に追いつかない。
            requestRouteReconciliation(token)
            return
        }
        guard OwnershipPolicy.shouldSuspendForLackOfOwnership(isSelfOwner: classified.isSelfOwner, ownerPresent: classified.ownerPresent) else { return }
        standDownFromOwnership(token)
    }

    /// 責務と停止種別は所有権と一体で降りる。握手で降りる経路とリースを失う経路で扱いを変えない。
    private func standDownFromOwnership(_ token: AudioWorldToken) {
        driverLifecycle.abandonVisibilityOwnership(token)
        outputController.abandonRestoreObligation(token)
        abandonAirPlayMode(token)
        switch engine.processingState {
        case .suspended(.driverOperation), .suspended(.applicationTermination), .suspended(.ownershipUnavailable):
            return
        case .active, .suspended(.routeUnavailable):
            engine.suspend(cause: .ownershipUnavailable, token)
        }
    }

    private func abandonOwnerResponsibilities() {
        audioWorld.submitUncoalesced { [driverLifecycle, outputController] token in
            OwnershipCoordinator.abandonOwnerResponsibilities(
                driverLifecycle: driverLifecycle, outputController: outputController, token
            )
        }
    }

    /// 所有していない側が降ろす責務。self を捕まえないよう、依存は引数で受け取る。
    private static func abandonOwnerResponsibilities(
        driverLifecycle: DriverLifecycleController, outputController: OutputDeviceController, _ token: AudioWorldToken
    ) {
        driverLifecycle.abandonVisibilityOwnership(token)
        outputController.abandonRestoreObligation(token)
    }

    /// 一度もアクティブになっていないセッションへ所有権が渡ってくるため、
    /// 利用者が Settings で選んだ出力先も候補に置く。
    private func resolveResumeTarget(_ token: AudioWorldToken) -> ResolvedOutputDevice? {
        directory.firstSelectableOutputDevice(
            preferring: [
                engine.intendedOutputDeviceUIDAtSuspension,
                outputController.restoreTargetUID,
                configuredOutputDeviceUID(),
            ],
            driverDeviceUID: driverDeviceUID, token
        )
    }

    // MARK: - 読み出し (専用キュー、毎回パスから開き直す)

    private func classifyCurrentState() -> Classification? {
        guard let reader = try? SharedRingReader.open(path: sharedMemoryPath).get(),
              let snapshot = reader.readOwnershipSnapshot() else { return nil }

        return Classification(
            snapshot: snapshot,
            ownerPresent: OwnershipPolicy.isOwned(snapshot),
            isSelfOwner: OwnershipPolicy.isSelfOwner(snapshot, selfProcessID: SharedRingReader.selfProcessID),
            requestPresent: OwnershipPolicy.isRequestedByOther(snapshot, selfProcessID: SharedRingReader.selfProcessID)
        )
    }

    private static func currentInode(path: String) -> UInt64? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return UInt64(status.st_ino)
    }

    // MARK: - 書き込み (audio world のキュー上でのみ呼ぶ)

    @discardableResult
    private func performWrite(_ operation: OwnershipOperation, _ token: AudioWorldToken) -> Bool {
        performWrite(operation, deviceID: directory.resolveHiddenDeviceID(forUID: driverDeviceUID, token), token)
    }

    @discardableResult
    private func performWrite(_ operation: OwnershipOperation, deviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        guard let id = deviceID else { return false }
        let payload: [String: Any] = [
            OwnershipPropertyKey.operation: operation.rawValue,
            OwnershipPropertyKey.uid: getuid(),
        ]
        return setDeviceCustomProperty(DriverConfig.ownershipSelector, payload as CFDictionary, forDeviceID: id, token)
    }

    // MARK: - 通知購読

    private func ensureListener(deviceID resolvedID: AudioDeviceID?, _ token: AudioWorldToken) {
        guard resolvedID != listenerDeviceID else { return }
        removeListener(token)
        guard let resolvedID else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.runPass() }
        var addr = Self.ownershipAddress
        // 登録できなかった回を記録すると、以降は同じ id で素通りして周期パスだけに縮退したままになる。
        guard AudioObjectAddPropertyListenerBlock(resolvedID, &addr, audioWorld.listenerQueue, block) == noErr else { return }
        listenerDeviceID = resolvedID
        listenerBlock = block
    }

    private func removeListener(_ token: AudioWorldToken) {
        if let previousID = listenerDeviceID, let block = listenerBlock {
            var addr = Self.ownershipAddress
            AudioObjectRemovePropertyListenerBlock(previousID, &addr, audioWorld.listenerQueue, block)
        }
        listenerDeviceID = nil
        listenerBlock = nil
    }

    private static let ownershipAddress = AudioObjectPropertyAddress(
        mSelector: DriverConfig.ownershipSelector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - Diagnostics への押し出し

    private func recordObservation(_ classified: Classification) {
        engine.runtimeMetrics.recordOwnershipObservation(
            OwnershipObservationSnapshot(
                ownerProcessID: classified.snapshot.ownerProcessID,
                ownerUID: classified.snapshot.ownerUID,
                leaseRemainingSeconds: classified.snapshot.ownershipLeaseRemainingSeconds,
                requestProcessID: classified.snapshot.requestProcessID,
                requestUID: classified.snapshot.requestUID,
                requestLeaseRemainingSeconds: classified.snapshot.requestLeaseRemainingSeconds,
                isSelfOwner: classified.isSelfOwner
            ),
            observed: true
        )
    }

    private func publish(_ classified: Classification, isClaimingSeat: Bool = false) {
        let identity = OwnershipPolicy.publishedOwnerIdentity(classified.snapshot)
        publish(
            isSelfOwner: classified.isSelfOwner, ownerProcessID: identity.processID, ownerUID: identity.uid,
            isClaimingSeat: isClaimingSeat
        )
    }

    /// wasSelfOwner を更新してから呼ぶこと。押し出す記憶はその値そのものであり、ここで導き直さない。
    private func publish(
        isSelfOwner: Bool, ownerProcessID: UInt32, ownerUID: UInt32,
        isObserved: Bool = true, isClaimingSeat: Bool = false
    ) {
        didUpdate?(OwnershipCoordinatorUpdate(
            isSelfOwner: isSelfOwner, ownerProcessID: ownerProcessID, ownerUID: ownerUID,
            isRequestingOwnership: isRequestingOwnership, isObserved: isObserved,
            lastKnownSelfOwner: wasSelfOwner, isClaimingSeat: isClaimingSeat
        ))
    }
}
