import XCTest
@testable import SimpleEQ

/// ステレオ段の測定器。ここが狂うとプリアンプの下げ幅が静かにずれる。
final class SoundLabStereoProbeTests: XCTestCase {
    private let rate = 48000.0

    private func probe() -> SoundLabStereoProbe { SoundLabStereoProbe(sampleRate: rate) }

    /// 何も効かせなければ入出力は一致するため、比は 0dB でなければならない。
    /// 無音や取り違えで 0 になるのではないことは、下の検証と対で担保する。
    func testNeutralSettingsMeasureZero() {
        let response = probe().measure()
        XCTAssertEqual(response.energyWeightedGainDb, 0, accuracy: 1e-6)
        XCTAssertEqual(response.worstCaseGainDb, 0, accuracy: 1e-6)
    }

    /// 押し上げが実測の水準に届くことまで見る。0 との比較では、
    /// 段が何もしなくても浮動小数の誤差が正の側に出て通ってしまう。
    private let saturatingFloorDb = 0.05

    func testEachSaturatingFeatureRaisesTheMeasuredLevel() {
        var bass = BassHarmonicsSettings()
        bass.enabled = true
        XCTAssertGreaterThan(probe().measure(bass: bass).energyWeightedGainDb, saturatingFloorDb)

        var exciter = TrebleExciterSettings()
        exciter.enabled = true
        XCTAssertGreaterThan(probe().measure(exciter: exciter).energyWeightedGainDb, saturatingFloorDb)
    }

    /// 広がりは Side を上げるため、非相関のノイズに対しては押し上げとして出る。
    func testTheExpanderRaisesTheMeasuredLevel() {
        var expander = StereoExpanderSettings()
        expander.enabled = true
        XCTAssertGreaterThan(probe().measure(expander: expander).energyWeightedGainDb, 0)
    }

    /// 飽和は入力振幅で挙動が変わる。代表レベルを 1 つ選ぶ必要があるのはこのため。
    func testSaturationMeasuresLessAsTheInputGrows() {
        var bass = BassHarmonicsSettings()
        bass.enabled = true
        let quiet = probe().measure(bass: bass, inputLevelDbFS: -40).energyWeightedGainDb
        let loud = probe().measure(bass: bass, inputLevelDbFS: -6).energyWeightedGainDb
        XCTAssertGreaterThan(quiet - loud, saturatingFloorDb, "大信号ほど潰れるため押し上げは小さくなる")
    }

    /// 代表レベルは定数ではなく、入力のピークがフルスケールへ当たる位置。
    func testTheRepresentativeLevelComesFromTheCrestFactor() {
        let p = probe()
        XCTAssertGreaterThan(p.inputCrestFactorDb, 0)
        XCTAssertEqual(p.representativeLevelDbFS, -p.inputCrestFactorDb, accuracy: 1e-9)

        var bass = BassHarmonicsSettings()
        bass.enabled = true
        XCTAssertEqual(
            p.measure(bass: bass).energyWeightedGainDb,
            p.measure(bass: bass, inputLevelDbFS: p.representativeLevelDbFS).energyWeightedGainDb,
            accuracy: 1e-9,
            "レベルを省いた測定は代表レベルで測る"
        )
    }

    /// 左右が同じ列だと Side が消え、広がりが測れなくなる。
    func testTheInputCarriesSideContent() {
        var expander = StereoExpanderSettings()
        expander.enabled = true
        expander.width = StereoExpanderSettings.widthRange.bounds.lowerBound
        XCTAssertLessThan(
            probe().measure(expander: expander).energyWeightedGainDb, 0,
            "Side を消せばレベルは下がる = 入力に Side がある"
        )
    }
}
