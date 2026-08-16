import XCTest
import CoreAudio
@testable import SimpleEQ

/// AudioConfig の導出関数 (CoreAudio に触れない純粋関数) を検証する。
final class AudioConfigTests: XCTestCase {
    // MARK: - ioBufferFrames(deviceSampleRate:)

    func testIoBufferFramesAtBaseSampleRateMatchesExpectedFrameCount() {
        XCTAssertEqual(AudioConfig.ioBufferFrames(deviceSampleRate: 48000), 256)
    }

    func testIoBufferFramesAt44_1kHzMatchesExpectedFrameCount() {
        XCTAssertEqual(AudioConfig.ioBufferFrames(deviceSampleRate: 44100), 236)
    }

    func testIoBufferFramesAt88_2kHzMatchesExpectedFrameCount() {
        XCTAssertEqual(AudioConfig.ioBufferFrames(deviceSampleRate: 88200), 471)
    }

    func testIoBufferFramesAt96kHzMatchesExpectedFrameCount() {
        XCTAssertEqual(AudioConfig.ioBufferFrames(deviceSampleRate: 96000), 512)
    }

    // レートが上がるほど、同じ時間の締切を満たすフレーム数も増える (方向の健全性)。
    func testIoBufferFramesGrowsWithSampleRate() {
        let at48k = AudioConfig.ioBufferFrames(deviceSampleRate: 48000)
        let at96k = AudioConfig.ioBufferFrames(deviceSampleRate: 96000)
        XCTAssertGreaterThan(at96k, at48k)
    }

    // MARK: - makePlanarASBD(channels:sampleRate:)

    // 1ch だけでは ch 数を掛ける書き違い (4 * channels) を検出できないため、1ch/2ch の両方を検証する。
    func testMakePlanarASBDMonoHasPerSampleFrameSize() {
        let asbd = AudioConfig.makePlanarASBD(channels: 1, sampleRate: 48000)
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)

        XCTAssertEqual(asbd.mSampleRate, 48000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(asbd.mFramesPerPacket, 1)
        XCTAssertEqual(asbd.mBytesPerFrame, bytesPerSample)
        XCTAssertEqual(asbd.mBytesPerPacket, bytesPerSample)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
    }

    func testMakePlanarASBDStereoStillHasPerSampleFrameSize() {
        let asbd = AudioConfig.makePlanarASBD(channels: 2, sampleRate: 44100)
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)

        XCTAssertEqual(asbd.mSampleRate, 44100)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mFramesPerPacket, 1)
        // 非interleaved は 1 AudioBuffer = 1ch ぶんのみを保持するため、2ch でも ch 数を
        // 掛けた値 (2 * bytesPerSample) とは一致しない。
        XCTAssertEqual(asbd.mBytesPerFrame, bytesPerSample)
        XCTAssertEqual(asbd.mBytesPerPacket, bytesPerSample)
        XCTAssertNotEqual(asbd.mBytesPerFrame, 2 * bytesPerSample)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
    }
}
