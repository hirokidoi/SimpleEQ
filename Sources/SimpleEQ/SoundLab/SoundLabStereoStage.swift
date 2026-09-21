import Foundation

/// EQ の前段で、インターリーブされたステレオへ直接かかる処理。
/// 広がり → 低音の倍音 → チャンネルごとの色付け の順に、効いているものだけを通す。
/// リアルタイム経路のため確保・ロック・ログを行わない。
final class SoundLabStereoStage {
    private let sampleRate: Double
    private let channels: Int

    private var sideGain: Float = 1
    /// この境目より下は広げずに残す。下限まで下げると実質すべてが対象になる。
    private var sideLowPassCoef: Float = 0
    private var sideLowState: Float = 0

    /// 左右の相関を崩して、量を上げずに広がりを出す。
    private var diffusionEnabled = false
    private var diffusionCoef: Float = 0
    private var diffusionStates: [Float]

    private var bassEnabled = false
    private var bassCoef: Float = 0
    private var bassDrive: Float = 1
    private var bassMix: Float = 0
    private var bassLowState1: Float = 0
    private var bassLowState2: Float = 0
    private var bassHarmonicState: Float = 0

    private var exciterEnabled = false
    private var exciterCoef: Float = 0
    private var exciterDrive: Float = 1
    private var exciterMix: Float = 0
    private var exciterLowState: [Float]

    /// 広がりが原音のままなら Side には触れない。M/S の往復だけでも浮動小数の誤差が乗る。
    private var expanderActive = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        channels = Int(AudioConfig.channels)
        exciterLowState = Array(repeating: 0, count: channels)
        diffusionStates = Array(repeating: 0, count: StereoExpanderSettings.diffusionStageCount)
    }

    func apply(
        expander: StereoExpanderSettings,
        bass: BassHarmonicsSettings,
        exciter: TrebleExciterSettings
    ) {
        sideGain = expander.enabled ? Float(expander.width) : 1
        sideLowPassCoef = coefficient(expander.crossover)
        diffusionEnabled = expander.enabled && expander.diffusionEnabled
        diffusionCoef = Float(expander.diffusionAmount)
        expanderActive = sideGain != 1 || diffusionEnabled

        bassEnabled = bass.enabled
        bassCoef = coefficient(bass.cutoff)
        bassDrive = Float(bass.drive)
        bassMix = Float(bass.mix / 100)

        exciterEnabled = exciter.enabled
        exciterCoef = coefficient(exciter.cutoff)
        exciterDrive = Float(exciter.drive)
        exciterMix = Float(exciter.mix / 100)
    }

    private func coefficient(_ frequency: Double) -> Float {
        SoundLabSpec.onePoleCoefficient(frequency: frequency, sampleRate: sampleRate)
    }

    /// 倍音を作るための飽和。tanh より安く、同じく滑らかに潰れる。
    private func saturate(_ value: Float) -> Float {
        value / (1 + abs(value))
    }

    /// 位相だけを周波数ごとにずらす一次オールパス。振幅は変えない。
    private func diffuse(_ input: Float, coef: Float) -> Float {
        var value = input
        for stage in 0..<diffusionStates.count {
            let output = -coef * value + diffusionStates[stage]
            diffusionStates[stage] = value + coef * output
            value = output
        }
        return value
    }

    /// M/S はステレオでのみ意味を持つため、それ以外の構成では何もしない。
    /// 広がりは Side、低音の倍音は Mid にしか触れないため、順に掛けても互いを崩さない。
    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        guard channels == 2 else { return }
        if expanderActive { widen(buf, frames: frames) }
        if bassEnabled { addBassHarmonics(buf, frames: frames) }
        if exciterEnabled { excite(buf, frames: frames) }
    }

    private func widen(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let gain = sideGain
        let coef = sideLowPassCoef
        let keep = 1 - coef
        let diffuses = diffusionEnabled
        let diffCoef = diffusionCoef
        var low = sideLowState
        for frame in 0..<frames {
            let base = frame * channels
            let left = buf[base]
            let right = buf[base + 1]
            let mid = (left + right) * 0.5
            var side = (left - right) * 0.5
            if diffuses { side = diffuse(side, coef: diffCoef) }
            low = coef * low + keep * side
            let shaped = low + (side - low) * gain
            buf[base] = mid + shaped
            buf[base + 1] = mid - shaped
        }
        sideLowState = low
    }

    /// Mid に対して行う。低音は中央に定位するため、左右別々に歪ませると定位が乱れる。
    private func addBassHarmonics(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let coef = bassCoef
        let keep = 1 - coef
        let drive = bassDrive
        let mix = bassMix
        var low1 = bassLowState1
        var low2 = bassLowState2
        var harmonic = bassHarmonicState
        for frame in 0..<frames {
            let base = frame * channels
            let mid = (buf[base] + buf[base + 1]) * 0.5
            low1 = coef * low1 + keep * mid
            low2 = coef * low2 + keep * low1
            let driven = saturate(low2 * drive)
            harmonic = coef * harmonic + keep * driven
            let added = (driven - harmonic) * mix
            buf[base] += added
            buf[base + 1] += added
        }
        bassLowState1 = low1
        bassLowState2 = low2
        bassHarmonicState = harmonic
    }

    /// チャンネルごとに行う。高域は左右で内容が異なる。
    private func excite(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let coef = exciterCoef
        let keep = 1 - coef
        let drive = exciterDrive
        let mix = exciterMix
        for c in 0..<channels {
            var low = exciterLowState[c]
            for frame in 0..<frames {
                let index = frame * channels + c
                let value = buf[index]
                low = coef * low + keep * value
                buf[index] = value + saturate((value - low) * drive) * mix
            }
            exciterLowState[c] = low
        }
    }
}
