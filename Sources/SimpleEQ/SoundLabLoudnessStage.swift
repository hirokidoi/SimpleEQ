import Foundation

/// 出力段でインターリーブされたステレオへ直接かかる、音量に反比例した低域・高域の補い。
/// レベル解析より後ろに置くため、ここでの押し上げはクリップ判定にも表示にも乗らない。
/// リアルタイム経路のため確保・ロック・ログを行わない。
final class SoundLabLoudnessStage {
    private let sampleRate: Double
    private let channels: Int

    private var enabled = false
    private var bassCoef: Float = 0
    private var trebleCoef: Float = 0
    /// 操作値と音量から決まる、押し上げの倍率の上限。
    private var targetFactor: Float = 1
    /// 実際に掛けている倍率。空きが足りなければ上限より小さくなる。
    private var factor: Float = 1
    private var bassState: [Float]
    private var trebleState: [Float]

    private var releaseSeconds = LoudnessSettings.headroomReleaseRange.defaultValue

    /// 実際に掛かっている押し上げ量。
    var appliedBoostDb: Double { 20 * log10(Double(max(1, factor))) }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        channels = Int(AudioConfig.channels)
        bassState = Array(repeating: 0, count: channels)
        trebleState = Array(repeating: 0, count: channels)
    }

    /// 深さは音量に反比例するため、音量もここで受け取る。
    func apply(_ settings: LoudnessSettings, outputVolume: Float) {
        if !settings.enabled { factor = 1 }
        enabled = settings.enabled
        bassCoef = coefficient(settings.bassFrequency)
        trebleCoef = coefficient(settings.trebleFrequency)
        releaseSeconds = settings.headroomReleaseSeconds
        let depth = Double(max(0, min(1, 1 - outputVolume)))
        targetFactor = Float(SoundLabSpec.linearGain(db: settings.amountDb * depth))
    }

    private func coefficient(_ frequency: Double) -> Float {
        SoundLabSpec.onePoleCoefficient(frequency: frequency, sampleRate: sampleRate)
    }

    /// 空きが足りなければ即座に収まる倍率まで落とし、空きが戻ったら時間をかけて上限へ返す。
    /// 落とす側を待たせると、待っている間に潰れる。
    private func advanceFactor(outputPeak: Float, frames: Int) {
        let allowed = outputPeak > 0 ? 1 / outputPeak : .greatestFiniteMagnitude
        let target = min(targetFactor, max(1, allowed))
        if target <= factor {
            factor = target
            return
        }
        let elapsed = Double(frames) / sampleRate
        let step = Float(min(1, elapsed / releaseSeconds))
        factor += (target - factor) * step
    }

    /// outputPeak は押し上げ前のこのブロックのピーク。フルスケールまでの空きがここから決まる。
    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int, outputPeak: Float) {
        guard enabled, frames > 0 else { return }
        advanceFactor(outputPeak: outputPeak, frames: frames)
        let gain = factor - 1
        guard gain != 0 else { return }
        let bassCoef = self.bassCoef
        let bassKeep = 1 - bassCoef
        let trebleCoef = self.trebleCoef
        let trebleKeep = 1 - trebleCoef
        for c in 0..<channels {
            var lowState = bassState[c]
            var highState = trebleState[c]
            for frame in 0..<frames {
                let index = frame * channels + c
                let value = buf[index]
                lowState = bassCoef * lowState + bassKeep * value
                highState = trebleCoef * highState + trebleKeep * value
                buf[index] = value + (lowState + (value - highState)) * gain
            }
            bassState[c] = lowState
            trebleState[c] = highState
        }
    }
}
