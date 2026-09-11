import Foundation

/// 導出が勘定に入れる機能。
///
/// ライブシミュレーターは押し上げが丸めの刻みに届かないため外す。
struct MeasuredSoundLab: Hashable, Sendable {
    var stereoExpander: StereoExpanderSettings
    var bassHarmonics: BassHarmonicsSettings
    var trebleExciter: TrebleExciterSettings

    init(_ settings: SoundLabSettings) {
        stereoExpander = settings.stereoExpander
        bassHarmonics = settings.bassHarmonics
        trebleExciter = settings.trebleExciter
    }

    /// すべて切れていれば段は素通しであり、測っても 0dB にしかならない。
    var anyEnabled: Bool { stereoExpander.enabled || bassHarmonics.enabled || trebleExciter.enabled }
}

/// EQ 合成応答の要約値。
struct EQMagnitudeResponse: Equatable, Sendable {
    let energyWeightedGainDb: Double
    let worstCaseGainDb: Double
}

/// 導出の材料。EQ とステレオ段は要約の仕方が違うため、合わせずに持つ。
struct AutoPreampResponse: Equatable, Sendable {
    let eq: EQMagnitudeResponse
    let soundLab: EQMagnitudeResponse

    init(
        eq: EQMagnitudeResponse,
        soundLab: EQMagnitudeResponse = EQMagnitudeResponse(energyWeightedGainDb: 0, worstCaseGainDb: 0)
    ) {
        self.eq = eq
        self.soundLab = soundLab
    }
}

/// プリアンプ自動導出の仕様。CoreAudio に触れない純粋関数のみを持つ。
enum AutoPreampSpec {
    static let targetDbRange: ClosedRange<Double> = -6...6
    static let targetDbStep: Double = 1
    static let targetDbDefault: Double = 0
    /// 実測値。
    static let worstCaseHeadroomDb: Double = 6
    static let maxPreampDb: Double = 0
    static var minPreampDb: Double { EQSpec.DB_MIN }
    static let bandLowHz: Double = 20
    static let bandHighHz: Double = 20000

    static func normalizedTargetDb(_ db: Double) -> Double {
        let stepped = (db / targetDbStep).rounded() * targetDbStep
        return min(targetDbRange.upperBound, max(targetDbRange.lowerBound, stepped))
    }

    static func eqGainDb(_ response: EQMagnitudeResponse) -> Double {
        max(response.energyWeightedGainDb, response.worstCaseGainDb - worstCaseHeadroomDb)
    }

    /// 余裕は周波数上の最悪値に許すもので、信号全体の比で測る段には当てはめない。
    /// 下がる側は採らない。ノイズでの見積もりは実音源より深く下がる。
    static func soundLabGainDb(_ response: EQMagnitudeResponse) -> Double {
        max(0, response.energyWeightedGainDb, response.worstCaseGainDb)
    }

    static func compositeGainDb(_ response: AutoPreampResponse) -> Double {
        eqGainDb(response.eq) + soundLabGainDb(response.soundLab)
    }

    static func derivedPreampDb(response: AutoPreampResponse, targetDb: Double) -> Double {
        let raw = targetDb - compositeGainDb(response)
        let clamped = min(maxPreampDb, max(minPreampDb, raw))
        // 目標は上限ではないため、深い側へは寄せない。半端は深い側へ倒す。
        return clamped.rounded(.toNearestOrAwayFromZero)
    }

    /// 実数 FFT の片側パワースペクトル (長さ = FFT 長/2) からピンク加重の合成応答を求める。
    /// bin 幅は powerSpectrum の長さから逆算するため、FFT 長を別引数で受け取らない。
    static func response(powerSpectrum: [Float], sampleRate: Double) -> EQMagnitudeResponse {
        let binHz = sampleRate / Double(powerSpectrum.count * 2)
        let hiHz = min(bandHighHz, sampleRate / 2)
        let loBin = max(1, Int((bandLowHz / binHz).rounded(.up)))
        let hiBin = min(powerSpectrum.count - 1, Int((hiHz / binHz).rounded(.down)))
        guard loBin <= hiBin else { return EQMagnitudeResponse(energyWeightedGainDb: 0, worstCaseGainDb: 0) }

        var num = 0.0
        var den = 0.0
        var worstPower = 0.0
        for k in loBin...hiBin {
            let f = Double(k) * binHz
            let power = Double(powerSpectrum[k])
            let weight = 1.0 / f
            num += power * weight
            den += weight
            worstPower = max(worstPower, power)
        }
        return EQMagnitudeResponse(
            energyWeightedGainDb: 10 * log10(num / den),
            worstCaseGainDb: 10 * log10(worstPower)
        )
    }
}
