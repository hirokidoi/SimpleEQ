import XCTest

@testable import SimpleEQ

final class ClickSequencePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private let origin = CGPoint(x: 100, y: 100)

    private func startsNew(after seconds: TimeInterval, movedBy drift: CGFloat) -> Bool {
        ClickSequencePolicy.startsNewSequence(
            now: t0.addingTimeInterval(seconds), location: CGPoint(x: origin.x + drift, y: origin.y),
            lastPressAt: t0, lastPressLocation: origin, interval: 0.5, maxDrift: 4
        )
    }

    func testFirstPressAlwaysStartsASequence() {
        XCTAssertTrue(
            ClickSequencePolicy.startsNewSequence(
                now: t0, location: origin, lastPressAt: nil, lastPressLocation: nil, interval: 0.5, maxDrift: 4
            )
        )
    }

    func testPressCloseInTimeAndPlaceContinuesTheSequence() {
        XCTAssertFalse(startsNew(after: 0.4, movedBy: 2))
    }

    func testPressAfterTheIntervalStartsANewSequence() {
        XCTAssertTrue(startsNew(after: 0.6, movedBy: 0))
    }

    // 離れた位置での押下まで同じ列に含めると、直前のクリックの判定を別の場所が引き継いでしまう。
    func testPressFarFromThePreviousOneStartsANewSequence() {
        XCTAssertTrue(startsNew(after: 0.1, movedBy: 20))
    }
}
