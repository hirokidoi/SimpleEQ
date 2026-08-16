import Foundation

/// EQ 合成応答の要約値。
struct EQMagnitudeResponse: Equatable, Sendable {
    let energyWeightedGainDb: Double
    let worstCaseGainDb: Double
}

/// プリアンプ自動導出の仕様。CoreAudio に触れない純粋関数のみを持つ。
enum AutoPreampSpec {
    static let targetDbRange: ClosedRange<Double> = 0...6
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

    static func compositeGainDb(_ response: EQMagnitudeResponse) -> Double {
        max(response.energyWeightedGainDb, response.worstCaseGainDb - worstCaseHeadroomDb)
    }

    static func derivedPreampDb(response: EQMagnitudeResponse, targetDb: Double) -> Double {
        let raw = targetDb - compositeGainDb(response)
        let clamped = min(maxPreampDb, max(minPreampDb, raw))
        // 浅い側へ丸めると目標を超えるため。
        return clamped.rounded(.down)
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
