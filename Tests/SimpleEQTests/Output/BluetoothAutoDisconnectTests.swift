import XCTest
import CoreAudio
import CoreBluetooth
@testable import SimpleEQ

/// 切断の要求と完了通知を記録する。テストから IOBluetooth / CoreBluetooth は呼ばない。
/// 許可は OS 側の値とキャッシュを分けて持ち、読み直しでだけキャッシュへ反映する。
final class FakeBluetoothConnectionControl: BluetoothConnectionControl, @unchecked Sendable {
    private let lock = NSLock()
    private var prepareCalls = 0
    private var requested: [String] = []
    private var completions: [@Sendable (Bool) -> Void] = []
    private var systemDenied = false
    private var cachedDenied = false
    private var refreshCalls = 0
    private var changeHandler: (@Sendable () -> Void)?

    var prepareCount: Int { lock.withLock { prepareCalls } }
    var refreshCount: Int { lock.withLock { refreshCalls } }
    var disconnectUIDs: [String] { lock.withLock { requested } }
    var isAuthorizationDenied: Bool { lock.withLock { cachedDenied } }

    func prepareAuthorization() { lock.withLock { prepareCalls += 1 } }

    func observeAuthorizationChanges(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { changeHandler = handler }
    }

    func refreshAuthorization() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            refreshCalls += 1
            guard cachedDenied != systemDenied else { return nil }
            cachedDenied = systemDenied
            return changeHandler
        }
        handler?()
    }

    /// OS 側の値だけを変える。反映は読み直しの時点。
    func setAuthorizationDenied(_ denied: Bool) { lock.withLock { systemDenied = denied } }

    /// OS 側の値を変えて即座に読み直す。
    func applyAuthorizationDenied(_ denied: Bool) {
        setAuthorizationDenied(denied)
        refreshAuthorization()
    }

    func disconnect(outputDeviceUID: String, completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            requested.append(outputDeviceUID)
            completions.append(completion)
        }
    }

    func completeAll(success: Bool) {
        let pending = lock.withLock { () -> [@Sendable (Bool) -> Void] in
            defer { completions.removeAll() }
            return completions
        }
        pending.forEach { $0(success) }
    }
}

final class FakeBluetoothAutoDisconnectEngine: BluetoothAutoDisconnectEngine, @unchecked Sendable {
    var observation: OutputSilenceObservation?
    var intendedOutputDeviceUID: String?

    func outputSilenceObservation(_ token: AudioWorldToken) -> OutputSilenceObservation? { observation }
}

final class BluetoothAutoDisconnectTests: XCTestCase {
    // MARK: - Tracker (limit と各値はテスト内の任意値)

    private let limit: TimeInterval = 60
    private let target = "bt-uid"

    private func observation(sound: TimeInterval?) -> OutputSilenceObservation {
        OutputSilenceObservation(lastSoundAt: sound)
    }

    private func evaluate(
        _ tracker: inout BluetoothAutoDisconnectTracker, at now: TimeInterval, _ observation: OutputSilenceObservation?,
        target: String? = "bt-uid", limit: TimeInterval? = nil
    ) -> BluetoothAutoDisconnectTracker.Verdict {
        tracker.evaluate(observation: observation, targetUID: target, limitSeconds: limit ?? self.limit, now: now)
    }

    func testTrackerCountsFromArmingWhileNoSoundIsHeard() {
        var tracker = BluetoothAutoDisconnectTracker()
        XCTAssertEqual(evaluate(&tracker, at: 100, observation(sound: nil)), .countingDown(remainingSeconds: limit))
        XCTAssertEqual(evaluate(&tracker, at: 115, observation(sound: nil)), .countingDown(remainingSeconds: limit - 15))
    }

    func testTrackerDoesNotCountASoundBeforeArming() {
        var tracker = BluetoothAutoDisconnectTracker()
        XCTAssertEqual(evaluate(&tracker, at: 100, observation(sound: 99)), .countingDown(remainingSeconds: limit), "再生中とも読まない")
    }

    func testTrackerReadsASoundSinceTheLastEvaluationAsPlayingAndCountsFromIt() {
        var tracker = BluetoothAutoDisconnectTracker()
        _ = evaluate(&tracker, at: 100, observation(sound: nil))
        XCTAssertEqual(evaluate(&tracker, at: 115, observation(sound: 110)), .playing)
        XCTAssertEqual(evaluate(&tracker, at: 130, observation(sound: 110)), .countingDown(remainingSeconds: limit - 20))
    }

    // 短い通知音: 評価と評価の間で鳴り終わる。
    func testTrackerCatchesASoundThatStartsAndEndsBetweenEvaluations() {
        var tracker = BluetoothAutoDisconnectTracker()
        _ = evaluate(&tracker, at: 100, observation(sound: nil))
        XCTAssertEqual(evaluate(&tracker, at: 145, observation(sound: nil)), .countingDown(remainingSeconds: limit - 45))
        XCTAssertEqual(evaluate(&tracker, at: 160, observation(sound: 150)), .playing, "満了の時刻でも切断しない")
        XCTAssertEqual(evaluate(&tracker, at: 175, observation(sound: 150)), .countingDown(remainingSeconds: limit - 25))
    }

    func testTrackerDisconnectsOnceAtExpiryThenAwaitsRearm() {
        var tracker = BluetoothAutoDisconnectTracker()
        _ = evaluate(&tracker, at: 100, observation(sound: nil))
        XCTAssertEqual(evaluate(&tracker, at: 160, observation(sound: nil)), .disconnect)
        XCTAssertEqual(evaluate(&tracker, at: 175, observation(sound: nil)), .awaitingRearm)
        XCTAssertEqual(evaluate(&tracker, at: 190, observation(sound: nil)), .awaitingRearm)
    }

    func testTrackerRearmsAfterASoundAndDisconnectsAgainAtTheNextExpiry() {
        var tracker = BluetoothAutoDisconnectTracker()
        _ = evaluate(&tracker, at: 100, observation(sound: nil))
        XCTAssertEqual(evaluate(&tracker, at: 160, observation(sound: nil)), .disconnect)
        XCTAssertEqual(evaluate(&tracker, at: 175, observation(sound: 170)), .playing)
        XCTAssertEqual(evaluate(&tracker, at: 190, observation(sound: 170)), .countingDown(remainingSeconds: limit - 20))
        XCTAssertEqual(evaluate(&tracker, at: 230, observation(sound: 170)), .disconnect)
    }

    func testTrackerRearmsAtTheEvaluationWhenTheTargetChanges() {
        var tracker = BluetoothAutoDisconnectTracker()
        _ = evaluate(&tracker, at: 100, observation(sound: nil), target: "a")
        XCTAssertEqual(evaluate(&tracker, at: 115, observation(sound: nil), target: "b"), .countingDown(remainingSeconds: limit))
    }

    func testTrackerIsInactiveWithoutAnObservationAndRearmsWhenItResumes() {
        var tracker = BluetoothAutoDisconnectTracker()
        _ = evaluate(&tracker, at: 100, observation(sound: nil))
        XCTAssertEqual(evaluate(&tracker, at: 115, nil), .inactive)
        XCTAssertEqual(evaluate(&tracker, at: 130, observation(sound: nil)), .countingDown(remainingSeconds: limit))
    }

    func testTrackerIsInactiveWithoutATargetWhileKeepingTheObservation() {
        var tracker = BluetoothAutoDisconnectTracker()
        XCTAssertEqual(evaluate(&tracker, at: 100, observation(sound: nil), target: nil), .inactive)
    }

    func testTrackerDoesNotDisconnectAgainWhenTheSameTargetReturnsWhileSilenceContinues() {
        func disconnected() -> BluetoothAutoDisconnectTracker {
            var tracker = BluetoothAutoDisconnectTracker()
            _ = evaluate(&tracker, at: 100, observation(sound: nil))
            XCTAssertEqual(evaluate(&tracker, at: 160, observation(sound: nil)), .disconnect)
            return tracker
        }
        var moved = disconnected()
        XCTAssertEqual(evaluate(&moved, at: 175, observation(sound: nil), target: "other"), .countingDown(remainingSeconds: limit))
        XCTAssertEqual(evaluate(&moved, at: 190, observation(sound: nil)), .awaitingRearm, "同じ UID が戻っても再切断しない")

        var vanished = disconnected()
        XCTAssertEqual(evaluate(&vanished, at: 175, observation(sound: nil), target: nil), .inactive)
        XCTAssertEqual(evaluate(&vanished, at: 190, observation(sound: nil)), .awaitingRearm)

        var stopped = disconnected()
        XCTAssertEqual(evaluate(&stopped, at: 175, nil), .inactive)
        XCTAssertEqual(evaluate(&stopped, at: 190, observation(sound: nil)), .awaitingRearm, "観測が途切れても同じ")
    }

    func testTrackerCountsAgainOnceASoundCameWhileTheTargetWasAway() {
        func disconnected() -> BluetoothAutoDisconnectTracker {
            var tracker = BluetoothAutoDisconnectTracker()
            _ = evaluate(&tracker, at: 100, observation(sound: nil))
            XCTAssertEqual(evaluate(&tracker, at: 160, observation(sound: nil)), .disconnect)
            return tracker
        }
        var away = disconnected()
        XCTAssertEqual(evaluate(&away, at: 175, observation(sound: 170), target: nil), .inactive, "対象が無い間の音も区間の終わり")
        XCTAssertEqual(evaluate(&away, at: 190, observation(sound: 170)), .countingDown(remainingSeconds: limit))

        var unobserved = disconnected()
        XCTAssertEqual(evaluate(&unobserved, at: 175, nil), .inactive)
        XCTAssertEqual(evaluate(&unobserved, at: 190, observation(sound: 180)), .countingDown(remainingSeconds: limit), "観測が途切れた間の音も同じ")
    }

    func testTrackerAppliesAShorterLimitToTheKeptOrigin() {
        var tracker = BluetoothAutoDisconnectTracker()
        XCTAssertEqual(evaluate(&tracker, at: 100, observation(sound: nil), limit: 600), .countingDown(remainingSeconds: 600))
        XCTAssertEqual(evaluate(&tracker, at: 165, observation(sound: nil), limit: 60), .disconnect)
    }

    // MARK: - 設定の導出・表示値

    func testSettingsAreEnabledOnlyWithMinutes() {
        XCTAssertTrue(BluetoothAutoDisconnectSettings(silenceMinutes: 1).isEnabled)
        XCTAssertFalse(BluetoothAutoDisconnectSettings(silenceMinutes: nil).isEnabled)
        XCTAssertFalse(BluetoothAutoDisconnectSettings.disabled.isEnabled)
    }

    func testSettingsConvertMinutesToSeconds() {
        let settings = BluetoothAutoDisconnectSettings(silenceMinutes: 3)
        XCTAssertEqual(settings.silenceLimitSeconds, 180)
    }

    func testMinutesRemainingRoundsUpWithAFloorOfOne() {
        XCTAssertEqual(BluetoothAutoDisconnectStatus.minutesRemaining(seconds: 0), 1)
        XCTAssertEqual(BluetoothAutoDisconnectStatus.minutesRemaining(seconds: 1), 1)
        XCTAssertEqual(BluetoothAutoDisconnectStatus.minutesRemaining(seconds: 60), 1)
        XCTAssertEqual(BluetoothAutoDisconnectStatus.minutesRemaining(seconds: 61), 2)
        XCTAssertEqual(BluetoothAutoDisconnectStatus.minutesRemaining(seconds: 120), 2)
    }

    // MARK: - アドレス照合・transport (擬似アドレス)

    func testPairedAddressMatchesRegardlessOfCaseAndSeparator() {
        let addresses = ["11:22:33:44:55:66", "aa-bb-cc-dd-ee-ff"]
        XCTAssertEqual(
            BluetoothAddress.pairedAddress(matchingDeviceUID: "AA:BB:CC:DD:EE:FF:output", among: addresses), "aa-bb-cc-dd-ee-ff"
        )
        XCTAssertEqual(
            BluetoothAddress.pairedAddress(matchingDeviceUID: "11-22-33-44-55-66", among: addresses), "11:22:33:44:55:66"
        )
    }

    func testPairedAddressDoesNotMatchAnotherDeviceOrAnEmptyList() {
        XCTAssertNil(BluetoothAddress.pairedAddress(matchingDeviceUID: "00:00:00:00:00:01:output", among: ["11:22:33:44:55:66"]))
        XCTAssertNil(BluetoothAddress.pairedAddress(matchingDeviceUID: "11:22:33:44:55:66:output", among: []))
        XCTAssertNil(BluetoothAddress.pairedAddress(matchingDeviceUID: "11:22:33:44:55:66:output", among: [""]), "空のアドレスはどの UID にも含まれてしまう")
    }

    func testOnlyBluetoothTransportsAreBluetoothOutputs() {
        XCTAssertTrue(isBluetoothOutputTransport(kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(isBluetoothOutputTransport(kAudioDeviceTransportTypeBluetoothLE))
        XCTAssertFalse(isBluetoothOutputTransport(kAudioDeviceTransportTypeUSB))
        XCTAssertFalse(isBluetoothOutputTransport(kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(isBluetoothOutputTransport(nil))
    }

    // MARK: - 調停役 (fake 境界越しの配線)

    private final class Fixture {
        let uid = "bt-uid"
        let deviceID: AudioDeviceID = 42
        let deviceName = "Headphones"
        let engine = FakeBluetoothAutoDisconnectEngine()
        let directory = MockAudioDeviceDirectory()
        let airPlay = FakeAirPlayMode()
        let control = FakeBluetoothConnectionControl()
        let world = makeTestAudioWorld()
        let clock = TestClock(now: 1000)
        let statuses = Recorded<[BluetoothAutoDisconnectStatus]>([])
        let coordinator: BluetoothAutoDisconnectCoordinator

        static let enabled = BluetoothAutoDisconnectSettings(silenceMinutes: 1)

        init(authorizationDenied: Bool = false) {
            control.setAuthorizationDenied(authorizationDenied)
            directory.deviceIDsByUID[uid] = deviceID
            directory.transportTypes[deviceID] = kAudioDeviceTransportTypeBluetooth
            directory.namesByDeviceID[deviceID] = deviceName
            engine.intendedOutputDeviceUID = uid
            engine.observation = OutputSilenceObservation(lastSoundAt: nil)
            let clock = clock
            coordinator = BluetoothAutoDisconnectCoordinator(
                engine: engine, directory: directory, airPlayMode: airPlay, connectionControl: control,
                audioWorld: world, now: { clock.now }
            )
            let statuses = statuses
            coordinator.statusDidChange = { status in statuses.update { $0.append(status) } }
        }

        func settle() { drainAudioWorld(world, settlingMainQueueFor: 0) }
    }

    func testCoordinatorPreparesAuthorizationOnlyWhenTheFeatureBecomesEnabled() {
        let f = Fixture()
        f.coordinator.configure(.disabled, testToken)
        XCTAssertEqual(f.control.prepareCount, 0)
        f.coordinator.configure(Fixture.enabled, testToken)
        XCTAssertEqual(f.control.prepareCount, 1)
        f.coordinator.configure(Fixture.enabled, testToken)
        XCTAssertEqual(f.control.prepareCount, 1, "同じ設定の再適用では求めない")
        f.coordinator.configure(.disabled, testToken)
        f.coordinator.configure(Fixture.enabled, testToken)
        XCTAssertEqual(f.control.prepareCount, 2)
    }

    func testCoordinatorStaysSilentForANonBluetoothOutput() {
        let f = Fixture()
        f.directory.transportTypes[f.deviceID] = kAudioDeviceTransportTypeUSB
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: 600)
        f.coordinator.evaluate(testToken)
        XCTAssertTrue(f.control.disconnectUIDs.isEmpty)
        XCTAssertTrue(f.statuses.value.isEmpty)
    }

    func testCoordinatorStaysSilentInAirPlayModeAndWithoutAnObservation() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        XCTAssertEqual(f.statuses.value, [
            .countingDown(
                deviceName: f.deviceName,
                minutesRemaining: BluetoothAutoDisconnectStatus.minutesRemaining(seconds: Fixture.enabled.silenceLimitSeconds)
            )
        ])

        f.airPlay.branch = .engaged(endpointDeviceID: nil)
        f.clock.advance(by: 600)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.statuses.value.last, BluetoothAutoDisconnectStatus.none)

        f.airPlay.branch = .notApplicable
        f.engine.observation = nil
        f.coordinator.evaluate(testToken)
        XCTAssertTrue(f.control.disconnectUIDs.isEmpty)
    }

    func testCoordinatorDisconnectsOnceAtExpiryAndDoesNotRetryAfterAFailure() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: Fixture.enabled.silenceLimitSeconds)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.control.disconnectUIDs, [f.uid])
        XCTAssertEqual(f.statuses.value.last, BluetoothAutoDisconnectStatus.none)

        f.control.completeAll(success: false)
        f.settle()
        f.clock.advance(by: 15)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.control.disconnectUIDs, [f.uid], "失敗しても再発行しない")
    }

    func testCoordinatorDoesNotDisconnectAgainWhenTheSameDeviceReturnsAndDoesAfterReenabling() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: Fixture.enabled.silenceLimitSeconds)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.control.disconnectUIDs.count, 1)

        f.directory.transportTypes[f.deviceID] = kAudioDeviceTransportTypeUSB
        f.clock.advance(by: 15)
        f.coordinator.evaluate(testToken)
        f.directory.transportTypes[f.deviceID] = kAudioDeviceTransportTypeBluetooth
        f.clock.advance(by: Fixture.enabled.silenceLimitSeconds)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.control.disconnectUIDs.count, 1)

        f.coordinator.configure(.disabled, testToken)
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: Fixture.enabled.silenceLimitSeconds)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.control.disconnectUIDs.count, 2)
    }

    func testCoordinatorNotifiesTheStatusOnlyWhenItChanges() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: 5)
        f.coordinator.evaluate(testToken)
        f.clock.advance(by: 5)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.statuses.value.count, 1)

        f.coordinator.configure(.disabled, testToken)
        XCTAssertEqual(f.statuses.value.last, BluetoothAutoDisconnectStatus.none)
        XCTAssertEqual(f.statuses.value.count, 2)
    }

    func testCoordinatorReportsPlayingWhileASoundIsHeard() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: 15)
        f.engine.observation = OutputSilenceObservation(lastSoundAt: f.clock.now - 1)
        f.coordinator.evaluate(testToken)
        XCTAssertEqual(f.statuses.value.last, .playing(deviceName: f.deviceName))
    }

    // MARK: - 許可が無いとき

    func testAuthorizationCacheTreatsDeniedAndRestrictedAsDeniedAndReportsOnlyChanges() {
        var cache = BluetoothAuthorizationCache()
        XCTAssertFalse(cache.isDenied)
        XCTAssertFalse(cache.update(.notDetermined))
        XCTAssertFalse(cache.update(.allowedAlways))
        XCTAssertTrue(cache.update(.denied))
        XCTAssertTrue(cache.isDenied)
        XCTAssertFalse(cache.update(.restricted), "拒否のままなら変化なし")
        XCTAssertTrue(cache.isDenied)
        XCTAssertTrue(cache.update(.allowedAlways))
        XCTAssertFalse(cache.isDenied)
        XCTAssertTrue(cache.update(.restricted))
        XCTAssertTrue(cache.update(.notDetermined))
    }

    func testCoordinatorReportsUnauthorizedAndNeverDisconnectsWhileDeniedEvenIfEnabled() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        f.control.applyAuthorizationDenied(true)
        f.settle()
        XCTAssertEqual(f.statuses.value.last, BluetoothAutoDisconnectStatus.unauthorized)

        let refreshes = f.control.refreshCount
        f.clock.advance(by: Fixture.enabled.silenceLimitSeconds * 2)
        f.coordinator.evaluate(testToken)
        XCTAssertGreaterThan(f.control.refreshCount, refreshes, "評価のたびに読み直す")
        XCTAssertTrue(f.control.disconnectUIDs.isEmpty)
        XCTAssertEqual(f.statuses.value.last, BluetoothAutoDisconnectStatus.unauthorized)
    }

    func testCoordinatorReportsUnauthorizedEvenWhenDisabled() {
        let f = Fixture()
        f.coordinator.configure(.disabled, testToken)
        XCTAssertTrue(f.statuses.value.isEmpty)
        f.control.applyAuthorizationDenied(true)
        f.settle()
        XCTAssertEqual(f.statuses.value, [.unauthorized])
        f.coordinator.configure(.disabled, testToken)
        XCTAssertEqual(f.statuses.value, [.unauthorized])
    }

    func testCoordinatorReturnsToACleanCountdownWhenAuthorizationComesBack() {
        let f = Fixture()
        f.coordinator.configure(Fixture.enabled, testToken)
        f.clock.advance(by: Fixture.enabled.silenceLimitSeconds - 5)
        f.control.applyAuthorizationDenied(true)
        f.settle()
        XCTAssertEqual(f.statuses.value.last, BluetoothAutoDisconnectStatus.unauthorized)

        f.clock.advance(by: 600)
        f.control.applyAuthorizationDenied(false)
        f.settle()
        XCTAssertEqual(
            f.statuses.value.last,
            .countingDown(
                deviceName: f.deviceName,
                minutesRemaining: BluetoothAutoDisconnectStatus.minutesRemaining(seconds: Fixture.enabled.silenceLimitSeconds)
            ),
            "拒否の間の経過は数えず、新しい無音区間として始める"
        )
        XCTAssertTrue(f.control.disconnectUIDs.isEmpty)
    }

    // 起動配線の順序: 調停役の生成 → 世界の drain → statusDidChange の代入 → configure。
    func testCoordinatorDeliversUnauthorizedToAStatusHandlerAssignedAfterConstruction() {
        let control = FakeBluetoothConnectionControl()
        control.setAuthorizationDenied(true)
        let world = makeTestAudioWorld()
        let engine = FakeBluetoothAutoDisconnectEngine()
        let coordinator = BluetoothAutoDisconnectCoordinator(
            engine: engine, directory: MockAudioDeviceDirectory(), airPlayMode: FakeAirPlayMode(),
            connectionControl: control, audioWorld: world
        )
        drainAudioWorld(world, settlingMainQueueFor: 0)
        let statuses = Recorded<[BluetoothAutoDisconnectStatus]>([])
        coordinator.statusDidChange = { status in statuses.update { $0.append(status) } }
        XCTAssertEqual(control.refreshCount, 0, "生成では読まない")

        world.submitUncoalesced { coordinator.configure(Fixture.enabled, $0) }
        drainAudioWorld(world, settlingMainQueueFor: 0)
        XCTAssertEqual(statuses.value, [.unauthorized])
    }
}
