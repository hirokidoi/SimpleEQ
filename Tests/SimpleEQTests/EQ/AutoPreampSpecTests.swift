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
              expectedByTarget: [-6: -6, -5: -5, -4: -4, -3: -3, -2: -2, -1: -1,
                                 0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0]),
        Curve(name: "Perfect", energyWeightedGainDb: 6.51, worstCaseGainDb: 12.06,
              expectedByTarget: [-6: -12, -5: -12, -4: -11, -3: -10, -2: -9, -1: -8,
                                 0: -7, 1: -6, 2: -5, 3: -4, 4: -3, 5: -2, 6: -1]),
        Curve(name: "Eargasm Explosion", energyWeightedGainDb: 5.50, worstCaseGainDb: 10.71,
              expectedByTarget: [-6: -12, -5: -11, -4: -10, -3: -9, -2: -8, -1: -7,
                                 0: -6, 1: -5, 2: -4, 3: -3, 4: -2, 5: -1, 6: 0]),
        Curve(name: "単一+12@1kHz", energyWeightedGainDb: 1.93, worstCaseGainDb: 12.00,
              expectedByTarget: [-6: -12, -5: -11, -4: -10, -3: -9, -2: -8, -1: -7,
                                 0: -6, 1: -5, 2: -4, 3: -3, 4: -2, 5: -1, 6: 0]),
        Curve(name: "単一+6@1kHz", energyWeightedGainDb: 0.63, worstCaseGainDb: 6.00,
              expectedByTarget: [-6: -7, -5: -6, -4: -5, -3: -4, -2: -3, -1: -2,
                                 0: -1, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0]),
        Curve(name: "隣接3本+12", energyWeightedGainDb: 7.10, worstCaseGainDb: 17.37,
              expectedByTarget: [-6: -12, -5: -12, -4: -12, -3: -12, -2: -12, -1: -12,
                                 0: -11, 1: -10, 2: -9, 3: -8, 4: -7, 5: -6, 6: -5]),
        Curve(name: "全バンド+12", energyWeightedGainDb: 17.91, worstCaseGainDb: 20.41,
              expectedByTarget: [-6: -12, -5: -12, -4: -12, -3: -12, -2: -12, -1: -12,
                                 0: -12, 1: -12, 2: -12, 3: -12, 4: -12, 5: -12, 6: -12]),
        Curve(name: "全バンド−12", energyWeightedGainDb: -16.28, worstCaseGainDb: -3.19,
              expectedByTarget: [-6: 0, -5: 0, -4: 0, -3: 0, -2: 0, -1: 0,
                                 0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0]),
    ]

    func testDerivedPreampDbMatchesConfirmedTable() {
        for curve in curves {
            let response = AutoPreampResponse(eq: EQMagnitudeResponse(
                energyWeightedGainDb: curve.energyWeightedGainDb, worstCaseGainDb: curve.worstCaseGainDb
            ))
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

    func testRoundsToTheNearestStep() {
        let shallow = AutoPreampResponse(eq: EQMagnitudeResponse(energyWeightedGainDb: 11.37, worstCaseGainDb: 0))
        XCTAssertEqual(
            AutoPreampSpec.derivedPreampDb(response: shallow, targetDb: 0), -11,
            "切り下げなら -12 になる"
        )
        let deep = AutoPreampResponse(eq: EQMagnitudeResponse(energyWeightedGainDb: 11.63, worstCaseGainDb: 0))
        XCTAssertEqual(AutoPreampSpec.derivedPreampDb(response: deep, targetDb: 0), -12)
    }

    /// 半端は深い側へ倒す。
    func testHalfStepFallsToTheDeeperSide() {
        let half = AutoPreampResponse(eq: EQMagnitudeResponse(energyWeightedGainDb: 5.50, worstCaseGainDb: 0))
        XCTAssertEqual(AutoPreampSpec.derivedPreampDb(response: half, targetDb: 0), -6)
    }

    // MARK: - 導出が勘定に入れる範囲

    func testTheDerivationTakesEveryStereoStageFeature() {
        var settings = SoundLabSettings()
        settings.liveSimulation.enabled = true
        settings.loudness.enabled = true
        settings.stereoExpander.enabled = true
        settings.bassHarmonics.enabled = true
        settings.trebleExciter.enabled = true

        let measured = MeasuredSoundLab(settings)
        XCTAssertEqual(measured.stereoExpander, settings.stereoExpander)
        XCTAssertEqual(measured.bassHarmonics, settings.bassHarmonics)
        XCTAssertEqual(measured.trebleExciter, settings.trebleExciter)
        XCTAssertEqual(
            measured, MeasuredSoundLab(sameExceptTheExcludedFeatures(settings)),
            "外した機能をどう動かしても勘定は変わらない"
        )
    }

    /// 外した機能だけを動かした写しを作る。
    private func sameExceptTheExcludedFeatures(_ settings: SoundLabSettings) -> SoundLabSettings {
        var other = settings
        other.liveSimulation.enabled.toggle()
        other.liveSimulation.mix = LiveSimulationSettings.mixRange.bounds.upperBound
        other.loudness.enabled.toggle()
        return other
    }

    func testTheExpanderAloneEngagesTheStage() {
        var settings = SoundLabSettings()
        XCTAssertFalse(MeasuredSoundLab(settings).anyEnabled, "前提: 既定ではすべて切")
        settings.stereoExpander.enabled = true
        XCTAssertTrue(MeasuredSoundLab(settings).anyEnabled)
    }

    // MARK: - ステレオ段の上がり

    /// EQ の持ち上げが小さいカーブでも、段の上がりが余裕に吸われない。
    func testTheStageRiseIsNotSpentOnTheEQHeadroom() {
        let response = AutoPreampResponse(
            eq: EQMagnitudeResponse(energyWeightedGainDb: 0, worstCaseGainDb: 0),
            soundLab: EQMagnitudeResponse(energyWeightedGainDb: 1.2, worstCaseGainDb: 2)
        )
        XCTAssertEqual(
            AutoPreampSpec.derivedPreampDb(response: response, targetDb: 0), -2,
            "足してから余裕を引けば -1 になる"
        )
    }

    /// 大きい方で決まるのではなく、EQ の分に上乗せされる。
    func testTheStageRiseAddsOnTopOfTheEQ() {
        let response = AutoPreampResponse(
            eq: EQMagnitudeResponse(energyWeightedGainDb: 5, worstCaseGainDb: 5),
            soundLab: EQMagnitudeResponse(energyWeightedGainDb: 2, worstCaseGainDb: 2)
        )
        XCTAssertEqual(AutoPreampSpec.derivedPreampDb(response: response, targetDb: 0), -7)
    }

    func testTheStageRiseTakesTheGreaterOfAverageAndPeak() {
        func derived(average: Double, peak: Double) -> Double {
            AutoPreampSpec.derivedPreampDb(
                response: AutoPreampResponse(
                    eq: EQMagnitudeResponse(energyWeightedGainDb: 0, worstCaseGainDb: 0),
                    soundLab: EQMagnitudeResponse(energyWeightedGainDb: average, worstCaseGainDb: peak)
                ),
                targetDb: 0
            )
        }
        XCTAssertEqual(derived(average: 2.4, peak: 1), -2, "平均が大きい")
        XCTAssertEqual(derived(average: 1, peak: 2.6), -3, "ピークが大きい")
    }

    func testAFallingStageDoesNotMakeThePreampShallower() {
        let response = AutoPreampResponse(
            eq: EQMagnitudeResponse(energyWeightedGainDb: 5, worstCaseGainDb: 5),
            soundLab: EQMagnitudeResponse(energyWeightedGainDb: -2, worstCaseGainDb: -1)
        )
        XCTAssertEqual(AutoPreampSpec.derivedPreampDb(response: response, targetDb: 0), -5)
    }

    /// クランプは合計に掛かる。EQ の分だけで先に打ち止めると、段の上がりが下限を越えて足される。
    func testTheClampAppliesToTheSum() {
        let eqGain = -EQSpec.DB_MIN - 2
        let response = AutoPreampResponse(
            eq: EQMagnitudeResponse(energyWeightedGainDb: eqGain, worstCaseGainDb: eqGain),
            soundLab: EQMagnitudeResponse(energyWeightedGainDb: 4, worstCaseGainDb: 4)
        )
        XCTAssertEqual(AutoPreampSpec.derivedPreampDb(response: response, targetDb: 0), EQSpec.DB_MIN)
    }

    /// 測定の数値誤差が段をまたがせない。
    func testNegligibleGainStaysAtZero() {
        let noise = AutoPreampResponse(eq: EQMagnitudeResponse(energyWeightedGainDb: 2.2e-9, worstCaseGainDb: 0))
        XCTAssertEqual(
            AutoPreampSpec.derivedPreampDb(response: noise, targetDb: 0), 0,
            "切り下げなら -1 になる"
        )
    }

    // MARK: - クランプ

    func testClampNeverExceedsMaxPreampDb() {
        // カット系カーブ (加重・最悪ともに負) は 0 を超えない。
        let response = AutoPreampResponse(eq: EQMagnitudeResponse(energyWeightedGainDb: -16.28, worstCaseGainDb: -3.19))
        for target in targetSteps {
            let got = AutoPreampSpec.derivedPreampDb(response: response, targetDb: target)
            XCTAssertLessThanOrEqual(got, AutoPreampSpec.maxPreampDb)
        }
    }

    func testClampNeverGoesBelowEQSpecDbMin() {
        // 深いカーブ (全バンド+12) は EQSpec.DB_MIN を下回らない。
        let response = AutoPreampResponse(eq: EQMagnitudeResponse(energyWeightedGainDb: 17.91, worstCaseGainDb: 20.41))
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
        XCTAssertEqual(AutoPreampSpec.eqGainDb(response), 12.00 - AutoPreampSpec.worstCaseHeadroomDb)
    }

    func testEnergyIsAdoptedForWideCurves() {
        // 加重が最悪値から Δ を引いた値を上回るカーブでは、加重が採用される。
        let response = EQMagnitudeResponse(energyWeightedGainDb: 6.51, worstCaseGainDb: 12.06)
        XCTAssertEqual(AutoPreampSpec.eqGainDb(response), 6.51)
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
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(-50), AutoPreampSpec.targetDbRange.lowerBound)
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(50), AutoPreampSpec.targetDbRange.upperBound)
    }

    /// 期待値表はこの範囲に対して手で書いてある。範囲を導出で書くと、狭めた回に表の行が黙って使われなくなる。
    func testTargetDbRangeMatchesTheValueTheExpectedTableWasWrittenAgainst() {
        XCTAssertEqual(AutoPreampSpec.targetDbRange, -6...6)
    }

    func testTargetDbDefaultSitsInTheRangeAndOnTheStepGrid() {
        XCTAssertTrue(
            AutoPreampSpec.targetDbRange.contains(AutoPreampSpec.targetDbDefault),
            "既定値が範囲の外にある"
        )
        XCTAssertEqual(
            AutoPreampSpec.normalizedTargetDb(AutoPreampSpec.targetDbDefault),
            AutoPreampSpec.targetDbDefault,
            "既定値が刻みに乗っていない"
        )
    }

    func testNormalizedTargetDbSnapsToStep() {
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(2.4), 2)
        XCTAssertEqual(AutoPreampSpec.normalizedTargetDb(2.6), 3)
    }
}
