import CoreAudio
import Foundation

/// UI 世界へ押し出す AirPlay モードの相。
enum AirPlayModePhase: Equatable, Sendable {
    case inactive
    /// 入った直後・作り直し中・端末の消滅後の猶予中・許可の結果待ち。
    case awaitingCapture
    case capturing
    /// 取り込み経路で稼働しているが、許可が拒否されていて入力は常に無音。
    case captureDenied
    /// 間隔と回数を抑えて構築を再試行している。
    case captureFailed
}

enum CaptureAuthorization: Equatable, Sendable {
    case unread
    case granted
    case denied
    /// 許可状態を読めない、または未決定なのに求められない。
    case unreadable
}

// MARK: - 判定

enum AirPlayModePolicy {
    /// 端末の切り替え中にデフォルト出力が一般デバイスを経由した時間の最大値 (実測値)。
    static let observedFallbackDwellSeconds: TimeInterval = 0.45
    /// 設計値。
    static let settleSafetyFactor: Double = 2

    static var settleSeconds: TimeInterval { observedFallbackDwellSeconds * settleSafetyFactor }

    /// 取り込みの IO が回り始めるまでの猶予 (設計値)。
    static let captureStartupAllowanceSeconds: TimeInterval = 2

    /// 最初の書き込みが届くまでは IO の周期から導いたしきい値で読まない。AirPlay の Aggregate は回り始めるまでがそれより長い。
    static func captureStalled(
        elapsedSinceLastWrite: TimeInterval, hasReceivedWriteSinceStart: Bool, cycleThreshold: TimeInterval
    ) -> Bool {
        elapsedSinceLastWrite > (hasReceivedWriteSinceStart ? cycleThreshold : captureStartupAllowanceSeconds)
    }

    enum DefaultOutputObservation: Equatable {
        case unreadable
        case airPlay(uid: String)
        case other(uid: String, selectable: Bool)
    }

    enum Action: Equatable {
        case none
        case enter(uid: String)
        case rebuild(uid: String)
        case rebuildUnhealthyRoute(uid: String)
        case beginSettle(deadline: TimeInterval)
        case awaitSettle
        case depart
    }

    /// 所有権は処理状態を通して効く。
    static func allowsEntry(adopts: Bool, processingState: ProcessingState) -> Bool {
        guard adopts else { return false }
        switch processingState {
        case .active: return true
        case .suspended(let cause): return SuspensionPolicy.allowsAutomaticResume(cause)
        }
    }

    static func action(
        phase: AirPlayModePhase, endpointUID: String?, defaultOutput: DefaultOutputObservation,
        adopts: Bool, processingState: ProcessingState,
        departureObservedWhileEndpointAlive: Bool, settleDeadline: TimeInterval?, now: TimeInterval,
        retryAllowed: Bool, unhealthyRebuildAllowed: Bool, routeHealthy: Bool
    ) -> Action {
        if case .unreadable = defaultOutput { return .none }
        let entryAllowed = allowsEntry(adopts: adopts, processingState: processingState)
        guard phase != .inactive else {
            guard entryAllowed, case .airPlay(let uid) = defaultOutput else { return .none }
            return .enter(uid: uid)
        }
        guard entryAllowed else { return .depart }

        switch defaultOutput {
        case .unreadable:
            return .none
        case .airPlay(let uid):
            guard uid == endpointUID else { return .rebuild(uid: uid) }
            // 猶予を始めた時点で取り込み経路は停止・破棄済みなので、依頼し直さないと止まったままになる。
            if settleDeadline != nil { return .rebuild(uid: uid) }
            switch phase {
            case .captureFailed:
                return retryAllowed ? .rebuild(uid: uid) : .none
            case .capturing, .captureDenied:
                // 作り直しは構成変更の通知を生み次の是正を呼ぶため、不健全が続く環境で往復し続けないよう間隔を置く。
                return routeHealthy || !unhealthyRebuildAllowed ? .none : .rebuildUnhealthyRoute(uid: uid)
            case .inactive, .awaitingCapture:
                return .none
            }
        case .other:
            if departureObservedWhileEndpointAlive { return .depart }
            guard let settleDeadline else { return .beginSettle(deadline: now + settleSeconds) }
            return now < settleDeadline ? .awaitSettle : .depart
        }
    }

    static func routeHealthy(
        auhalDeviceUID: String?, endpointUID: String, captureStalled: Bool,
        appliedRate: Double, aggregateRate: Double?
    ) -> Bool {
        auhalDeviceUID == endpointUID && !captureStalled && aggregateRate == appliedRate
    }

    /// AirPlay に入る前の出力先は候補にしない。
    static func departureResumeCandidate(defaultOutput: DefaultOutputObservation) -> String? {
        guard case .other(let uid, true) = defaultOutput else { return nil }
        return uid
    }
}

/// 回数と間隔の両方で試行を抑える。時刻は呼び出し側が 1 つの時計で揃えて渡す (秒)。
struct RetryThrottle: Equatable {
    let interval: TimeInterval
    let maxConsecutiveFailures: Int
    private(set) var consecutiveFailures = 0
    private(set) var lastAttempt: TimeInterval?

    init(interval: TimeInterval, maxConsecutiveFailures: Int) {
        self.interval = interval
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    func allowsAttempt(now: TimeInterval) -> Bool {
        guard consecutiveFailures < maxConsecutiveFailures else { return false }
        guard let lastAttempt else { return true }
        return now - lastAttempt >= interval
    }

    mutating func noteAttempt(now: TimeInterval) {
        lastAttempt = now
    }

    mutating func noteFailure() {
        consecutiveFailures += 1
    }

    mutating func noteSuccess() {
        consecutiveFailures = 0
    }

    mutating func reset() {
        consecutiveFailures = 0
        lastAttempt = nil
    }
}

// MARK: - 調停役

protocol AirPlayRoutingEngine: AnyObject, Sendable {
    var processingState: ProcessingState { get }
    /// 取り込み経路で稼働している間だけ、使用中のエンドポイントの UID。
    var airPlayRoute: String? { get }
    func suspend(cause: SuspensionCause, _ token: AudioWorldToken)
    func airPlayRouteHealthy(_ token: AudioWorldToken) -> Bool
}

extension AudioEngine: AirPlayRoutingEngine {}

enum AirPlayReconcileBranch: Equatable {
    case notApplicable
    case engaged(endpointDeviceID: AudioDeviceID?)
    case departed(resumeCandidateUID: String?)
}

protocol AirPlayModeReconciling: AnyObject, Sendable {
    var isEngaged: Bool { get }
    func reconcile(adopts: Bool, _ token: AudioWorldToken) -> AirPlayReconcileBranch
    func noteConfigurationNotification(_ token: AudioWorldToken)
    /// 読み出しのみ。
    func matchesIntent(adopts: Bool, _ token: AudioWorldToken) -> Bool
}

/// AirPlay モードを扱わない構成の是正役に渡す。
final class AirPlayModeNotApplicable: AirPlayModeReconciling {
    var isEngaged: Bool { false }
    func reconcile(adopts: Bool, _ token: AudioWorldToken) -> AirPlayReconcileBranch { .notApplicable }
    func noteConfigurationNotification(_ token: AudioWorldToken) {}
    func matchesIntent(adopts: Bool, _ token: AudioWorldToken) -> Bool { true }
}

/// オーディオ世界のキュー上だけで読み書きする。
final class AirPlayModeCoordinator: AirPlayModeReconciling, @unchecked Sendable {
    var requestCapture: (@Sendable (CaptureBuildRequest) -> Void)?
    var requestRouteReconciliation: (@Sendable (AudioWorldToken) -> Void)?
    var scheduleRouteReconciliation: (@Sendable (_ after: TimeInterval) -> Void)?
    var phaseDidChange: (@Sendable (AirPlayModePhase) -> Void)?

    private let engine: AirPlayRoutingEngine
    private let activationCoordinator: AudioActivationCoordinator
    private let directory: AudioDeviceDirectory
    private let driverDeviceUID: String
    private let metrics: AudioRuntimeMetrics
    /// スリープ中に進まない時計 (秒)。
    private let now: @Sendable () -> TimeInterval

    private(set) var phase: AirPlayModePhase = .inactive {
        didSet {
            guard phase != oldValue else { return }
            phaseDidChange?(phase)
        }
    }
    private(set) var generation: UInt64 = 0
    private var endpointUID: String?
    /// このプロセスでの ID。生存の読み取りにだけ使い、比較には使わない。
    private var endpointDeviceID: AudioDeviceID?
    private var departureObservedWhileEndpointAlive = false
    private var settleDeadline: TimeInterval?
    private var awaitingAuthorizationGeneration: UInt64?
    private var lastAdopts = false
    private var retryThrottle = RetryThrottle(
        interval: DeviceRoutingReconciler.automaticResumeRetryInterval,
        maxConsecutiveFailures: DeviceRoutingReconciler.automaticResumeMaxConsecutiveFailures
    )
    private var lastUnhealthyRebuildAt: TimeInterval?

    init(
        engine: AirPlayRoutingEngine, activationCoordinator: AudioActivationCoordinator,
        directory: AudioDeviceDirectory = CoreAudioDeviceDirectory(), driverDeviceUID: String,
        metrics: AudioRuntimeMetrics, now: @escaping @Sendable () -> TimeInterval = uptimeSeconds
    ) {
        self.engine = engine
        self.activationCoordinator = activationCoordinator
        self.directory = directory
        self.driverDeviceUID = driverDeviceUID
        self.metrics = metrics
        self.now = now
    }

    var isEngaged: Bool { phase != .inactive }

    func reconcile(adopts: Bool, _ token: AudioWorldToken) -> AirPlayReconcileBranch {
        lastAdopts = adopts
        let defaultOutput = readDefaultOutput(token)
        switch decideAction(adopts: adopts, defaultOutput: defaultOutput.observation, token) {
        case .none, .awaitSettle:
            // 合流窓の間に外れて同じエンドポイントへ戻った印を残すと、次の切り替えの経由を選択と取り違える。
            if case .airPlay(let uid) = defaultOutput.observation, uid == endpointUID {
                departureObservedWhileEndpointAlive = false
            }
        case .enter(let uid):
            guard let deviceID = defaultOutput.deviceID else { break }
            requestBuild(uid: uid, deviceID: deviceID, token)
        case .rebuild(let uid):
            guard let deviceID = defaultOutput.deviceID else { break }
            stopCapturingRoute(token)
            requestBuild(uid: uid, deviceID: deviceID, token)
        case .rebuildUnhealthyRoute(let uid):
            guard let deviceID = defaultOutput.deviceID else { break }
            lastUnhealthyRebuildAt = now()
            stopCapturingRoute(token)
            requestBuild(uid: uid, deviceID: deviceID, token)
        case .beginSettle(let deadline):
            stopCapturingRoute(token)
            generation += 1
            settleDeadline = deadline
            phase = .awaitingCapture
            scheduleRouteReconciliation?(deadline - now())
        case .depart:
            stopCapturingRoute(token)
            clearEngagement()
            return .departed(
                resumeCandidateUID: AirPlayModePolicy.departureResumeCandidate(defaultOutput: defaultOutput.observation)
            )
        }
        return isEngaged ? .engaged(endpointDeviceID: endpointDeviceID) : .notApplicable
    }

    // 読み遅れて消滅後になった場合は猶予側に倒れるだけで、誤って引き取らない。
    func noteConfigurationNotification(_ token: AudioWorldToken) {
        guard isEngaged, let endpointUID, let endpointDeviceID else { return }
        guard let currentID = directory.defaultOutputDeviceID(token),
              let currentUID = directory.uid(forDeviceID: currentID, token),
              currentUID != endpointUID,
              directory.isDeviceAlive(endpointDeviceID, token) == true else { return }
        departureObservedWhileEndpointAlive = true
    }

    func matchesIntent(adopts: Bool, _ token: AudioWorldToken) -> Bool {
        switch decideAction(adopts: adopts, defaultOutput: readDefaultOutput(token).observation, token) {
        case .none, .awaitSettle: return true
        case .enter, .rebuild, .rebuildUnhealthyRoute, .beginSettle, .depart: return false
        }
    }

    func deliver(_ outcome: CaptureBuildOutcome, generation deliveredGeneration: UInt64, _ token: AudioWorldToken) {
        guard deliveredGeneration == generation, phase == .awaitingCapture,
              AirPlayModePolicy.allowsEntry(adopts: lastAdopts, processingState: engine.processingState) else {
            if case .built(let capture, _) = outcome { capture.destroy(token) }
            return
        }
        switch outcome {
        case .awaitingAuthorization:
            awaitingAuthorizationGeneration = deliveredGeneration
            return
        case .failed:
            if engine.processingState == .active { engine.suspend(cause: .routeUnavailable, token) }
            retryThrottle.noteFailure()
            phase = .captureFailed
        case .built(let capture, let authorization):
            metrics.recordCaptureAuthorization(authorization)
            if engine.processingState == .active { engine.suspend(cause: .routeUnavailable, token) }
            if activationCoordinator.activateAirPlay(capture: capture, token) {
                retryThrottle.noteSuccess()
                phase = authorization == .denied ? .captureDenied : .capturing
            } else {
                capture.destroy(token)
                retryThrottle.noteFailure()
                phase = .captureFailed
            }
        }
        requestRouteReconciliation?(token)
    }

    func authorizationRequestDidComplete(_ token: AudioWorldToken) {
        guard awaitingAuthorizationGeneration == generation, phase == .awaitingCapture,
              AirPlayModePolicy.allowsEntry(adopts: lastAdopts, processingState: engine.processingState),
              let endpointUID, let endpointDeviceID else { return }
        requestBuild(uid: endpointUID, deviceID: endpointDeviceID, token)
    }

    /// エンジンの停止は呼び出し側が行う。
    func abandon(_ token: AudioWorldToken) {
        clearEngagement()
    }

    // MARK: - 内部

    private func decideAction(
        adopts: Bool, defaultOutput: AirPlayModePolicy.DefaultOutputObservation, _ token: AudioWorldToken
    ) -> AirPlayModePolicy.Action {
        let checksRoute = phase == .capturing || phase == .captureDenied
        let currentTime = now()
        return AirPlayModePolicy.action(
            phase: phase, endpointUID: endpointUID, defaultOutput: defaultOutput,
            adopts: adopts, processingState: engine.processingState,
            departureObservedWhileEndpointAlive: departureObservedWhileEndpointAlive,
            settleDeadline: settleDeadline, now: currentTime,
            retryAllowed: retryThrottle.allowsAttempt(now: currentTime),
            unhealthyRebuildAllowed: lastUnhealthyRebuildAt.map {
                currentTime - $0 >= DeviceRoutingReconciler.automaticResumeRetryInterval
            } ?? true,
            routeHealthy: checksRoute ? engine.airPlayRouteHealthy(token) : true
        )
    }

    private func readDefaultOutput(
        _ token: AudioWorldToken
    ) -> (observation: AirPlayModePolicy.DefaultOutputObservation, deviceID: AudioDeviceID?) {
        guard let id = directory.defaultOutputDeviceID(token), let uid = directory.uid(forDeviceID: id, token) else {
            return (.unreadable, nil)
        }
        guard !directory.isAirPlayDevice(id, token) else { return (.airPlay(uid: uid), id) }
        // 選べるかは抜ける回にしか使わず、解決にはデバイスの列挙を伴う。
        let selectable = isEngaged
            && directory.selectableOutputDevice(forUID: uid, driverDeviceUID: driverDeviceUID, token) != nil
        return (.other(uid: uid, selectable: selectable), id)
    }

    private func requestBuild(uid: String, deviceID: AudioDeviceID, _ token: AudioWorldToken) {
        generation += 1
        departureObservedWhileEndpointAlive = false
        settleDeadline = nil
        if uid != endpointUID {
            retryThrottle.reset()
            lastUnhealthyRebuildAt = nil
        }
        endpointUID = uid
        endpointDeviceID = deviceID
        phase = .awaitingCapture
        retryThrottle.noteAttempt(now: now())
        requestCapture?(CaptureBuildRequest(
            endpointUID: uid, endpointDeviceID: deviceID,
            selfProcessObjectID: directory.selfProcessObjectID(token), generation: generation
        ))
    }

    private func stopCapturingRoute(_ token: AudioWorldToken) {
        guard engine.airPlayRoute != nil else { return }
        engine.suspend(cause: .routeUnavailable, token)
    }

    private func clearEngagement() {
        generation += 1
        endpointUID = nil
        endpointDeviceID = nil
        departureObservedWhileEndpointAlive = false
        settleDeadline = nil
        awaitingAuthorizationGeneration = nil
        retryThrottle.reset()
        phase = .inactive
    }
}
