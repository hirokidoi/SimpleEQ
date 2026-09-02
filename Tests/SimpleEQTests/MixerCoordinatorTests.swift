import XCTest
@testable import SimpleEQ

/// オーディオ世界への依頼だけを差し替え、調停役のパスを実物のまま回す。
private final class FakeMixerBridge: MixerAudioBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRoster: [MixerRosterEntry] = []
    private var storedTables: [[String: Double]] = []
    private var storedObservations: [MixerCoordinationObservation] = []

    var roster: [MixerRosterEntry] {
        get { lock.withLock { storedRoster } }
        set { lock.withLock { storedRoster = newValue } }
    }
    var pushedTables: [[String: Double]] { lock.withLock { storedTables } }
    var observations: [MixerCoordinationObservation] { lock.withLock { storedObservations } }

    func readMixerRoster(_ token: AudioWorldToken) -> [MixerRosterEntry] { roster }

    func writeMixerGainTable(_ table: [String: Double], _ token: AudioWorldToken) -> Bool {
        lock.withLock { storedTables.append(table) }
        return true
    }

    func recordMixerCoordination(_ observation: MixerCoordinationObservation) {
        lock.withLock { storedObservations.append(observation) }
    }
}

/// 押し込みの更新期限を実時間に頼らず動かすための時計。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    var now: Double { lock.withLock { value } }
    func advance(by seconds: Double) { lock.withLock { value += seconds } }
}

/// メインスレッド外から届く押し出しの受け口。
private final class UpdateSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedUpdates: [MixerCoordinatorUpdate] = []
    private var expectation: XCTestExpectation?

    var last: MixerCoordinatorUpdate? { lock.withLock { storedUpdates.last } }

    func arm(_ expectation: XCTestExpectation) { lock.withLock { self.expectation = expectation } }

    func receive(_ update: MixerCoordinatorUpdate) {
        let armed: XCTestExpectation? = lock.withLock {
            storedUpdates.append(update)
            return expectation
        }
        armed?.fulfill()
    }
}

final class MixerCoordinatorTests: XCTestCase {
    private static let playerPath = "/Applications/Player.app/Contents/MacOS/Player"
    private static let playerKey = MixerSpec.bundleKey("com.example.player")

    private var bridge: FakeMixerBridge!
    private var levelStore: MixerLevelStore!
    private var coordinator: MixerCoordinator!
    private var clock: TestClock!
    private var sink: UpdateSink!

    override func setUp() {
        super.setUp()
        bridge = FakeMixerBridge()
        levelStore = MixerLevelStore(slotCount: 4)
        clock = TestClock()
        sink = UpdateSink()
        let resolver = MixerAppResolver(environment: MixerAppResolver.Environment(
            responsibleForPID: { $0 },
            parentPID: { _ in nil },
            executablePath: { $0 == 501 ? Self.playerPath : nil },
            bundleInfo: { _ in MixerAppResolver.BundleInfo(bundleID: "com.example.player", displayName: "Player") }
        ))
        coordinator = MixerCoordinator(
            audioWorld: AudioWorld(queue: DispatchQueue(label: "MixerCoordinatorTests.audioWorld")),
            bridge: bridge,
            levelStore: levelStore,
            resolver: resolver,
            queue: DispatchQueue(label: "MixerCoordinatorTests.coordinator"),
            now: { [clock = clock!] in clock.now }
        )
        coordinator.didUpdate = { [sink = sink!] update in sink.receive(update) }
    }

    override func tearDown() {
        coordinator = nil
        levelStore = nil
        bridge = nil
        sink = nil
        clock = nil
        super.tearDown()
    }

    // MARK: - 駆動

    private func advanceClock(by seconds: Double) {
        clock.advance(by: seconds)
    }

    /// ドライバが席を張り替えたことにして名簿の版数を進める。
    private func bumpRosterRevision(generation: UInt32) {
        levelStore.beginFold(tableGeneration: generation)
    }

    @discardableResult
    private func waitForUpdate(_ body: () -> Void) -> MixerCoordinatorUpdate {
        let armed = expectation(description: "coordinator update")
        sink.arm(armed)
        body()
        wait(for: [armed], timeout: 2)
        return sink.last!
    }

    private func entry(clientID: UInt32, pid: UInt32, bundleID: String, active: Bool) -> MixerRosterEntry {
        MixerRosterEntry(clientID: clientID, processID: pid, bundleID: bundleID, active: active)
    }

    // MARK: - 候補プール

    func testActiveClientsEnterTheCandidatePoolAndStayForTheSession() {
        bridge.roster = [entry(clientID: 1, pid: 501, bundleID: "com.example.player", active: true)]
        var update = waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        XCTAssertNotNil(update.identities[Self.playerKey])
        XCTAssertTrue(update.playingKeys.contains(Self.playerKey))
        XCTAssertEqual(update.clientIDsByChannelKey[Self.playerKey], [1])

        bridge.roster = []
        update = waitForUpdate { bumpRosterRevision(generation: 2); coordinator.runPass() }
        XCTAssertNotNil(update.identities[Self.playerKey], "席が消えてもセッション中は候補に残る")
        XCTAssertFalse(update.playingKeys.contains(Self.playerKey))
    }

    /// 席を取っただけで鳴っていないクライアントは行の母集合に入らない。
    func testSeatedButSilentClientDoesNotEnterTheCandidatePool() {
        bridge.roster = [entry(clientID: 1, pid: 501, bundleID: "com.example.player", active: false)]
        let update = waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        XCTAssertTrue(update.identities.isEmpty)
    }

    func testUnresolvableClientIsNeverOffered() {
        bridge.roster = [entry(clientID: 1, pid: 999, bundleID: "com.example.ghost", active: true)]
        let update = waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        XCTAssertTrue(update.identities.isEmpty)
        XCTAssertEqual(bridge.observations.last?.unresolvedCount, 1)
    }

    // MARK: - 押し込み

    func testNeutralChannelsNeverReachCoreAudio() {
        bridge.roster = [entry(clientID: 1, pid: 501, bundleID: "com.example.player", active: true)]
        waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        waitForUpdate {
            coordinator.updateChannels([MixerChannelSnapshot(key: Self.playerKey, gain: MixerGainScale.unityGain)])
        }
        XCTAssertTrue(bridge.pushedTables.isEmpty, "中立の間は書き込みが 1 件も増えない")
    }

    func testNonNeutralChannelIsPushedAndRenewedOnceTheDeadlinePasses() {
        bridge.roster = [entry(clientID: 1, pid: 501, bundleID: "com.example.player", active: true)]
        waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        waitForUpdate { coordinator.updateChannels([MixerChannelSnapshot(key: Self.playerKey, gain: 0.5)]) }
        XCTAssertEqual(bridge.pushedTables.count, 1)
        XCTAssertEqual(
            bridge.pushedTables.last, [MixerSpec.matchKey(bundleID: "com.example.player", processID: 501)!: 0.5]
        )

        waitForUpdate { coordinator.runPass() }
        XCTAssertEqual(bridge.pushedTables.count, 1, "周期が回るだけでは押し込まない")

        advanceClock(by: MixerCoordinator.passInterval)
        waitForUpdate { coordinator.runPass() }
        XCTAssertEqual(bridge.pushedTables.count, 2, "更新期限が来たら同じ内容でも押し込む")
    }

    func testReturningEveryChannelToNeutralPushesOnceToReleaseTheLease() {
        bridge.roster = [entry(clientID: 1, pid: 501, bundleID: "com.example.player", active: true)]
        waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        waitForUpdate { coordinator.updateChannels([MixerChannelSnapshot(key: Self.playerKey, gain: 0.5)]) }

        waitForUpdate {
            coordinator.updateChannels([MixerChannelSnapshot(key: Self.playerKey, gain: MixerGainScale.unityGain)])
        }
        XCTAssertEqual(bridge.pushedTables.count, 2)
        XCTAssertEqual(bridge.pushedTables.last, [:], "中立へ戻す 1 回でリースが解除される")

        advanceClock(by: MixerCoordinator.passInterval * 3)
        waitForUpdate { coordinator.runPass() }
        XCTAssertEqual(bridge.pushedTables.count, 2, "中立が続く間は更新期限が来ても押し込まない")
    }

    // MARK: - 診断へ渡す内訳

    func testCoordinationObservationCarriesTheResolutionBreakdown() {
        bridge.roster = [entry(clientID: 1, pid: 501, bundleID: "com.example.player", active: true)]
        waitForUpdate { bumpRosterRevision(generation: 1); coordinator.runPass() }
        waitForUpdate { coordinator.updateChannels([MixerChannelSnapshot(key: Self.playerKey, gain: 0.5)]) }

        let observation = try! XCTUnwrap(bridge.observations.last)
        XCTAssertEqual(observation.channelCount, 1)
        XCTAssertEqual(observation.nonNeutralChannelCount, 1)
        XCTAssertEqual(observation.resolvedByPrivateAPICount + observation.resolvedAsProcessCount, 1)
        XCTAssertTrue(observation.privateAPIAvailable)
    }
}
