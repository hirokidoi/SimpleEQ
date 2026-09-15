import CoreAudio
import XCTest
@testable import SimpleEQ

/// 取り込み経路のリングを、実メモリ・実アトミックのまま書き手と読み手の両側から駆動する。
final class CaptureRingTests: XCTestCase {
    private let sampleRate: Double = 44100
    private let channels = Int(AudioConfig.channels)

    // MARK: - 容量

    func testCapacityIsDerivedFromTheOccupancyBoundsAtTheLargestBlocks() {
        for rate in TestSampleRates.all {
            let block = AudioConfig.maxRenderFrames
            let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: block, clientRequestFrames: block, sampleRate: rate)
            let ceiling = OccupancyPolicy.maxOccupancyFrames(targetOccupancyFrames: target, writerBlockFrames: block, sampleRate: rate)
            XCTAssertEqual(CaptureRing.capacityFrames(sampleRate: rate), ceiling + block, "rate=\(rate)")
            XCTAssertEqual(CaptureRing(sampleRate: rate).capacityFrames, CaptureRing.capacityFrames(sampleRate: rate), "rate=\(rate)")
        }
    }

    func testAWriteAfterTheStartMarkIsReportedAsReceived() {
        let ring = CaptureRing(sampleRate: sampleRate)
        ring.markWriterStarting()
        XCTAssertFalse(ring.hasReceivedWriteSinceStart)

        write(ring, frames: 16)
        XCTAssertTrue(ring.hasReceivedWriteSinceStart)

        ring.markWriterStarting()
        XCTAssertFalse(ring.hasReceivedWriteSinceStart, "開始の印を付け直せば、次の書き込みまでは届いていない")
    }

    // MARK: - 占有量制御

    private func write(_ ring: CaptureRing, frames: Int, value: Float = 0.25) {
        let block = [Float](repeating: value, count: frames * channels)
        block.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
    }

    @discardableResult
    private func read(_ ring: CaptureRing, frames: Int) -> Int {
        var dst = [Float](repeating: 0, count: frames * channels)
        return dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: frames) }
    }

    /// 書き手 512 frames に対し読み手が 256 frames ずつ 2 回読む定常状態を作る。
    private func driveSteadyState(_ ring: CaptureRing, cycles: Int, writerBlock: Int, request: Int) -> [Int] {
        var delivered: [Int] = []
        for _ in 0..<cycles {
            write(ring, frames: writerBlock)
            delivered.append(read(ring, frames: request))
            delivered.append(read(ring, frames: request))
        }
        return delivered
    }

    func testOccupancySettlesOnTheTargetWhenWriterAndReaderBlocksDiffer() {
        let writerBlock = 512
        let request = 256
        let metrics = AudioRuntimeMetrics()
        let ring = CaptureRing(sampleRate: sampleRate, initialWriterBlockFrames: writerBlock, metrics: metrics)
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlock, clientRequestFrames: request, sampleRate: sampleRate)
        let primingCycles = target / writerBlock + 1

        _ = driveSteadyState(
            ring, cycles: primingCycles + OccupancyCursor.writerBlockObservationWindowCalls,
            writerBlock: writerBlock, request: request
        )
        let delivered = driveSteadyState(ring, cycles: 64, writerBlock: writerBlock, request: request)

        XCTAssertEqual(metrics.targetOccupancyFrames, target)
        XCTAssertTrue(delivered.allSatisfy { $0 == request }, "プライミング後は毎回要求ぶんを返す")
        let window = try! XCTUnwrap(metrics.availableWindowStats)
        XCTAssertEqual(window.maxFrames - window.minFrames, request, "1 周期の書き込みと 2 回の読み出しで同じ 2 段を往復する")
        XCTAssertGreaterThanOrEqual(window.minFrames, target - request)
        XCTAssertLessThanOrEqual(window.maxFrames, target + request)
        XCTAssertEqual(metrics.resyncEventCount, 0)
        XCTAssertEqual(metrics.driftTrimEventCount, 0)
        XCTAssertEqual(metrics.partialReadCount, 0)
    }

    func testAReaderThatStallsPastTheCeilingIsResynchronized() {
        let writerBlock = 512
        let request = 256
        let metrics = AudioRuntimeMetrics()
        let ring = CaptureRing(sampleRate: sampleRate, initialWriterBlockFrames: writerBlock, metrics: metrics)
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlock, clientRequestFrames: request, sampleRate: sampleRate)
        let ceiling = OccupancyPolicy.maxOccupancyFrames(targetOccupancyFrames: target, writerBlockFrames: writerBlock, sampleRate: sampleRate)
        _ = driveSteadyState(ring, cycles: 128, writerBlock: writerBlock, request: request)
        XCTAssertEqual(metrics.resyncEventCount, 0, "前提: 定常状態では再同期しない")

        write(ring, frames: ceiling + writerBlock)
        Thread.sleep(forTimeInterval: OccupancyPolicy.discontinuityIntervalThreshold(clientRequestFrames: request, sampleRate: sampleRate) * 2)
        read(ring, frames: request)

        XCTAssertEqual(metrics.resyncEventCount, 1)
        XCTAssertEqual(metrics.occupancyResetDueToUnmixableSeamCount, 0, "混ぜる相手が残る超過は作り直さない")
    }

    func testAWriterThatRunsAheadOfTheCapacityRebuildsTheOccupancy() {
        let writerBlock = 512
        let request = 256
        let metrics = AudioRuntimeMetrics()
        let ring = CaptureRing(sampleRate: sampleRate, initialWriterBlockFrames: writerBlock, metrics: metrics)
        _ = driveSteadyState(ring, cycles: 128, writerBlock: writerBlock, request: request)

        write(ring, frames: ring.capacityFrames + writerBlock)
        Thread.sleep(forTimeInterval: OccupancyPolicy.discontinuityIntervalThreshold(clientRequestFrames: request, sampleRate: sampleRate) * 2)
        read(ring, frames: request)

        XCTAssertEqual(metrics.occupancyResetDueToUnmixableSeamCount, 1)
        XCTAssertEqual(metrics.resyncEventCount, 0)
    }

    // MARK: - 1 周期の取り込み

    /// 包絡が 1 に張り付くまで読み、以後は書いた値がそのまま読める状態のリングを返す。
    private func makeTransparentRing() -> CaptureRing {
        let ring = CaptureRing(sampleRate: sampleRate, primingEnabled: false)
        let chunk = 256
        let saturation = OccupancyPolicy.silenceSeamFadeFrames(sampleRate: sampleRate) + chunk
        var consumed = 0
        while consumed < saturation {
            write(ring, frames: chunk, value: 0)
            consumed += read(ring, frames: chunk)
        }
        return ring
    }

    private func readBack(_ ring: CaptureRing, frames: Int) -> (got: Int, samples: [Float]) {
        var dst = [Float](repeating: .nan, count: frames * channels)
        let got = dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: frames) }
        return (got, Array(dst.prefix(got * channels)))
    }

    private struct BufferSpec {
        let channels: UInt32
        let samples: [Float]?
    }

    /// 検証が組み立てた AudioBufferList を渡す。samples が nil のバッファは mData を持たない。
    private func withBufferList<Result>(
        _ specs: [BufferSpec], _ body: (UnsafeMutablePointer<AudioBufferList>, [UnsafeMutablePointer<Float>?]) -> Result
    ) -> Result {
        let list = AudioBufferList.allocate(maximumBuffers: max(1, specs.count))
        list.count = specs.count
        var storages: [UnsafeMutablePointer<Float>?] = []
        for (index, spec) in specs.enumerated() {
            guard let samples = spec.samples else {
                list[index] = AudioBuffer(mNumberChannels: spec.channels, mDataByteSize: 0, mData: nil)
                storages.append(nil)
                continue
            }
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: max(1, samples.count))
            storage.initialize(from: samples, count: samples.count)
            list[index] = AudioBuffer(
                mNumberChannels: spec.channels, mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage)
            )
            storages.append(storage)
        }
        defer {
            storages.forEach { $0?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        return body(list.unsafeMutablePointer, storages)
    }

    private func runCycle(
        input: [BufferSpec], output: [BufferSpec]?, layout: CaptureInputLayout, ring: CaptureRing,
        scratchFrames: Int = AudioConfig.maxRenderFrames, fallbackCycleFrames: Int = 512
    ) -> [Float]? {
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * channels)
        defer { scratch.deallocate() }
        return withBufferList(input) { inputList, _ in
            guard let output else {
                writeCaptureCycle(
                    input: inputList, output: nil, layout: layout, channels: channels,
                    scratch: scratch, scratchFrames: scratchFrames, fallbackCycleFrames: fallbackCycleFrames, into: ring
                )
                return nil
            }
            return withBufferList(output) { outputList, outputStorages in
                writeCaptureCycle(
                    input: inputList, output: outputList, layout: layout, channels: channels,
                    scratch: scratch, scratchFrames: scratchFrames, fallbackCycleFrames: fallbackCycleFrames, into: ring
                )
                return zip(output, outputStorages).flatMap { spec, storage in
                    (0..<(spec.samples?.count ?? 0)).map { storage![$0] }
                }
            }
        }
    }

    // サブデバイスの入力が先、Tap が後ろ。先頭から取ると出力デバイス側の入力を読んでしまう。
    func testTheInterleavedTapIsTakenFromTheEndOfTheInputList() {
        let frames = 64
        let ring = makeTransparentRing()
        let subDevice = BufferSpec(channels: 2, samples: [Float](repeating: 9, count: frames * 2))
        let tap = BufferSpec(channels: 2, samples: (0..<frames).flatMap { [Float($0), Float(1000 + $0)] })

        let output = runCycle(
            input: [subDevice, tap], output: [BufferSpec(channels: 2, samples: [Float](repeating: 5, count: frames * 2))],
            layout: .interleaved, ring: ring
        )

        let read = readBack(ring, frames: frames)
        XCTAssertEqual(read.got, frames)
        XCTAssertEqual(read.samples, tap.samples)
        XCTAssertEqual(output, [Float](repeating: 0, count: frames * 2), "出力バッファは 0 で埋める")
    }

    func testANonInterleavedTapIsInterleavedFromTheLastBuffers() {
        let frames = 64
        let ring = makeTransparentRing()
        let subDevice = BufferSpec(channels: 1, samples: [Float](repeating: 9, count: frames))
        let left = BufferSpec(channels: 1, samples: (0..<frames).map { Float($0) })
        let right = BufferSpec(channels: 1, samples: (0..<frames).map { Float(1000 + $0) })

        _ = runCycle(input: [subDevice, left, right], output: nil, layout: .nonInterleaved, ring: ring)

        let read = readBack(ring, frames: frames)
        XCTAssertEqual(read.got, frames)
        XCTAssertEqual(read.samples, (0..<frames).flatMap { [Float($0), Float(1000 + $0)] })
    }

    func testFramesBeyondTheScratchAreInterleavedPieceByPieceInOrder() {
        let frames = 100
        let scratchFrames = 16
        let ring = makeTransparentRing()
        let left = BufferSpec(channels: 1, samples: (0..<frames).map { Float($0) })
        let right = BufferSpec(channels: 1, samples: (0..<frames).map { Float(1000 + $0) })

        _ = runCycle(input: [left, right], output: nil, layout: .nonInterleaved, ring: ring, scratchFrames: scratchFrames)

        let read = readBack(ring, frames: frames)
        XCTAssertEqual(read.got, frames)
        XCTAssertEqual(read.samples, (0..<frames).flatMap { [Float($0), Float(1000 + $0)] })
    }

    // 書かない周期を作ると、読み手はその間を書き手の停止として読む。
    func testACycleWithoutTheTapWritesSilenceOfTheOutputCycleLength() {
        let outputFrames = 48
        let ring = makeTransparentRing()
        write(ring, frames: outputFrames, value: 0.5)
        _ = readBack(ring, frames: outputFrames)

        let output = runCycle(
            input: [BufferSpec(channels: 2, samples: nil)],
            output: [BufferSpec(channels: 2, samples: [Float](repeating: 5, count: outputFrames * 2))],
            layout: .interleaved, ring: ring
        )

        let read = readBack(ring, frames: outputFrames * 2)
        XCTAssertEqual(read.got, outputFrames, "出力の周期と同じフレーム数だけ書く")
        XCTAssertEqual(read.samples, [Float](repeating: 0, count: outputFrames * 2))
        XCTAssertEqual(output, [Float](repeating: 0, count: outputFrames * 2))
    }

    func testACycleWithoutTheTapOrAnOutputFallsBackToTheConfiguredCycleLength() {
        let fallbackFrames = 40
        let ring = makeTransparentRing()

        _ = runCycle(input: [], output: nil, layout: .nonInterleaved, ring: ring, fallbackCycleFrames: fallbackFrames)

        XCTAssertEqual(readBack(ring, frames: fallbackFrames * 2).got, fallbackFrames)
    }

    // MARK: - Tap の形式

    func testOnlyAFloatStreamOfThePathChannelCountIsAccepted() {
        let interleaved = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: AudioConfig.channels,
            mBitsPerChannel: 32, mReserved: 0
        )
        XCTAssertEqual(AirPlayCapture.captureInputLayout(interleaved), .interleaved)

        var nonInterleaved = interleaved
        nonInterleaved.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        XCTAssertEqual(AirPlayCapture.captureInputLayout(nonInterleaved), .nonInterleaved)

        var integer = interleaved
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        XCTAssertNil(AirPlayCapture.captureInputLayout(integer))

        var mono = interleaved
        mono.mChannelsPerFrame = 1
        XCTAssertNil(AirPlayCapture.captureInputLayout(mono))
    }
}
