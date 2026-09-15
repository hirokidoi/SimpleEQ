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

    func testOutputIsTheInputExactlyTheDelayLater() {
        let delay = 37
        let (input, output) = run(PresentationDelayLine(delayFrames: delay, channels: channels), blockLengths: [64, 64, 64])

        XCTAssertEqual(Array(output.prefix(delay * channels)), [Float](repeating: 0, count: delay * channels))
        XCTAssertEqual(Array(output.dropFirst(delay * channels)), Array(input.prefix(input.count - delay * channels)))
    }

    func testTheDelayHoldsWhileTheCycleLengthVaries() {
        let delay = 50
        let (input, output) = run(PresentationDelayLine(delayFrames: delay, channels: channels), blockLengths: [1, 7, 64, 3, 128, 20])

        XCTAssertEqual(Array(output.dropFirst(delay * channels)), Array(input.prefix(input.count - delay * channels)))
    }

    func testAZeroDelayPassesTheInputThrough() {
        let (input, output) = run(PresentationDelayLine(delayFrames: 0, channels: channels), blockLengths: [16, 5])

        XCTAssertEqual(output, input)
    }

    func testTheDeclaredDelaysAddUpAndAreCappedAtTheDesignBound() {
        let rate: Double = 44100
        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(deviceLatency: 88, streamLatency: 88_200, safetyOffset: 320, sampleRate: rate),
            88 + 88_200 + 320
        )
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * rate).rounded(.down))
        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(deviceLatency: 0, streamLatency: UInt32(cap + 1), safetyOffset: 0, sampleRate: rate),
            cap
        )
    }
}
