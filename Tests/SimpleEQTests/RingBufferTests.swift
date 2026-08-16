import Dispatch
import XCTest
@testable import SimpleEQ

final class RingBufferTests: XCTestCase {
    private func makeFrames(_ values: [Float], channels: Int) -> [Float] {
        values.flatMap { v in Array(repeating: v, count: channels) }
    }

    func testWriteThenReadRoundTrip() {
        let channels = 2
        let ring = RingBuffer(capacityFrames: 8, channels: channels)
        let src = makeFrames([1, 2, 3], channels: channels)
        var dst = [Float](repeating: -1, count: 3 * channels)

        src.withUnsafeBufferPointer { s in
            ring.write(s.baseAddress!, frames: 3)
        }
        let got = dst.withUnsafeMutableBufferPointer { d in
            ring.read(into: d.baseAddress!, frames: 3)
        }

        XCTAssertEqual(got, 3)
        XCTAssertEqual(dst, src)
    }

    func testReadWhenEmptyFillsSilence() {
        let ring = RingBuffer(capacityFrames: 8, channels: 2)
        var dst = [Float](repeating: 9, count: 4 * 2)

        let got = dst.withUnsafeMutableBufferPointer { d in
            ring.read(into: d.baseAddress!, frames: 4)
        }

        XCTAssertEqual(got, 0)
        XCTAssertEqual(dst, [Float](repeating: 0, count: 8))
    }

    func testWriteBeyondCapacityIsDropped() {
        let channels = 1
        let ring = RingBuffer(capacityFrames: 4, channels: channels)
        let src = makeFrames([1, 2, 3, 4, 5], channels: channels)

        src.withUnsafeBufferPointer { s in
            ring.write(s.baseAddress!, frames: 5)
        }

        XCTAssertEqual(ring.availableRead, 3)
    }

    func testWrapAroundPreservesOrder() {
        let channels = 1
        let ring = RingBuffer(capacityFrames: 4, channels: channels)

        // 折返しが発生するように write/read を繰り返す
        for round in 0..<3 {
            let src = makeFrames([Float(round * 10 + 1), Float(round * 10 + 2)], channels: channels)
            src.withUnsafeBufferPointer { s in ring.write(s.baseAddress!, frames: 2) }

            var dst = [Float](repeating: -1, count: 2)
            let got = dst.withUnsafeMutableBufferPointer { d in ring.read(into: d.baseAddress!, frames: 2) }
            XCTAssertEqual(got, 2)
            XCTAssertEqual(dst, src)
        }
    }

    // MARK: - 並行性 (SPSC の writeFrame/readFrame アトミック化の回帰テスト)

    /// producer/consumer を実スレッドで並行に走らせ、reader が観測する値列が単調増加である
    /// ことを検証する恒久テスト。`swift test --sanitize=thread` 実行時の TSan 警告 0 件を回帰ゲートとして担保する。
    func testConcurrentWriteReadIsRaceFreeUnderThreadSanitizer() {
        let channels = 1
        let iterations = 8192
        let ring = RingBuffer(capacityFrames: 256, channels: channels)

        // busy-wait に実時間の上限 (maxWait) を設け、デッドロックが混入しても無期限ハングにしない。
        let maxWait: TimeInterval = 10
        let deadline = Date().addingTimeInterval(maxWait)

        let writerQueue = DispatchQueue(label: "com.simpleeq.tests.ringbuffer.writer")
        let writerDone = DispatchSemaphore(value: 0)
        let writerTimedOut = Recorded<Bool>(false)
        writerQueue.async {
            writeLoop: for i in 0..<iterations {
                var value = Float(i)
                // 空きができるまで待ってから書く (deadline 超過で打ち切る)。
                while ring.availableWrite < 1 {
                    if Date() > deadline {
                        writerTimedOut.update { $0 = true }
                        break writeLoop
                    }
                }
                withUnsafePointer(to: &value) { ptr in
                    ring.write(ptr, frames: 1)
                }
            }
            writerDone.signal()
        }

        var observed: [Float] = []
        observed.reserveCapacity(iterations)
        var dst: Float = -1
        var readerTimedOut = false
        while observed.count < iterations {
            if Date() > deadline {
                readerTimedOut = true
                break
            }
            let got = withUnsafeMutablePointer(to: &dst) { ptr in ring.read(into: ptr, frames: 1) }
            if got == 1 {
                observed.append(dst)
            }
        }
        _ = writerDone.wait(timeout: .now() + maxWait)

        guard !writerTimedOut.value, !readerTimedOut else {
            XCTFail("producer/consumer が \(maxWait) 秒以内に完了しなかった (RingBuffer のデッドロック/ハングの疑い)")
            return
        }

        XCTAssertEqual(observed.count, iterations)
        for i in 1..<observed.count {
            XCTAssertGreaterThan(
                observed[i], observed[i - 1],
                "reader が観測する値は単調増加であるはず (逆転・重複はレースの兆候)"
            )
        }
    }
}
