import CoreAudio
import XCTest
@testable import SimpleEQ

final class DriverSampleRatePolicyTests: XCTestCase {
    private let available: [ClosedRange<Double>] = TestSampleRates.all.map { $0...$0 }

    private func request(
        output: Double?, driver: Double?, available: [ClosedRange<Double>]? = nil, requested: Double? = nil
    ) -> Double? {
        DriverSampleRatePolicy.rateToRequest(
            outputRate: output, driverRate: driver, driverAvailableRates: available ?? self.available, requestedRate: requested
        )
    }

    func testRequestsTheOutputRateForEveryDifferingPair() {
        for output in TestSampleRates.all {
            for driver in TestSampleRates.all where driver != output {
                XCTAssertEqual(request(output: output, driver: driver), output, "output \(output) driver \(driver)")
            }
        }
    }

    func testRequestsNothingWhenTheDriverAlreadyMatches() {
        for rate in TestSampleRates.all {
            XCTAssertNil(request(output: rate, driver: rate), "\(rate)")
        }
    }

    func testRequestsNothingForARateOutsideTheDeclaredList() throws {
        let lowest = try XCTUnwrap(TestSampleRates.all.min())
        let highest = try XCTUnwrap(TestSampleRates.all.max())
        let outside = [lowest / 2, lowest / 2 + 1, highest * 2]
        for rate in outside {
            XCTAssertFalse(available.contains { $0.contains(rate) }, "前提: 一覧の外 \(rate)")
            XCTAssertNil(request(output: rate, driver: lowest), "\(rate)")
        }
    }

    func testRequestsNothingWhenAnInputIsUnreadable() {
        let rate = TestSampleRates.all[0]
        let other = TestSampleRates.all[1]
        XCTAssertNil(request(output: nil, driver: other))
        XCTAssertNil(request(output: 0, driver: other))
        XCTAssertNil(request(output: -rate, driver: other))
        XCTAssertNil(request(output: rate, driver: nil))
        XCTAssertNil(request(output: rate, driver: 0))
        XCTAssertNil(request(output: rate, driver: -other))
        XCTAssertNil(request(output: rate, driver: other, available: []))
        XCTAssertEqual(request(output: rate, driver: other), rate, "前提: 全部読めれば依頼する")
    }

    func testAPendingRequestIsComparedInsteadOfTheDriverValue() {
        for output in TestSampleRates.all {
            XCTAssertNil(request(output: output, driver: TestSampleRates.all[0], requested: output), "依頼中 = 出力 \(output)")
            for requested in TestSampleRates.all where requested != output {
                XCTAssertEqual(request(output: output, driver: TestSampleRates.all[0], requested: requested), output)
            }
        }
    }

    func testARangeAcceptsAValueInsideIt() {
        let range = [TestSampleRates.all[0]...TestSampleRates.all[3]]
        let inside = (TestSampleRates.all[0] + TestSampleRates.all[3]) / 2
        XCTAssertEqual(request(output: inside, driver: TestSampleRates.all[0], available: range), inside)
    }

    func testReturningToTheOldDriverValueWhileARequestIsPendingRequestsAgain() {
        for output in TestSampleRates.all {
            for requested in TestSampleRates.all where requested != output {
                XCTAssertEqual(request(output: output, driver: output, requested: requested), output, "output \(output) requested \(requested)")
            }
        }
    }
}

private final class RecordingPort: DriverSampleRateFollowerPort {
    enum Event: Equatable {
        case readDriver
        case latency(Int)
        case rate(Double)
    }

    var driver: DriverSampleRateFollower.DriverReading?
    var refusesRate = false
    var totalAtRate: (Double) -> Int = { Int($0) }
    private(set) var events: [Event] = []

    init(driverRate: Double, availableRates: [ClosedRange<Double>]) {
        driver = .init(rate: driverRate, availableRates: availableRates)
    }

    var rates: [Double] { events.compactMap { if case .rate(let rate) = $0 { rate } else { nil } } }
    var latencies: [Int] { events.compactMap { if case .latency(let frames) = $0 { frames } else { nil } } }

    func clear() {
        events = []
    }

    func readDriver() -> DriverSampleRateFollower.DriverReading? {
        events.append(.readDriver)
        return driver
    }

    func declaredLatencyTotal(at rate: Double) -> Int {
        totalAtRate(rate)
    }

    func writeDeclaredLatency(_ frames: Int) {
        events.append(.latency(frames))
    }

    func writeDriverRate(_ rate: Double) -> Bool {
        events.append(.rate(rate))
        return !refusesRate
    }
}

final class DriverSampleRateFollowerTests: XCTestCase {
    private typealias Event = RecordingPort.Event

    private let driverRate = TestSampleRates.all[1]
    private let outputRate = TestSampleRates.all[0]
    private let otherRate = TestSampleRates.all[3]
    private let ranges: [ClosedRange<Double>] = TestSampleRates.all.map { $0...$0 }
    private lazy var port = RecordingPort(driverRate: driverRate, availableRates: ranges)
    private var follower = DriverSampleRateFollower()

    private func total(_ rate: Double) -> Int { port.totalAtRate(rate) }
    private var appliedTotal: Int { total(driverRate) }

    override func setUp() {
        XCTAssertEqual(Set([driverRate, outputRate, otherRate]).count, 3, "前提: 3 つのレートは互いに違う")
        XCTAssertTrue(Set([driverRate, outputRate, otherRate]).isSubset(of: TestSampleRates.all))
        XCTAssertEqual(Set([total(driverRate), total(outputRate), total(otherRate)]).count, 3, "前提: 申告の合計はレートごとに違う")
    }

    private func decide(_ output: Double?) {
        follower.decide(outputRate: output, appliedTotal: appliedTotal, port: port)
    }

    private func follow(_ output: Double?) {
        follower.followOutputRate(output, appliedTotal: appliedTotal, port: port)
    }

    /// 出力先のレートを依頼して反映まで済み、ドライバが出力先のレートになった状態にする。
    private func settle() {
        decide(outputRate)
        XCTAssertEqual(port.rates, [outputRate], "前提: 依頼が出た")
        follower.driverRateDidChange()
        port.driver = .init(rate: outputRate, availableRates: ranges)
        port.clear()
    }

    func testDecidingWritesTheDeclarationAtTheTargetRateBeforeTheRate() {
        decide(outputRate)

        XCTAssertEqual(port.events, [.readDriver, .latency(total(outputRate)), .rate(outputRate)])
        XCTAssertTrue(follower.holdsDeclarations)
    }

    func testDecidingDeclaresTheAppliedRateWhenNothingIsAsked() throws {
        decide(driverRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(appliedTotal)], "一致なら依頼しない")
        XCTAssertFalse(follower.holdsDeclarations)

        port.clear()
        let lowest = try XCTUnwrap(TestSampleRates.all.min())
        XCTAssertFalse(ranges.contains { $0.contains(lowest / 2) }, "前提: 一覧の外")
        decide(lowest / 2)
        XCTAssertEqual(port.events, [.readDriver, .latency(appliedTotal)], "一覧外なら依頼しない")
        XCTAssertFalse(follower.holdsDeclarations)
    }

    func testAClosedGateWritesOnlyTheAppliedTotalAndForgetsTheOrigin() {
        port.driver = .init(rate: outputRate, availableRates: ranges)
        decide(outputRate)
        port.clear()
        port.driver = nil

        decide(outputRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(appliedTotal)])

        port.clear()
        port.driver = .init(rate: driverRate, availableRates: ranges)
        follow(outputRate)
        XCTAssertEqual(port.rates, [outputRate], "起点を忘れているので同じ出力先のレートでも判定し直す")
    }

    func testADecisionWhileARequestIsPendingOnlyDeclaresAtThePendingRate() {
        decide(outputRate)
        port.clear()

        decide(outputRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(total(outputRate))], "依頼は重ねない")
        XCTAssertTrue(follower.holdsDeclarations)

        port.clear()
        port.totalAtRate = { Int($0) + 1000 }
        decide(outputRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(Int(outputRate) + 1000)], "別の出力先でも行き先のレートで先書きする")
    }

    func testAnOutputThatAsksForNothingWhileARequestIsPendingDeclaresAtThePendingRate() throws {
        decide(outputRate)
        let lowest = try XCTUnwrap(TestSampleRates.all.min())
        XCTAssertFalse(ranges.contains { $0.contains(lowest / 2) }, "前提: 一覧の外")

        for output in [lowest / 2, nil] {
            port.clear()
            decide(output)
            XCTAssertEqual(port.events, [.readDriver, .latency(total(outputRate))], "依頼しない出力先も行き先のレートで先書きする")
            XCTAssertTrue(follower.holdsDeclarations)
        }
    }

    func testSettlingEndsTheRequestAndTheChainStopsThere() {
        decide(outputRate)
        follower.driverRateDidChange()
        XCTAssertFalse(follower.holdsDeclarations)

        port.driver = .init(rate: outputRate, availableRates: ranges)
        port.clear()
        follow(outputRate)

        XCTAssertEqual(port.events, [], "反映からは依頼しない")
    }

    func testARateChangeMadeOutsideIsNotPushedBackUntilTheNextDecision() {
        settle()
        port.driver = .init(rate: otherRate, availableRates: ranges)
        follower.driverRateDidChange()

        follow(outputRate)

        XCTAssertEqual(port.events, [])
    }

    func testARequestThatNeverLandsIsReleasedOnTheSecondPassWithoutAskingAgain() {
        decide(outputRate)
        follower.periodicPassDidBegin()
        XCTAssertTrue(follower.holdsDeclarations, "依頼を出した周では手放さない")

        port.clear()
        decide(outputRate)
        XCTAssertEqual(port.rates, [], "最初の周では重複を抑える")

        follower.periodicPassDidBegin()
        XCTAssertFalse(follower.holdsDeclarations)
        port.clear()
        follow(outputRate)
        XCTAssertEqual(port.events, [], "手放しても再依頼しない")
    }

    func testFollowingAsksOnlyWhenTheOutputRateMovedAndNotAgainAfterTheRelease() {
        settle()

        follow(otherRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(total(otherRate)), .rate(otherRate)])

        port.clear()
        follow(otherRate)
        follower.periodicPassDidBegin()
        follower.periodicPassDidBegin()
        follow(otherRate)
        XCTAssertEqual(port.events, [], "動いていなければ依頼しない")
        XCTAssertFalse(follower.holdsDeclarations)
    }

    func testAFollowThatCouldNotReadTheDriverIsJudgedAgainOnTheNextPass() {
        port.driver = .init(rate: driverRate, availableRates: [])
        follow(otherRate)
        XCTAssertEqual(port.events, [.readDriver], "一覧が読めない間は書かない")

        port.driver = .init(rate: driverRate, availableRates: ranges)
        port.clear()
        follow(otherRate)
        XCTAssertEqual(port.rates, [otherRate], "出力先のレートが同じままでも判定し直す")

        var unreadableRate = DriverSampleRateFollower()
        port.driver = .init(rate: 0, availableRates: ranges)
        port.clear()
        unreadableRate.followOutputRate(otherRate, appliedTotal: appliedTotal, port: port)
        XCTAssertEqual(port.events, [.readDriver], "ドライバのレートが読めない間は書かない")

        port.driver = .init(rate: driverRate, availableRates: ranges)
        port.clear()
        unreadableRate.followOutputRate(otherRate, appliedTotal: appliedTotal, port: port)
        XCTAssertEqual(port.rates, [otherRate])
    }

    func testAClosedGateOnAPeriodicPassForgetsTheOriginSoRegainingItAsksAgain() {
        settle()
        port.driver = nil

        follow(otherRate)
        follow(outputRate)
        XCTAssertEqual(port.events, [.readDriver, .readDriver], "門が閉じている間は書かない")

        port.driver = .init(rate: driverRate, availableRates: ranges)
        port.clear()
        follow(outputRate)
        XCTAssertEqual(port.rates, [outputRate])
    }

    func testARefusedRequestRestoresTheAppliedTotalAndIsNotRetried() {
        port.refusesRate = true

        decide(outputRate)

        XCTAssertEqual(port.events, [.readDriver, .latency(total(outputRate)), .rate(outputRate), .latency(appliedTotal)])
        XCTAssertFalse(follower.holdsDeclarations)

        port.clear()
        for _ in 0..<3 { follow(outputRate) }
        XCTAssertEqual(port.events, [], "再依頼も再申告も無い")
    }

    func testARefusedFollowWhileARequestIsPendingReturnsToThePendingRate() {
        decide(outputRate)
        port.clear()
        port.refusesRate = true

        follow(otherRate)

        XCTAssertEqual(port.events, [.readDriver, .latency(total(otherRate)), .rate(otherRate), .latency(total(outputRate))])
        XCTAssertTrue(follower.holdsDeclarations)

        port.clear()
        port.refusesRate = false
        decide(outputRate)
        XCTAssertEqual(port.rates, [], "依頼中は元の行き先のまま")
    }

    func testARefusedRateForAnOutputDecidedWhileARequestIsPendingReturnsToTheNewOutputsValue() {
        decide(outputRate)
        port.clear()
        port.totalAtRate = { Int($0) + 1000 }
        port.refusesRate = true

        decide(otherRate)

        XCTAssertEqual(
            port.events,
            [.readDriver, .latency(Int(otherRate) + 1000), .rate(otherRate), .latency(Int(outputRate) + 1000)]
        )
        XCTAssertTrue(follower.holdsDeclarations)
    }

    func testReturningToTheOldDriverRateWhileARequestIsPendingAsksAgainAndWaitsForTheRelease() {
        decide(outputRate)
        port.clear()

        decide(driverRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(total(driverRate)), .rate(driverRate)])
        XCTAssertTrue(follower.holdsDeclarations)

        follower.periodicPassDidBegin()
        XCTAssertTrue(follower.holdsDeclarations)
        follower.periodicPassDidBegin()
        XCTAssertFalse(follower.holdsDeclarations)
    }

    func testResetForgetsThePendingRequestAndTheOriginSeparately() {
        decide(outputRate)
        follower.reset()
        XCTAssertFalse(follower.holdsDeclarations)
        port.clear()
        decide(outputRate)
        XCTAssertEqual(port.events, [.readDriver, .latency(total(outputRate)), .rate(outputRate)], "依頼中を忘れている")

        var other = DriverSampleRateFollower()
        port.clear()
        other.decide(outputRate: outputRate, appliedTotal: appliedTotal, port: port)
        other.reset()
        port.clear()
        other.followOutputRate(outputRate, appliedTotal: appliedTotal, port: port)
        XCTAssertEqual(port.events.first, .readDriver, "起点を忘れているので判定し直す")
    }
}

final class DeviceSampleRateReadTests: XCTestCase {
    func testTheDefaultOutputDeviceNominalRateIsInsideItsAvailableRanges() throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else {
            throw XCTSkip("この環境に既定の出力デバイスが無い")
        }
        let ranges = availableNominalSampleRates(id, testToken)
        let rate = try XCTUnwrap(nominalSampleRate(id, testToken))

        XCTAssertFalse(ranges.isEmpty)
        XCTAssertTrue(ranges.contains { $0.contains(rate) }, "\(rate) in \(ranges)")
    }
}
