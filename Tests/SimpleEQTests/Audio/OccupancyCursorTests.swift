import XCTest
@testable import SimpleEQ

/// 読み口 (書き込みカウンタ・世代・ペイロード) を 1 回の読み出しごとに受け取る境界を確かめる。
final class OccupancyCursorTests: XCTestCase {
    private let sampleRate = AudioConfig.appliedSampleRate

    private func makeCursor(ringFrames: Int, primingEnabled: Bool, writerBlockFrames: Int = 256) -> OccupancyCursor {
        OccupancyCursor(
            ringFrames: ringFrames, channels: 1, primingEnabled: primingEnabled,
            initialWriterBlockFrames: writerBlockFrames, appliedSampleRate: sampleRate, metrics: AudioRuntimeMetrics()
        )
    }

    // 継ぎ目の包絡は 0 から上がるので、値そのものでなく符号で「どのペイロードを読んだか」を見る。
    func testEachReadTakesItsSamplesFromThePayloadHandedToIt() {
        let frames = 32
        let cursor = makeCursor(ringFrames: frames * 4, primingEnabled: false)
        let positive = [Float](repeating: 1, count: frames * 4)
        let negative = [Float](repeating: -1, count: frames * 4)
        var dst = [Float](repeating: 0, count: frames)

        let firstGot = positive.withUnsafeBufferPointer { payload in
            dst.withUnsafeMutableBufferPointer {
                cursor.read(into: $0.baseAddress!, frames: frames, writeCounter: UInt64(frames), epoch: 0, payload: payload.baseAddress)
            }
        }
        XCTAssertEqual(firstGot, frames)
        XCTAssertTrue(dst.contains { $0 > 0 } && !dst.contains { $0 < 0 }, "1 回目は 1 回目に渡したペイロードを読む")

        let secondGot = negative.withUnsafeBufferPointer { payload in
            dst.withUnsafeMutableBufferPointer {
                cursor.read(into: $0.baseAddress!, frames: frames, writeCounter: UInt64(frames * 2), epoch: 0, payload: payload.baseAddress)
            }
        }
        XCTAssertEqual(secondGot, frames)
        XCTAssertTrue(dst.contains { $0 < 0 } && !dst.contains { $0 > 0 }, "2 回目は 2 回目に渡したペイロードを読む")
    }

    func testAReadWithoutAPayloadDeliversNothingEvenWhenTheCounterHasAdvanced() {
        let frames = 32
        let cursor = makeCursor(ringFrames: frames * 4, primingEnabled: false)
        var dst = [Float](repeating: -1, count: frames)

        let got = dst.withUnsafeMutableBufferPointer {
            cursor.read(into: $0.baseAddress!, frames: frames, writeCounter: UInt64(frames), epoch: 0, payload: nil)
        }

        XCTAssertEqual(got, 0)
    }

    // 世代の変化だけを変えた対で見る。変化が無ければ同じ超過でも保留時間の対象に留まる。
    func testAChangeInTheEpochHandedToTheReadIsTreatedAsADiscontinuity() {
        let writerBlockFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: writerBlockFrames, sampleRate: sampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: sampleRate
        )
        let backlog = maxOccupancy + target
        let payload = [Float](repeating: 0, count: backlog * 4)

        func resyncCount(secondEpoch: UInt32) -> UInt64 {
            let cursor = makeCursor(ringFrames: backlog * 4, primingEnabled: true, writerBlockFrames: writerBlockFrames)
            var dst = [Float](repeating: 0, count: writerBlockFrames)
            payload.withUnsafeBufferPointer { ring in
                dst.withUnsafeMutableBufferPointer {
                    _ = cursor.read(into: $0.baseAddress!, frames: writerBlockFrames, writeCounter: 0, epoch: 1, payload: ring.baseAddress)
                    _ = cursor.read(
                        into: $0.baseAddress!, frames: writerBlockFrames,
                        writeCounter: UInt64(backlog), epoch: secondEpoch, payload: ring.baseAddress
                    )
                }
            }
            return cursor.metrics.resyncEventCount
        }

        XCTAssertEqual(resyncCount(secondEpoch: 2), 1, "世代が変われば即時に再同期する")
        XCTAssertEqual(resyncCount(secondEpoch: 1), 0, "世代が同じなら即時には再同期しない")
    }
}
