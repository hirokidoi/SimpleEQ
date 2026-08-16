import XCTest
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
}
