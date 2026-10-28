import XCTest
@testable import SimpleEQ

final class DriverPresentationLatencyTests: XCTestCase {
    func testTheAppPathFramesMatchTheFixedMillisecondsAtEveryRate() {
        for rate in TestSampleRates.all {
            let frames = DriverPresentationLatencyPolicy.appPathFrames(appliedSampleRate: rate)
            let milliseconds = Double(frames) / rate * 1000

            XCTAssertEqual(
                milliseconds, DriverPresentationLatencyPolicy.appPathMilliseconds,
                accuracy: 0.5 / rate * 1000, "レート \(rate)"
            )
        }
        XCTAssertNotEqual(
            DriverPresentationLatencyPolicy.appPathFrames(appliedSampleRate: 44100),
            DriverPresentationLatencyPolicy.appPathFrames(appliedSampleRate: 96000),
            "前提: レートが違えばフレーム数が変わる"
        )
    }

    func testTheTotalIsTheOutputDeclarationPlusTheAppPath() {
        let rate = 48000.0
        let total = DriverPresentationLatencyPolicy.totalFrames(outputDeclaredFrames: 1000, avSyncOffsetMilliseconds: DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault, appliedSampleRate: rate)

        XCTAssertEqual(total, 1000 + DriverPresentationLatencyPolicy.appPathFrames(appliedSampleRate: rate))
    }

    func testAnUnreadableOutputDeclarationCountsAsZero() {
        let withNil = DriverPresentationLatencyPolicy.totalFrames(outputDeclaredFrames: nil, avSyncOffsetMilliseconds: DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault, appliedSampleRate: 48000)
        let withZero = DriverPresentationLatencyPolicy.totalFrames(outputDeclaredFrames: 0, avSyncOffsetMilliseconds: DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault, appliedSampleRate: 48000)

        XCTAssertEqual(withNil, withZero)
        XCTAssertEqual(withNil, DriverPresentationLatencyPolicy.appPathFrames(appliedSampleRate: 48000))
    }

    func testTheTotalStaysWithinTheRangeTheDriverAccepts() {
        let huge = DriverPresentationLatencyPolicy.totalFrames(outputDeclaredFrames: Int(UInt32.max), avSyncOffsetMilliseconds: DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault, appliedSampleRate: 48000)
        let negative = DriverPresentationLatencyPolicy.totalFrames(outputDeclaredFrames: -1_000_000, avSyncOffsetMilliseconds: DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault, appliedSampleRate: 48000)

        XCTAssertEqual(huge, Int(UInt32.max))
        XCTAssertEqual(negative, 0)
    }

    // MARK: - 映像との同期補正

    private typealias Policy = DriverPresentationLatencyPolicy

    func testTheTotalIsTheDeclarationPlusTheAppPathPlusTheOffset() {
        for rate in TestSampleRates.all {
            for offset in [120, -50] {
                let total = Policy.totalFrames(outputDeclaredFrames: 5000, avSyncOffsetMilliseconds: offset, appliedSampleRate: rate)
                let expected = 5000
                    + Policy.appPathFrames(appliedSampleRate: rate)
                    + Policy.frames(milliseconds: Double(offset), appliedSampleRate: rate)

                XCTAssertEqual(total, expected, "レート \(rate) 補正 \(offset)")
                XCTAssertNotEqual(
                    total,
                    Policy.totalFrames(outputDeclaredFrames: 5000, avSyncOffsetMilliseconds: Policy.avSyncOffsetMillisecondsDefault, appliedSampleRate: rate)
                )
            }
        }
    }

    func testTheOffsetAtTheLowerBoundNeverMakesTheTotalNegative() {
        XCTAssertLessThan(
            Policy.appPathFrames(appliedSampleRate: 48000)
                + Policy.frames(milliseconds: Double(Policy.avSyncOffsetMillisecondsRange.lowerBound), appliedSampleRate: 48000),
            0
        )
        let total = Policy.totalFrames(
            outputDeclaredFrames: 0, avSyncOffsetMilliseconds: Policy.avSyncOffsetMillisecondsRange.lowerBound, appliedSampleRate: 48000
        )

        XCTAssertEqual(total, 0)
    }

    func testTheOffsetIsAddedEvenWhenTheOutputDeclarationIsUnreadable() {
        let offset = Policy.avSyncOffsetMillisecondsRange.upperBound
        let total = Policy.totalFrames(outputDeclaredFrames: nil, avSyncOffsetMilliseconds: offset, appliedSampleRate: 48000)

        XCTAssertEqual(
            total,
            Policy.appPathFrames(appliedSampleRate: 48000) + Policy.frames(milliseconds: Double(offset), appliedSampleRate: 48000)
        )
    }

    func testNormalizedOffsetClampsToTheRange() {
        let range = Policy.avSyncOffsetMillisecondsRange
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(range.upperBound + 1000), range.upperBound)
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(range.lowerBound - 1000), range.lowerBound)
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(range.lowerBound), range.lowerBound)
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(range.upperBound), range.upperBound)
    }

    func testNormalizedOffsetRoundsToTheNearestStep() {
        let step = Policy.avSyncOffsetMillisecondsStep
        let base = 2 * step
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(base + 1), base)
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(base + step - 1), base + step)
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(-base - 1), -base)
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(base), base)
    }

    func testTheDefaultOffsetIsInsideTheRangeAndOnTheStepGrid() {
        let value = Policy.avSyncOffsetMillisecondsDefault
        XCTAssertTrue(Policy.avSyncOffsetMillisecondsRange.contains(value))
        XCTAssertEqual(Policy.normalizedAVSyncOffsetMilliseconds(value), value)
    }
}
