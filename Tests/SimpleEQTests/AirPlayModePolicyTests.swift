import XCTest
@testable import SimpleEQ

final class AirPlayModePolicyTests: XCTestCase {
    private typealias Observation = AirPlayModePolicy.DefaultOutputObservation

    private let endpointUID = "airplay-1"
    private let allStates: [ProcessingState] = [.active] + SuspensionCause.allCases.map { .suspended($0) }

    private func action(
        phase: AirPlayModePhase, endpointUID: String? = "airplay-1", defaultOutput: Observation,
        adopts: Bool = true, processingState: ProcessingState = .active,
        departureObserved: Bool = false, settleDeadline: TimeInterval? = nil, now: TimeInterval = 100,
        retryAllowed: Bool = true, unhealthyRebuildAllowed: Bool = true, routeHealthy: Bool = true
    ) -> AirPlayModePolicy.Action {
        AirPlayModePolicy.action(
            phase: phase, endpointUID: endpointUID, defaultOutput: defaultOutput,
            adopts: adopts, processingState: processingState,
            departureObservedWhileEndpointAlive: departureObserved, settleDeadline: settleDeadline, now: now,
            retryAllowed: retryAllowed, unhealthyRebuildAllowed: unhealthyRebuildAllowed, routeHealthy: routeHealthy
        )
    }

    // MARK: - 入る条件

    func testEntryRequiresAdoptionAndAStateThatMayResumeOnItsOwn() {
        for adopts in [true, false] {
            for state in allStates {
                let expected: Bool
                switch state {
                case .active: expected = adopts
                case .suspended(let cause): expected = adopts && SuspensionPolicy.allowsAutomaticResume(cause)
                }
                XCTAssertEqual(
                    AirPlayModePolicy.allowsEntry(adopts: adopts, processingState: state), expected,
                    "adopts=\(adopts) state=\(state)"
                )
            }
        }
    }

    func testAnInactiveModeEntersOnlyWhenTheDefaultOutputIsAirPlayAndEntryIsAllowed() {
        let outputs: [Observation] = [.unreadable, .airPlay(uid: "ap"), .other(uid: "g", selectable: true), .other(uid: "g", selectable: false)]
        for adopts in [true, false] {
            for state in allStates {
                for output in outputs {
                    let result = action(phase: .inactive, endpointUID: nil, defaultOutput: output, adopts: adopts, processingState: state)
                    let entryAllowed = AirPlayModePolicy.allowsEntry(adopts: adopts, processingState: state)
                    if case .airPlay(let uid) = output, entryAllowed {
                        XCTAssertEqual(result, .enter(uid: uid), "adopts=\(adopts) state=\(state)")
                    } else {
                        XCTAssertEqual(result, .none, "adopts=\(adopts) state=\(state) output=\(output)")
                    }
                }
            }
        }
    }

    // MARK: - モード中

    func testAnUnreadableDefaultOutputChangesNothingInEveryPhase() {
        for phase: AirPlayModePhase in [.awaitingCapture, .capturing, .captureDenied, .captureFailed] {
            XCTAssertEqual(action(phase: phase, defaultOutput: .unreadable, adopts: false), .none, "phase=\(phase)")
        }
    }

    func testLosingTheEntryConditionDepartsFromEveryActivePhase() {
        for phase: AirPlayModePhase in [.awaitingCapture, .capturing, .captureDenied, .captureFailed] {
            XCTAssertEqual(action(phase: phase, defaultOutput: .airPlay(uid: endpointUID), adopts: false), .depart, "phase=\(phase)")
            XCTAssertEqual(
                action(phase: phase, defaultOutput: .airPlay(uid: endpointUID), processingState: .suspended(.driverOperation)),
                .depart, "phase=\(phase)"
            )
        }
    }

    func testTheSameEndpointIsLeftAloneWhileItsRouteIsHealthyOrBeingBuilt() {
        XCTAssertEqual(action(phase: .awaitingCapture, defaultOutput: .airPlay(uid: endpointUID)), .none)
        XCTAssertEqual(action(phase: .capturing, defaultOutput: .airPlay(uid: endpointUID)), .none)
        XCTAssertEqual(action(phase: .captureDenied, defaultOutput: .airPlay(uid: endpointUID)), .none)
    }

    func testAnUnhealthyRouteOnTheSameEndpointIsRebuiltWithoutSettling() {
        XCTAssertEqual(
            action(phase: .capturing, defaultOutput: .airPlay(uid: endpointUID), routeHealthy: false), .rebuildUnhealthyRoute(uid: endpointUID)
        )
        XCTAssertEqual(
            action(phase: .captureDenied, defaultOutput: .airPlay(uid: endpointUID), routeHealthy: false), .rebuildUnhealthyRoute(uid: endpointUID)
        )
        XCTAssertEqual(
            action(phase: .captureFailed, defaultOutput: .airPlay(uid: endpointUID), routeHealthy: false), .rebuild(uid: endpointUID),
            "失敗からの再試行は不健全による作り直しとして数えない"
        )
        XCTAssertEqual(
            action(phase: .awaitingCapture, defaultOutput: .airPlay(uid: endpointUID), routeHealthy: false), .none,
            "構築中は経路の健全性を問わない"
        )
        XCTAssertEqual(
            action(phase: .capturing, defaultOutput: .airPlay(uid: endpointUID), unhealthyRebuildAllowed: false, routeHealthy: false), .none,
            "不健全による作り直しの間隔が空くまでは作り直さない"
        )
        XCTAssertEqual(
            action(phase: .capturing, defaultOutput: .airPlay(uid: endpointUID), retryAllowed: false, routeHealthy: false),
            .rebuildUnhealthyRoute(uid: endpointUID), "失敗の再試行の抑制は、不健全による作り直しを止めない"
        )
    }

    func testAFailedCaptureIsRetriedOnlyWhenTheThrottleAllowsIt() {
        XCTAssertEqual(action(phase: .captureFailed, defaultOutput: .airPlay(uid: endpointUID), retryAllowed: true), .rebuild(uid: endpointUID))
        XCTAssertEqual(action(phase: .captureFailed, defaultOutput: .airPlay(uid: endpointUID), retryAllowed: false), .none)
    }

    // UID が同じでも猶予中なら取り込み経路は止めてあるので、依頼し直さないと止まったままになる。
    func testReturningToTheSameEndpointDuringTheSettleRebuilds() {
        XCTAssertEqual(
            action(phase: .awaitingCapture, defaultOutput: .airPlay(uid: endpointUID), settleDeadline: 101, now: 100.5),
            .rebuild(uid: endpointUID)
        )
    }

    // ID はプロセスごとに違って見えるので、比べるのは UID だけ。
    func testADifferentEndpointUIDIsRebuiltInEveryActivePhase() {
        for phase: AirPlayModePhase in [.awaitingCapture, .capturing, .captureDenied, .captureFailed] {
            XCTAssertEqual(
                action(phase: phase, defaultOutput: .airPlay(uid: "airplay-2"), retryAllowed: false), .rebuild(uid: "airplay-2"),
                "phase=\(phase)"
            )
        }
    }

    func testLeavingForAnotherDeviceWhileTheEndpointWasAliveDepartsAtOnce() {
        for selectable in [true, false] {
            XCTAssertEqual(
                action(phase: .capturing, defaultOutput: .other(uid: "g", selectable: selectable), departureObserved: true),
                .depart
            )
        }
    }

    func testLeavingWithoutThatObservationSettlesFirstAndDepartsAtTheDeadline() {
        let now: TimeInterval = 100
        XCTAssertEqual(
            action(phase: .capturing, defaultOutput: .other(uid: "g", selectable: true), now: now),
            .beginSettle(deadline: now + AirPlayModePolicy.settleSeconds)
        )
        let deadline = now + AirPlayModePolicy.settleSeconds
        XCTAssertEqual(
            action(phase: .awaitingCapture, defaultOutput: .other(uid: "g", selectable: true), settleDeadline: deadline, now: deadline - 0.001),
            .awaitSettle
        )
        XCTAssertEqual(
            action(phase: .awaitingCapture, defaultOutput: .other(uid: "g", selectable: true), settleDeadline: deadline, now: deadline),
            .depart, "期限ちょうどで抜ける"
        )
    }

    func testTheSettleIsDerivedFromTheObservedDwellAndTheSafetyFactor() {
        XCTAssertEqual(
            AirPlayModePolicy.settleSeconds,
            AirPlayModePolicy.observedFallbackDwellSeconds * AirPlayModePolicy.settleSafetyFactor
        )
        XCTAssertGreaterThan(AirPlayModePolicy.settleSeconds, AirPlayModePolicy.observedFallbackDwellSeconds)
    }

    // MARK: - 経路の検算・抜けた後の候補

    func testARouteIsHealthyOnlyWhenEveryObservationAgrees() {
        XCTAssertTrue(AirPlayModePolicy.routeHealthy(auhalDeviceUID: "ap", endpointUID: "ap", captureStalled: false, appliedRate: 44100, aggregateRate: 44100))
        XCTAssertFalse(AirPlayModePolicy.routeHealthy(auhalDeviceUID: "other", endpointUID: "ap", captureStalled: false, appliedRate: 44100, aggregateRate: 44100))
        XCTAssertFalse(AirPlayModePolicy.routeHealthy(auhalDeviceUID: nil, endpointUID: "ap", captureStalled: false, appliedRate: 44100, aggregateRate: 44100))
        XCTAssertFalse(AirPlayModePolicy.routeHealthy(auhalDeviceUID: "ap", endpointUID: "ap", captureStalled: true, appliedRate: 44100, aggregateRate: 44100))
        XCTAssertFalse(AirPlayModePolicy.routeHealthy(auhalDeviceUID: "ap", endpointUID: "ap", captureStalled: false, appliedRate: 44100, aggregateRate: 48000))
        XCTAssertFalse(AirPlayModePolicy.routeHealthy(auhalDeviceUID: "ap", endpointUID: "ap", captureStalled: false, appliedRate: 44100, aggregateRate: nil))
    }

    func testTheCaptureWriterIsReadAsStoppedByTheStartupAllowanceUntilItsFirstWrite() {
        let cycle: TimeInterval = 0.1
        let allowance = AirPlayModePolicy.captureStartupAllowanceSeconds
        XCTAssertGreaterThan(allowance, cycle, "前提: 猶予は周期しきい値より長い")

        XCTAssertFalse(AirPlayModePolicy.captureStalled(elapsedSinceLastWrite: cycle * 4, hasReceivedWriteSinceStart: false, cycleThreshold: cycle))
        XCTAssertFalse(AirPlayModePolicy.captureStalled(elapsedSinceLastWrite: allowance, hasReceivedWriteSinceStart: false, cycleThreshold: cycle))
        XCTAssertTrue(
            AirPlayModePolicy.captureStalled(elapsedSinceLastWrite: allowance + cycle, hasReceivedWriteSinceStart: false, cycleThreshold: cycle),
            "一度も書き込みが届かないまま猶予を過ぎたら止まっている"
        )
        XCTAssertFalse(AirPlayModePolicy.captureStalled(elapsedSinceLastWrite: cycle, hasReceivedWriteSinceStart: true, cycleThreshold: cycle))
        XCTAssertTrue(
            AirPlayModePolicy.captureStalled(elapsedSinceLastWrite: cycle * 4, hasReceivedWriteSinceStart: true, cycleThreshold: cycle),
            "書き込みが届いた後は周期しきい値で読む"
        )
    }

    // AirPlay に入る前の出力先は候補にしない。候補は抜けた時点のデフォルト出力だけ。
    func testTheResumeCandidateIsOnlyASelectableDefaultOutput() {
        XCTAssertEqual(AirPlayModePolicy.departureResumeCandidate(defaultOutput: .other(uid: "g", selectable: true)), "g")
        XCTAssertNil(AirPlayModePolicy.departureResumeCandidate(defaultOutput: .other(uid: "g", selectable: false)))
        XCTAssertNil(AirPlayModePolicy.departureResumeCandidate(defaultOutput: .airPlay(uid: "ap")))
        XCTAssertNil(AirPlayModePolicy.departureResumeCandidate(defaultOutput: .unreadable))
    }
}

final class RetryThrottleTests: XCTestCase {
    private func makeThrottle() -> RetryThrottle {
        RetryThrottle(interval: 15, maxConsecutiveFailures: 3)
    }

    func testTheFirstAttemptIsAllowedAndTheNextWaitsForTheInterval() {
        var throttle = makeThrottle()
        XCTAssertTrue(throttle.allowsAttempt(now: 0))
        throttle.noteAttempt(now: 0)
        XCTAssertFalse(throttle.allowsAttempt(now: 14.999))
        XCTAssertTrue(throttle.allowsAttempt(now: 15), "間隔ちょうどで許す")
    }

    func testConsecutiveFailuresStopAttemptsUntilASuccessOrReset() {
        var throttle = makeThrottle()
        for n in 0..<3 {
            throttle.noteAttempt(now: TimeInterval(n) * 15)
            throttle.noteFailure()
        }
        XCTAssertFalse(throttle.allowsAttempt(now: 1000), "上限に達したら間隔が空いても許さない")

        var succeeded = throttle
        succeeded.noteSuccess()
        XCTAssertTrue(succeeded.allowsAttempt(now: 1000), "成功で回数を数え直す")
        XCTAssertFalse(succeeded.allowsAttempt(now: 30 + 1), "成功しても直前の試行からの間隔は保つ")

        var reset = throttle
        reset.reset()
        XCTAssertTrue(reset.allowsAttempt(now: 0), "リセットで回数も間隔も戻す")
    }
}
