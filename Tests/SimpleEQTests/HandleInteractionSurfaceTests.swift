import XCTest

@testable import SimpleEQ

final class EQPlotCursorTests: XCTestCase {
    private let onHandle = EQLayout.handleHitTolerance / 2
    private let offHandle = EQLayout.handleHitTolerance * 2

    // 掴む操作 (ドラッグ・ダブルクリックでのリセット) はすべてこの判定を読む。
    func testHandleIsGrabbableOnlyWhileShown() {
        XCTAssertTrue(EQPlotCursor.grabbable(handlesRevealed: true, distanceToHandle: onHandle))
        XCTAssertFalse(
            EQPlotCursor.grabbable(handlesRevealed: false, distanceToHandle: onHandle),
            "見えていない間は、その高さでも掴ませないこと"
        )
        XCTAssertFalse(EQPlotCursor.grabbable(handlesRevealed: true, distanceToHandle: offHandle))
    }

    func testHandleCursorOnlyWhileHandleIsVisible() {
        XCTAssertEqual(
            EQPlotCursor.kind(processingInEffect: true, handlesRevealed: true, distanceToHandle: onHandle),
            .grabHandle
        )
        XCTAssertEqual(
            EQPlotCursor.kind(processingInEffect: true, handlesRevealed: false, distanceToHandle: onHandle),
            .pressToReveal,
            "掴めない間は、その高さでも掴めるカーソルを出さないこと"
        )
    }

    func testAwayFromHandleAsksForAPress() {
        for visible in [true, false] {
            XCTAssertEqual(
                EQPlotCursor.kind(processingInEffect: true, handlesRevealed: visible, distanceToHandle: offHandle),
                .pressToReveal
            )
        }
    }

    func testWithoutEffectFallsBackToArrow() {
        XCTAssertEqual(
            EQPlotCursor.kind(processingInEffect: false, handlesRevealed: true, distanceToHandle: onHandle),
            .arrow
        )
    }
}
