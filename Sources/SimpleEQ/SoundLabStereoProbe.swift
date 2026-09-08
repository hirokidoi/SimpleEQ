import Foundation

/// ステレオ段の押し上げ量の測定器。
///
/// 段は飽和による非線形と M/S 操作を含むため、インパルス応答では測れない。
/// 非相関のステレオノイズを段へ直接通し、入出力の比を採る。
/// 段は CoreAudio を使わない素の型なので、バッファを通すだけで測れる。
final class SoundLabStereoProbe {
    private let sampleRate: Double
    private let warmupFrames: Int
    private let measureFrames: Int
    private let channels = Int(AudioConfig.channels)

    /// 単位 RMS の入力。乱数は固定なので、同じ設定なら同じ結果が出る。
    private let reference: [Float]
    private var work: [Float]

    /// 一次フィルタの整定に要る長さと、比が安定する長さ。どちらも実測で選定。
    init(sampleRate: Double, warmupSeconds: Double = 0.05, measureSeconds: Double = 0.25) {
        self.sampleRate = sampleRate
        warmupFrames = Int((warmupSeconds * sampleRate).rounded(.up))
        measureFrames = Int((measureSeconds * sampleRate).rounded(.up))
        let total = (warmupFrames + measureFrames) * channels
        // L/R を非相関にする。相関があると Side 成分が消え、エクスパンダーが測れない。
        reference = PinkNoise.makeInterleaved(sampleCount: total, channels: channels)
        work = [Float](repeating: 0, count: total)
    }

    /// 入力のピーク/RMS 比。入力レベルを RMS で与えるため、フルスケールまでの余裕はこれを引いた値になる。
    var inputCrestFactorDb: Double {
        let s = Self.summarize(reference, from: warmupFrames * channels, scale: 1)
        guard s.rms > 0 else { return 0 }
        return 20 * log10(s.peak / s.rms)
    }

    /// 飽和を測る以上、入力レベルを 1 つ選ぶ必要がある。
    /// 実際にフルスケールへ当たる素材の位置で測るため、クレストファクタから導く。
    var representativeLevelDbFS: Double { -inputCrestFactorDb }

    func measure(
        expander: StereoExpanderSettings = StereoExpanderSettings(),
        bass: BassHarmonicsSettings = BassHarmonicsSettings(),
        exciter: TrebleExciterSettings = TrebleExciterSettings()
    ) -> EQMagnitudeResponse {
        measure(expander: expander, bass: bass, exciter: exciter, inputLevelDbFS: representativeLevelDbFS)
    }

    /// 入力レベルは RMS の dBFS。飽和が非線形なため、レベルが変われば結果も変わる。
    func measure(
        expander: StereoExpanderSettings = StereoExpanderSettings(),
        bass: BassHarmonicsSettings = BassHarmonicsSettings(),
        exciter: TrebleExciterSettings = TrebleExciterSettings(),
        inputLevelDbFS: Double
    ) -> EQMagnitudeResponse {
        let scale = Float(SoundLabSpec.linearGain(db: inputLevelDbFS))
        let total = warmupFrames + measureFrames
        for i in 0..<work.count { work[i] = reference[i] * scale }

        let stage = SoundLabStereoStage(sampleRate: sampleRate)
        stage.apply(expander: expander, bass: bass, exciter: exciter)
        work.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            stage.process(base, frames: total)
        }

        let start = warmupFrames * channels
        let input = Self.summarize(reference, from: start, scale: scale)
        let output = Self.summarize(work, from: start, scale: 1)
        guard input.rms > 0, input.peak > 0 else {
            return EQMagnitudeResponse(energyWeightedGainDb: 0, worstCaseGainDb: 0)
        }
        return EQMagnitudeResponse(
            energyWeightedGainDb: 20 * log10(output.rms / input.rms),
            worstCaseGainDb: 20 * log10(output.peak / input.peak)
        )
    }

    private static func summarize(
        _ samples: [Float], from start: Int, scale: Float
    ) -> (rms: Double, peak: Double) {
        var sum = 0.0
        var peak = 0.0
        for i in start..<samples.count {
            let v = Double(samples[i] * scale)
            sum += v * v
            peak = max(peak, abs(v))
        }
        return (sqrt(sum / Double(samples.count - start)), peak)
    }
}
