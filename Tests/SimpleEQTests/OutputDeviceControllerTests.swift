import XCTest
import CoreAudio
@testable import SimpleEQ

/// モック。同一テストターゲット内で再利用するため internal にしている。
/// この代役へ触れる経路は直列キューが順序を作るため、同時に触れることが無い。
final class MockAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    var currentDefaultOutputID: AudioDeviceID?
    var uidsByDeviceID: [AudioDeviceID: String] = [:]
    var deviceIDsByUID: [String: AudioDeviceID] = [:]
    var hiddenDeviceIDsByUID: [String: AudioDeviceID] = [:]
    var isHiddenByDeviceID: [AudioDeviceID: Bool] = [:]
    var namesByDeviceID: [AudioDeviceID: String] = [:]
    /// 書き込み先ごとに結果コード失敗を模す。
    var setDefaultOutputFailingDeviceIDs: Set<AudioDeviceID> = []
    /// Aggregate/Multi-Output がドライバを内包している状況を模す。
    var containsDriverDeviceIDs: Set<AudioDeviceID> = []
    var airPlayDeviceIDs: Set<AudioDeviceID> = []

    /// デフォルト出力へ書き込む瞬間の状態を検証側から覗くための差し込み口。
    var willSetDefaultOutput: (@Sendable (AudioDeviceID) -> Void)?

    private(set) var setDefaultOutputCalls: [AudioDeviceID] = []
    private(set) var resolveHiddenDeviceIDCalls: [String] = []
    private(set) var setHiddenCalls: [(hidden: Bool, id: AudioDeviceID)] = []
    private(set) var setNameCalls: [(name: String, id: AudioDeviceID)] = []
    /// 表示名の判定へ到達したことを検証側から観測するための記録。
    private(set) var nameByDeviceIDCalls: [AudioDeviceID] = []
    var setNameShouldSucceed = true
    /// HAL 相当の問い合わせ回数を契機ごとに検証するための呼び出し記録。
    private(set) var deviceIDByUIDCalls: [String] = []
    private(set) var uidByDeviceIDCalls: [AudioDeviceID] = []
    private(set) var selectableOutputDeviceCalls: [String] = []

    func defaultOutputDeviceID(_ token: AudioWorldToken) -> AudioDeviceID? { currentDefaultOutputID }

    @discardableResult
    func setDefaultOutputDeviceID(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        willSetDefaultOutput?(id)
        setDefaultOutputCalls.append(id)
        // 失敗を返す回はデフォルト出力を動かさない (実機で結果コードが失敗を返したとき、
        // デフォルト出力は元のままであるため)。
        guard !setDefaultOutputFailingDeviceIDs.contains(id) else { return false }
        currentDefaultOutputID = id
        return true
    }

    func uid(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> String? {
        uidByDeviceIDCalls.append(id)
        return uidsByDeviceID[id]
    }

    func deviceID(forUID uid: String, _ token: AudioWorldToken) -> AudioDeviceID? {
        deviceIDByUIDCalls.append(uid)
        return deviceIDsByUID[uid]
    }

    /// UID 解決の結果へ除外判定を適用する。
    func selectableOutputDevice(forUID uid: String, driverDeviceUID: String, _ token: AudioWorldToken) -> ResolvedOutputDevice? {
        selectableOutputDeviceCalls.append(uid)
        guard let id = deviceIDsByUID[uid] else { return nil }
        let excluded = isExcludedFromOutputPicker(
            uid: uid, driverDeviceUID: driverDeviceUID,
            containsDriver: containsDriverDeviceIDs.contains(id), isAirPlay: airPlayDeviceIDs.contains(id)
        )
        return excluded ? nil : ResolvedOutputDevice(uid: uid, deviceID: id)
    }

    func isHidden(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool? { isHiddenByDeviceID[id] }

    func name(forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> String? {
        nameByDeviceIDCalls.append(id)
        return namesByDeviceID[id]
    }

    @discardableResult
    func setName(_ name: String, forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        setNameCalls.append((name: name, id: id))
        guard setNameShouldSucceed else { return false }
        namesByDeviceID[id] = name
        return true
    }

    /// 前提を組み立てる段階の呼び出しを、検証対象の回数から除くために使う。
    func resetCallRecords() {
        setDefaultOutputCalls = []
        resolveHiddenDeviceIDCalls = []
        setHiddenCalls = []
        setNameCalls = []
        nameByDeviceIDCalls = []
        deviceIDByUIDCalls = []
        uidByDeviceIDCalls = []
        selectableOutputDeviceCalls = []
    }

    func resolveHiddenDeviceID(forUID uid: String, _ token: AudioWorldToken) -> AudioDeviceID? {
        resolveHiddenDeviceIDCalls.append(uid)
        return hiddenDeviceIDsByUID[uid]
    }

    @discardableResult
    func setHidden(_ hidden: Bool, forDeviceID id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        setHiddenCalls.append((hidden: hidden, id: id))
        return true
    }

    func containsDriverDevice(_ id: AudioDeviceID, driverDeviceUID: String, _ token: AudioWorldToken) -> Bool {
        containsDriverDeviceIDs.contains(id)
    }

    func isAirPlayDevice(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        airPlayDeviceIDs.contains(id)
    }
}

@MainActor
final class OutputDeviceControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let multiOutputID: AudioDeviceID = 10
    private let multiOutputUID = "multi-output-uid"
    private let loopbackDeviceID: AudioDeviceID = 20
    private let loopbackDeviceUID = "loopback-device-uid"
    // 切替先 (自ドライバのデバイス) の UID は任意の固定値で代表させる。
    private let testDriverDeviceUID = "driver-device-uid"

    // 同期版は隔離を持たず、この検証が保持する状態を触れない。
    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("OutputDeviceControllerTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testOccupyDefaultOutputForDriverNeverWritesSettingsDirectlyAndDelegatesThroughPersistClosure() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let persisted = Recorded<[(uid: String?, pending: Bool)]>([])
        let controller = OutputDeviceController(
            directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID,
            persistRestoreState: { uid, pending in persisted.update { $0.append((uid, pending)) } }
        )

        XCTAssertTrue(controller.occupyDefaultOutputForDriver(testToken))

        XCTAssertNil(settings.savedDefaultOutputUID, "オーディオ世界側 (このコントローラ) は settings を直接書かない")
        XCTAssertFalse(settings.switchPending, "同上")
        XCTAssertEqual(persisted.value.last?.uid, multiOutputUID, "変化は persistRestoreState 経由で UI 世界へ渡る")
        XCTAssertEqual(persisted.value.last?.pending, true)
        XCTAssertEqual(controller.restoreTargetUID, multiOutputUID, "コントローラ自身の以後の判断は写しを使う (settings の反映を待たない)")
    }

    // (a) クリーン起動で現在のデフォルト出力を保存対象にし、自ドライバのデバイス単独へ切り替える。
    func testCleanStartupSavesCurrentDefaultAndSwitchesToTargetDevice() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.switchPending)

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let ok = controller.occupyDefaultOutputForDriver(testToken)

        XCTAssertTrue(ok)
        XCTAssertEqual(controller.currentRestoreState(testToken).uid, multiOutputUID)
        XCTAssertTrue(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(mock.setDefaultOutputCalls, [loopbackDeviceID])
        XCTAssertEqual(controller.resolvedRestoreTargetID, multiOutputID)
    }

    // デフォルト出力が AirPlay のときは占有しない。占有すると端末の選択が外れそのデバイスが消える。
    func testDoesNotOccupyWhenCurrentDefaultOutputIsAirPlay() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID
        mock.airPlayDeviceIDs = [multiOutputID]

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let ok = controller.occupyDefaultOutputForDriver(testToken)

        XCTAssertFalse(ok)
        XCTAssertNil(controller.currentRestoreState(testToken).uid, "解決できなくなる UID を復帰先に記録してはならない")
        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(mock.setDefaultOutputCalls, [], "デフォルト出力を動かしてはならない")
    }

    // デフォルト出力が既に自ドライバのとき、その UID を復帰先に記録してはならない。
    // 記録すると切り戻し先が自ドライバのままになり、戻しても無音が解けない。
    func testDoesNotOccupyWhenCurrentDefaultOutputIsDriverItselfWithoutPendingRestore() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.switchPending, "復帰の義務を負っていない状態から始める")

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let ok = controller.occupyDefaultOutputForDriver(testToken)

        XCTAssertFalse(ok)
        XCTAssertNil(controller.currentRestoreState(testToken).uid, "自ドライバ自身を復帰先に記録してはならない")
        XCTAssertFalse(controller.currentRestoreState(testToken).pending, "切り替えていない以上、復帰の義務も負わない")
        XCTAssertEqual(mock.setDefaultOutputCalls, [], "デフォルト出力を動かしてはならない")
    }

    func testPendingRestartReusesSavedUIDWithoutOverwriting() {
        let mock = MockAudioDeviceDirectory()
        // 前回が復帰せず終了した状態: デフォルト出力は自ドライバのデバイス単独のまま。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let ok = controller.occupyDefaultOutputForDriver(testToken)

        XCTAssertTrue(ok)
        XCTAssertEqual(controller.currentRestoreState(testToken).uid, multiOutputUID, "現在値 (自ドライバのデバイス単独) で上書きされてはならない")
        XCTAssertTrue(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(controller.resolvedRestoreTargetID, multiOutputID)
    }

    func testPendingRestartDoesNotReuseSavedUIDWhenNoLongerOccupying() {
        let mock = MockAudioDeviceDirectory()
        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID
        mock.deviceIDsByUID[userPickedUID] = userPickedID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertTrue(controller.occupyDefaultOutputForDriver(testToken))

        XCTAssertEqual(controller.currentRestoreState(testToken).uid, userPickedUID, "現在の選択が新しい復帰対象になる")
        XCTAssertEqual(controller.resolvedRestoreTargetID, userPickedID)
    }

    // 切替先デバイスが見つからない場合は失敗を返し、デフォルト出力の切替は行わない。
    func testStartupFailsWhenTargetDeviceMissing() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.occupyDefaultOutputForDriver(testToken))
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty)
    }

    func testStartupSwitchUsesProvidedDriverDeviceIDWithoutResolvingTargetUID() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let ok = controller.occupyDefaultOutputForDriver(driverDeviceID: loopbackDeviceID, testToken)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.setDefaultOutputCalls, [loopbackDeviceID])
        XCTAssertFalse(
            mock.deviceIDByUIDCalls.contains(testDriverDeviceUID),
            "ID を渡した場合は切替先の UID 解決を経由しない (復帰対象の UID 解決のみ)"
        )
        XCTAssertTrue(mock.resolveHiddenDeviceIDCalls.isEmpty)
    }

    func testStartupSwitchFallsBackToUIDResolutionWhenDriverDeviceIDNotProvided() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let ok = controller.occupyDefaultOutputForDriver(driverDeviceID: nil, testToken)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.setDefaultOutputCalls, [loopbackDeviceID])
        XCTAssertTrue(mock.deviceIDByUIDCalls.contains(testDriverDeviceUID))
    }

    // 切替先が列挙+照合で解決できない場合は、非表示デバイス向けの解決経路へフォールバックする。
    func testStartupSwitchFallsBackToHiddenResolutionWhenUIDNotEnumerable() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.hiddenDeviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertTrue(controller.occupyDefaultOutputForDriver(driverDeviceID: nil, testToken))
        XCTAssertEqual(mock.setDefaultOutputCalls, [loopbackDeviceID])
        XCTAssertEqual(mock.resolveHiddenDeviceIDCalls, [testDriverDeviceUID])
    }

    // MARK: - refreshRestoreTarget (復帰対象の ID キャッシュの打ち直し)

    // 復帰待ちの間は、保存済み UID から解決し直した ID で復帰対象を更新する。
    func testRefreshRestoreTargetReresolvesSavedUIDAfterDeviceIDsChange() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.occupyDefaultOutputForDriver(testToken)
        XCTAssertEqual(controller.resolvedRestoreTargetID, multiOutputID)

        // ID の総入れ替え: 同じ UID が別の ID を取る。
        let renumberedID: AudioDeviceID = 77
        mock.deviceIDsByUID[multiOutputUID] = renumberedID
        mock.uidsByDeviceID[renumberedID] = multiOutputUID

        XCTAssertEqual(controller.refreshRestoreTarget(testToken), renumberedID)
        XCTAssertEqual(controller.resolvedRestoreTargetID, renumberedID)
    }

    // 復帰済みの間は復帰対象を持たない状態が正しいため、打ち直しでも復活させない。
    func testRefreshRestoreTargetDoesNothingWhenRestoreAlreadyDone() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        // 占有継続 = 義務あり。読み取り失敗時の既定に依存させない。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertTrue(controller.restore(testToken))

        XCTAssertNil(controller.refreshRestoreTarget(testToken))
        XCTAssertNil(controller.resolvedRestoreTargetID)
    }

    // 復帰の義務が無い間は切り戻さない。義務を見ずに切り戻すと、選び直した出力先を保存値へ書き換えてしまう。
    func testRestoreDoesNotSwitchWhenNothingToRestore() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        // 1 回目は占有継続 = 義務あり。読み取り失敗時の既定に依存させない。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertTrue(controller.restore(testToken))
        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID])

        // 復帰後にユーザが別のデバイスを選び直した状態。
        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID

        XCTAssertTrue(controller.restore(testToken), "自ドライバから離れているので非表示にしてよい")
        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID], "選び直した出力先を書き換えない")
        XCTAssertEqual(mock.currentDefaultOutputID, userPickedID)
    }

    // 占有が解けている状態で切り戻すとユーザの現在の選択を奪うため、切り戻さず義務だけ畳む。
    func testRestoreDiscardsObligationWhenDefaultMovedAwayDuringSession() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        // ユーザが自分で選び直した出力先 (自ドライバではない)。
        let userPickedID: AudioDeviceID = 77
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = "user-picked-uid"

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertTrue(controller.restore(testToken))

        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty, "ユーザの現在の選択を書き換えない")
        XCTAssertEqual(mock.currentDefaultOutputID, userPickedID)
        XCTAssertFalse(
            controller.currentRestoreState(testToken).pending,
            "義務は消えている。残すと次回起動が過去の保存値を復帰対象として引き継ぐ"
        )
    }

    // 戻り値は「自ドライバのデバイスから離れているか」。デフォルト出力が自ドライバのままなら false を返す。
    func testRestoreReportsNotAwayWhenDefaultIsStillDriverDevice() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.restore(testToken))
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty)
    }

    // 復帰対象が解決できなくなったら ID キャッシュもクリアする。
    func testRefreshRestoreTargetClearsCachedRestoreTargetWhenResolutionFails() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertEqual(controller.refreshRestoreTarget(testToken), multiOutputID)
        XCTAssertNotNil(controller.resolvedRestoreTargetID)

        mock.deviceIDsByUID[multiOutputUID] = nil

        XCTAssertNil(controller.refreshRestoreTarget(testToken))
        XCTAssertNil(controller.resolvedRestoreTargetID, "解決できない間は復帰させない (何もしない方が安全側)")
    }

    func testStartupFailsWhenCurrentDefaultUnreadable() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.occupyDefaultOutputForDriver(testToken))
        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
    }

    func testCleanExitRestoresSavedDeviceAndClearsPending() {
        let mock = MockAudioDeviceDirectory()
        // 占有継続 (デフォルト出力が自ドライバのデバイスのまま) を明示し、
        // 読み取り失敗時の既定に依存せず「義務があるから切り戻す」経路を通ることを確かめる。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.restore(testToken)

        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID])
        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
        XCTAssertNil(controller.resolvedRestoreTargetID)
    }

    // 保存済み UID が解決できない場合、何もしない。
    func testCleanExitDoesNothingWhenSavedUIDUnresolvable() {
        let mock = MockAudioDeviceDirectory()
        // multiOutputUID をあえて deviceIDsByUID に登録しない = 解決失敗を再現
        // デフォルト出力は自ドライバのデバイスのまま (占有継続 = 復帰の義務がある状態)
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(
            controller.restore(testToken),
            "復帰できずデフォルト出力が自ドライバのままなら、ドライバを非表示にしてはならない"
        )
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty, "解決できない場合は出力を変更しない")
        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "次回起動時に同じ UID を再利用できるようクリアしない")
    }

    // デフォルト出力そのものが読み取れない場合は確証が持てないため、安全側 (自ドライバのまま) に倒す。
    func testRestoreReportsNotAwayWhenDefaultOutputUnreadable() {
        let mock = MockAudioDeviceDirectory()
        // currentDefaultOutputID を設定しない = 読み取り失敗を再現

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.restore(testToken))
    }

    // 保存済み UID は解決できても、CoreAudio 呼び出し自体が結果コード失敗を返す場合はクリアしてはならない。
    func testCleanExitDoesNotClearPendingWhenSetDefaultOutputDeviceIDFails() {
        let mock = MockAudioDeviceDirectory()
        // 占有継続 (デフォルト出力が自ドライバのデバイスのまま) を明示し、
        // 読み取り失敗時の既定に依存せず「義務があるから切り戻す」経路を通ることを確かめる。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.setDefaultOutputFailingDeviceIDs = [multiOutputID]

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.restore(testToken)

        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "CoreAudio 呼び出しが失敗した場合は復帰できていないためクリアしない")
        XCTAssertEqual(
            mock.currentDefaultOutputID, loopbackDeviceID,
            "モックの忠実性: 切替が失敗を返す回はデフォルト出力を動かさない (保証するのは HAL 側であり、この検証対象はモックの側)"
        )
        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID], "失敗を仕込んだ書き込み先が、この経路で実際に書く唯一の先であること")
    }

    // MARK: - reconcileRestoreObligation (復帰義務の実態追従)

    // 占有が解けたとき、義務を畳み、保存済み復帰先を占有が解けた時点のデフォルト出力へ打ち直し、ID キャッシュを解く。
    func testReconcileRestoreObligationDiscardsWhenOccupancyReleased() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-saved-uid"
        settings.switchPending = true
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        // ユーザがデフォルト出力を自ドライバから離れた別デバイスへ移した。
        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID

        controller.reconcileRestoreObligation(testToken)

        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(controller.currentRestoreState(testToken).uid, userPickedUID, "占有が解けた時点のデフォルト出力を次の復帰先として記録する")
        XCTAssertNil(controller.resolvedRestoreTargetID)
    }

    // 占有が本アプリの切替に由来する場合、占有が一度解けて義務が畳まれた後、占有が自ドライバへ戻ると義務を再び負う。
    func testReconcileRestoreObligationReassertsObligationWhenOccupancyReturnsAfterSessionSwitch() {
        let mock = MockAudioDeviceDirectory()
        let originalDefaultID: AudioDeviceID = 5
        let originalDefaultUID = "original-default-uid"
        mock.currentDefaultOutputID = originalDefaultID
        mock.uidsByDeviceID[originalDefaultID] = originalDefaultUID
        mock.deviceIDsByUID[originalDefaultUID] = originalDefaultID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertTrue(controller.occupyDefaultOutputForDriver(testToken), "前提: 本セッションが切替を実施した実績を作る")

        // 占有が一度解ける (ユーザが選び直した)。
        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID
        mock.deviceIDsByUID[userPickedUID] = userPickedID
        controller.reconcileRestoreObligation(testToken)
        XCTAssertFalse(controller.currentRestoreState(testToken).pending, "前提: 占有が解けて義務が畳まれている")
        XCTAssertEqual(controller.currentRestoreState(testToken).uid, userPickedUID)

        // 占有が自ドライバへ戻る。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        controller.reconcileRestoreObligation(testToken)

        XCTAssertTrue(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(controller.resolvedRestoreTargetID, userPickedID, "離脱時に記録した復帰先へ追従する")
    }

    func testReconcileRestoreObligationAssertsObligationWhenSwitchPendingPersistedWithoutSessionSwitch() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.reconcileRestoreObligation(testToken)

        XCTAssertTrue(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(controller.resolvedRestoreTargetID, multiOutputID)
    }

    // 占有していても、本アプリの切替に由来しない場合は義務を立てない。
    func testReconcileRestoreObligationDoesNothingWhenOccupiedWithoutOwnSwitch() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.reconcileRestoreObligation(testToken)

        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
        XCTAssertNil(controller.resolvedRestoreTargetID)
    }

    // デフォルト出力を読めない場合、ID キャッシュを保持している間は保存済み UID の解決結果へ ID キャッシュだけが追従する。
    func testReconcileRestoreObligationRefreshesCacheOnlyWhenCacheHeldAndDefaultOutputUnreadable() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertEqual(controller.refreshRestoreTarget(testToken), multiOutputID)
        XCTAssertNotNil(controller.resolvedRestoreTargetID)

        // ID の総入れ替えとともに、デフォルト出力自体も読めなくなる (coreaudiod 再起動直後を模す)。
        let renumberedID: AudioDeviceID = 88
        mock.deviceIDsByUID[multiOutputUID] = renumberedID
        mock.uidsByDeviceID[renumberedID] = multiOutputUID
        mock.currentDefaultOutputID = nil

        controller.reconcileRestoreObligation(testToken)

        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "義務の有無は動かさない")
        XCTAssertEqual(controller.resolvedRestoreTargetID, renumberedID, "ID キャッシュを持つ間は ID キャッシュだけ追従する")
    }

    // デフォルト出力を読めず、ID キャッシュも保持していない場合は何もしない。
    func testReconcileRestoreObligationDoesNothingWithoutCachedRestoreTargetWhenDefaultOutputUnreadable() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.switchPending = false

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.reconcileRestoreObligation(testToken)

        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
        XCTAssertNil(controller.resolvedRestoreTargetID)
    }

    // 義務を負い復帰先も保存済みだが ID キャッシュを解決していない状態で、デフォルト出力が読めない場合は解決を試みない。
    func testReconcileRestoreObligationDoesNotResolveRestoreTargetWhenCacheIsEmptyAndDefaultOutputUnreadable() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.currentDefaultOutputID = nil

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        XCTAssertNil(controller.resolvedRestoreTargetID)

        controller.reconcileRestoreObligation(testToken)

        XCTAssertNil(controller.resolvedRestoreTargetID, "ID キャッシュを持たない間は解決を試みない")
        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "義務の有無は動かさない")
    }

    // MARK: - noteOutputDeviceDidConfirm (復帰先の実出力先追従)

    // 義務を負っている間、出力先の確定を通すと復帰先がそのデバイスの UID へ追従する。
    func testNoteOutputDeviceDidConfirmFollowsConfirmedUIDWhileObligationHeld() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-restore-target"
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.noteOutputDeviceDidConfirm(uid: "actual-output-uid")

        XCTAssertEqual(controller.currentRestoreState(testToken).uid, "actual-output-uid")
    }

    // 自ドライバ自身の UID は復帰先として記録されない。記録すると、復帰しても無音が解けない。
    func testNoteOutputDeviceDidConfirmDoesNotRecordDriverOwnUID() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-restore-target"
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.noteOutputDeviceDidConfirm(uid: testDriverDeviceUID)

        XCTAssertEqual(controller.currentRestoreState(testToken).uid, "previous-restore-target", "自ドライバ自身の UID は記録しない")
    }

    // エンジンが一度も出力していない間は、起動直前のデフォルト出力が復帰先のままになる。
    func testRestoreTargetStaysAtStartupDefaultBeforeAnyOutputConfirmed() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertTrue(controller.occupyDefaultOutputForDriver(testToken))
        XCTAssertEqual(controller.restoreTargetUID, multiOutputUID, "起動直前のデフォルト出力がそのまま復帰先")
    }

    // 離脱分岐は追従の追加後も変更されず、占有が解けた時点のデフォルト出力を復帰先として記録する。
    func testDepartureBranchStillRewritesRestoreTargetOnOccupancyRelease() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-saved-uid"
        settings.switchPending = true
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID

        controller.reconcileRestoreObligation(testToken)

        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
        XCTAssertEqual(controller.currentRestoreState(testToken).uid, userPickedUID, "占有が解けた時点のデフォルト出力を復帰先として記録する")
    }

    // 復帰先の追従は義務を動かさない。値の追従と義務の追従は同一の入口にまとめない。
    func testNoteOutputDeviceDidConfirmDoesNotChangeObligationState() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID["previous-restore-target"] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-restore-target"
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.refreshRestoreTarget(testToken)
        XCTAssertNotNil(controller.resolvedRestoreTargetID, "前提: ID キャッシュ保持")

        controller.noteOutputDeviceDidConfirm(uid: "new-actual-output-uid")

        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "義務のフラグは動かない")
        XCTAssertNotNil(controller.resolvedRestoreTargetID, "ID キャッシュも動かない")
    }

    // 義務を負っていない状態では記録しない。是正パスを経由しない選び直しを模す。
    func testNoteOutputDeviceDidConfirmDoesNothingWhenObligationNotHeld() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-restore-target"
        settings.switchPending = false

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        controller.noteOutputDeviceDidConfirm(uid: "picked-without-reconciler-uid")

        XCTAssertEqual(controller.currentRestoreState(testToken).uid, "previous-restore-target", "義務を負っていない間は記録しない")
    }

    // 離脱分岐が復帰先を記録して義務を畳んだ後、出力先を選び直しても記録が上書きされない。
    func testNoteOutputDeviceDidConfirmDoesNotOverwriteAfterObligationDiscarded() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "previous-saved-uid"
        settings.switchPending = true
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        // ユーザまたは他アプリがデフォルト出力を自ドライバから離れた別デバイスへ移した (離脱分岐)。
        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID
        controller.reconcileRestoreObligation(testToken)
        XCTAssertFalse(controller.currentRestoreState(testToken).pending, "前提: 義務が畳まれている")
        XCTAssertEqual(controller.currentRestoreState(testToken).uid, userPickedUID)

        // その状態でユーザが上部バーから出力先を選び直す (是正パスを経由しない経路)。
        controller.noteOutputDeviceDidConfirm(uid: "newly-picked-uid")

        XCTAssertEqual(controller.currentRestoreState(testToken).uid, userPickedUID, "義務が畳まれた後の選び直しで上書きされてはならない")
    }

    // 義務が再び立つと追従のゲートが開き、以後の出力先へ追従する。
    func testNoteOutputDeviceDidConfirmFollowsAgainAfterObligationIsReasserted() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        // 前提: 本セッションが切替を実施した実績を作る。
        XCTAssertTrue(controller.occupyDefaultOutputForDriver(testToken))

        // 離脱分岐で義務を畳む (占有が一度解ける)。
        let userPickedID: AudioDeviceID = 77
        let userPickedUID = "user-picked-uid"
        mock.currentDefaultOutputID = userPickedID
        mock.uidsByDeviceID[userPickedID] = userPickedUID
        mock.deviceIDsByUID[userPickedUID] = userPickedID
        controller.reconcileRestoreObligation(testToken)
        XCTAssertFalse(controller.currentRestoreState(testToken).pending, "前提: 義務が畳まれている")

        // 占有が自ドライバへ戻り、義務が再び立つ。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        controller.reconcileRestoreObligation(testToken)
        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "前提: 義務が再び立っている")

        controller.noteOutputDeviceDidConfirm(uid: "newly-confirmed-uid")

        XCTAssertEqual(controller.currentRestoreState(testToken).uid, "newly-confirmed-uid", "ゲートが開き、実出力先へ追従する")
    }

    // MARK: - ensureDefaultOutputIsSafeToMutateDriver

    // 現在のデフォルト出力が自ドライバの UID と異なり、それを内包する構成でもない場合は何もせず続行してよい。
    func testEnsureSafeDefaultOutputIsNoOpWhenCurrentOutputNeitherIsDriverNorContainsIt() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertTrue(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty)
    }

    // 現在のデフォルト出力 UID が自ドライバの UID と一致する場合、保存済み UID の実デバイスへ復帰する。
    func testEnsureSafeDefaultOutputRestoresSavedDeviceWhenCurrentOutputIsDriver() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertTrue(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID])
        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
    }

    // UID は一致しないが、その ID を内包する構成の場合も直接一致と同じ経路で復帰する。
    func testEnsureSafeDefaultOutputRestoresWhenCurrentOutputIsAggregateContainingDriver() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.containsDriverDeviceIDs = [multiOutputID]
        mock.deviceIDsByUID[loopbackDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = loopbackDeviceUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertTrue(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertEqual(mock.setDefaultOutputCalls, [loopbackDeviceID])
        XCTAssertFalse(controller.currentRestoreState(testToken).pending)
    }

    // 保存済み UID が自ドライバを内包する構成を指す場合、
    // 退避してもガードが防ごうとしている状態のままになるため、書き込まずに失敗を返す。
    func testEnsureSafeDefaultOutputFailsWhenRestoreTargetContainsDriver() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.containsDriverDeviceIDs = [multiOutputID]

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty, "危険な退避先へは書き込まない")
        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "退避していない場合は復帰の義務も畳まない")
    }

    // 保存済み UID が自ドライバ自身を指す場合も、退避先として受け付けない。
    func testEnsureSafeDefaultOutputFailsWhenRestoreTargetIsDriverItself() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID
        mock.containsDriverDeviceIDs = [multiOutputID]
        mock.deviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = testDriverDeviceUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty, "危険な退避先へは書き込まない")
        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "退避していない場合は復帰の義務も畳まない")
    }

    // 一致するが保存済み UID が解決できない (集約デバイス削除等) 場合は復帰できず失敗を返す。
    func testEnsureSafeDefaultOutputFailsWhenDriverIsDefaultButSavedUIDUnresolvable() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        // multiOutputUID をあえて deviceIDsByUID に登録しない = 解決失敗を再現

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertTrue(mock.setDefaultOutputCalls.isEmpty)
    }

    // 一致し保存済み UID も解決可能だが、CoreAudio 呼び出し自体が結果コード失敗を返す場合は失敗を返す。
    func testEnsureSafeDefaultOutputFailsWhenSetDefaultOutputDeviceIDFails() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.setDefaultOutputFailingDeviceIDs = [multiOutputID]

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
        XCTAssertTrue(controller.currentRestoreState(testToken).pending, "復帰できていない場合はクリアしない")
        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID], "失敗を仕込んだ書き込み先が、この経路で実際に書く唯一の先であること")
    }

    // 現在のデフォルト出力そのものが読めない場合、確証が持てないため安全側に倒して中止する。
    func testEnsureSafeDefaultOutputFailsWhenCurrentDefaultUnreadable() {
        let mock = MockAudioDeviceDirectory()
        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
    }

    // 現在のデフォルト出力 ID は読めるが UID が解決できない場合も、同様に安全側に倒して中止する。
    func testEnsureSafeDefaultOutputFailsWhenCurrentUIDUnresolvable() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = multiOutputID
        // multiOutputID をあえて uidsByDeviceID に登録しない = UID 解決失敗を再現

        let settings = SettingsStore(defaults: defaults)
        let controller = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)

        XCTAssertFalse(controller.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: testDriverDeviceUID, testToken))
    }

    // MARK: - 終了シーケンスの順序 (停止 → 復帰 → 復帰できたときだけ非表示化)

    // 復帰に失敗した場合、非表示化を行ってはならない。
    // 行うと、デフォルト出力が自ドライバのデバイスを指したまま一覧から消え、選び直す手段が無くなる。
    func testCleanExitDoesNotHideDriverWhenRestoreFails() {
        let mock = MockAudioDeviceDirectory()
        // 占有継続 (デフォルト出力が自ドライバのデバイスのまま)。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        // 復帰先の保存済み UID (multiOutputUID) をあえて deviceIDsByUID に登録せず、解決失敗を再現する。

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let outputController = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let lifecycle = DriverLifecycleController(directory: mock, targetDeviceUID: testDriverDeviceUID)
        lifecycle.reapplyVisibility(deviceID: loopbackDeviceID, testToken) // 可視化済みの状態を作る。
        mock.resetCallRecords() // 前提構築で積んだ setHiddenCalls を検証対象から除く。

        if outputController.restore(testToken) {
            lifecycle.hideForCleanExit(testToken)
        }

        XCTAssertTrue(mock.setHiddenCalls.isEmpty, "復帰に失敗した場合は非表示化してはならない")
        XCTAssertTrue(outputController.currentRestoreState(testToken).pending, "復帰できていないため義務も残る")
    }

    // 終了シーケンス本体は static 関数として切り出されており、
    // 実クラスの組み合わせと実際のキュー経由の待ち合わせを通して、順序 (停止 → 復帰 → 非表示化) と完了待ちを固定できる。
    func testPerformCleanExitSequenceRestoresAndHidesInOrderThroughRealAudioWorld() {
        let mock = MockAudioDeviceDirectory()
        // 復帰前: デフォルト出力は自ドライバのデバイスのまま (占有継続)。
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.hiddenDeviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let audioWorld = AudioWorld()
        let engine = AudioEngine(audioWorld: audioWorld)
        let outputController = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let lifecycle = DriverLifecycleController(directory: mock, targetDeviceUID: testDriverDeviceUID)
        lifecycle.reapplyVisibility(deviceID: loopbackDeviceID, testToken) // 可視化済みの状態を作る。
        mock.resetCallRecords()

        let completed = AppDelegate.performCleanExitSequence(
            audioWorld: audioWorld, engine: engine, outputController: outputController,
            driverLifecycle: lifecycle, settings: settings, timeout: 1.0
        )

        XCTAssertTrue(completed, "上限内に完了する")
        XCTAssertEqual(mock.setDefaultOutputCalls, [multiOutputID], "先に元の出力デバイスへ復帰する")
        XCTAssertEqual(mock.setNameCalls.last?.name, DriverConfig.deviceName, "表示名を固定名へ戻す")
        XCTAssertEqual(mock.setHiddenCalls.last?.hidden, true, "復帰できたので専用ドライバのデバイスを非表示化する")
        XCTAssertEqual(mock.setHiddenCalls.last?.id, loopbackDeviceID)
        XCTAssertFalse(settings.switchPending, "復帰できたので義務が畳まれる")
    }

    /// 切り戻せない状況で動的な名前が残ると、無音の原因を探す側が存在しない経路を指す名前を見る。
    func testPerformCleanExitSequenceRestoresTheFixedNameEvenWhenTheRestoreFails() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.hiddenDeviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID
        mock.namesByDeviceID[loopbackDeviceID] = "SimpleEQ - 消えた出力先"

        let settings = SettingsStore(defaults: defaults)
        // 復帰対象が解決できないため切り戻せない。
        settings.savedDefaultOutputUID = "unresolvable-restore-target-uid"
        settings.switchPending = true

        let audioWorld = AudioWorld()
        let engine = AudioEngine(audioWorld: audioWorld)
        let outputController = OutputDeviceController(directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID)
        let lifecycle = DriverLifecycleController(directory: mock, targetDeviceUID: testDriverDeviceUID)
        lifecycle.reapplyVisibility(deviceID: loopbackDeviceID, testToken)
        mock.resetCallRecords()

        let completed = AppDelegate.performCleanExitSequence(
            audioWorld: audioWorld, engine: engine, outputController: outputController,
            driverLifecycle: lifecycle, settings: settings, timeout: 1.0
        )

        XCTAssertTrue(completed, "上限内に完了する")
        XCTAssertTrue(mock.setHiddenCalls.isEmpty, "切り戻せていないので非表示化しない")
        XCTAssertEqual(mock.setNameCalls.last?.name, DriverConfig.deviceName, "切り戻せなくても表示名は固定名へ戻す")
    }

    func testPerformCleanExitSequenceFlushesRestoreStateSynchronouslyEvenWithAsyncPersistClosure() {
        let mock = MockAudioDeviceDirectory()
        mock.currentDefaultOutputID = loopbackDeviceID
        mock.uidsByDeviceID[loopbackDeviceID] = testDriverDeviceUID
        mock.hiddenDeviceIDsByUID[testDriverDeviceUID] = loopbackDeviceID
        mock.deviceIDsByUID[multiOutputUID] = multiOutputID
        mock.uidsByDeviceID[multiOutputID] = multiOutputUID

        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = multiOutputUID
        settings.switchPending = true

        let audioWorld = AudioWorld()
        let engine = AudioEngine(audioWorld: audioWorld)
        // 本番と同じく main.async へ委譲する閉包を注入する。
        let outputController = OutputDeviceController(
            directory: mock, settings: settings, targetDeviceUID: testDriverDeviceUID,
            persistRestoreState: { uid, pending in
                DispatchQueue.main.async {
                    settings.savedDefaultOutputUID = uid
                    settings.switchPending = pending
                }
            }
        )
        let lifecycle = DriverLifecycleController(directory: mock, targetDeviceUID: testDriverDeviceUID)
        lifecycle.reapplyVisibility(deviceID: loopbackDeviceID, testToken)
        mock.resetCallRecords()

        let completed = AppDelegate.performCleanExitSequence(
            audioWorld: audioWorld, engine: engine, outputController: outputController,
            driverLifecycle: lifecycle, settings: settings, timeout: 1.0
        )

        XCTAssertTrue(completed, "上限内に完了する")
        XCTAssertFalse(settings.switchPending, "終了シーケンスの完了時点で、main.async の実行を待たずに確定している")
        XCTAssertEqual(settings.savedDefaultOutputUID, multiOutputUID)
    }
}

@MainActor
final class DriverLifecycleControllerTests: XCTestCase {
    private let targetUID = "SimpleEQAudio2ch_UID"
    private let visibleDeviceID: AudioDeviceID = 30
    private let hiddenDeviceID: AudioDeviceID = 40

    // (a) 通常解決で成功する場合は非表示解決経路を呼ばない。
    func testResolveAndMakeVisiblePrefersNormalResolutionOverHiddenResolution() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[targetUID] = visibleDeviceID
        mock.hiddenDeviceIDsByUID[targetUID] = hiddenDeviceID

        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)
        let resolved = controller.resolveAndMakeVisible(testToken)

        XCTAssertEqual(resolved, visibleDeviceID)
        XCTAssertTrue(mock.resolveHiddenDeviceIDCalls.isEmpty, "通常解決で成功した場合は非表示解決経路を呼ばない")
    }

    func testResolveAndMakeVisibleFallsBackToHiddenResolutionWhenNormalResolutionFails() {
        let mock = MockAudioDeviceDirectory()
        mock.hiddenDeviceIDsByUID[targetUID] = hiddenDeviceID

        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)
        let resolved = controller.resolveAndMakeVisible(testToken)

        XCTAssertEqual(resolved, hiddenDeviceID)
        XCTAssertEqual(mock.resolveHiddenDeviceIDCalls, [targetUID])
    }

    func testResolveAndMakeVisibleSetsResolvedDeviceVisible() {
        let mock = MockAudioDeviceDirectory()
        mock.hiddenDeviceIDsByUID[targetUID] = hiddenDeviceID

        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)
        controller.resolveAndMakeVisible(testToken)

        XCTAssertEqual(mock.setHiddenCalls.count, 1)
        XCTAssertEqual(mock.setHiddenCalls.first?.hidden, false)
        XCTAssertEqual(mock.setHiddenCalls.first?.id, hiddenDeviceID)
        XCTAssertEqual(controller.resolvedDeviceID, hiddenDeviceID)
    }

    func testResolveAndMakeVisibleReturnsNilWhenUnresolvable() {
        let mock = MockAudioDeviceDirectory()

        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)
        let resolved = controller.resolveAndMakeVisible(testToken)

        XCTAssertNil(resolved)
        XCTAssertTrue(mock.setHiddenCalls.isEmpty)
        XCTAssertNil(controller.resolvedDeviceID)
    }

    func testHideForCleanExitHidesResolvedDeviceAndIsIdempotent() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[targetUID] = visibleDeviceID

        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)
        controller.resolveAndMakeVisible(testToken)

        controller.hideForCleanExit(testToken)
        XCTAssertEqual(mock.setHiddenCalls.count, 2)
        XCTAssertEqual(mock.setHiddenCalls.last?.hidden, true)
        XCTAssertEqual(mock.setHiddenCalls.last?.id, visibleDeviceID)
        XCTAssertNil(controller.resolvedDeviceID)

        controller.hideForCleanExit(testToken)
        XCTAssertEqual(mock.setHiddenCalls.count, 2, "解決前 (resolvedDeviceID=nil) の再呼び出しは no-op")
    }

    // AudioDeviceID が入れ替わった場合、終了時の非表示化は起動時の ID ではなく UID から解決し直した ID に対して行う。
    func testHideForCleanExitReresolvesUIDInsteadOfUsingLaunchTimeID() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[targetUID] = visibleDeviceID

        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)
        controller.resolveAndMakeVisible(testToken)

        let renumberedID: AudioDeviceID = 50
        mock.deviceIDsByUID[targetUID] = renumberedID

        controller.hideForCleanExit(testToken)

        XCTAssertEqual(mock.setHiddenCalls.last?.hidden, true)
        XCTAssertEqual(mock.setHiddenCalls.last?.id, renumberedID)
    }

    func testReapplyVisibilityUpdatesResolvedIDAndSetsVisible() {
        let mock = MockAudioDeviceDirectory()
        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)

        controller.reapplyVisibility(deviceID: hiddenDeviceID, testToken)

        XCTAssertEqual(mock.setHiddenCalls.map(\.hidden), [false])
        XCTAssertEqual(mock.setHiddenCalls.map(\.id), [hiddenDeviceID])
        XCTAssertEqual(controller.resolvedDeviceID, hiddenDeviceID)
    }

    func testHideForCleanExitDoesNothingWhenNeverResolved() {
        let mock = MockAudioDeviceDirectory()
        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)

        controller.hideForCleanExit(testToken)

        XCTAssertTrue(mock.setHiddenCalls.isEmpty)
    }

    func testIsVisibilityOwnedBySessionFollowsResolvedDeviceID() {
        let mock = MockAudioDeviceDirectory()
        mock.deviceIDsByUID[targetUID] = visibleDeviceID
        let controller = DriverLifecycleController(directory: mock, targetDeviceUID: targetUID)

        XCTAssertFalse(controller.isVisibilityOwnedBySession)

        controller.resolveAndMakeVisible(testToken)
        XCTAssertTrue(controller.isVisibilityOwnedBySession)

        controller.hideForCleanExit(testToken)
        XCTAssertFalse(controller.isVisibilityOwnedBySession)
    }
}
