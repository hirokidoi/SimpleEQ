import XCTest
@testable import SimpleEQ

/// CoreAudio に触れない純粋関数なので、入出力だけを見る決定論的なテストで完結する。
final class OccupancyPolicyTests: XCTestCase {
    private let appliedSampleRate = AudioConfig.appliedSampleRate

    // MARK: - minimumMarginFrames(sampleRate:)

    // 基準レートでは内訳定数からの計算結果と厳密に一致すること。
    func testMinimumMarginFramesAtBaseSampleRateMatchesExpectedBreakdown() {
        XCTAssertEqual(OccupancyPolicy.minimumMarginFrames(sampleRate: 48000), 176)
    }

    // 他のレートでは時間の量の内訳をそのレートで換算し直した値になること (単純比例とは丸めの分だけ異なりうる)。
    func testMinimumMarginFramesAt44_1kHzMatchesExpectedBreakdown() {
        XCTAssertEqual(OccupancyPolicy.minimumMarginFrames(sampleRate: 44100), 165)
    }

    // MARK: - targetOccupancyFrames (o*)

    func testTargetOccupancyIsAlwaysAMultipleOfWriterBlockFrames() {
        for np in [64, 128, 256, 512, 1024] {
            for nc in [64, 128, 256, 279] {
                let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: np, clientRequestFrames: nc, sampleRate: appliedSampleRate)
                XCTAssertEqual(target % np, 0, "N_p=\(np) N_c=\(nc)")
            }
        }
    }

    func testEffectiveMarginNeverFallsBelowMinimumMargin() {
        // M_eff = o* - (N_p + N_c) は構造破綻 (瞬時下限割れ) を落とす検査。
        for np in [64, 128, 256, 512, 1024] {
            for nc in [64, 128, 256, 279] {
                let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: np, clientRequestFrames: nc, sampleRate: appliedSampleRate)
                let margin = OccupancyPolicy.effectiveMarginFrames(
                    targetOccupancyFrames: target, writerBlockFrames: np, clientRequestFrames: nc
                )
                XCTAssertGreaterThanOrEqual(
                    margin, OccupancyPolicy.minimumMarginFrames(sampleRate: appliedSampleRate), "N_p=\(np) N_c=\(nc)"
                )
            }
        }
    }

    func testMaxOccupancyCoversTargetPlusReaderStopWorstCasePlusOneBlock() {
        for np in [64, 256, 512] {
            let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: np, clientRequestFrames: 256, sampleRate: appliedSampleRate)
            let maxOcc = OccupancyPolicy.maxOccupancyFrames(
                targetOccupancyFrames: target, writerBlockFrames: np, sampleRate: appliedSampleRate
            )
            XCTAssertGreaterThanOrEqual(
                maxOcc, target + OccupancyPolicy.readerStopWorstCaseFrames(sampleRate: appliedSampleRate) + np
            )
        }
    }

    /// 目標バッファ量・余裕の期待値を、実装呼び出しとは独立の閉形式から算出する。
    private func expectedTargetAndMargin(np: Int, nc: Int) -> (target: Int, margin: Int) {
        let required = np + nc + OccupancyPolicy.minimumMarginFrames(sampleRate: appliedSampleRate)
        let blocks = (required + np - 1) / np
        let target = blocks * np
        return (target, target - (np + nc))
    }

    func testFixedWriterBlockAtDeviceGranularityKeepsPositiveMarginUnlikeAFixedTarget() {
        // 大きな書き手のブロック長でも、実効余裕は正の値を保ち下限以上であることを確認する。
        let np = 1024
        let nc = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: np, clientRequestFrames: nc, sampleRate: appliedSampleRate)
        let margin = OccupancyPolicy.effectiveMarginFrames(targetOccupancyFrames: target, writerBlockFrames: np, clientRequestFrames: nc)
        let expected = expectedTargetAndMargin(np: np, nc: nc)
        XCTAssertEqual(target, expected.target)
        XCTAssertEqual(margin, expected.margin)
        XCTAssertGreaterThanOrEqual(margin, OccupancyPolicy.minimumMarginFrames(sampleRate: appliedSampleRate))
    }

    func test44_1kHzClientRequestStillSatisfiesMinimumMargin() {
        let np = 256
        let nc = 279
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: np, clientRequestFrames: nc, sampleRate: appliedSampleRate)
        let margin = OccupancyPolicy.effectiveMarginFrames(targetOccupancyFrames: target, writerBlockFrames: np, clientRequestFrames: nc)
        let expected = expectedTargetAndMargin(np: np, nc: nc)
        XCTAssertEqual(target, expected.target)
        XCTAssertEqual(margin, expected.margin)
        XCTAssertGreaterThanOrEqual(margin, OccupancyPolicy.minimumMarginFrames(sampleRate: appliedSampleRate))
    }

    // MARK: - T_trim

    func testTrimHoldDurationMatchesClosedFormAndIsPositive() {
        let np = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: np, clientRequestFrames: 256, sampleRate: appliedSampleRate)
        let maxOcc = OccupancyPolicy.maxOccupancyFrames(targetOccupancyFrames: target, writerBlockFrames: np, sampleRate: appliedSampleRate)
        let hold = OccupancyPolicy.trimHoldDuration(
            targetOccupancyFrames: target, maxOccupancyFrames: maxOcc,
            sampleRate: appliedSampleRate, driftCorrectionMaxRateFraction: AudioConfig.driftCorrectionMaxRateFraction
        )
        let expected = Double(maxOcc - target) / (AudioConfig.driftCorrectionMaxRateFraction * appliedSampleRate)
        XCTAssertEqual(hold, expected, accuracy: 1e-9)
        XCTAssertGreaterThan(hold, 0)
    }

    // MARK: - 不連続の間隔閾値

    func testDiscontinuityIntervalThresholdGrowsWithClientRequestFrames() {
        let small = OccupancyPolicy.discontinuityIntervalThreshold(clientRequestFrames: 64, sampleRate: appliedSampleRate)
        let large = OccupancyPolicy.discontinuityIntervalThreshold(clientRequestFrames: 512, sampleRate: appliedSampleRate)
        XCTAssertGreaterThan(large, small)
        XCTAssertGreaterThan(small, OccupancyPolicy.readerStopWorstCaseSeconds)
    }

    // MARK: - framesToDiscard / requiresReprime

    func testFramesToDiscardIsZeroWhenWithinTarget() {
        XCTAssertEqual(OccupancyPolicy.framesToDiscard(available: 500, targetOccupancyFrames: 768), 0)
        XCTAssertEqual(OccupancyPolicy.framesToDiscard(available: 768, targetOccupancyFrames: 768), 0)
        XCTAssertEqual(OccupancyPolicy.framesToDiscard(available: 1000, targetOccupancyFrames: 768), 232)
    }

    func testRequiresReprimeOnlyWhenTargetGrowsPastCurrentAvailable() {
        XCTAssertTrue(
            OccupancyPolicy.requiresReprime(currentAvailable: 700, newTargetOccupancyFrames: 1024, previousTargetOccupancyFrames: 768)
        )
        // 目標が縮小する側は安全 (何もしない)。
        XCTAssertFalse(
            OccupancyPolicy.requiresReprime(currentAvailable: 700, newTargetOccupancyFrames: 512, previousTargetOccupancyFrames: 768)
        )
        // 既に新しい目標を満たしている側も安全。
        XCTAssertFalse(
            OccupancyPolicy.requiresReprime(currentAvailable: 1024, newTargetOccupancyFrames: 1024, previousTargetOccupancyFrames: 768)
        )
    }

    // MARK: - 無音を契機とするリセットの判定 (出力段の水準・継続時間・ずれ)

    // 判定はピーク単体ではなく「閾値 × その回の実効出力ゲイン」と比べる。
    func testOutputSilenceJudgementScalesTheThresholdByTheEffectiveOutputGain() {
        let threshold = OccupancyPolicy.silenceLevelThresholdAmplitude
        // 閾値を大きく上回る通常再生は、ゲインが 1 でも無音ではない。
        XCTAssertFalse(OccupancyPolicy.isOutputSilent(peak: threshold * 10, effectiveOutputGain: 1))
        // 閾値を下回るピークはゲイン 1 では無音。
        XCTAssertTrue(OccupancyPolicy.isOutputSilent(peak: threshold * 0.5, effectiveOutputGain: 1))
        // 同じピークでも、音量を絞っている回は「その音量での実出力としては大きい」ため無音ではない。
        XCTAssertFalse(OccupancyPolicy.isOutputSilent(peak: threshold * 0.5, effectiveOutputGain: 0.25))
        // 境界 (閾値 × ゲインちょうど) は無音側。
        XCTAssertTrue(OccupancyPolicy.isOutputSilent(peak: threshold * 0.25, effectiveOutputGain: 0.25))
        // 消音は閾値も 0 になり、ピーク 0 が無音と判定される。
        XCTAssertTrue(OccupancyPolicy.isOutputSilent(peak: 0, effectiveOutputGain: 0))
    }

    // 無音とみなす継続フレーム数は継続時間 (秒) をサンプルレートで換算した値であり、レートが変われば連動する。
    func testSilenceHoldFramesDerivesFromSampleRateInsteadOfAFixedFrameCount() {
        for rate in TestSampleRates.all {
            let frames = OccupancyPolicy.silenceHoldFrames(sampleRate: rate)
            XCTAssertEqual(
                Double(frames) / rate, OccupancyPolicy.silenceHoldSeconds, accuracy: 1 / rate,
                "継続フレーム数は継続時間と一致すること (rate=\(rate))"
            )
        }
        XCTAssertNotEqual(
            OccupancyPolicy.silenceHoldFrames(sampleRate: 48000),
            OccupancyPolicy.silenceHoldFrames(sampleRate: 44100),
            "レートが変われば換算結果も変わること"
        )
    }

    // リセットの契機は「無音が継続時間ぶん続いた」と「バッファ量が明らかにずれている」の AND。片側だけでは発火しない。
    func testSilenceResetRequiresBothTheSilenceHoldAndTheOccupancyDrift() {
        let hold = OccupancyPolicy.silenceHoldFrames(sampleRate: appliedSampleRate)
        let writerBlockFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: 256, sampleRate: appliedSampleRate
        )
        // 遊びの幅は判定に渡す量そのものから導く (テスト内に別の数値を置かない)。
        let driftThreshold = target + writerBlockFrames
        func requiresReset(silentFrames: Int, available: Int) -> Bool {
            OccupancyPolicy.requiresSilenceReset(
                silentFrames: silentFrames, available: available,
                targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: appliedSampleRate
            )
        }
        XCTAssertTrue(requiresReset(silentFrames: hold, available: driftThreshold + 1), "両方が成立すれば発火する")
        XCTAssertFalse(
            requiresReset(silentFrames: hold, available: driftThreshold),
            "境界: 遊びの幅ちょうどの超過は捨てる仕事が無い"
        )
        XCTAssertFalse(
            requiresReset(silentFrames: hold, available: target + 1),
            "健全な状態でも起こりうる遊びの内側の超過では発火しない"
        )
        XCTAssertFalse(
            requiresReset(silentFrames: hold - 1, available: driftThreshold + 1), "境界: 継続が 1 フレーム足りない"
        )
        XCTAssertFalse(requiresReset(silentFrames: 0, available: target * 4), "ずれだけでは発火しない")
    }

    // MARK: - occupancyMilliseconds (バッファ量のミリ秒換算)

    func testOccupancyMillisecondsDerivesFromSampleRateWithoutALiteralConversionFactor() {
        // 固定の換算係数を持たずサンプルレートから都度導出していることを確認する。
        let framesForOneSecond = Int(appliedSampleRate)
        XCTAssertEqual(OccupancyPolicy.occupancyMilliseconds(frames: framesForOneSecond, sampleRate: appliedSampleRate), 1000, accuracy: 1e-9)

        let halfRate = appliedSampleRate / 2
        XCTAssertEqual(
            OccupancyPolicy.occupancyMilliseconds(frames: framesForOneSecond, sampleRate: halfRate), 2000, accuracy: 1e-9
        )
    }

    func testFormattedMillisecondsRoundsToConfiguredFractionDigits() {
        let text = OccupancyPolicy.formattedMilliseconds(frames: 100, sampleRate: appliedSampleRate)
        let expectedValue = OccupancyPolicy.occupancyMilliseconds(frames: 100, sampleRate: appliedSampleRate)
        let expectedText = String(format: "%.\(OccupancyPolicy.millisecondsDisplayFractionDigits)f", expectedValue)
        XCTAssertEqual(text, expectedText)
    }

    // MARK: - durationSeconds / formattedDuration (プライミング待機などの継続時間)

    func testDurationSecondsDerivesFromSampleRateWithoutALiteralConversionFactor() {
        // 固定の換算係数を持たずサンプルレートから都度導出していることを確認する。
        let framesForOneSecond = Int(appliedSampleRate)
        XCTAssertEqual(OccupancyPolicy.durationSeconds(frames: framesForOneSecond, sampleRate: appliedSampleRate), 1, accuracy: 1e-9)

        let halfRate = appliedSampleRate / 2
        XCTAssertEqual(OccupancyPolicy.durationSeconds(frames: framesForOneSecond, sampleRate: halfRate), 2, accuracy: 1e-9)
    }

    func testFormattedDurationStaysReadableAcrossSecondMinuteAndHourScales() {
        XCTAssertEqual(OccupancyPolicy.formattedDuration(seconds: 45), "45秒")
        XCTAssertEqual(OccupancyPolicy.formattedDuration(seconds: 90), "1分30秒")
        XCTAssertEqual(OccupancyPolicy.formattedDuration(seconds: 3661), "1時間01分")
    }

    func testFormattedDurationClampsNegativeSecondsToZero() {
        XCTAssertEqual(OccupancyPolicy.formattedDuration(seconds: -5), "0秒")
    }

    // MARK: - occupancyGaugePosition (バッファ量のゲージ位置)

    func testOccupancyGaugePositionMapsEmptyAndFullToZeroAndOne() {
        XCTAssertEqual(OccupancyPolicy.occupancyGaugePosition(frames: 0, maxOccupancyFrames: 1000), 0)
        XCTAssertEqual(OccupancyPolicy.occupancyGaugePosition(frames: 1000, maxOccupancyFrames: 1000), 1)
        XCTAssertEqual(OccupancyPolicy.occupancyGaugePosition(frames: 500, maxOccupancyFrames: 1000), 0.5, accuracy: 1e-9)
    }

    func testOccupancyGaugePositionClampsValuesOutsideZeroToMaxRange() {
        XCTAssertEqual(OccupancyPolicy.occupancyGaugePosition(frames: 2000, maxOccupancyFrames: 1000), 1)
        XCTAssertEqual(OccupancyPolicy.occupancyGaugePosition(frames: -1, maxOccupancyFrames: 1000), 0)
        XCTAssertEqual(OccupancyPolicy.occupancyGaugePosition(frames: 500, maxOccupancyFrames: 0), 0, "上限バッファ量が 0 以下の防御")
    }

    // MARK: - fallingSeamGain / risingSeamGain (継ぎ目の包絡ゲイン)

    // 下降は単調に減り、総フレーム数ぶんの歩みで 0 に達したら以後は 0 で下げ止まる。
    func testFallingSeamGainDecreasesMonotonicallyAndFloorsAtZero() {
        let totalFrames = 10
        var gain: Float = 1
        var previous = gain
        for _ in 0..<totalFrames {
            gain = OccupancyPolicy.fallingSeamGain(current: gain, totalFrames: totalFrames)
            XCTAssertLessThanOrEqual(gain, previous, "単調に減少すること")
            previous = gain
        }
        XCTAssertEqual(gain, 0, accuracy: 1e-6, "総フレーム数ぶんの歩みで 0 に達すること")
        gain = OccupancyPolicy.fallingSeamGain(current: gain, totalFrames: totalFrames)
        XCTAssertEqual(gain, 0, "0 に達した後は下げ止まること")
    }

    // 上昇は単調に増え、総フレーム数ぶんの歩みで 1 に達したら以後は 1 で上げ止まる。
    func testRisingSeamGainIncreasesMonotonicallyAndCeilsAtOne() {
        let totalFrames = 10
        var gain: Float = 0
        var previous = gain
        for _ in 0..<totalFrames {
            gain = OccupancyPolicy.risingSeamGain(current: gain, totalFrames: totalFrames)
            XCTAssertGreaterThanOrEqual(gain, previous, "単調に増加すること")
            previous = gain
        }
        XCTAssertEqual(gain, 1, accuracy: 1e-6, "総フレーム数ぶんの歩みで 1 に達すること")
        gain = OccupancyPolicy.risingSeamGain(current: gain, totalFrames: totalFrames)
        XCTAssertEqual(gain, 1, "1 に達した後は上げ止まること")
    }

    // 総フレーム数が 0 以下でも 0 除算せず、端点へ直接飽和すること (下限 1 で守る契約)。
    func testSeamGainStepFunctionsDoNotDivideByZeroWhenTotalFramesIsNonPositive() {
        XCTAssertEqual(OccupancyPolicy.fallingSeamGain(current: 1, totalFrames: 0), 0)
        XCTAssertEqual(OccupancyPolicy.risingSeamGain(current: 0, totalFrames: 0), 1)
        XCTAssertEqual(OccupancyPolicy.fallingSeamGain(current: 1, totalFrames: -5), 0)
        XCTAssertEqual(OccupancyPolicy.risingSeamGain(current: 0, totalFrames: -5), 1)
    }
}
