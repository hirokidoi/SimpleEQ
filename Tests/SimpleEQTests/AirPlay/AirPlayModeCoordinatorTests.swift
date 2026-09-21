import CoreAudio
import XCTest
@testable import SimpleEQ

/// 調停役から見たエンジン。取り込み経路の組み立てと停止だけを模す。
/// この代役へ触れる経路は直列キューが順序を作るため、同時に触れることが無い。
final class FakeAirPlayEngine: AirPlayRoutingEngine, ActivatableAudioEngine, @unchecked Sendable {
    var processingState: ProcessingState = .active
    var airPlayRoute: String?
    var routeHealthy = true
    var assembleAirPlayShouldSucceed = true
    private(set) var events: [String] = []
    private(set) var suspendCalls: [SuspensionCause] = []
    private(set) var assembledCaptures: [AirPlayCaptureSource] = []

    func suspend(cause: SuspensionCause, _ token: AudioWorldToken) {
        events.append("suspend")
        suspendCalls.append(cause)
        airPlayRoute = nil
        processingState = .suspended(cause)
    }

    func airPlayRouteHealthy(_ token: AudioWorldToken) -> Bool { routeHealthy }

    @discardableResult
    func assemble(outputDevice: ResolvedOutputDevice, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        processingState = .active
        return true
    }

    @discardableResult
    func assembleAirPlay(capture: AirPlayCaptureSource, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        events.append("assembleAirPlay")
        assembledCaptures.append(capture)
        guard assembleAirPlayShouldSucceed else {
            processingState = .suspended(.routeUnavailable)
            return false
        }
        airPlayRoute = capture.endpointUID
        processingState = .active
        return true
    }
}

@MainActor
final class AirPlayModeCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    nonisolated private let tempURLs = Recorded<[URL]>([])

    private let driverUID = "driver-uid"
    private let driverID: AudioDeviceID = 40
    private let speakerUID = "speaker-uid"
    private let speakerID: AudioDeviceID = 10
    private let airPlayUID = "airplay-1"
    private let airPlayID: AudioDeviceID = 150
    private let otherAirPlayUID = "airplay-2"
    private let otherAirPlayID: AudioDeviceID = 156

    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("AirPlayModeCoordinatorTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        for url in tempURLs.value { try? FileManager.default.removeItem(at: url) }
        tempURLs.update { $0.removeAll() }
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private struct Fixture {
        let coordinator: AirPlayModeCoordinator
        let engine: FakeAirPlayEngine
        let directory: MockAudioDeviceDirectory
        let metrics: AudioRuntimeMetrics
        let clock: TestClock
        let requests: Recorded<[CaptureBuildRequest]>
        let reconciliations: Recorded<Int>
        let scheduledDelays: Recorded<[TimeInterval]>
        let phases: Recorded<[AirPlayModePhase]>

        var lastRequest: CaptureBuildRequest? { requests.value.last }
    }

    private func makeFixture(sharedMemoryOpens: Bool = true) -> Fixture {
        let directory = MockAudioDeviceDirectory()
        directory.hiddenDeviceIDsByUID[driverUID] = driverID
        directory.uidsByDeviceID[driverID] = driverUID
        for (uid, id) in [(speakerUID, speakerID), (airPlayUID, airPlayID), (otherAirPlayUID, otherAirPlayID)] {
            directory.deviceIDsByUID[uid] = id
            directory.uidsByDeviceID[id] = uid
        }
        directory.airPlayDeviceIDs = [airPlayID, otherAirPlayID]
        directory.currentDefaultOutputID = speakerID

        let engine = FakeAirPlayEngine()
        let settings = SettingsStore(defaults: defaults)
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: driverUID)
        let activation = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: { [tempURLs] in
                guard sharedMemoryOpens else { return .failure(.fileNotFound) }
                let url = makeOwnershipHeaderFixture(ownerProcessID: 0, leaseRemainingSeconds: 0)
                tempURLs.update { $0.append(url) }
                return SharedRingReader.open(path: url.path)
            }
        )
        let metrics = AudioRuntimeMetrics()
        let clock = TestClock(now: 1000)
        let coordinator = AirPlayModeCoordinator(
            engine: engine, activationCoordinator: activation, directory: directory,
            driverDeviceUID: driverUID, metrics: metrics, now: { clock.now }
        )
        let requests = Recorded<[CaptureBuildRequest]>([])
        let reconciliations = Recorded<Int>(0)
        let scheduledDelays = Recorded<[TimeInterval]>([])
        let phases = Recorded<[AirPlayModePhase]>([])
        coordinator.requestCapture = { request in requests.update { $0.append(request) } }
        coordinator.requestRouteReconciliation = { _ in reconciliations.update { $0 += 1 } }
        coordinator.scheduleRouteReconciliation = { after in scheduledDelays.update { $0.append(after) } }
        coordinator.phaseDidChange = { phase in phases.update { $0.append(phase) } }
        return Fixture(
            coordinator: coordinator, engine: engine, directory: directory, metrics: metrics, clock: clock,
            requests: requests, reconciliations: reconciliations, scheduledDelays: scheduledDelays, phases: phases
        )
    }

    @discardableResult
    private func reconcile(_ f: Fixture, adopts: Bool = true) -> AirPlayReconcileBranch {
        f.coordinator.reconcile(adopts: adopts, testToken)
    }

    /// デフォルト出力を AirPlay にして入り、構築の依頼が出た状態にする。
    private func enter(_ f: Fixture, uid: String? = nil) {
        let id = uid == otherAirPlayUID ? otherAirPlayID : airPlayID
        f.directory.currentDefaultOutputID = id
        f.directory.aliveDeviceIDs.insert(id)
        reconcile(f)
    }

    private func deliverBuilt(_ f: Fixture, authorization: CaptureAuthorization = .granted, generation: UInt64? = nil) -> FakeCaptureSource {
        let capture = FakeCaptureSource(endpointUID: f.lastRequest?.endpointUID ?? airPlayUID)
        f.coordinator.deliver(.built(capture, authorization), generation: generation ?? f.coordinator.generation, testToken)
        return capture
    }

    // MARK: - 入る

    func testEnteringRequestsACaptureForTheEndpointWithoutStoppingTheCurrentRoute() {
        let f = makeFixture()
        enter(f)

        XCTAssertEqual(f.requests.value.count, 1)
        XCTAssertEqual(f.lastRequest?.endpointUID, airPlayUID)
        XCTAssertEqual(f.lastRequest?.endpointDeviceID, airPlayID)
        XCTAssertEqual(f.lastRequest?.selfProcessObjectID, f.directory.selfProcessObject)
        XCTAssertEqual(f.lastRequest?.generation, f.coordinator.generation)
        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
        XCTAssertEqual(f.phases.value, [.awaitingCapture])
        XCTAssertTrue(f.engine.suspendCalls.isEmpty, "入る時点では通常の経路を止めない")
    }

    func testNothingIsRequestedWhileTheDefaultOutputIsAnOrdinaryDevice() {
        let f = makeFixture()
        XCTAssertEqual(reconcile(f), .notApplicable)
        XCTAssertTrue(f.requests.value.isEmpty)
    }

    // MARK: - 構築の結果

    func testABuiltCaptureStopsTheCurrentRouteBeforeAssemblingTheCapturePath() {
        let f = makeFixture()
        enter(f)

        let capture = deliverBuilt(f, authorization: .granted)

        XCTAssertEqual(f.engine.events, ["suspend", "assembleAirPlay"])
        XCTAssertTrue(f.engine.assembledCaptures.first === capture)
        XCTAssertEqual(f.coordinator.phase, .capturing)
        XCTAssertEqual(f.metrics.captureAuthorization, .granted)
        XCTAssertEqual(f.reconciliations.value, 1, "リスナー・可視性を追いつかせる")
    }

    func testADeniedCaptureIsAssembledAndMarkedDenied() {
        let f = makeFixture()
        enter(f)

        _ = deliverBuilt(f, authorization: .denied)

        XCTAssertEqual(f.engine.assembledCaptures.count, 1, "拒否でも経路は組む")
        XCTAssertEqual(f.coordinator.phase, .captureDenied)
        XCTAssertEqual(f.metrics.captureAuthorization, .denied)
    }

    func testAnUnreadableAuthorizationCapturesLikeAGrantedOne() {
        let f = makeFixture()
        enter(f)

        _ = deliverBuilt(f, authorization: .unreadable)

        XCTAssertEqual(f.coordinator.phase, .capturing)
        XCTAssertEqual(f.metrics.captureAuthorization, .unreadable)
    }

    func testAResultForAnOlderGenerationIsDestroyedAndNeverAssembled() {
        let f = makeFixture()
        enter(f)
        let staleGeneration = f.coordinator.generation
        enter(f, uid: otherAirPlayUID)

        let capture = deliverBuilt(f, generation: staleGeneration)

        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertTrue(f.engine.assembledCaptures.isEmpty)
        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
    }

    func testAResultArrivingAfterTheEntryConditionWasLostIsDestroyed() {
        let f = makeFixture()
        enter(f)
        f.engine.processingState = .suspended(.ownershipUnavailable)

        let capture = deliverBuilt(f)

        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertTrue(f.engine.assembledCaptures.isEmpty)
    }

    func testACaptureThatCannotBeActivatedIsDestroyedAndCountsAsAFailure() {
        let f = makeFixture(sharedMemoryOpens: false)
        enter(f)

        let capture = deliverBuilt(f)

        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertEqual(f.coordinator.phase, .captureFailed)
    }

    // 経路を組めない回は通常の経路も止め、元の音が AirPlay で鳴る状態に置く。
    func testAFailureStopsTheRouteAndRetriesOnlyAfterTheInterval() {
        let f = makeFixture()
        enter(f)

        f.coordinator.deliver(.failed, generation: f.coordinator.generation, testToken)

        XCTAssertEqual(f.coordinator.phase, .captureFailed)
        XCTAssertEqual(f.engine.suspendCalls, [.routeUnavailable])
        XCTAssertEqual(f.reconciliations.value, 1)

        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 1, "間隔が空くまで作り直さない")

        f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 2)
        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
    }

    func testRetriesStopAfterTheConsecutiveFailureLimit() {
        let f = makeFixture()
        enter(f)
        for _ in 0..<DeviceRoutingReconciler.automaticResumeMaxConsecutiveFailures {
            f.coordinator.deliver(.failed, generation: f.coordinator.generation, testToken)
            f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
            reconcile(f)
        }
        let requestsAtLimit = f.requests.value.count

        f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
        reconcile(f)

        XCTAssertEqual(f.requests.value.count, requestsAtLimit)
        XCTAssertEqual(f.coordinator.phase, .captureFailed)
    }

    // MARK: - 端末の切り替え・抜ける

    func testADifferentEndpointIsRebuiltAtOnceAndTheCapturePathIsStopped() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        let generation = f.coordinator.generation

        enter(f, uid: otherAirPlayUID)

        XCTAssertEqual(f.lastRequest?.endpointUID, otherAirPlayUID)
        XCTAssertGreaterThan(f.coordinator.generation, generation)
        XCTAssertEqual(f.engine.suspendCalls.last, .routeUnavailable, "取り込み経路で稼働中なら止めてから作り直す")
        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
    }

    // ID はプロセスごとに違って見え、再利用もされるので、比べるのは UID だけ。
    func testTheEndpointIsComparedByUIDAndNeverByDeviceID() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        let renumberedID: AudioDeviceID = 151
        f.directory.uidsByDeviceID[renumberedID] = airPlayUID
        f.directory.airPlayDeviceIDs.insert(renumberedID)

        f.directory.currentDefaultOutputID = renumberedID
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 1, "UID が同じなら ID が違っても作り直さない")

        f.directory.uidsByDeviceID[airPlayID] = otherAirPlayUID
        f.directory.currentDefaultOutputID = airPlayID
        reconcile(f)
        XCTAssertEqual(f.lastRequest?.endpointUID, otherAirPlayUID, "ID が同じでも UID が違えば作り直す")
    }

    func testAnUnhealthyRouteIsRebuiltForTheSameEndpoint() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        f.engine.routeHealthy = false

        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 2, "構築の直後でも、不健全による最初の作り直しは待たない")
        XCTAssertEqual(f.lastRequest?.endpointUID, airPlayUID)

        _ = deliverBuilt(f)
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 2, "不健全による作り直しが続くときは間隔を置く")
        XCTAssertTrue(f.coordinator.matchesIntent(adopts: true, testToken))

        f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
        XCTAssertFalse(f.coordinator.matchesIntent(adopts: true, testToken), "間隔が空いたら定期の検算が是正へ上げる")
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 3)
    }

    func testTheUnhealthyRebuildIntervalStartsOverOnAnotherEndpoint() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        f.engine.routeHealthy = false
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 2, "前提: 不健全による作り直し")
        _ = deliverBuilt(f)

        f.directory.currentDefaultOutputID = otherAirPlayID
        f.directory.aliveDeviceIDs.insert(otherAirPlayID)
        reconcile(f)
        XCTAssertEqual(f.lastRequest?.endpointUID, otherAirPlayUID, "前提: 別の端末へ作り直す")
        _ = deliverBuilt(f)
        reconcile(f)

        XCTAssertEqual(f.requests.value.count, 4, "別の端末の最初の不健全は待たない")
    }

    func testTheUnhealthyRebuildIntervalStartsOverAfterLeaving() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        f.engine.routeHealthy = false
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 2, "前提: 不健全による作り直し")
        _ = deliverBuilt(f)

        f.directory.currentDefaultOutputID = speakerID
        f.coordinator.noteConfigurationNotification(testToken)
        XCTAssertEqual(reconcile(f), .departed(resumeCandidateUID: speakerUID), "前提: 抜ける")
        enter(f)
        _ = deliverBuilt(f)
        reconcile(f)

        XCTAssertEqual(f.requests.value.count, 4, "入り直した後の最初の不健全は待たない")
    }

    func testAnUnhealthyRouteRightAfterARetriedBuildIsRebuiltWithoutWaiting() {
        let f = makeFixture()
        enter(f)
        f.coordinator.deliver(.failed, generation: f.coordinator.generation, testToken)
        f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
        reconcile(f)
        XCTAssertEqual(f.requests.value.count, 2, "前提: 失敗の再試行で作り直す")
        _ = deliverBuilt(f)
        f.engine.routeHealthy = false

        reconcile(f)

        XCTAssertEqual(f.requests.value.count, 3, "間隔を数えるのは不健全による作り直しだけ")
    }

    func testReturningToTheSameEndpointBeforeReconcilingForgetsTheDepartureObservedWhileAlive() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        f.directory.currentDefaultOutputID = speakerID
        f.coordinator.noteConfigurationNotification(testToken)
        f.directory.currentDefaultOutputID = airPlayID
        reconcile(f)

        f.directory.aliveDeviceIDs.remove(airPlayID)
        f.directory.currentDefaultOutputID = speakerID
        let branch = reconcile(f)

        XCTAssertEqual(branch, .engaged(endpointDeviceID: airPlayID), "切り替えの経由かもしれないので猶予を置く")
        XCTAssertEqual(f.scheduledDelays.value.count, 1)
        XCTAssertEqual(f.scheduledDelays.value.first ?? 0, AirPlayModePolicy.settleSeconds, accuracy: 1e-9)
    }

    func testWhileInactiveTheDefaultOutputIsNotResolvedAsAnOutputChoice() {
        let f = makeFixture()

        reconcile(f)
        _ = f.coordinator.matchesIntent(adopts: true, testToken)

        XCTAssertTrue(f.directory.selectableOutputDeviceCalls.isEmpty)
    }

    func testLeavingWhileTheEndpointIsAliveDepartsInTheSamePassWithTheCandidate() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)

        f.directory.currentDefaultOutputID = speakerID
        f.coordinator.noteConfigurationNotification(testToken)
        let branch = reconcile(f)

        XCTAssertEqual(branch, .departed(resumeCandidateUID: speakerUID))
        XCTAssertEqual(f.coordinator.phase, .inactive)
        XCTAssertEqual(f.engine.suspendCalls.last, .routeUnavailable)
        XCTAssertTrue(f.scheduledDelays.value.isEmpty, "猶予を置かない")
    }

    // 読み遅れて消滅後に通知を処理した回は、猶予側に倒れる。
    func testLeavingAfterTheEndpointVanishedSettlesAndDepartsAtTheDeadline() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        let generation = f.coordinator.generation

        f.directory.aliveDeviceIDs.remove(airPlayID)
        f.directory.currentDefaultOutputID = speakerID
        f.coordinator.noteConfigurationNotification(testToken)
        XCTAssertEqual(reconcile(f), .engaged(endpointDeviceID: airPlayID))

        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
        XCTAssertEqual(f.engine.suspendCalls.last, .routeUnavailable, "猶予の間は取り込み経路を止める")
        XCTAssertGreaterThan(f.coordinator.generation, generation)
        XCTAssertEqual(f.scheduledDelays.value.count, 1)
        XCTAssertEqual(f.scheduledDelays.value.first ?? 0, AirPlayModePolicy.settleSeconds, accuracy: 1e-9, "期限に是正を予約する")

        XCTAssertEqual(reconcile(f), .engaged(endpointDeviceID: airPlayID), "期限前は待つ")
        XCTAssertEqual(f.scheduledDelays.value.count, 1, "待つ回は予約し直さない")

        f.clock.advance(by: AirPlayModePolicy.settleSeconds)
        XCTAssertEqual(reconcile(f), .departed(resumeCandidateUID: speakerUID), "期限ちょうどで抜ける")
    }

    func testReturningToTheSameEndpointDuringTheSettleRequestsAFreshCapture() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)
        f.directory.currentDefaultOutputID = speakerID
        reconcile(f)
        let settleGeneration = f.coordinator.generation

        f.directory.currentDefaultOutputID = airPlayID
        reconcile(f)

        XCTAssertEqual(f.requests.value.count, 2)
        XCTAssertGreaterThan(f.coordinator.generation, settleGeneration)
        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
    }

    func testTurningAdoptionOffDepartsWithoutACandidate() {
        let f = makeFixture()
        enter(f)
        _ = deliverBuilt(f)

        XCTAssertEqual(reconcile(f, adopts: false), .departed(resumeCandidateUID: nil))
        XCTAssertEqual(f.coordinator.phase, .inactive)
    }

    func testAbandoningAdvancesTheGenerationSoALateResultIsDiscarded() {
        let f = makeFixture()
        enter(f)
        let generation = f.coordinator.generation

        f.coordinator.abandon(testToken)
        let capture = deliverBuilt(f, generation: generation)

        XCTAssertGreaterThan(f.coordinator.generation, generation)
        XCTAssertEqual(f.coordinator.phase, .inactive)
        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertTrue(f.engine.assembledCaptures.isEmpty)
    }

    func testMatchingIntentOnlyReads() {
        let f = makeFixture()
        f.directory.currentDefaultOutputID = airPlayID

        XCTAssertFalse(f.coordinator.matchesIntent(adopts: true, testToken), "入るべき状態は一致しない")
        XCTAssertTrue(f.requests.value.isEmpty)
        XCTAssertEqual(f.coordinator.phase, .inactive)
        XCTAssertTrue(f.engine.suspendCalls.isEmpty)

        XCTAssertTrue(f.coordinator.matchesIntent(adopts: false, testToken))
    }

    // MARK: - 許可の結果待ち

    private func awaitAuthorization(_ f: Fixture) {
        f.coordinator.deliver(.awaitingAuthorization, generation: f.coordinator.generation, testToken)
    }

    func testWaitingForTheAuthorizationKeepsEverythingAsItIs() {
        let f = makeFixture()
        enter(f)

        awaitAuthorization(f)

        XCTAssertEqual(f.coordinator.phase, .awaitingCapture)
        XCTAssertTrue(f.engine.suspendCalls.isEmpty, "エンジンは止めない")
        XCTAssertEqual(f.reconciliations.value, 0)
        XCTAssertTrue(f.coordinator.matchesIntent(adopts: true, testToken))
    }

    func testTheArrivalOfTheResultRequestsTheSameEndpointAgainOnce() {
        let f = makeFixture()
        enter(f)
        awaitAuthorization(f)
        let generation = f.coordinator.generation

        f.coordinator.authorizationRequestDidComplete(testToken)
        f.coordinator.authorizationRequestDidComplete(testToken)

        XCTAssertEqual(f.requests.value.count, 2)
        XCTAssertEqual(f.lastRequest?.endpointUID, airPlayUID)
        XCTAssertEqual(f.lastRequest?.generation, generation + 1)
        XCTAssertTrue(f.engine.suspendCalls.isEmpty)
    }

    // ダイアログで拒否した直後から警告の入力が立つ。
    func testARebuildAfterTheResultThatComesBackDeniedIsMarkedDenied() {
        let f = makeFixture()
        enter(f)
        awaitAuthorization(f)
        f.coordinator.authorizationRequestDidComplete(testToken)

        _ = deliverBuilt(f, authorization: .denied)

        XCTAssertEqual(f.coordinator.phase, .captureDenied)
    }

    func testTheResultIsIgnoredOnceTheGenerationHasMovedOn() {
        let cases: [(String, (AirPlayModeCoordinatorTests, Fixture) -> Void)] = [
            ("作り直し", { tests, f in tests.enter(f, uid: tests.otherAirPlayUID) }),
            ("猶予", { tests, f in
                f.directory.aliveDeviceIDs.removeAll()
                f.directory.currentDefaultOutputID = tests.speakerID
                tests.reconcile(f)
            }),
            ("抜ける", { tests, f in tests.reconcile(f, adopts: false) }),
            ("明け渡し", { _, f in f.coordinator.abandon(testToken) }),
        ]
        for (label, move) in cases {
            let f = makeFixture()
            enter(f)
            awaitAuthorization(f)
            move(self, f)
            let requestsBefore = f.requests.value.count

            f.coordinator.authorizationRequestDidComplete(testToken)

            XCTAssertEqual(f.requests.value.count, requestsBefore, label)
        }
    }

    func testTheResultIsIgnoredOnceTheEntryConditionIsLost() {
        let f = makeFixture()
        enter(f)
        awaitAuthorization(f)
        f.engine.processingState = .suspended(.driverOperation)

        f.coordinator.authorizationRequestDidComplete(testToken)

        XCTAssertEqual(f.requests.value.count, 1)
    }

    func testAWaitReportedForAnOlderGenerationIsNotRemembered() {
        let f = makeFixture()
        enter(f)
        let staleGeneration = f.coordinator.generation
        enter(f, uid: otherAirPlayUID)

        f.coordinator.deliver(.awaitingAuthorization, generation: staleGeneration, testToken)
        f.coordinator.authorizationRequestDidComplete(testToken)

        XCTAssertEqual(f.requests.value.count, 2)
    }

    // 回数の上限をまたぐ並びで見る。結果待ちを失敗に数えると、ここで作り直しが止まる。
    func testWaitingForTheAuthorizationIsNotCountedAsAFailure() {
        let f = makeFixture()
        enter(f)
        for _ in 0..<(DeviceRoutingReconciler.automaticResumeMaxConsecutiveFailures - 2) {
            f.coordinator.deliver(.failed, generation: f.coordinator.generation, testToken)
            f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
            reconcile(f)
        }
        awaitAuthorization(f)
        f.coordinator.authorizationRequestDidComplete(testToken)
        f.coordinator.deliver(.failed, generation: f.coordinator.generation, testToken)
        f.clock.advance(by: DeviceRoutingReconciler.automaticResumeRetryInterval)
        let requestsBefore = f.requests.value.count

        reconcile(f)

        XCTAssertEqual(f.requests.value.count, requestsBefore + 1)
    }
}
