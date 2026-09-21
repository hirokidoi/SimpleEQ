import Foundation
import CoreAudio
import AudioToolbox

enum AudioConfig {
    /// FFT サイズ・I/O バッファの導出などが基準にするレート。他のレートでのフレーム数はここからの換算で求める。
    static let baseSampleRate: Double = 48000.0

    /// 書き込みは適用の単一入口 (applySampleRate(_:)) に限られ、常に出力 AUHAL が停止している間の 1 回だけ行われる。
    /// 出力 AUHAL の Stop/Start 自体が realtime スレッドとの同期点になるため、アトミックな読み書きは持たせない。
    nonisolated(unsafe) private(set) static var appliedSampleRate: Double = baseSampleRate
    static let channels: UInt32 = 2

    /// オーディオユニットの MaximumFramesPerSlice にも使う。
    static let maxRenderFrames = 8192

    /// 基準レートでの一定フレーム数ぶんの時間量。
    /// フレーム数はデバイスの実サンプルレートから都度導出する (ioBufferFrames(deviceSampleRate:))。
    private static let ioBufferDeadlineSeconds: Double = 256.0 / baseSampleRate

    /// ドリフト補正ループが打ち消せるレートの上限 (絶対値、比率)。
    static let driftCorrectionMaxRateFraction: Double = 1000e-6

    static func applySampleRate(_ rate: Double) {
        appliedSampleRate = rate
    }

    static func makeASBD() -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: appliedSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerSample * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
    }

    /// 渡すのは出力デバイスのレートであり、ドライバの実レートではない
    /// (両者は一致しないことがある)。
    static func ioBufferFrames(deviceSampleRate: Double) -> UInt32 {
        UInt32((ioBufferDeadlineSeconds * deviceSampleRate).rounded(.up))
    }

    /// 非interleaved (1 AudioBuffer = 1ch ぶんのみ保持)。
    static func makePlanarASBD(channels: UInt32, sampleRate: Double) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
    }
}
