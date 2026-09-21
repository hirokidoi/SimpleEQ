import XCTest
import SimpleEQRingC
@testable import SimpleEQ

/// 所有権の操作の可否と、席をどう書き換えるか。共有ヘッダの純粋関数をシム経由で駆動する。
/// ドライバの制御経路で唯一の認可点にあたるため、拒否側と通す側を対で固定する。
final class OwnershipPlanTests: XCTestCase {

    private let denied = simpleeq_ownership_outcome_denied()
    private let noChange = simpleeq_ownership_outcome_no_change()
    private let applied = simpleeq_ownership_outcome_applied()

    private let caller: UInt32 = 501
    private let other: UInt32 = 97009

    private func plan(
        _ operation: UInt32, caller: UInt32? = nil, declaredUID: UInt32 = 20,
        owner: UInt32 = 0, ownerHoldsSeat: Bool = false,
        request: UInt32 = 0, requestUID: UInt32 = 0, requestStands: Bool = false
    ) -> SimpleEQOwnershipPlanResult {
        simpleeq_ownership_compute_plan(
            operation, caller ?? self.caller, declaredUID,
            owner, ownerHoldsSeat, request, requestUID, requestStands
        )
    }

    // MARK: - 席が埋まっているかの判定

    // 期限で決める。pid だけを見ると、名乗ったまま時間の切れた席を埋まっていると読み、誰も掴めなくなる。
    func testSeatIsHeldOnlyWhileAProcessIDAndAFutureDeadlineAreBothPresent() {
        XCTAssertTrue(simpleeq_ownership_seat_is_held(501, 2000, 1000))
        XCTAssertFalse(simpleeq_ownership_seat_is_held(0, 2000, 1000), "pid 不在の席は埋まっていない")
        XCTAssertFalse(simpleeq_ownership_seat_is_held(501, 0, 1000), "期限 0 は席を持っていない取り決め")
        XCTAssertFalse(simpleeq_ownership_seat_is_held(501, 1000, 1000), "期限に達した席は空いている")
        XCTAssertFalse(simpleeq_ownership_seat_is_held(501, 1000, 2000), "過ぎた期限の席は空いている")
    }

    // MARK: - 呼び出し元の同定

    func testAnUnidentifiedCallerIsRefusedWhateverItAsksFor() {
        for operation in [
            simpleeq_ownership_op_claim(), simpleeq_ownership_op_request(),
            simpleeq_ownership_op_cancel(), simpleeq_ownership_op_release(),
            simpleeq_ownership_op_renew(),
        ] {
            let result = plan(operation, caller: 0)
            XCTAssertEqual(result.outcome, denied, "op=\(operation)")
            XCTAssertFalse(result.writesOwnerSeat, "op=\(operation)")
            XCTAssertFalse(result.writesRequestSeat, "op=\(operation)")
            XCTAssertFalse(result.renewsOwnerLease, "op=\(operation)")
            XCTAssertFalse(result.renewsRequestLease, "op=\(operation)")
        }
    }

    func testAnUnknownOperationIsRefused() {
        let result = plan(simpleeq_ownership_op_unknown())
        XCTAssertEqual(result.outcome, denied)
        XCTAssertFalse(result.writesOwnerSeat)
        XCTAssertFalse(result.writesRequestSeat)
    }

    // MARK: - claim

    func testClaimIsRefusedWhileSomeoneHoldsTheSeat() {
        let result = plan(simpleeq_ownership_op_claim(), owner: other, ownerHoldsSeat: true)
        XCTAssertEqual(result.outcome, denied)
        XCTAssertFalse(result.writesOwnerSeat, "拒否した回は席に触れない")
    }

    // 名前が残ったまま期限が切れた席は空席として扱う。埋まっていると読むと、回収の契機が誰からも生まれない。
    func testClaimTakesASeatWhoseNameRemainsButWhoseLeaseHasRunOut() {
        let result = plan(simpleeq_ownership_op_claim(), owner: other, ownerHoldsSeat: false)
        XCTAssertEqual(result.outcome, applied)
        XCTAssertTrue(result.writesOwnerSeat)
        XCTAssertEqual(result.ownerProcessID, caller)
        XCTAssertEqual(result.ownerUID, 20)
        XCTAssertFalse(result.writesRequestSeat, "要求の席は動かさない")
    }

    // MARK: - request

    // 待ち枠は 1 つしかない。上書きすると、消された側は renew も cancel も自分の要求に届かず待ち続ける。
    func testRequestIsRefusedWhileAnotherRequestStands() {
        let result = plan(simpleeq_ownership_op_request(), owner: other, ownerHoldsSeat: true, request: 777, requestStands: true)
        XCTAssertEqual(result.outcome, denied)
        XCTAssertFalse(result.writesRequestSeat)
    }

    func testRequestReplacesTheCallersOwnStandingRequest() {
        let result = plan(simpleeq_ownership_op_request(), owner: other, ownerHoldsSeat: true, request: caller, requestStands: true)
        XCTAssertEqual(result.outcome, applied)
        XCTAssertTrue(result.writesRequestSeat)
        XCTAssertEqual(result.requestProcessID, caller)
    }

    // 満了した要求は無いものとして扱う。残っていると読むと、後から待つ側が永久に要求を出せない。
    func testRequestTakesTheWaitingSeatWhoseLeaseHasRunOut() {
        let result = plan(simpleeq_ownership_op_request(), owner: other, ownerHoldsSeat: true, request: 777, requestStands: false)
        XCTAssertEqual(result.outcome, applied)
        XCTAssertEqual(result.requestProcessID, caller)
    }

    // MARK: - cancel

    func testCancelLeavesAnotherProcessRequestAlone() {
        let result = plan(simpleeq_ownership_op_cancel(), request: 777, requestStands: true)
        XCTAssertEqual(result.outcome, noChange)
        XCTAssertFalse(result.writesRequestSeat)
    }

    func testCancelClearsTheCallersOwnRequest() {
        let result = plan(simpleeq_ownership_op_cancel(), request: caller, requestStands: true)
        XCTAssertEqual(result.outcome, applied)
        XCTAssertTrue(result.writesRequestSeat)
        XCTAssertEqual(result.requestProcessID, 0, "pid 0 が空席を表す")
        XCTAssertEqual(result.requestUID, 0)
        XCTAssertFalse(result.writesOwnerSeat, "所有者の席は動かさない")
    }

    // MARK: - release

    func testReleaseByANonOwnerChangesNothing() {
        let result = plan(simpleeq_ownership_op_release(), owner: other, ownerHoldsSeat: true)
        XCTAssertEqual(result.outcome, noChange)
        XCTAssertFalse(result.writesOwnerSeat, "他人の席を空けさせない")
    }

    func testReleaseEmptiesTheSeatWhenNobodyIsWaiting() {
        let result = plan(simpleeq_ownership_op_release(), owner: caller, ownerHoldsSeat: true)
        XCTAssertEqual(result.outcome, applied)
        XCTAssertTrue(result.writesOwnerSeat)
        XCTAssertEqual(result.ownerProcessID, 0)
        XCTAssertFalse(result.writesRequestSeat)
    }

    func testReleaseHandsTheSeatToAStandingRequestAndClearsIt() {
        let result = plan(
            simpleeq_ownership_op_release(), owner: caller, ownerHoldsSeat: true,
            request: 777, requestUID: 30, requestStands: true
        )
        XCTAssertEqual(result.outcome, applied)
        XCTAssertTrue(result.writesOwnerSeat)
        XCTAssertEqual(result.ownerProcessID, 777, "待っていた側が座る")
        XCTAssertEqual(result.ownerUID, 30, "申告値もそのまま移す")
        XCTAssertTrue(result.writesRequestSeat)
        XCTAssertEqual(result.requestProcessID, 0, "渡したら待ち枠を空ける")
    }

    // 満了席を掴んだ直後に終わるインスタンスが、死んだ自分の pid へ所有権を戻すと、
    // 次のインスタンスがリース満了まで待たされる。
    func testReleaseDoesNotHandTheSeatToTheCallersOwnStandingRequest() {
        let result = plan(
            simpleeq_ownership_op_release(), owner: caller, ownerHoldsSeat: true,
            request: caller, requestUID: 20, requestStands: true
        )
        XCTAssertEqual(result.outcome, applied)
        XCTAssertEqual(result.ownerProcessID, 0, "自分自身へ渡さず空席にする")
        XCTAssertFalse(result.writesRequestSeat, "残った自分の要求は誰も待っていないので触らない")
    }

    func testReleaseIgnoresAnExpiredRequest() {
        let result = plan(
            simpleeq_ownership_op_release(), owner: caller, ownerHoldsSeat: true,
            request: 777, requestUID: 30, requestStands: false
        )
        XCTAssertEqual(result.ownerProcessID, 0, "応える相手が居ないので空席にする")
        XCTAssertFalse(result.writesRequestSeat)
    }

    // MARK: - renew

    // 期限を延ばすだけで所有者も要求者も動かない。変化として扱うと、通知を受けた側が renew を
    // 打ち返し、往復の速さで回り続ける。
    func testRenewNeverCountsAsAChange() {
        for (owner, request) in [(caller, UInt32(0)), (other, caller), (other, UInt32(777))] {
            let result = plan(
                simpleeq_ownership_op_renew(), owner: owner, ownerHoldsSeat: true,
                request: request, requestStands: request != 0
            )
            XCTAssertEqual(result.outcome, noChange, "owner=\(owner) request=\(request)")
            XCTAssertFalse(result.writesOwnerSeat, "owner=\(owner) request=\(request)")
            XCTAssertFalse(result.writesRequestSeat, "owner=\(owner) request=\(request)")
        }
    }

    func testRenewExtendsWhicheverLeaseTheCallerHolds() {
        let asOwner = plan(simpleeq_ownership_op_renew(), owner: caller, ownerHoldsSeat: true)
        XCTAssertTrue(asOwner.renewsOwnerLease)
        XCTAssertFalse(asOwner.renewsRequestLease)

        let asRequester = plan(
            simpleeq_ownership_op_renew(), owner: other, ownerHoldsSeat: true,
            request: caller, requestStands: true
        )
        XCTAssertFalse(asRequester.renewsOwnerLease)
        XCTAssertTrue(asRequester.renewsRequestLease)

        let asStranger = plan(simpleeq_ownership_op_renew(), owner: other, ownerHoldsSeat: true, request: 777, requestStands: true)
        XCTAssertFalse(asStranger.renewsOwnerLease, "名乗っていない側の期限は延ばさない")
        XCTAssertFalse(asStranger.renewsRequestLease)
    }

    // 自分の席が満了していても renew は通る。降りるのではなく取り直す側へ進むため。
    func testRenewExtendsTheCallersOwnSeatEvenAfterItsLeaseRanOut() {
        let result = plan(simpleeq_ownership_op_renew(), owner: caller, ownerHoldsSeat: false)
        XCTAssertTrue(result.renewsOwnerLease)
    }
}
