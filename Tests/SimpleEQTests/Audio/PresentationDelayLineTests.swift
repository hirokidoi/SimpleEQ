import XCTest
@testable import SimpleEQ

final class PresentationDelayLineTests: XCTestCase {
    private let channels = 2

    /// 左に 1 始まりの連番、右にその負を流し、周期ごとの長さを変えながら通した出力を返す。
    private func run(_ line: PresentationDelayLine, blockLengths: [Int]) -> (input: [Float], output: [Float]) {
        var input: [Float] = []
        var output: [Float] = []
        var next: Float = 1
        for length in blockLengths {
            var block: [Float] = []
            for _ in 0..<length {
                block.append(next)
                block.append(-next)
                next += 1
            }
            var delayed = [Float](repeating: .nan, count: block.count)
            block.withUnsafeBufferPointer { source in
                delayed.withUnsafeMutableBufferPointer {
                    line.process(source.baseAddress!, frames: length, into: $0.baseAddress!)
                }
            }
            input += block
            output += delayed
        }
        return (input, output)
    }

    private func line(delay: Int, capacity: Int? = nil) -> PresentationDelayLine {
        PresentationDelayLine(capacityFrames: capacity ?? delay, delayFrames: delay, channels: channels)
    }

    func testOutputIsTheInputExactlyTheDelayLater() {
        let delay = 37
        let (input, output) = run(line(delay: delay), blockLengths: [64, 64, 64])

        XCTAssertEqual(Array(output.prefix(delay * channels)), [Float](repeating: 0, count: delay * channels))
        XCTAssertEqual(Array(output.dropFirst(delay * channels)), Array(input.prefix(input.count - delay * channels)))
    }

    func testTheDelayHoldsWhileTheCycleLengthVaries() {
        let delay = 50
        let (input, output) = run(line(delay: delay), blockLengths: [1, 7, 64, 3, 128, 20])

        XCTAssertEqual(Array(output.dropFirst(delay * channels)), Array(input.prefix(input.count - delay * channels)))
    }

    func testTheDelayHoldsWhenTheCapacityExceedsIt() {
        let delay = 20
        let (input, output) = run(line(delay: delay, capacity: 200), blockLengths: [64, 5, 64])

        XCTAssertEqual(Array(output.prefix(delay * channels)), [Float](repeating: 0, count: delay * channels))
        XCTAssertEqual(Array(output.dropFirst(delay * channels)), Array(input.prefix(input.count - delay * channels)))
    }

    func testAZeroDelayPassesTheInputThrough() {
        let (input, output) = run(line(delay: 0, capacity: 30), blockLengths: [16, 5])

        XCTAssertEqual(output, input)
    }

    func testTheOutputFollowsTheInputDelayedByTheNewValueAfterAMidStreamChange() {
        for (before, after) in [(10, 40), (40, 10)] {
            let target = line(delay: before, capacity: 64)
            let (input1, output1) = run(target, blockLengths: [64, 64])
            XCTAssertEqual(Array(output1.dropFirst(before * channels)), Array(input1.prefix(input1.count - before * channels)))

            target.setDelayFrames(after)
            XCTAssertEqual(target.delayFrames, after)
            // run は 1 始まりの連番を作り直すため、続きの入力を自前で流す。
            var next = Float(input1.count / channels + 1)
            var input2: [Float] = []
            var output2 = [Float](repeating: .nan, count: 32 * channels)
            for _ in 0..<32 {
                input2.append(next)
                input2.append(-next)
                next += 1
            }
            input2.withUnsafeBufferPointer { source in
                output2.withUnsafeMutableBufferPointer {
                    target.process(source.baseAddress!, frames: 32, into: $0.baseAddress!)
                }
            }
            let all = input1 + input2
            let expected = Array(all[(all.count - 32 * channels - after * channels)..<(all.count - after * channels)])
            XCTAssertEqual(output2, expected, "遅延 \(before) -> \(after)")
        }
    }

    func testLengtheningTheDelayExposesInputThatPassedWhileTheDelayWasZero() {
        let target = line(delay: 0, capacity: 100)
        let (input1, _) = run(target, blockLengths: [50])

        target.setDelayFrames(30)
        var probe = [Float](repeating: 0, count: 2 * channels)
        var output = [Float](repeating: .nan, count: 2 * channels)
        probe.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer {
                target.process(UnsafePointer(source.baseAddress!), frames: 2, into: $0.baseAddress!)
            }
        }
        let expected = Array(input1[(input1.count - 30 * channels)..<(input1.count - 28 * channels)])
        XCTAssertEqual(output, expected)
    }

    func testSetDelayFramesClampsToTheCapacityAndZero() {
        let target = line(delay: 5, capacity: 50)

        target.setDelayFrames(500)
        XCTAssertEqual(target.delayFrames, 50)
        target.setDelayFrames(-3)
        XCTAssertEqual(target.delayFrames, 0)
    }

    func testTheInitialDelayIsClampedToTheCapacity() {
        XCTAssertEqual(line(delay: 80, capacity: 50).delayFrames, 50)
    }

    // MARK: - 純粋関数

    private let rate = AudioConfig.baseSampleRate

    private func declared(_ device: UInt32, _ stream: UInt32 = 0, _ safety: UInt32 = 0, deviceRate: Double? = nil) -> Int {
        PresentationDelayLine.declaredFrames(
            deviceLatency: device, streamLatency: stream, safetyOffset: safety,
            deviceSampleRate: deviceRate ?? rate, appliedSampleRate: rate
        )
    }

    private func frames(_ milliseconds: Int) -> Int {
        Int((Double(milliseconds) / 1000 * rate).rounded())
    }

    func testDeclaredFramesIsTheSumOfThreeTermsRegardlessOfTheBreakdown() {
        XCTAssertEqual(declared(1000), 1000)
        XCTAssertEqual(declared(700, 200, 100), 1000)
        XCTAssertEqual(declared(0, 0, 0), 0)
    }

    func testEqualRealLatencyProducesTheSameDeclaredFramesRegardlessOfDeviceSampleRate() {
        let otherRate: Double = rate == 44100 ? 48000 : 44100
        // 整数秒にしてどちらのレートでも割り切れるようにする。
        let seconds = 1.0
        let atOtherRate = declared(UInt32(seconds * otherRate), deviceRate: otherRate)
        let atAppliedRate = declared(UInt32(seconds * rate))
        XCTAssertGreaterThan(atAppliedRate, 0)
        XCTAssertEqual(atOtherRate, atAppliedRate)
    }

    func testDelayFramesIsTheDeclaredPlusTheOffset() {
        let base = 5000
        XCTAssertEqual(
            PresentationDelayLine.delayFrames(declaredFrames: base, offsetMilliseconds: 120, appliedSampleRate: rate),
            base + frames(120)
        )
        XCTAssertEqual(
            PresentationDelayLine.delayFrames(declaredFrames: base, offsetMilliseconds: -50, appliedSampleRate: rate),
            base + frames(-50)
        )
    }

    func testDelayFramesNeverGoesBelowZero() {
        let lowest = PresentationDelayLine.userOffsetMillisecondsRange.lowerBound
        XCTAssertEqual(PresentationDelayLine.delayFrames(declaredFrames: 0, offsetMilliseconds: lowest, appliedSampleRate: rate), 0)
        XCTAssertEqual(
            PresentationDelayLine.delayFrames(declaredFrames: frames(-lowest) / 2, offsetMilliseconds: lowest, appliedSampleRate: rate),
            0
        )
    }

    func testDelayFramesIsCappedAtTheDesignBound() {
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * rate).rounded(.down))
        let highest = PresentationDelayLine.userOffsetMillisecondsRange.upperBound
        XCTAssertEqual(
            PresentationDelayLine.delayFrames(declaredFrames: cap * 2, offsetMilliseconds: highest, appliedSampleRate: rate),
            cap
        )
    }

    func testCapacityIsTheDeclaredPlusTheUpperOffset() {
        let highest = PresentationDelayLine.userOffsetMillisecondsRange.upperBound
        XCTAssertEqual(
            PresentationDelayLine.capacityFrames(declaredFrames: 5000, appliedSampleRate: rate),
            5000 + frames(highest)
        )
        XCTAssertEqual(PresentationDelayLine.capacityFrames(declaredFrames: 0, appliedSampleRate: rate), frames(highest))
    }

    func testCapacityIsCappedAtTheDesignBound() {
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * rate).rounded(.down))
        XCTAssertEqual(PresentationDelayLine.capacityFrames(declaredFrames: cap * 2, appliedSampleRate: rate), cap)
    }

    func testTheDelayNeverExceedsTheCapacityForAnyOffsetInTheRange() {
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * rate).rounded(.down))
        let range = PresentationDelayLine.userOffsetMillisecondsRange
        for declaredFrames in [0, 1, 5000, cap - 1, cap, cap * 2] {
            let capacity = PresentationDelayLine.capacityFrames(declaredFrames: declaredFrames, appliedSampleRate: rate)
            XCTAssertGreaterThan(capacity, 0)
            for offset in stride(from: range.lowerBound, through: range.upperBound, by: PresentationDelayLine.userOffsetMillisecondsStep) {
                XCTAssertLessThanOrEqual(
                    PresentationDelayLine.delayFrames(declaredFrames: declaredFrames, offsetMilliseconds: offset, appliedSampleRate: rate),
                    capacity, "declared \(declaredFrames) offset \(offset)"
                )
            }
        }
    }

    func testNormalizedOffsetClampsToTheRange() {
        let range = PresentationDelayLine.userOffsetMillisecondsRange
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(range.upperBound + 1000), range.upperBound)
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(range.lowerBound - 1000), range.lowerBound)
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(range.lowerBound), range.lowerBound)
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(range.upperBound), range.upperBound)
    }

    func testNormalizedOffsetRoundsToTheNearestStep() {
        let step = PresentationDelayLine.userOffsetMillisecondsStep
        let base = 2 * step
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(base + 1), base)
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(base + step - 1), base + step)
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(-base - 1), -base)
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(base), base)
    }

    func testTheDefaultOffsetIsInsideTheRangeAndOnTheStepGrid() {
        let value = PresentationDelayLine.userOffsetMillisecondsDefault
        XCTAssertTrue(PresentationDelayLine.userOffsetMillisecondsRange.contains(value))
        XCTAssertEqual(PresentationDelayLine.normalizedUserOffsetMilliseconds(value), value)
    }
}
