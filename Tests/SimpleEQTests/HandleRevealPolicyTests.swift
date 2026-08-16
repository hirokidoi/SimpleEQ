import XCTest

@testable import SimpleEQ

final class HandleRevealPolicyTests: XCTestCase {
    func testStaysRevealedWhileTheButtonIsDownEvenOutsideTheCanvas() {
        XCTAssertTrue(HandleRevealPolicy.staysRevealed(pointerButtonDown: true, pointerInsideCanvas: false))
    }

    func testStaysRevealedWhileThePointerIsInsideWithoutTheButton() {
        XCTAssertTrue(HandleRevealPolicy.staysRevealed(pointerButtonDown: false, pointerInsideCanvas: true))
    }

    func testDropsOnlyWhenTheButtonIsUpAndThePointerIsOutside() {
        XCTAssertFalse(HandleRevealPolicy.staysRevealed(pointerButtonDown: false, pointerInsideCanvas: false))
    }
}
