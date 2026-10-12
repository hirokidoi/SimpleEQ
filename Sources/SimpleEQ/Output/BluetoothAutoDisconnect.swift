import CoreAudio
import CoreBluetooth
import Foundation

/// 出力段の無音の観測。値は評価の瞬間のもの。
struct OutputSilenceObservation: Equatable, Sendable {
    let writerIOIsRunning: Bool
    let silentSeconds: TimeInterval
    /// 出力コールバックが 0 フレームを返した回数の起動以来の累計。
    let primingSilenceCount: UInt64
}

struct BluetoothAutoDisconnectSettings: Equatable, Sendable {
    let isEnabled: Bool
    let silenceLimitSeconds: TimeInterval

    /// nil は切断しない。
    init(silenceMinutes: Int?) {
        isEnabled = silenceMinutes != nil
        silenceLimitSeconds = TimeInterval(silenceMinutes ?? 0) * 60
    }

    static let disabled = BluetoothAutoDisconnectSettings(silenceMinutes: nil)
}

enum BluetoothAutoDisconnectStatus: Equatable, Sendable {
    case none
    case playing(deviceName: String)
    case countingDown(deviceName: String, minutesRemaining: Int)
    /// Bluetooth の許可が拒否・制限されている。
    case unauthorized

    /// 切り上げ。0 分と表示すると切断済みに見えるため下限は 1。
    static func minutesRemaining(seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }
}

/// 無音の継続を数えて切断の時機を返す状態機械。時計・観測・対象は呼び出し側が渡す。
struct BluetoothAutoDisconnectTracker {
    enum Verdict: Equatable {
        case inactive
        case playing
        case countingDown(remainingSeconds: TimeInterval)
        case disconnect
        case awaitingRearm
    }

    // 観測系
    private var lastEvaluatedAt: TimeInterval?
    private var lastPrimingSilenceCount: UInt64?
    private var lastEvaluationAmbiguous = false
    // 対象系
    private var targetUID: String?
    private var silenceOrigin: TimeInterval?
    // 区間系: この無音区間で切断した UID。音が出るか機能が無効になるまで保持する。
    private var disconnectedUIDs: Set<String> = []

    mutating func evaluate(
        observation: OutputSilenceObservation?, targetUID newTargetUID: String?,
        limitSeconds: TimeInterval, now: TimeInterval
    ) -> Verdict {
        guard let observation else {
            lastEvaluatedAt = nil
            lastPrimingSilenceCount = nil
            lastEvaluationAmbiguous = false
            targetUID = nil
            silenceOrigin = nil
            return .inactive
        }

        let window = lastEvaluatedAt.map { now - $0 } ?? 0
        let counterRewound = observation.writerIOIsRunning && observation.silentSeconds <= window
        // 音以外 (各種リセット・再プライミング) の巻き戻りは 0 フレーム返却を伴う。音と読むと起点が引き直され続けて満了しない。
        let zeroFrameReturned = lastPrimingSilenceCount.map { observation.primingSilenceCount > $0 } ?? false
        let ambiguous = counterRewound && zeroFrameReturned
        // 判別できなかった区間の後で IO が止まっていれば、その間に鳴って終わった再生とみなす。
        let stoppedAfterAmbiguous = lastEvaluationAmbiguous && !observation.writerIOIsRunning
        lastEvaluatedAt = now
        lastPrimingSilenceCount = observation.primingSilenceCount
        lastEvaluationAmbiguous = ambiguous

        if (counterRewound && !zeroFrameReturned) || stoppedAfterAmbiguous {
            silenceOrigin = nil
            disconnectedUIDs.removeAll()
            targetUID = newTargetUID
            return newTargetUID == nil ? .inactive : .playing
        }

        guard let newTargetUID else {
            targetUID = nil
            silenceOrigin = nil
            return .inactive
        }
        if newTargetUID != targetUID { silenceOrigin = nil }
        targetUID = newTargetUID

        if disconnectedUIDs.contains(newTargetUID) { return .awaitingRearm }

        let origin = silenceOrigin ?? (observation.writerIOIsRunning ? now - observation.silentSeconds : now)
        silenceOrigin = origin

        let remaining = limitSeconds - (now - origin)
        if remaining > 0 { return .countingDown(remainingSeconds: remaining) }

        // 音か判別できない評価では満了を見送る。
        if ambiguous { return .countingDown(remainingSeconds: 0) }

        disconnectedUIDs.insert(newTargetUID)
        return .disconnect
    }
}

enum BluetoothAddress {
    static func canonical(_ raw: String) -> String {
        raw.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    /// 公開された対応付けは無く、BT 端点の UID にアドレスが含まれるという観測に依存する。
    static func pairedAddress(matchingDeviceUID uid: String, among addresses: [String]) -> String? {
        let canonicalUID = canonical(uid)
        return addresses.first { !$0.isEmpty && canonicalUID.contains(canonical($0)) }
    }
}

/// 許可状態の読み取り結果の保持と、拒否かどうかの変化の検知。
struct BluetoothAuthorizationCache: Equatable {
    private(set) var isDenied = false

    /// 変化したときだけ true。未知の値は拒否として扱わない。
    mutating func update(_ authorization: CBManagerAuthorization) -> Bool {
        let denied: Bool
        switch authorization {
        case .denied, .restricted: denied = true
        case .notDetermined, .allowedAlways: denied = false
        @unknown default: denied = false
        }
        defer { isDenied = denied }
        return denied != isDenied
    }
}

/// 実装は自前の直列キューで実行し、呼び出し元を待たせない。
protocol BluetoothConnectionControl: Sendable {
    /// 読み取り済みの値。未読・未確認・許可済みは false。
    var isAuthorizationDenied: Bool { get }
    func prepareAuthorization()
    /// 読み直しは非同期で、拒否かどうかが変わったときだけハンドラを呼ぶ。
    func refreshAuthorization()
    func observeAuthorizationChanges(_ handler: @escaping @Sendable () -> Void)
    func disconnect(outputDeviceUID: String, completion: @escaping @Sendable (Bool) -> Void)
}

protocol BluetoothAutoDisconnectEngine: AnyObject, Sendable {
    var intendedOutputDeviceUID: String? { get }
    func outputSilenceObservation(_ token: AudioWorldToken) -> OutputSilenceObservation?
}

extension AudioEngine: BluetoothAutoDisconnectEngine {}

/// 状態はオーディオ世界のキュー上でのみ読み書きする。
final class BluetoothAutoDisconnectCoordinator: @unchecked Sendable {
    private static let fallbackDeviceName = "Bluetooth デバイス"

    private let engine: BluetoothAutoDisconnectEngine
    private let directory: AudioDeviceDirectory
    private let airPlayMode: AirPlayModeReconciling
    private let connectionControl: BluetoothConnectionControl
    private let audioWorld: AudioWorld
    private let now: @Sendable () -> TimeInterval

    private var settings = BluetoothAutoDisconnectSettings.disabled
    private var tracker = BluetoothAutoDisconnectTracker()
    private var status = BluetoothAutoDisconnectStatus.none

    /// オーディオ世界のキュー上で発火する。変化したときだけ。
    var statusDidChange: (@Sendable (BluetoothAutoDisconnectStatus) -> Void)?

    /// 実機の接続操作を既定にしない (テストが本物を掴む経路を作らない)。
    init(
        engine: BluetoothAutoDisconnectEngine, directory: AudioDeviceDirectory = CoreAudioDeviceDirectory(),
        airPlayMode: AirPlayModeReconciling, connectionControl: BluetoothConnectionControl, audioWorld: AudioWorld,
        now: @escaping @Sendable () -> TimeInterval = uptimeSeconds
    ) {
        self.engine = engine
        self.directory = directory
        self.airPlayMode = airPlayMode
        self.connectionControl = connectionControl
        self.audioWorld = audioWorld
        self.now = now
        connectionControl.observeAuthorizationChanges { [weak self, audioWorld] in
            audioWorld.submitUncoalesced { [weak self] token in self?.evaluate(token) }
        }
    }

    func configure(_ newSettings: BluetoothAutoDisconnectSettings, _ token: AudioWorldToken) {
        let becameEnabled = !settings.isEnabled && newSettings.isEnabled
        settings = newSettings
        if becameEnabled { connectionControl.prepareAuthorization() }
        evaluate(token)
    }

    func evaluate(_ token: AudioWorldToken) {
        connectionControl.refreshAuthorization()
        if connectionControl.isAuthorizationDenied {
            tracker = BluetoothAutoDisconnectTracker()
            publish(.unauthorized)
            return
        }

        guard settings.isEnabled else {
            tracker = BluetoothAutoDisconnectTracker()
            publish(.none)
            return
        }

        let observation = airPlayMode.isEngaged ? nil : engine.outputSilenceObservation(token)
        var target: (uid: String, deviceID: AudioDeviceID)?
        if observation != nil, let uid = engine.intendedOutputDeviceUID,
           let deviceID = directory.deviceID(forUID: uid, token),
           isBluetoothOutputTransport(directory.transportType(forDeviceID: deviceID, token)) {
            target = (uid, deviceID)
        }

        let verdict = tracker.evaluate(
            observation: observation, targetUID: target?.uid,
            limitSeconds: settings.silenceLimitSeconds, now: now()
        )
        let deviceName = target.map { directory.name(forDeviceID: $0.deviceID, token) ?? Self.fallbackDeviceName }

        switch verdict {
        case .inactive, .awaitingRearm:
            publish(.none)
        case .playing:
            publish(deviceName.map { .playing(deviceName: $0) } ?? .none)
        case .countingDown(let remaining):
            publish(deviceName.map {
                .countingDown(deviceName: $0, minutesRemaining: BluetoothAutoDisconnectStatus.minutesRemaining(seconds: remaining))
            } ?? .none)
        case .disconnect:
            publish(.none)
            guard let target, let deviceName else { return }
            connectionControl.disconnect(outputDeviceUID: target.uid) { [weak self, audioWorld] success in
                audioWorld.submitUncoalesced { [weak self] token in
                    self?.disconnectDidFinish(deviceName: deviceName, success: success, token)
                }
            }
        }
    }

    private func disconnectDidFinish(deviceName: String, success: Bool, _ token: AudioWorldToken) {
        if success {
            print("[info] Bluetooth auto-disconnect: disconnected \(deviceName)")
        } else {
            print("[warn] Bluetooth auto-disconnect: could not disconnect \(deviceName)")
        }
    }

    private func publish(_ newStatus: BluetoothAutoDisconnectStatus) {
        guard newStatus != status else { return }
        status = newStatus
        statusDidChange?(newStatus)
    }
}
