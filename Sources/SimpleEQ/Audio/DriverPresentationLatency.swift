import CoreAudio
import Foundation

enum DriverPresentationLatencyPolicy {
    // 実測値 (BlackHole ループバックで 7.1〜9.6 ms)。小さめに寄せ、音がわずかに遅れる側にずらす。
    static let appPathMilliseconds: Double = 8

    /// 映像との同期補正の範囲 (ミリ秒、設計値)。
    static let avSyncOffsetMillisecondsRange: ClosedRange<Int> = -200...300
    /// 映像との同期補正の刻み (ミリ秒、設計値)。
    static let avSyncOffsetMillisecondsStep = 10
    static let avSyncOffsetMillisecondsDefault = 0

    static func normalizedAVSyncOffsetMilliseconds(_ milliseconds: Int) -> Int {
        let clamped = min(max(milliseconds, avSyncOffsetMillisecondsRange.lowerBound), avSyncOffsetMillisecondsRange.upperBound)
        let steps = (Double(clamped) / Double(avSyncOffsetMillisecondsStep)).rounded()
        return Int(steps) * avSyncOffsetMillisecondsStep
    }

    static func frames(milliseconds: Double, appliedSampleRate: Double) -> Int {
        Int((milliseconds / 1000 * appliedSampleRate).rounded())
    }

    static func appPathFrames(appliedSampleRate: Double) -> Int {
        frames(milliseconds: appPathMilliseconds, appliedSampleRate: appliedSampleRate)
    }

    /// 適用レートのフレーム数。
    static func totalFrames(outputDeclaredFrames: Int?, avSyncOffsetMilliseconds: Int, appliedSampleRate: Double) -> Int {
        let sum = (outputDeclaredFrames ?? 0)
            + appPathFrames(appliedSampleRate: appliedSampleRate)
            + frames(milliseconds: Double(avSyncOffsetMilliseconds), appliedSampleRate: appliedSampleRate)
        return min(max(sum, 0), Int(UInt32.max))
    }
}

/// ドライバの申告遅延の読み書き。テストが実機のドライバへ書かないよう差し替え可能にする。
protocol DriverPresentationLatencyIO: Sendable {
    func read(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Int?
    func write(_ frames: Int, _ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool
}

final class CoreAudioDriverPresentationLatencyIO: DriverPresentationLatencyIO {
    func read(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Int? {
        guard let value = deviceCustomProperty(DriverConfig.presentationLatencySelector, forDeviceID: id, token),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var frames: Int64 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &frames) else { return nil }
        return Int(frames)
    }

    func write(_ frames: Int, _ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        var value = Int64(frames)
        guard let number = CFNumberCreate(nil, .sInt64Type, &value) else { return false }
        return setDeviceCustomProperty(DriverConfig.presentationLatencySelector, number, forDeviceID: id, token)
    }
}
