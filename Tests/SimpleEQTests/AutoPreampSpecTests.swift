import XCTest
@testable import SimpleEQ

/// プリアンプ導出式・積分範囲を CoreAudio に触れず検証する。
final class AutoPreampSpecTests: XCTestCase {

    // MARK: - derivedPreampDb

    private struct Curve {
        let name: String
        let energyWeightedGainDb: Double
        let worstCaseGainDb: Double
        let expectedByTarget: [Double: Double]   // targetDb → 期待される導出値
    }

    private var targetSteps: [Double] {
        stride(
            from: AutoPreampSpec.targetDbRange.lowerBound,
            through: AutoPreampSpec.targetDbRange.upperBound,
            by: AutoPreampSpec.targetDbStep
        ).map { $0 }
    }

    private let curves: [Curve] = [
        Curve(name: "Flat", energyWeightedGainDb: 0.00, worstCaseGainDb: 0.00,
              expectedByTarget: [0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0]),
        Curve(name: "Perfect", energyWeightedGainDb: 6.51, worstCaseGainDb: 12.06,
              expectedByTarget: [0: -7, 1: -6, 2: -5, 3: -4, 4: -3, 5: -2, 6: -1]),
        Curve(name: "Eargasm Explosion", energyWeightedGainDb: 5.50, worstCaseGainDb: 10.71,
              expectedByTarget: [0: -6, 1: -5, 2: -4, 3: -3, 4: -2, 5: -1, 6: 0]),
        Curve(name: "単一+12@1kHz", energyWeightedGainDb: 1.93, worstCaseGainDb: 12.00,
              expectedByTarget: [0: -6, 1: -5, 2: -4, 3: -3, 4: -2, 5: -1, 6: 0]),
        Curve(name: "単一+6@1kHz", energyWeightedGainDb: 0.63, worstCaseGainDb: 6.00,
              expectedByTarget: [0: -1, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0]),
        Curve(name: "隣接3本+12", energyWeightedGainDb: 7.10, worstCaseGainDb: 17.37,
              expectedByTarget: [0: -12, 1: -11, 2: -10, 3: -9, 4: -8, 5: -7, 6: -6]),
        Curve(name: "全バンド+12", energyWeightedGainDb: 17.91, worstCaseGainDb: 20.41,
              expectedByTarget: [0: -12, 1: -12, 2: -12, 3: -12, 4: -12, 5: -12, 6: -12]),
        Curve(name: "全バンド−12", energyWeightedGainDb: -16.28, worstCaseGainDb: -3.19,
              expectedByTarget: [0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0]),
    ]

    func testDerivedPreampDbMatchesConfirmedTable() {
        for curve in curves {
            let response = EQMagnitudeResponse(
                energyWeightedGainDb: curve.energyWeightedGainDb, worstCaseGainDb: curve.worstCaseGainDb
            )
            for target in targetSteps {
                guard let expected = curve.expectedByTarget[target] else {
                    XCTFail("期待値表が目標 \(target)dB を含んでいない (\(curve.name))")
                    continue
                }
                let got = AutoPreampSpec.derivedPreampDb(response: response, targetDb: target)
                XCTAssertEqual(got, expected, "\(curve.name) target=\(target)dB")
            }
        }
    }

    // MARK: - 丸め方向

    func testRoundingTruncatesTowardsSafety() {
        let ee = EQMagnitudeResponse(energyWeightedGainDb: 5.50, worstCaseGainDb: 10.71)
        XCTAssertEqual(AutoPreampSpec.derivedPreampDb(response: ee, targetDb: 0), -6, "四捨五入なら -5 になる")
    }

    func testAdoptedValueNeverExceedsRawTowardsZero() {
        // クランプが効かない範囲で、採用値 (floor) が raw を超えないこと。
        for energyDb in stride(from: -10.0, through: 10.0, by: 1.0) {
            for worstDb in stride(from: -5.0, through: 15.0, by: 1.0) {
                let response = EQMagnitudeResponse(energyWeightedGainDb: energyDb, worstCaseGainDb: worstDb)
                for target in targetSteps {
                    let raw = target - AutoPreampSpec.compositeGainDb(response)
                    guard raw >= AutoPreampSpec.minPreampDb, raw <= AutoPreampSpec.maxPreampDb else { continue }
                    let got = AutoPreampSpec.derivedPreampDb(response: response, targetDb: target)
                    XCTAssertLessThanOrEqual(Double(got), raw)
                }
            }
        }
    }

    // MARK: - クランプ

    func testClampNeverExceedsMaxPreampDb() {
        // カット系カーブ (加重・最悪ともに負) は 0 を超えない。
        let response = EQMagnitudeResponse(energyWeightedGainDb: -16.28, worstCaseGainDb: -3.19)
        for target in targetSteps {
            let got = AutoPreampSpec.derivedPreampDb(response: response, targetDb: target)
            XCTAssertLessThanOrEqual(got, AutoPreampSpec.maxPreampDb)
        }
    }

    func testClampNeverGoesBelowEQSpecDbMin() {
        // 深いカーブ (全バンド+12) は EQSpec.DB_MIN を下回らない。
        let response = EQMagnitudeResponse(energyWeightedGainDb: 17.91, worstCaseGainDb: 20.41)
        for target in targetSteps {
            let got = AutoPreampSpec.derivedPreampDb(response: response, targetDb: target)
            XCTAssertGreaterThanOrEqual(got, EQSpec.DB_MIN)
        }
    }

    func testMinPreampDbIsDerivedFromEQSpecDbMin() {
        XCTAssertEqual(AutoPreampSpec.minPreampDb, EQSpec.DB_MIN)
    }

    // MARK: - Δ の床

    func testFloorIsAdoptedWhenWorstCaseDominatesOverEnergy() {
        // 単一+12@1kHz: 加重 1.93 は低いが最悪値 12.00 が高い → 床 (最悪-Δ) が採用される。
        let response = EQMagnitudeResponse(energyWeightedGainDb: 1.93, worstCaseGainDb: 12.00)
        XCTAssertEqual(AutoPreampSpec.compositeGainDb(response), 12.00 - AutoPreampSpec.worstCaseHeadroomDb)
    }

    func testEnergyIsAdoptedForWideCurves() {
        // 加重が最悪値から Δ を引いた値を上回るカーブでは、加重が採用される。
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6.51, worstCaseGainDb: 12.06)
        XCTAssertEqual(AutoPreampSpec.compositeGainDb(response), 6.51)
    }

    // MARK: - response(powerSpectrum:sampleRate:)

    func testResponseWithUniformUnityPowerIsZeroDb() {
        let spectrum = [Float](repeating: 1, count: 32768)
        let response = AutoPreampSpec.response(powerSpectrum: spectrum, sampleRate: 48000)
        XCTAssertEqual(response.energyWeightedGainDb, 0, accuracy: 1e-6)
        XCTAssertEqual(response.worstCaseGainDb, 0, accuracy: 1e-6)
    }

    func testResponseWithUniformPowerMatchesExpectedDb() {
        for x in [-6.0, 3.0, 9.0] {
            let power = Float(pow(10, x / 10))
            let spectrum = [Float](repeating: power, count: 32768)
            let response = AutoPreampSpec.response(powerSpectrum: spectrum, sampleRate: 48000)
            XCTAssertEqual(response.energyWeightedGainDb, x, accuracy: 1e-4)
            XCTAssertEqual(response.worstCaseGainDb, x, accuracy: 1e-4)
        }
    }

    func testResponseIgnoresBinsOutsideIntegrationRange() {
        let count = 32768
        var spectrum = [Float](repeating: 1, count: count)
        let sampleRate = 48000.0
        let binHz = sampleRate / Double(count * 2)
        // 20Hz 未満 (積分下限の 1 つ手前) と 20kHz 超 (積分上限の少し先) に巨大な値を置く。
        let belowRangeBin = max(0, Int((AutoPreampSpec.bandLowHz / binHz).rounded(.up)) - 1)
        let aboveRangeBin = min(count - 1, Int((AutoPreampSpec.bandHighHz / binHz).rounded(.down)) + 5)
        spectrum[belowRangeBin] = 1e12
        spectrum[aboveRangeBin] = 1e12

        let response = AutoPreampSpec.response(powerSpectrum: spectrum, sampleRate: sampleRate)
        XCTAssertEqual(response.energyWeightedGainDb, 0, accuracy: 1e-4)
        XCTAssertEqual(response.worstCaseGainDb, 0, accuracy: 1e-4)
    }

    func testResponseSingleBinBoostDominatesWorstCaseButNotEnergy() {
        let count = 32768
        var spectrum = [Float](repeating: 1, count: count)
        let boostedBin = count / 4
        let boostedPowerDb = 40.0
        spectrum[boostedBin] = Float(pow(10, boostedPowerDb / 10))

        let response = AutoPreampSpec.response(powerSpectrum: spectrum, sampleRate: 48000)
        XCTAssertEqual(response.worstCaseGainDb, boostedPowerDb, accuracy: 1e-3)
        XCTAssertLessThan(response.energyWeightedGainDb, response.worstCaseGainDb - 20)
    }

    /// bin 幅と積分上限がレートに追随することを、レートごとに位置の変わる 1 本のピークで判じる。
    /// 一様スペクトルでは bin 幅も上限も間違ったまま 0dB を返すため、性質を検出できない。
    func testResponseBinWidthAndUpperBoundTrackSampleRate() {
        let count = 32768
        for sampleRate in [44100.0, 48000.0, 96000.0] {
            let binHz = sampleRate / Double(count * 2)
            let upperHz = min(AutoPreampSpec.bandHighHz, sampleRate / 2)

            // 積分帯の内側ぎりぎりに置いたピークは最悪値として拾われる。
            var inside = [Float](repeating: 1, count: count)
            let insideBin = Int((upperHz / binHz).rounded(.down)) - 1
            inside[insideBin] = 100
            XCTAssertEqual(
                AutoPreampSpec.response(powerSpectrum: inside, sampleRate: sampleRate).worstCaseGainDb,
                20, accuracy: 1e-3, "fs=\(sampleRate) 上限の内側"
            )

            // 1 bin 外へずらすと拾われない。bin 幅か上限がずれていればどちらかの判定が破れる。
            var outside = [Float](repeating: 1, count: count)
            let outsideBin = Int((upperHz / binHz).rounded(.down)) + 1
            outside[outsideBin] = 100
            XCTAssertEqual(
                AutoPreampSpec.response(powerSpectrum: outside, sampleRate: sampleRate).worstCaseGainDb,
                0, accuracy: 1e-3, "fs=\(sampleRate) 上限の外側"
            )
        }
    }

    /// 加重がピンク (1/f) であることを、同じ大きさの山を低域と高域に置いて判じる。
    /// 一様加重なら両者は一致するため、重み付けが外れたときに検出できる。
    func testEnergyWeightingFavorsLowFrequencies() {
        let count = 32768
        let sampleRate = 48000.0
        let binHz = sampleRate / Double(count * 2)

        func gain(atHz hz: Double) -> Double {
            var spectrum = [Float](repeating: 1, count: count)
            spectrum[Int((hz / binHz).rounded())] = 1e6
            return AutoPreampSpec.response(powerSpectrum: spectrum, sampleRate: sampleRate).energyWeightedGainDb
        }

        let low = gain(atHz: 100), high = gain(atHz: 10000)
        XCTAssertGreaterThan(low, high + 10, "低域の山のほうが加重で重く効くこと")
        XCTAssertEqual(
            AutoPreampSpec.response(powerSpectrum: [Float](repeating: 1, count: count), sampleRate: sampleRate)
                .energyWeightedGainDb,
            0, accuracy: 1e-4, "平坦なら重み付けによらず 0dB"
        )
    }

    // MARK: - normalizedTargetDb

    func testNormalizedTargetDbClampsToRange() {
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(-5), AutoPreampSpec.targetDbRange.lowerBound)
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(50), AutoPreampSpec.targetDbRange.upperBound)
    }

    func testNormalizedTargetDbSnapsToStep() {
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(2.4), 2)
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(2.6), 3)
    }
}
