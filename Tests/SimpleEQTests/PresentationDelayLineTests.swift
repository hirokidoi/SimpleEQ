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

    func testResultIsZeroAtOrBelowThePerceptualLead() {
        let rate = AudioConfig.baseSampleRate
        let lead = UInt32((PresentationDelayLine.perceptualLeadSeconds * rate).rounded())
        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(
                deviceLatency: lead, streamLatency: 0, safetyOffset: 0, deviceSampleRate: rate, appliedSampleRate: rate
            ),
            0, "申告値が前倒し量ちょうどなら 0"
        )
        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(
                deviceLatency: lead / 2, streamLatency: 0, safetyOffset: 0, deviceSampleRate: rate, appliedSampleRate: rate
            ),
            0, "申告値が前倒し量未満でも 0"
        )
    }

    func testResultIsTheAmountByWhichTheDeclaredTotalExceedsTheLead() {
        let rate = AudioConfig.baseSampleRate
        let lead = Int((PresentationDelayLine.perceptualLeadSeconds * rate).rounded())
        let k = 1000
        let total = UInt32(lead + k)

        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(
                deviceLatency: total, streamLatency: 0, safetyOffset: 0, deviceSampleRate: rate, appliedSampleRate: rate
            ),
            k
        )
        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(
                deviceLatency: total - 300, streamLatency: 200, safetyOffset: 100, deviceSampleRate: rate, appliedSampleRate: rate
            ),
            k, "3 項の内訳によらず合計だけで結果が決まる"
        )
    }

    func testEqualRealLatencyProducesTheSameResultRegardlessOfDeviceSampleRate() {
        let appliedRate = AudioConfig.baseSampleRate
        let otherRate: Double = appliedRate == 44100 ? 48000 : 44100
        // 整数秒にしてどちらのレートでも割り切れるようにする。
        let seconds = PresentationDelayLine.perceptualLeadSeconds.rounded(.up) + 1
        let atOtherRate = PresentationDelayLine.presentationDelayFrames(
            deviceLatency: UInt32(seconds * otherRate), streamLatency: 0, safetyOffset: 0,
            deviceSampleRate: otherRate, appliedSampleRate: appliedRate
        )
        let atAppliedRateItself = PresentationDelayLine.presentationDelayFrames(
            deviceLatency: UInt32(seconds * appliedRate), streamLatency: 0, safetyOffset: 0,
            deviceSampleRate: appliedRate, appliedSampleRate: appliedRate
        )
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * appliedRate).rounded(.down))
        XCTAssertGreaterThan(atAppliedRateItself, 0, "前提: 前倒しで 0 に潰れていない")
        XCTAssertLessThan(atAppliedRateItself, cap, "前提: 上限で頭打ちになっていない")
        XCTAssertEqual(atOtherRate, atAppliedRateItself, "同じ実時間の申告値は出力先のレートによらず同じ結果になる")
    }

    func testResultIsCappedAtTheDesignBound() {
        let rate = AudioConfig.baseSampleRate
        let cap = Int((PresentationDelayLine.maxPresentationDelaySeconds * rate).rounded(.down))
        XCTAssertEqual(
            PresentationDelayLine.presentationDelayFrames(
                deviceLatency: 0, streamLatency: UInt32(cap * 2), safetyOffset: 0, deviceSampleRate: rate, appliedSampleRate: rate
            ),
            cap
        )
    }
}
