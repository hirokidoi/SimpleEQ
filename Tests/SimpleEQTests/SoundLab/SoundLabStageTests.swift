import XCTest
@testable import SimpleEQ

/// 自前 DSP の 2 段と、操作値そのものの検証。
final class SoundLabStageTests: XCTestCase {
    private let rate = 48000.0
    private let frames = 2048

    /// 決まった列を作る。段が値を素通しするかを見るため、入力そのものと比べられる形にする。
    private func makeInput() -> [Float] {
        PinkNoise.makeInterleaved(sampleCount: frames * Int(AudioConfig.channels), channels: Int(AudioConfig.channels))
    }

    private func process(_ input: [Float], _ body: (UnsafeMutablePointer<Float>) -> Void) -> [Float] {
        var work = input
        work.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            body(base)
        }
        return work
    }

    // MARK: - 無効なら素通し

    func testStereoStagePassesTheInputThroughWhenEverythingIsOff() {
        let input = makeInput()
        let stage = SoundLabStereoStage(sampleRate: rate)
        stage.apply(expander: StereoExpanderSettings(), bass: BassHarmonicsSettings(), exciter: TrebleExciterSettings())
        let output = process(input) { stage.process($0, frames: frames) }
        XCTAssertEqual(output, input)
    }

    /// 広がりが原音のままなら Side には触れない。M/S の往復だけでも誤差が乗るため、
    /// 「有効だが何も広げない」状態は素通しでなければならない。
    func testTheStereoStageLeavesTheSignalAloneWhenTheWidthIsNeutral() {
        var expander = StereoExpanderSettings()
        expander.enabled = true
        expander.width = 1
        expander.diffusionEnabled = false

        let input = makeInput()
        let stage = SoundLabStereoStage(sampleRate: rate)
        stage.apply(expander: expander, bass: BassHarmonicsSettings(), exciter: TrebleExciterSettings())
        let output = process(input) { stage.process($0, frames: frames) }
        XCTAssertEqual(output, input)
    }

    func testLoudnessStagePassesTheInputThroughWhenOff() {
        let input = makeInput()
        let stage = SoundLabLoudnessStage(sampleRate: rate)
        stage.apply(LoudnessSettings(), outputVolume: 0.1)
        let output = process(input) { stage.process($0, frames: frames, outputPeak: 0.5) }
        XCTAssertEqual(output, input)
    }

    /// 音量が最大なら深さが 0 になるため、有効でも素通しになる。
    func testLoudnessStageDoesNothingAtFullVolume() {
        let input = makeInput()
        var settings = SoundLabSettings()
        settings.loudness.enabled = true
        let stage = SoundLabLoudnessStage(sampleRate: rate)
        stage.apply(settings.loudness, outputVolume: 1)
        let output = process(input) { stage.process($0, frames: frames, outputPeak: 0.5) }
        XCTAssertEqual(output, input)
        XCTAssertEqual(stage.appliedBoostDb, 0, accuracy: 1e-9)
    }

    /// 有効にすれば動く。素通しの検証が「段が呼ばれていないだけ」で通らないことを担保する。
    /// 差が実測の水準に届くことまで見る。一致しないことだけを見ると、
    /// 段が何もしなくても経路上の浮動小数の誤差で通ってしまう。
    func testEachFeatureChangesTheSignalWhenEnabled() {
        let input = makeInput()
        for feature in SoundLabFeature.allCases where feature != .liveSimulation {
            var settings = SoundLabSettings()
            settings[keyPath: feature.enabledKeyPath] = true

            let output: [Float]
            if feature == .loudness {
                let stage = SoundLabLoudnessStage(sampleRate: rate)
                stage.apply(settings.loudness, outputVolume: 0.1)
                output = process(input) { stage.process($0, frames: frames, outputPeak: 0.01) }
            } else {
                let stage = SoundLabStereoStage(sampleRate: rate)
                stage.apply(
                    expander: settings.stereoExpander,
                    bass: settings.bassHarmonics,
                    exciter: settings.trebleExciter
                )
                output = process(input) { stage.process($0, frames: frames) }
            }
            var largest: Float = 0
            for i in 0..<output.count { largest = max(largest, abs(output[i] - input[i])) }
            XCTAssertGreaterThan(largest, Self.audibleDifference, "\(feature.title)")
        }
    }

    /// 効いている機能が生む差の実測より十分下、経路上の丸め誤差より十分上に置いた床。
    private static let audibleDifference: Float = 0.01

    // MARK: - 操作値

    func testEveryDefaultSitsInsideItsRange() {
        let ranges: [(String, SoundLabSpec.Range)] = [
            ("liveSimulationMix", LiveSimulationSettings.mixRange),
            ("stereoWidth", StereoExpanderSettings.widthRange),
            ("stereoWidthCrossover", StereoExpanderSettings.crossoverRange),
            ("diffusion", StereoExpanderSettings.diffusionRange),
            ("bassCutoff", BassHarmonicsSettings.cutoffRange),
            ("bassDrive", BassHarmonicsSettings.driveRange),
            ("bassMix", BassHarmonicsSettings.mixRange),
            ("exciterCutoff", TrebleExciterSettings.cutoffRange),
            ("exciterDrive", TrebleExciterSettings.driveRange),
            ("exciterMix", TrebleExciterSettings.mixRange),
            ("loudnessAmount", LoudnessSettings.amountRange),
            ("loudnessBassFrequency", LoudnessSettings.bassFrequencyRange),
            ("loudnessTrebleFrequency", LoudnessSettings.trebleFrequencyRange),
            ("loudnessHeadroomRelease", LoudnessSettings.headroomReleaseRange)
        ]
        for (name, range) in ranges {
            XCTAssertTrue(range.bounds.contains(range.defaultValue), "\(name) の既定値が範囲の外")
            XCTAssertGreaterThan(range.step, 0, "\(name) の刻みが 0 以下")
            let steps = (range.bounds.upperBound - range.bounds.lowerBound) / range.step
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9, "\(name) の範囲が刻みで割り切れない")
        }
    }

    /// 既定の操作値がそのまま素通しの状態であること。
    func testTheDefaultSettingsAreNeutral() {
        let settings = SoundLabSettings()
        for feature in SoundLabFeature.allCases {
            XCTAssertFalse(settings[keyPath: feature.enabledKeyPath], "\(feature.title) が既定で有効")
        }
    }

    // MARK: - ヘッドルームの頭打ち

    /// 空きの申告どおりに押し上げを抑えるか。申告を止めた場合と対で見る。
    func testTheBoostIsHeldToTheHeadroomItIsToldAbout() {
        var settings = LoudnessSettings()
        settings.enabled = true
        settings.amountDb = LoudnessSettings.amountRange.bounds.upperBound

        // 詰まったマスターを模す。低域の純音は押し上げが最も乗る形。
        let signalPeak: Float = 0.95

        func maxOutput(tellingTheHeadroom: Bool) -> Float {
            let stage = SoundLabLoudnessStage(sampleRate: rate)
            stage.apply(settings, outputVolume: 0.15)
            var buf = [Float](repeating: 0, count: frames * Int(AudioConfig.channels))
            var phase = 0.0
            var peak: Float = 0
            for _ in 0..<200 {
                for f in 0..<frames {
                    let v = Float(sin(phase)) * signalPeak
                    buf[f * Int(AudioConfig.channels)] = v
                    buf[f * Int(AudioConfig.channels) + 1] = v
                    phase += 2 * Double.pi * 80 / rate
                }
                buf.withUnsafeMutableBufferPointer { p in
                    guard let base = p.baseAddress else { return }
                    stage.process(base, frames: frames, outputPeak: tellingTheHeadroom ? signalPeak : 0)
                }
                for v in buf { peak = max(peak, abs(v)) }
            }
            return peak
        }

        XCTAssertLessThanOrEqual(maxOutput(tellingTheHeadroom: true), 1, "フルスケールへ収まる")
        XCTAssertGreaterThan(
            maxOutput(tellingTheHeadroom: false), 1,
            "空きを告げなければ超える = 頭打ちが仕事をしている"
        )
    }

    /// 空きが広ければ上限どおりに押し上げる。頭打ちが常時効いてしまっていないこと。
    /// 押し上げは戻す速さに従って上がるため、収束させてから見る。
    func testPlentyOfHeadroomLeavesTheBoostAtItsLimit() {
        let volume: Float = 0.15
        var settings = LoudnessSettings()
        settings.enabled = true
        let stage = SoundLabLoudnessStage(sampleRate: rate)
        stage.apply(settings, outputVolume: volume)

        let quiet: Float = 0.001
        var buf = [Float](repeating: quiet, count: frames * Int(AudioConfig.channels))
        let blocks = Int(settings.headroomReleaseSeconds * rate / Double(frames)) * 10
        buf.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for _ in 0..<blocks { stage.process(base, frames: frames, outputPeak: quiet) }
        }
        XCTAssertEqual(
            stage.appliedBoostDb, settings.amountDb * Double(1 - volume), accuracy: 0.01,
            "空きが広ければ操作値どおりの上限まで戻る"
        )
    }

    /// 段が空きを測る相手は、押し上げ前のバッファのピーク。
    /// 解析はゲインを掛ける前の値を返すため、掛けた後の大きさへ直して渡す。
    func testTheHeadroomReferenceFollowsTheOutputGain() {
        let analysed: Float = 0.9
        XCTAssertEqual(
            loudnessHeadroomReference(peakBeforeVolume: analysed, outputGain: 1), analysed,
            "ゲインが中立なら解析の値そのもの"
        )
        let attenuated = effectiveOutputGain(volume: 0.5, muted: false)
        XCTAssertLessThan(
            loudnessHeadroomReference(peakBeforeVolume: analysed, outputGain: attenuated), analysed,
            "ゲインが絞っていれば空きはその分広い"
        )
    }

    // MARK: - エンジンが段へ配る値

    private func edited() -> SoundLabSettings {
        var s = SoundLabSettings()
        s.bassHarmonics.enabled = true
        s.bassHarmonics.drive = 9
        s.trebleExciter.enabled = true
        return s
    }

    func testBypassHandsTheStagesNeutralValues() {
        let engine = AudioEngine()
        let settings = edited()

        engine.applySoundLab(settings, testToken)
        XCTAssertEqual(engine.soundLabSettingsInEffect, settings)

        engine.setBypass(true, testToken)
        XCTAssertEqual(engine.soundLabSettingsInEffect, SoundLabSettings(), "バイパス中は素通しの値")

        engine.setBypass(false, testToken)
        XCTAssertEqual(engine.soundLabSettingsInEffect, settings, "戻せば元の値へ返る")
    }

    /// 音量はラウドネスの深さの入力であり、動いた時点で配り直される。
    func testTheStagesAreFedAgainWhenTheVolumeMoves() {
        let engine = AudioEngine()
        let settings = edited()
        engine.applySoundLab(settings, testToken)

        engine.applyDriverVolumeAndMute(volume: 0.25, muted: false, testToken)
        XCTAssertEqual(engine.outputVolume, 0.25, "前提: 音量が動いている")
        XCTAssertEqual(engine.soundLabOutputVolumeInEffect, 0.25, "動いた音量が段まで届いている")
        XCTAssertEqual(engine.soundLabSettingsInEffect, settings)
    }

    /// 深さは音量に反比例する。段が受け取った音量が実際に押し上げを決めていること。
    func testTheVolumeDecidesHowDeepTheBoostGoes() {
        var settings = LoudnessSettings()
        settings.enabled = true

        func settledBoostDb(volume: Float) -> Double {
            let stage = SoundLabLoudnessStage(sampleRate: rate)
            stage.apply(settings, outputVolume: volume)
            let quiet: Float = 0.001
            var buf = [Float](repeating: quiet, count: frames * Int(AudioConfig.channels))
            let blocks = Int(settings.headroomReleaseSeconds * rate / Double(frames)) * 10
            buf.withUnsafeMutableBufferPointer { p in
                guard let base = p.baseAddress else { return }
                for _ in 0..<blocks { stage.process(base, frames: frames, outputPeak: quiet) }
            }
            return stage.appliedBoostDb
        }

        XCTAssertGreaterThan(
            settledBoostDb(volume: 0.2), settledBoostDb(volume: 0.8),
            "音量を絞るほど深く補う"
        )
    }

    /// 戻す速さは操作値であり、押し上げの返り方が実際に変わる。
    func testTheReleaseTimeChangesHowFastTheBoostReturns() {
        var settings = SoundLabSettings()
        settings.loudness.enabled = true
        settings.loudness.amountDb = LoudnessSettings.amountRange.bounds.upperBound

        func boostAfterHeadroomReturns(release: Double) -> Double {
            settings.loudness.headroomReleaseSeconds = release
            let stage = SoundLabLoudnessStage(sampleRate: rate)
            stage.apply(settings.loudness, outputVolume: 0.15)
            var buf = [Float](repeating: 0, count: frames * Int(AudioConfig.channels))
            // 空きの無い状態で頭打ちに当ててから、空いた状態を一定時間流す。
            buf.withUnsafeMutableBufferPointer { p in
                guard let base = p.baseAddress else { return }
                stage.process(base, frames: frames, outputPeak: 0.95)
                for _ in 0..<Int(rate / Double(frames)) {
                    stage.process(base, frames: frames, outputPeak: 0.05)
                }
            }
            return stage.appliedBoostDb
        }

        let quick = boostAfterHeadroomReturns(release: LoudnessSettings.headroomReleaseRange.bounds.lowerBound)
        let slow = boostAfterHeadroomReturns(release: LoudnessSettings.headroomReleaseRange.bounds.upperBound)
        XCTAssertGreaterThan(quick, slow, "速い側ほど早く戻る")
    }

    /// アプリのゲイン段が音量を担当する構成では、押し上げが減衰量を超えることが構造上ありえない。
    /// 補正の上限と音量の dB レンジは別々に決まるため、どちらを動かしてもこの保証は崩れうる。
    func testTheBoostCannotOutrunTheAttenuationItRidesOn() {
        var settings = LoudnessSettings()
        settings.enabled = true
        settings.amountDb = LoudnessSettings.amountRange.bounds.upperBound
        // 押し上げが上限へ届くまでの待ちを縮める。空きは十分に空けて頭打ちを外す。
        settings.headroomReleaseSeconds = LoudnessSettings.headroomReleaseRange.bounds.lowerBound

        for step in 1...8 {
            let volume = Float(step) / 8
            let stage = SoundLabLoudnessStage(sampleRate: rate)
            stage.apply(settings, outputVolume: volume)
            let quiet: Float = 0.001
            var buf = [Float](repeating: quiet, count: frames * Int(AudioConfig.channels))
            let blocks = Int(settings.headroomReleaseSeconds * rate / Double(frames)) * 20
            buf.withUnsafeMutableBufferPointer { p in
                guard let base = p.baseAddress else { return }
                for _ in 0..<max(1, blocks) { stage.process(base, frames: frames, outputPeak: quiet) }
            }
            let attenuationDb = -20 * log10(Double(effectiveOutputGain(volume: volume, muted: false)))
            XCTAssertLessThanOrEqual(
                stage.appliedBoostDb, attenuationDb + 1e-9,
                "音量 \(volume) で押し上げが減衰量を上回る"
            )
        }
    }

    func testNormalizingLeavesValidValuesAlone() {
        var settings = SoundLabSettings()
        settings.stereoExpander.width = 2.0
        settings.bassHarmonics.drive = 4.5
        XCTAssertEqual(settings.normalized, settings)
    }
}
