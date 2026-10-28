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

    private func line(delay: Int) -> PresentationDelayLine {
        PresentationDelayLine(delayFrames: delay, channels: channels)
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

    func testAZeroDelayPassesTheInputThrough() {
        let (input, output) = run(line(delay: 0), blockLengths: [16, 5])

        XCTAssertEqual(output, input)
    }

    func testANegativeInitialDelayBecomesZero() {
        XCTAssertEqual(line(delay: -5).delayFrames, 0)
    }

    // MARK: - 純粋関数

    private let rate = AudioConfig.baseSampleRate

    private func declared(_ device: UInt32, _ stream: UInt32 = 0, _ safety: UInt32 = 0, deviceRate: Double? = nil) -> Int {
        PresentationDelayLine.declaredFrames(
            deviceLatency: device, streamLatency: stream, safetyOffset: safety,
            deviceSampleRate: deviceRate ?? rate, appliedSampleRate: rate
        )
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

    func testDelayFramesIsTheDeclaredValueAsIs() {
        XCTAssertEqual(PresentationDelayLine.delayFrames(declaredFrames: 5000, appliedSampleRate: rate), 5000)
        XCTAssertEqual(PresentationDelayLine.delayFrames(declaredFrames: 0, appliedSampleRate: rate), 0)
    }

    func testDelayFramesNeverGoesBelowZero() {
        XCTAssertEqual(PresentationDelayLine.delayFrames(declaredFrames: -1, appliedSampleRate: rate), 0)
    }

    func testDelayFramesIsCappedAtTheDesignBound() {
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * rate).rounded(.down))
        XCTAssertEqual(PresentationDelayLine.delayFrames(declaredFrames: cap, appliedSampleRate: rate), cap)
        XCTAssertEqual(PresentationDelayLine.delayFrames(declaredFrames: cap * 2, appliedSampleRate: rate), cap)
    }
}
