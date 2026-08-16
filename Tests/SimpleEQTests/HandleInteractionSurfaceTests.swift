import XCTest

@testable import SimpleEQ

final class EQPlotCursorTests: XCTestCase {
    private let onHandle = EQLayout.handleHitTolerance / 2
    private let offHandle = EQLayout.handleHitTolerance * 2

    func testHandleCursorOnlyWhileHandleIsVisible() {
        XCTAssertEqual(
            EQPlotCursor.kind(processingInEffect: true, handleGrabbable: true, distanceToHandle: onHandle),
            .grabHandle
        )
        XCTAssertEqual(
            EQPlotCursor.kind(processingInEffect: true, handleGrabbable: false, distanceToHandle: onHandle),
            .clickToReveal,
            "掴めない間は、その高さでも掴めるカーソルを出さないこと"
        )
    }

    func testAwayFromHandleAsksForAClick() {
        for visible in [true, false] {
            XCTAssertEqual(
                EQPlotCursor.kind(processingInEffect: true, handleGrabbable: visible, distanceToHandle: offHandle),
                .clickToReveal
            )
        }
    }

    func testWithoutEffectFallsBackToArrow() {
        XCTAssertEqual(
            EQPlotCursor.kind(processingInEffect: false, handleGrabbable: true, distanceToHandle: onHandle),
            .arrow
        )
    }
}
