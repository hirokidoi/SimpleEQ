import Foundation
import CoreAudio
import AudioToolbox

enum AudioConfig {
    /// FFT サイズ・I/O バッファの導出などが基準にするレート。他のレートでのフレーム数はここからの
    /// 換算で求める。
    static let baseSampleRate: Double = 48000.0

    /// 書き込みは適用の単一入口 (applySampleRate(_:)) に限られ、常に出力 AUHAL が停止している間の
    /// 1 回だけ行われる。出力 AUHAL の Stop/Start 自体が realtime スレッドとの同期点になるため、
    /// アトミックな読み書きは持たせない。
    nonisolated(unsafe) private(set) static var appliedSampleRate: Double = baseSampleRate
    static let channels: UInt32 = 2

    /// オーディオユニットの MaximumFramesPerSlice にも使う。
    static let maxRenderFrames = 8192

    /// 基準レートでの一定フレーム数ぶんの時間量。フレーム数はデバイスの実サンプルレートから
    /// 都度導出する (ioBufferFrames(deviceSampleRate:))。
    private static let ioBufferDeadlineSeconds: Double = 256.0 / baseSampleRate

    /// ドリフト補正ループが打ち消せるレートの上限 (絶対値、比率)。
    static let driftCorrectionMaxRateFraction: Double = 1000e-6

    static func applySampleRate(_ rate: Double) {
        appliedSampleRate = rate
    }

    static func makeASBD() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: appliedSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// 渡すのは出力デバイスのレートであり、ドライバの実レートではない
    /// (両者は一致しないことがある)。
    static func ioBufferFrames(deviceSampleRate: Double) -> UInt32 {
        UInt32((ioBufferDeadlineSeconds * deviceSampleRate).rounded(.up))
    }
}
