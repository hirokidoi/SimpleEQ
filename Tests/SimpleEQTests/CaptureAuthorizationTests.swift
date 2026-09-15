import CoreAudio
import XCTest
@testable import SimpleEQ

/// TCC の 2 関数の代役。求める呼び出しの回数と、呼ばれたときに受け取ったコールバックを記録する。
private final class FakeTCC: Sendable {
    let preflightValue = Recorded<Int32?>(2)
    let requestCalls = Recorded<[@Sendable (Bool) -> Void]>([])
    /// 求めた瞬間に結果を返す TCC を模す。コールバックは別スレッドから呼ぶ。
    let answerImmediately = Recorded<Bool?>(nil)

    func probe(canRequest: Bool = true) -> CaptureAuthorizationProbe {
        let preflightValue = preflightValue
        let requestCalls = requestCalls
        let answerImmediately = answerImmediately
        var preflight: CaptureAuthorizationProbe.Preflight?
        if preflightValue.value != nil {
            preflight = { preflightValue.value ?? -1 }
        }
        var request: CaptureAuthorizationProbe.Request?
        if canRequest {
            request = { (completion: @escaping @Sendable (Bool) -> Void) in
                requestCalls.update { $0.append(completion) }
                guard let granted = answerImmediately.value else { return }
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    completion(granted)
                    answered.signal()
                }
                answered.wait()
            }
        }
        return CaptureAuthorizationProbe(preflight: preflight, request: request)
    }
}

final class CaptureAuthorizationGateTests: XCTestCase {
    private typealias Gate = CaptureAuthorizationGate

    // MARK: - 判定の表

    func testGrantedAndDeniedPreflightValuesBuildWithoutRequesting() {
        for canRequest in [true, false] {
            XCTAssertEqual(Gate.decision(preflight: 0, requestProgress: .notRequested, canRequest: canRequest), .build(.granted))
            XCTAssertEqual(Gate.decision(preflight: 1, requestProgress: .notRequested, canRequest: canRequest), .build(.denied))
        }
    }

    func testAnUndeterminedValueRequestsOnceAndThenWaits() {
        XCTAssertEqual(Gate.decision(preflight: 2, requestProgress: .notRequested, canRequest: true), .request)
        XCTAssertEqual(Gate.decision(preflight: 2, requestProgress: .awaitingResult, canRequest: true), .awaitResult)
    }

    // 求めた結果が事前の値に反映された場合は事前の値が、反映されない場合は結果が決める。
    func testAResultDecidesOnlyWhileThePreflightStillReadsUndetermined() {
        XCTAssertEqual(Gate.decision(preflight: 0, requestProgress: .resulted(granted: false), canRequest: true), .build(.granted))
        XCTAssertEqual(Gate.decision(preflight: 1, requestProgress: .resulted(granted: true), canRequest: true), .build(.denied))
        XCTAssertEqual(Gate.decision(preflight: 2, requestProgress: .resulted(granted: true), canRequest: true), .build(.granted))
        XCTAssertEqual(Gate.decision(preflight: 2, requestProgress: .resulted(granted: false), canRequest: true), .build(.denied))
    }

    func testAnEnvironmentThatCannotRequestOrReadBuildsAsUnreadable() {
        XCTAssertEqual(Gate.decision(preflight: 2, requestProgress: .notRequested, canRequest: false), .build(.unreadable))
        for canRequest in [true, false] {
            XCTAssertEqual(Gate.decision(preflight: nil, requestProgress: .notRequested, canRequest: canRequest), .build(.unreadable))
        }
        XCTAssertEqual(Gate.decision(preflight: 3, requestProgress: .notRequested, canRequest: true), .build(.unreadable))
        XCTAssertEqual(Gate.decision(preflight: -1, requestProgress: .notRequested, canRequest: true), .build(.unreadable))
    }

    // MARK: - 門の入口

    private func makeGate(_ tcc: FakeTCC, canRequest: Bool = true, queue: DispatchQueue, resultDidArrive: @escaping @Sendable () -> Void = {}) -> Gate {
        Gate(probe: tcc.probe(canRequest: canRequest), queue: queue, resultDidArrive: resultDidArrive)
    }

    func testTheRequestIsMadeOncePerProcessEvenAcrossRepeatedAdmissions() {
        let tcc = FakeTCC()
        let queue = DispatchQueue(label: "CaptureAuthorizationGateTests.build")
        let gate = makeGate(tcc, queue: queue)

        XCTAssertEqual(queue.sync { gate.admit() }, .awaitingResult)
        XCTAssertEqual(queue.sync { gate.admit() }, .awaitingResult)

        XCTAssertEqual(tcc.requestCalls.value.count, 1)
        XCTAssertEqual(queue.sync { gate.progress }, .awaitingResult)
    }

    func testReadablePreflightValuesAreReadAfreshOnEveryAdmissionAndNeverRequest() {
        let tcc = FakeTCC()
        let queue = DispatchQueue(label: "CaptureAuthorizationGateTests.build")
        let gate = makeGate(tcc, queue: queue)

        tcc.preflightValue.update { $0 = 0 }
        XCTAssertEqual(queue.sync { gate.admit() }, .build(.granted))
        tcc.preflightValue.update { $0 = 1 }
        XCTAssertEqual(queue.sync { gate.admit() }, .build(.denied))

        XCTAssertTrue(tcc.requestCalls.value.isEmpty)
    }

    func testAResultFromAnotherThreadIsRecordedBeforeTheArrivalIsAnnounced() {
        let tcc = FakeTCC()
        let queue = DispatchQueue(label: "CaptureAuthorizationGateTests.build")
        let progressAtAnnouncement = Recorded<[Gate.RequestProgress]>([])
        let gateBox = Recorded<Gate?>(nil)
        let gate = makeGate(tcc, queue: queue) {
            dispatchPrecondition(condition: .onQueue(queue))
            progressAtAnnouncement.update { $0.append(gateBox.value!.progress) }
        }
        gateBox.update { $0 = gate }

        XCTAssertEqual(queue.sync { gate.admit() }, .awaitingResult)
        let completion = tcc.requestCalls.value[0]
        let answered = expectation(description: "別スレッドからの結果")
        DispatchQueue.global().async {
            completion(false)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        queue.sync {}

        XCTAssertEqual(progressAtAnnouncement.value, [.resulted(granted: false)])
        tcc.preflightValue.update { $0 = 2 }
        XCTAssertEqual(queue.sync { gate.admit() }, .build(.denied), "事前の値が 2 のままなら結果のとおりに構築する")
        XCTAssertEqual(tcc.requestCalls.value.count, 1, "求め直さない")
    }
}

final class CaptureAuthorizationProbeTests: XCTestCase {
    // 呼ぶとテストの責任主体で TCC に問い合わせるため、引けることだけを見る。
    func testBothSymbolsResolveOnThisMachine() {
        XCTAssertNotNil(CaptureAuthorizationProbe.system.preflight)
        XCTAssertNotNil(CaptureAuthorizationProbe.system.request)
    }
}

final class AirPlayCaptureBuilderTests: XCTestCase {
    private enum Arrival: Equatable {
        case awaitingAuthorization(generation: UInt64)
        case built(CaptureAuthorization, generation: UInt64)
        case failed(generation: UInt64)
        case authorizationResult
    }

    private func request(generation: UInt64 = 1, selfProcessObjectID: AudioObjectID? = 7) -> CaptureBuildRequest {
        CaptureBuildRequest(endpointUID: "airplay-uid", endpointDeviceID: 150, selfProcessObjectID: selfProcessObjectID, generation: generation)
    }

    /// 届け先はオーディオ世界に見立てた直列キュー。到着順をそのキューの上で記録する。
    private func makeBuilder(
        _ tcc: FakeTCC, makeCapture: @escaping AirPlayCaptureBuilder.MakeCapture, arrivals: Recorded<[Arrival]>,
        destination: DispatchQueue, buildQueue: DispatchQueue
    ) -> AirPlayCaptureBuilder {
        AirPlayCaptureBuilder(
            probe: tcc.probe(), queue: buildQueue, makeCapture: makeCapture,
            didFinish: { outcome, generation in
                let arrival: Arrival
                switch outcome {
                case .awaitingAuthorization: arrival = .awaitingAuthorization(generation: generation)
                case .built(_, let authorization): arrival = .built(authorization, generation: generation)
                case .failed: arrival = .failed(generation: generation)
                }
                destination.async { arrivals.update { $0.append(arrival) } }
            },
            authorizationResultDidArrive: {
                destination.async { arrivals.update { $0.append(.authorizationResult) } }
            }
        )
    }

    private func settle(_ buildQueue: DispatchQueue, _ destination: DispatchQueue) {
        buildQueue.sync {}
        buildQueue.sync {}
        destination.sync {}
    }

    func testAWaitingGateDeliversTheWaitWithoutMakingATap() {
        let tcc = FakeTCC()
        let madeCaptures = Recorded<Int>(0)
        let arrivals = Recorded<[Arrival]>([])
        let buildQueue = DispatchQueue(label: "AirPlayCaptureBuilderTests.build")
        let destination = DispatchQueue(label: "AirPlayCaptureBuilderTests.world")
        let builder = makeBuilder(
            tcc, makeCapture: { _, _ in madeCaptures.update { $0 += 1 }; return FakeCaptureSource() },
            arrivals: arrivals, destination: destination, buildQueue: buildQueue
        )

        builder.build(request(generation: 3))
        settle(buildQueue, destination)

        XCTAssertEqual(arrivals.value, [.awaitingAuthorization(generation: 3)])
        XCTAssertEqual(madeCaptures.value, 0)
    }

    func testABuildCarriesTheAuthorizationTheGateSettledOn() {
        let tcc = FakeTCC()
        tcc.preflightValue.update { $0 = 1 }
        let arrivals = Recorded<[Arrival]>([])
        let buildQueue = DispatchQueue(label: "AirPlayCaptureBuilderTests.build")
        let destination = DispatchQueue(label: "AirPlayCaptureBuilderTests.world")
        let excluded = Recorded<[AudioObjectID]>([])
        let builder = makeBuilder(
            tcc, makeCapture: { _, selfObject in excluded.update { $0.append(selfObject) }; return FakeCaptureSource() },
            arrivals: arrivals, destination: destination, buildQueue: buildQueue
        )

        builder.build(request(generation: 4))
        settle(buildQueue, destination)

        XCTAssertEqual(arrivals.value, [.built(.denied, generation: 4)])
        XCTAssertEqual(excluded.value, [7], "自プロセスを除外して作る")
    }

    func testAFailedTapDeliversAFailure() {
        let tcc = FakeTCC()
        tcc.preflightValue.update { $0 = 0 }
        let arrivals = Recorded<[Arrival]>([])
        let buildQueue = DispatchQueue(label: "AirPlayCaptureBuilderTests.build")
        let destination = DispatchQueue(label: "AirPlayCaptureBuilderTests.world")
        let builder = makeBuilder(
            tcc, makeCapture: { _, _ in nil }, arrivals: arrivals, destination: destination, buildQueue: buildQueue
        )

        builder.build(request(generation: 5))
        settle(buildQueue, destination)

        XCTAssertEqual(arrivals.value, [.failed(generation: 5)])
    }

    // 除外しないと出し直した音まで自分の Tap でミュートされる。門にも進まない。
    func testWithoutTheOwnProcessObjectNothingIsRequestedOrMade() {
        let tcc = FakeTCC()
        let madeCaptures = Recorded<Int>(0)
        let arrivals = Recorded<[Arrival]>([])
        let buildQueue = DispatchQueue(label: "AirPlayCaptureBuilderTests.build")
        let destination = DispatchQueue(label: "AirPlayCaptureBuilderTests.world")
        let builder = makeBuilder(
            tcc, makeCapture: { _, _ in madeCaptures.update { $0 += 1 }; return FakeCaptureSource() },
            arrivals: arrivals, destination: destination, buildQueue: buildQueue
        )

        builder.build(request(generation: 6, selfProcessObjectID: nil))
        settle(buildQueue, destination)

        XCTAssertEqual(arrivals.value, [.failed(generation: 6)])
        XCTAssertTrue(tcc.requestCalls.value.isEmpty)
        XCTAssertEqual(madeCaptures.value, 0)
    }

    // TCC が求めた瞬間に答えても、結果待ちは結果が届いた知らせより先にオーディオ世界へ着く。
    func testTheWaitArrivesBeforeTheResultEvenWhenTheAnswerIsImmediate() {
        let tcc = FakeTCC()
        tcc.answerImmediately.update { $0 = true }
        let arrivals = Recorded<[Arrival]>([])
        let buildQueue = DispatchQueue(label: "AirPlayCaptureBuilderTests.build")
        let destination = DispatchQueue(label: "AirPlayCaptureBuilderTests.world")
        let builder = makeBuilder(
            tcc, makeCapture: { _, _ in FakeCaptureSource() }, arrivals: arrivals, destination: destination, buildQueue: buildQueue
        )

        builder.build(request(generation: 8))
        settle(buildQueue, destination)

        XCTAssertEqual(arrivals.value, [.awaitingAuthorization(generation: 8), .authorizationResult])
    }
}
