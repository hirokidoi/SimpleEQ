import AudioToolbox
import CoreAudio

protocol AudioDeviceDirectory: Sendable {
    func defaultOutputDeviceID(_ token: AudioWorldToken) -> AudioDeviceID?
    @discardableResult
    func setDefaultOutputDeviceID(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool
    func uid(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> String?
    func deviceID(forUID uid: String, _ token: AudioWorldToken) -> AudioDeviceID?

    func selectableOutputDevice(forUID uid: String, driverDeviceUID: String, _ token: AudioWorldToken) -> ResolvedOutputDevice?

    /// 非表示デバイスは列挙+照合では解決できないため、列挙を経由しない専用の経路で解決する。
    func resolveHiddenDeviceID(forUID uid: String, _ token: AudioWorldToken) -> AudioDeviceID?

    /// kAudioDevicePropertyIsHidden は外部クライアントから直接 Set できないため、
    /// ドライバが申告するカスタムプロパティ経由でのみ書き換える。
    @discardableResult
    func setHidden(_ hidden: Bool, forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool

    func isHidden(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool?

    func name(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> String?

    /// kAudioObjectPropertyName はドライバが書き換えを受け付けないため、
    /// ドライバが申告するカスタムプロパティ経由でのみ書き換える。
    @discardableResult
    func setName(_ name: String, forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool

    func containsDriverDevice(_ id: AudioDeviceID, driverDeviceUID: String, _ token: AudioWorldToken) -> Bool

    func isAirPlayDevice(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool
}

final class CoreAudioDeviceDirectory: AudioDeviceDirectory {
    func defaultOutputDeviceID(_ token: AudioWorldToken) -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr ? id : nil
    }

    @discardableResult
    func setDefaultOutputDeviceID(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        var v = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &v
        )
        return st == noErr
    }

    func uid(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> String? {
        deviceUID(id, token)
    }

    func deviceID(forUID targetUID: String, _ token: AudioWorldToken) -> AudioDeviceID? {
        allDeviceIDs(token).first { uid(forDeviceID: $0, token) == targetUID }
    }

    func selectableOutputDevice(forUID targetUID: String, driverDeviceUID: String, _ token: AudioWorldToken) -> ResolvedOutputDevice? {
        resolveSelectableOutputDevice(uid: targetUID, needsOutput: true, driverDeviceUID: driverDeviceUID, token)
    }

    func resolveHiddenDeviceID(forUID targetUID: String, _ token: AudioWorldToken) -> AudioDeviceID? {
        translateUIDToDeviceID(forUID: targetUID, token)
    }

    func containsDriverDevice(_ id: AudioDeviceID, driverDeviceUID: String, _ token: AudioWorldToken) -> Bool {
        // モジュール名を修飾しないと self.containsDriverDevice(...) と解釈され無限再帰になる。
        SimpleEQ.containsDriverDevice(id, driverDeviceUID: driverDeviceUID, token)
    }

    func isAirPlayDevice(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        SimpleEQ.isAirPlayDevice(id, token)
    }

    private func setCustomProperty(
        _ selector: AudioObjectPropertySelector, _ value: CFTypeRef,
        forDeviceID id: AudioDeviceID, _ token: AudioWorldToken
    ) -> Bool {
        setDeviceCustomProperty(selector, value, forDeviceID: id, token)
    }

    @discardableResult
    func setHidden(_ hidden: Bool, forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        setCustomProperty(
            DriverConfig.visibilityOverrideSelector,
            hidden ? kCFBooleanTrue : kCFBooleanFalse, forDeviceID: id, token
        )
    }

    func name(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> String? {
        deviceName(id, token)
    }

    @discardableResult
    func setName(_ name: String, forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        setCustomProperty(DriverConfig.nameOverrideSelector, name as CFString, forDeviceID: id, token)
    }

    func isHidden(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return st == noErr ? value != 0 : nil
    }
}

/// 専用ドライバのデバイスの見え方 (可視性と表示名) のライフサイクル。
/// アプリ起動時に出現させ、終了時に既定の見え方へ戻す。既定は非表示かつ固定名。
final class DriverLifecycleController: @unchecked Sendable {
    private let directory: AudioDeviceDirectory
    private let targetDeviceUID: String
    private(set) var resolvedDeviceID: AudioDeviceID?

    init(directory: AudioDeviceDirectory = CoreAudioDeviceDirectory(), targetDeviceUID: String) {
        self.directory = directory
        self.targetDeviceUID = targetDeviceUID
    }

    @discardableResult
    func resolveAndMakeVisible(_ token: AudioWorldToken) -> AudioDeviceID? {
        guard let id = resolveDeviceID(token) else { return nil }
        reapplyVisibility(deviceID: id, token)
        return id
    }

    func reapplyVisibility(deviceID: AudioDeviceID, _ token: AudioWorldToken) {
        resolvedDeviceID = deviceID
        directory.setHidden(false, forDeviceID: deviceID, token)
    }

    /// 切り戻せたかに関わらず戻す。鳴っていない出力先を名乗ったまま残すと、無音の原因を探す側を誤誘導する。
    func restoreDisplayNameForCleanExit(_ token: AudioWorldToken) {
        guard let id = resolveDeviceID(token) else { return }
        directory.setName(DriverConfig.deviceName, forDeviceID: id, token)
    }

    func hideForCleanExit(_ token: AudioWorldToken) {
        guard resolvedDeviceID != nil else { return }
        resolvedDeviceID = nil
        guard let id = resolveDeviceID(token) else { return }
        directory.setHidden(true, forDeviceID: id, token)
    }

    var isVisibilityOwnedBySession: Bool { resolvedDeviceID != nil }

    private func resolveDeviceID(_ token: AudioWorldToken) -> AudioDeviceID? {
        directory.deviceID(forUID: targetDeviceUID, token) ?? directory.resolveHiddenDeviceID(forUID: targetDeviceUID, token)
    }
}

/// 自ドライバのデバイス単独への出力切替・復帰を担う状態機械。
final class OutputDeviceController: @unchecked Sendable {
    private let directory: AudioDeviceDirectory
    private let targetDeviceUID: String

    private(set) var resolvedRestoreTargetID: AudioDeviceID?

    private var switchedDefaultOutputThisSession = false

    private var savedDefaultOutputUID: String?
    private var switchPending: Bool
    private let persistRestoreState: @Sendable (String?, Bool) -> Void

    var restoreTargetUID: String? { savedDefaultOutputUID }

    func currentRestoreState(_ token: AudioWorldToken) -> (uid: String?, pending: Bool) {
        (savedDefaultOutputUID, switchPending)
    }

    func restoreObligationNeedsReconcile(_ token: AudioWorldToken) -> Bool {
        guard let currentUID = currentDefaultOutputUID(token) else {
            guard let cached = resolvedRestoreTargetID, let uid = savedDefaultOutputUID else { return false }
            return cached != directory.deviceID(forUID: uid, token)
        }
        if currentUID == targetDeviceUID {
            guard switchPending || switchedDefaultOutputThisSession else { return false }
            guard switchPending else { return true }
            guard let uid = savedDefaultOutputUID else { return false }
            return resolvedRestoreTargetID != directory.deviceID(forUID: uid, token)
        }
        return switchPending || savedDefaultOutputUID != currentUID
    }

    @MainActor
    init(
        directory: AudioDeviceDirectory = CoreAudioDeviceDirectory(),
        settings: SettingsStore,
        targetDeviceUID: String,
        persistRestoreState: (@Sendable (String?, Bool) -> Void)? = nil
    ) {
        self.directory = directory
        self.targetDeviceUID = targetDeviceUID
        self.savedDefaultOutputUID = settings.savedDefaultOutputUID
        self.switchPending = settings.switchPending
        self.persistRestoreState = persistRestoreState ?? { _, _ in }
    }

    @discardableResult
    func occupyDefaultOutputForDriver(driverDeviceID: AudioDeviceID? = nil, _ token: AudioWorldToken) -> Bool {
        guard let restoreUID = determineRestoreUID(token) else { return false }
        savedDefaultOutputUID = restoreUID
        switchPending = true
        persistRestoreState(savedDefaultOutputUID, switchPending)
        refreshRestoreTarget(token)

        guard let targetID = driverDeviceID
            ?? directory.deviceID(forUID: targetDeviceUID, token)
            ?? directory.resolveHiddenDeviceID(forUID: targetDeviceUID, token) else {
            return false
        }
        let switched = directory.setDefaultOutputDeviceID(targetID, token)
        if switched { switchedDefaultOutputThisSession = true }
        return switched
    }

    @discardableResult
    func refreshRestoreTarget(_ token: AudioWorldToken) -> AudioDeviceID? {
        guard switchPending, let uid = savedDefaultOutputUID else { return nil }
        resolvedRestoreTargetID = directory.deviceID(forUID: uid, token)
        return resolvedRestoreTargetID
    }

    func reconcileRestoreObligation(_ token: AudioWorldToken) {
        guard let currentUID = currentDefaultOutputUID(token) else {
            guard resolvedRestoreTargetID != nil else { return }
            refreshRestoreTarget(token)
            return
        }
        if currentUID == targetDeviceUID {
            guard switchPending || switchedDefaultOutputThisSession else { return }
            switchPending = true
            persistRestoreState(savedDefaultOutputUID, switchPending)
            refreshRestoreTarget(token)
            return
        }
        if savedDefaultOutputUID != currentUID {
            savedDefaultOutputUID = currentUID
            persistRestoreState(savedDefaultOutputUID, switchPending)
        }
        discardRestoreObligation()
    }

    /// 義務を負っている間 (switchPending) に限り記録する。
    /// 自ドライバ自身の UID は記録しない (復帰先が自ドライバを指したままだと無音が解けない)。
    func noteOutputDeviceDidConfirm(uid: String) {
        guard switchPending else { return }
        guard uid != targetDeviceUID else { return }
        guard savedDefaultOutputUID != uid else { return }
        savedDefaultOutputUID = uid
        persistRestoreState(savedDefaultOutputUID, switchPending)
    }

    private func currentDefaultOutputUID(_ token: AudioWorldToken) -> String? {
        guard let id = directory.defaultOutputDeviceID(token) else { return nil }
        return directory.uid(forDeviceID: id, token)
    }

    /// 切り戻すのは復帰の義務が残っている間だけ。義務が既に解けている場合は書き換えず、フラグのみ畳む。
    /// - Returns: システムのデフォルト出力が自ドライバのデバイスから離れているか。
    @discardableResult
    func restore(_ token: AudioWorldToken) -> Bool {
        if switchPending {
            if occupiesDefaultOutput(token) {
                performRestore(token)
            } else {
                discardRestoreObligation()
            }
        }
        return !occupiesDefaultOutput(token)
    }

    /// システムのデフォルト出力を自ドライバのデバイスが占有しているか。
    /// 読み取れない場合は確証が持てないため安全側 (占有しているとみなす) に倒す。切り戻しの要否を決める側が呼ぶ。
    func occupiesDefaultOutput(_ token: AudioWorldToken) -> Bool {
        guard let uid = currentDefaultOutputUID(token) else { return true }
        return uid == targetDeviceUID
    }

    /// 読み取れない場合は偽に倒す。確証が無いならデフォルト出力へ書き込まない側が呼ぶ。
    func defaultOutputConfirmedAsDriver(_ token: AudioWorldToken) -> Bool {
        currentDefaultOutputUID(token) == targetDeviceUID
    }

    /// 読み取れない場合は安全側 (届いているとみなす) に倒す。
    func defaultOutputReachesDriver(_ token: AudioWorldToken) -> Bool {
        guard let id = directory.defaultOutputDeviceID(token),
              let uid = directory.uid(forDeviceID: id, token) else { return true }
        return reachesDriver(deviceID: id, uid: uid, driverDeviceUID: targetDeviceUID, token)
    }

    /// 復帰の義務を畳む (切り戻しは行わない)。占有が既に解けている場合に使う。
    private func discardRestoreObligation() {
        switchPending = false
        resolvedRestoreTargetID = nil
        persistRestoreState(savedDefaultOutputUID, switchPending)
    }

    @discardableResult
    private func performRestore(_ token: AudioWorldToken) -> Bool {
        guard let uid = savedDefaultOutputUID, let id = directory.deviceID(forUID: uid, token) else { return false }
        return applyRestore(toDeviceID: id, token)
    }

    private func applyRestore(toDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        guard directory.setDefaultOutputDeviceID(id, token) else { return false }
        discardRestoreObligation()
        return true
    }

    private func reachesDriver(
        deviceID: AudioDeviceID, uid: String, driverDeviceUID: String, _ token: AudioWorldToken
    ) -> Bool {
        uid == driverDeviceUID || directory.containsDriverDevice(deviceID, driverDeviceUID: driverDeviceUID, token)
    }

    /// 保存済み UID を引き継ぐのは、前回の切替が現に占有中のままである場合だけ。
    /// 自ドライバ自身は復帰先にしない (戻しても無音が解けない)。
    /// AirPlay のデバイスは復帰先にしない (二度と解決できない値が残り続ける)。
    private func determineRestoreUID(_ token: AudioWorldToken) -> String? {
        if switchPending, occupiesDefaultOutput(token), let saved = savedDefaultOutputUID {
            return saved
        }
        guard let id = directory.defaultOutputDeviceID(token),
              let uid = directory.uid(forDeviceID: id, token),
              uid != targetDeviceUID,
              !directory.isAirPlayDevice(id, token) else { return nil }
        return uid
    }

    /// ドライバのインストール/更新/アンインストールスクリプト実行前に必ず呼ぶ安全性ガード。
    /// 自ドライバのデバイスがデフォルト出力のままスクリプトを実行すると coreaudiod が不安定化する。
    /// - Returns: 破壊的スクリプトを実行してよいか。
    @discardableResult
    func ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: String, _ token: AudioWorldToken) -> Bool {
        guard let currentID = directory.defaultOutputDeviceID(token), let currentUID = directory.uid(forDeviceID: currentID, token) else {
            return false
        }
        guard reachesDriver(deviceID: currentID, uid: currentUID, driverDeviceUID: driverDeviceUID, token) else { return true }
        guard let restoreUID = savedDefaultOutputUID,
              let restoreID = directory.deviceID(forUID: restoreUID, token),
              !reachesDriver(deviceID: restoreID, uid: restoreUID, driverDeviceUID: driverDeviceUID, token) else {
            return false
        }
        return applyRestore(toDeviceID: restoreID, token)
    }
}
