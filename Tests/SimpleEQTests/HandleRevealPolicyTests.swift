import XCTest

@testable import SimpleEQ

final class HandleRevealPolicyTests: XCTestCase {
    func testStaysRevealedWhileTheButtonIsDownEvenOutsideTheCanvas() {
        XCTAssertTrue(HandleRevealPolicy.staysRevealed(
            pointerButtonDown: true, pointerInsideCanvas: false, pointerOverPresetRail: false
        ))
    }

    func testStaysRevealedWhileThePointerIsInsideWithoutTheButton() {
        XCTAssertTrue(HandleRevealPolicy.staysRevealed(
            pointerButtonDown: false, pointerInsideCanvas: true, pointerOverPresetRail: false
        ))
    }

    func testStaysRevealedWhileThePointerIsOverThePresetRail() {
        XCTAssertTrue(HandleRevealPolicy.staysRevealed(
            pointerButtonDown: false, pointerInsideCanvas: false, pointerOverPresetRail: true
        ))
    }

    func testDropsOnlyWhenEveryHoldingConditionIsAbsent() {
        XCTAssertFalse(HandleRevealPolicy.staysRevealed(
            pointerButtonDown: false, pointerInsideCanvas: false, pointerOverPresetRail: false
        ))
    }

    // 押下の起点は居場所だけを見る (押下そのものを保持の理由に数えない)。
    func testThePlaceAloneDecidesWhetherAPressKeepsIt() {
        XCTAssertTrue(HandleRevealPolicy.staysRevealedAt(
            pointerInsideCanvas: true, pointerOverPresetRail: false
        ))
        XCTAssertTrue(HandleRevealPolicy.staysRevealedAt(
            pointerInsideCanvas: false, pointerOverPresetRail: true
        ))
        XCTAssertFalse(HandleRevealPolicy.staysRevealedAt(
            pointerInsideCanvas: false, pointerOverPresetRail: false
        ))
    }

    func testTheHoldRefillsWhileTheConditionsAreMet() {
        let advanced = HandleRevealPolicy.advanced(
            holdRemaining: 0, dt: 1, holdSeconds: 2, staysRevealed: true, windowIsKey: true
        )
        XCTAssertEqual(advanced.holdRemaining, 2)
        XCTAssertTrue(advanced.revealed)
    }

    func testTheHoldDrainsByTheElapsedTimeAndDropsAtZero() {
        let draining = HandleRevealPolicy.advanced(
            holdRemaining: 2, dt: 0.5, holdSeconds: 2, staysRevealed: false, windowIsKey: true
        )
        XCTAssertEqual(draining.holdRemaining, 1.5, accuracy: 1e-9)
        XCTAssertTrue(draining.revealed, "残っている間は表示を保つこと")

        let drained = HandleRevealPolicy.advanced(
            holdRemaining: 0.25, dt: 1, holdSeconds: 2, staysRevealed: false, windowIsKey: true
        )
        XCTAssertEqual(drained.holdRemaining, 0, "引き切っても負へは進まないこと")
        XCTAssertFalse(drained.revealed)
    }

    func testTheWindowOffTheFrontDropsItWithoutSpendingTheHold() {
        let advanced = HandleRevealPolicy.advanced(
            holdRemaining: 2, dt: 0, holdSeconds: 2, staysRevealed: true, windowIsKey: false
        )
        XCTAssertFalse(advanced.revealed, "保持条件を満たしていても落とすこと")
        XCTAssertEqual(advanced.holdRemaining, 0)
    }

    func testTheHoldOfZeroDropsOnTheFirstReadWithoutAHold() {
        let held = HandleRevealPolicy.advanced(
            holdRemaining: 0, dt: 0, holdSeconds: 0, staysRevealed: true, windowIsKey: true
        )
        XCTAssertTrue(held.revealed, "猶予なしでも保持条件を満たす間は保つこと")

        let left = HandleRevealPolicy.advanced(
            holdRemaining: 0, dt: 0, holdSeconds: 0, staysRevealed: false, windowIsKey: true
        )
        XCTAssertFalse(left.revealed, "猶予なしでは外れた時点で落とすこと")
    }

    func testPressRevealsOnlyForTheClickGesture() {
        XCTAssertTrue(HandleRevealPolicy.revealsOnPress(.click))
        XCTAssertFalse(HandleRevealPolicy.revealsOnPress(.longPress))
    }

    func testDefaultIsTheLongPress() {
        XCTAssertEqual(HandleRevealGesture.default, .longPress)
    }
}
