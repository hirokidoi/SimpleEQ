import XCTest
@testable import SimpleEQ

/// 非対称平滑化 (attack/release)、および L/R マスターレベルの取得を実際の FFT パイプラインを通して検証する。
final class LevelMeterTests: XCTestCase {
    private let attack = 0.8
    private let release = 0.3

    // MARK: - deriveFFTSize(sampleRate:) / hop の到来レート

    func testDeriveFFTSizeMatchesExpectedSizeAcrossSupportedRates() {
        XCTAssertEqual(LevelMeter.deriveFFTSize(sampleRate: 48000), 4096)
        XCTAssertEqual(LevelMeter.deriveFFTSize(sampleRate: 44100), 4096)
        XCTAssertEqual(LevelMeter.deriveFFTSize(sampleRate: 88200), 8192)
        XCTAssertEqual(LevelMeter.deriveFFTSize(sampleRate: 96000), 8192)
    }

    func testAnalyzedWindowCountMatchesHopArrivalRegardlessOfDrawCadence() {
        for rate in TestSampleRates.all {
            let fftSize = LevelMeter.deriveFFTSize(sampleRate: rate)
            let hopSize = LevelMeter.deriveHopSize(fftSize: fftSize)
            let totalHops = 5

            // 粗い刻み: 複数 hop ぶんを溜めてから 1 回だけ解析を呼ぶ。
            // capture() は 1 回の呼び出しで AudioConfig.maxRenderFrames を超える書き込みをクランプするため、
            // 書き込み自体はその上限内のチャンクへ分けて行う (取り込みは複数回・解析は 1 回)。
            let coarse = LevelMeter(bandFrequencies: EQSpec.FREQS, appliedSampleRate: rate)
            var remaining = hopSize * totalHops
            let chunk = [Float](repeating: 0.5, count: min(AudioConfig.maxRenderFrames, remaining))
            while remaining > 0 {
                let n = min(chunk.count, remaining)
                chunk.withUnsafeBufferPointer { ptr in
                    coarse.capture(ptr.baseAddress!, frameCount: n, channels: 1)
                }
                remaining -= n
            }
            _ = coarse.analyzeAvailableHops()
            XCTAssertEqual(coarse.hopsAnalyzedForTesting, totalHops, "sampleRate=\(rate) (粗い刻み)")

            // 細かい刻み: hop 到着のたびに解析を呼ぶ。
            let fine = LevelMeter(bandFrequencies: EQSpec.FREQS, appliedSampleRate: rate)
            for _ in 0..<totalHops {
                let hop = [Float](repeating: 0.5, count: hopSize)
                hop.withUnsafeBufferPointer { ptr in fine.capture(ptr.baseAddress!, frameCount: hopSize, channels: 1) }
                _ = fine.analyzeAvailableHops()
            }
            XCTAssertEqual(fine.hopsAnalyzedForTesting, totalHops, "sampleRate=\(rate) (細かい刻み)")
        }
    }

    // 目標が現在値より上 (立ち上がり) のときは attack 係数で寄る。
    func testRisingUsesAttack() {
        let out = LevelMeter.smoothed(prev: 0, target: 10, attack: attack, release: release)
        XCTAssertEqual(out, 0 + (10 - 0) * attack, accuracy: 1e-9)
    }

    // 目標が現在値より下 (下がり) のときは release 係数で寄る。attack より緩やかに動く。
    func testFallingUsesRelease() {
        let out = LevelMeter.smoothed(prev: 10, target: 0, attack: attack, release: release)
        XCTAssertEqual(out, 10 + (0 - 10) * release, accuracy: 1e-9)
        // 同じ振れ幅なら立ち上がりより移動量が小さい (release < attack)。
        let rise = LevelMeter.smoothed(prev: 0, target: 10, attack: attack, release: release)
        XCTAssertLessThan(abs(out - 10), abs(rise - 0))
    }

    // 目標＝現在値なら動かない。
    func testEqualTargetHolds() {
        XCTAssertEqual(LevelMeter.smoothed(prev: -12, target: -12, attack: attack, release: release), -12, accuracy: 1e-9)
    }

    // 係数 1 は即時追従、0 は不動。
    func testCoefBounds() {
        XCTAssertEqual(LevelMeter.smoothed(prev: -60, target: 0, attack: 1, release: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(LevelMeter.smoothed(prev: -60, target: 0, attack: 0, release: 0), -60, accuracy: 1e-9)
    }

    // MARK: - advancePeak (ピークホールド)

    // 表示レベルが現在のピーク以上なら、ピークをそのレベルへ引き上げてホールドを再開する。
    func testPeakRisesToLevelAndResetsHold() {
        var hold = 0.0
        let out = LevelMeter.advancePeak(level: -3, peak: -10, holdRemaining: &hold, dt: 0.5, holdSeconds: 1.2, decayDbPerSec: 24)
        XCTAssertEqual(out, -3, accuracy: 1e-9)
        XCTAssertEqual(hold, 1.2, accuracy: 1e-9)
    }

    // 表示レベルがピーク未満でもホールド残り時間があるうちはピークを維持し、残り時間を消費する。
    func testPeakHoldsWhileRemainingTime() {
        var hold = 1.0
        let out = LevelMeter.advancePeak(level: -20, peak: -10, holdRemaining: &hold, dt: 0.4, holdSeconds: 1.2, decayDbPerSec: 24)
        XCTAssertEqual(out, -10, accuracy: 1e-9)
        XCTAssertEqual(hold, 0.6, accuracy: 1e-9)
    }

    // ホールド時間が尽きたら decayDbPerSec * dt 分だけピークを下げる。ただし表示レベルを下回らない。
    func testPeakDecaysAfterHoldExpiresButNotBelowLevel() {
        var hold = 0.0
        let out = LevelMeter.advancePeak(level: -30, peak: -10, holdRemaining: &hold, dt: 0.5, holdSeconds: 1.2, decayDbPerSec: 24)
        XCTAssertEqual(out, -22, accuracy: 1e-9)

        var hold2 = 0.0
        let clamped = LevelMeter.advancePeak(level: -15, peak: -10, holdRemaining: &hold2, dt: 1.0, holdSeconds: 1.2, decayDbPerSec: 24)
        XCTAssertEqual(clamped, -15, accuracy: 1e-9)
    }

    // decayDbPerSec=0 は「減衰しない」ではなく「ホールド終了後は瞬時に表示レベルへ落ちる」を意味する。
    // ごく小さい dt でも、ホールドが尽きていれば peak ではなく level を返す。
    func testPeakDecayDbPerSecZeroSnapsToLevelInsteadOfHoldingForever() {
        var hold = 0.0
        let out = LevelMeter.advancePeak(level: -40, peak: -5, holdRemaining: &hold, dt: 0.001, holdSeconds: 1.2, decayDbPerSec: 0)
        XCTAssertEqual(out, -40, accuracy: 1e-9)
    }

    // ホールド中は decayDbPerSec=0 でも通常通りピークを維持する (瞬時に消えるのはホールド終了後のみ)。
    func testPeakDecayDbPerSecZeroStillHoldsWhileRemainingTime() {
        var hold = 0.5
        let out = LevelMeter.advancePeak(level: -40, peak: -5, holdRemaining: &hold, dt: 0.1, holdSeconds: 1.2, decayDbPerSec: 0)
        XCTAssertEqual(out, -5, accuracy: 1e-9)
        XCTAssertEqual(hold, 0.4, accuracy: 1e-9)
    }

    // MARK: - resetForRestart (メインウインドウ再表示時のビジュアライザちらつき対策)

    private func makeMeter() -> LevelMeter {
        LevelMeter(bandFrequencies: EQSpec.FREQS, appliedSampleRate: AudioConfig.appliedSampleRate)
    }

    // 非表示中も呼ばれ続ける realtime コールバックを模擬する。
    private func writeFullScaleDummyAudio(into meter: LevelMeter, frameCount: Int = 8192) {
        let samples = [Float](repeating: 1.0, count: frameCount)
        samples.withUnsafeBufferPointer { ptr in
            meter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 1)
        }
    }

    func testResetForRestartDiscardsBacklogSoAnalysisStaysAtFloor() {
        let meter = makeMeter()
        let floor = meter.snapshot()

        writeFullScaleDummyAudio(into: meter)
        meter.resetForRestart()
        meter.analyzeAvailableHops()

        XCTAssertEqual(meter.snapshot(), floor)
    }

    func testAnalyzeWithoutResetWouldConsumeBacklog() {
        let meter = makeMeter()
        let floor = meter.snapshot()

        writeFullScaleDummyAudio(into: meter)
        meter.analyzeAvailableHops()

        XCTAssertNotEqual(meter.snapshot(), floor)
    }

    private func writeSilentDummyAudio(into meter: LevelMeter, frameCount: Int = 8192) {
        let samples = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { ptr in
            meter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 1)
        }
    }

    // MARK: - resetPeaksToCurrentLevel (ピークホールド再有効化時の凍結値クリア)

    // 大音量入力の直後に無音を数回解析させると、
    // release 平滑化で表示レベルは下がる一方ピークはホールド時間が尽きるまで凍結され続ける。
    func testResetPeaksToCurrentLevelClearsStalePeakDisparity() {
        let meter = makeMeter()
        writeFullScaleDummyAudio(into: meter)
        meter.analyzeAvailableHops()

        for _ in 0..<3 {
            writeSilentDummyAudio(into: meter)
            meter.analyzeAvailableHops()
        }
        let beforeReset = meter.snapshot()
        XCTAssertTrue(
            zip(beforeReset.peaks, beforeReset.levels).contains { peak, level in peak > level },
            "ホールド中のピークは表示レベルより高いまま保持されているはず"
        )

        meter.resetPeaksToCurrentLevel()
        let afterReset = meter.snapshot()
        XCTAssertEqual(afterReset.peaks, afterReset.levels)
    }

    // MARK: - stereo (L/R マスターレベル)

    private func writeStereoDummyAudio(into meter: LevelMeter, left: Float, right: Float, frameCount: Int = 8192) {
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for f in 0..<frameCount {
            interleaved[f * 2] = left
            interleaved[f * 2 + 1] = right
        }
        interleaved.withUnsafeBufferPointer { ptr in
            meter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 2)
        }
    }

    // L/R で異なる振幅のステレオ音声を投入すると、それぞれ独立した dBFS として区別されること。
    func testStereoCaptureProducesDistinctLeftRightLevels() {
        let meter = makeMeter()
        writeStereoDummyAudio(into: meter, left: 1.0, right: 0.5)
        meter.analyzeAvailableHops()

        let stereo = meter.snapshot().stereo
        XCTAssertGreaterThan(stereo.leftDb, stereo.rightDb)
    }

    func testMonoCaptureDoesNotPopulateStereoLevels() {
        let meter = makeMeter()
        let floorStereo = meter.snapshot().stereo

        writeFullScaleDummyAudio(into: meter)
        meter.analyzeAvailableHops()

        XCTAssertEqual(meter.snapshot().stereo, floorStereo)
    }

    func testResetForRestartDiscardsStereoBacklogSoAnalysisStaysAtFloor() {
        let meter = makeMeter()
        let floorStereo = meter.snapshot().stereo

        writeStereoDummyAudio(into: meter, left: 1.0, right: 1.0)
        meter.resetForRestart()
        meter.analyzeAvailableHops()

        XCTAssertEqual(meter.snapshot().stereo, floorStereo)
    }

    // 大音量入力の直後に無音を数回解析させ、L/R のピークホールドが保持されている状態から凍結値が現在の表示レベルへ揃うこと。
    func testResetPeaksToCurrentLevelClearsStalePeakDisparityForStereo() {
        let meter = makeMeter()
        writeStereoDummyAudio(into: meter, left: 1.0, right: 1.0)
        meter.analyzeAvailableHops()

        for _ in 0..<3 {
            writeStereoDummyAudio(into: meter, left: 0, right: 0)
            meter.analyzeAvailableHops()
        }
        let beforeReset = meter.snapshot().stereo
        XCTAssertTrue(
            beforeReset.leftPeakDb > beforeReset.leftDb && beforeReset.rightPeakDb > beforeReset.rightDb,
            "ホールド中の L/R ピークは表示レベルより高いまま保持されているはず"
        )

        meter.resetPeaksToCurrentLevel()
        let afterReset = meter.snapshot().stereo
        XCTAssertEqual(afterReset.leftPeakDb, afterReset.leftDb)
        XCTAssertEqual(afterReset.rightPeakDb, afterReset.rightDb)
    }

    // MARK: - stereoPeakRing (ダウンミックスループ内集計)

    func testStereoPeakAccumulatesMaxAcrossMultipleCaptureCalls() {
        let combined = makeMeter()
        writeStereoDummyAudio(into: combined, left: 0.1, right: 0.05, frameCount: 1024)
        writeStereoDummyAudio(into: combined, left: 0.9, right: 0.8, frameCount: 1024)
        writeStereoDummyAudio(into: combined, left: 0.1, right: 0.05, frameCount: 1024)
        combined.analyzeAvailableHops()
        let combinedStereo = combined.snapshot().stereo

        // 対照実験: 低振幅の呼び出しだけを与えた場合。
        let lowOnly = makeMeter()
        writeStereoDummyAudio(into: lowOnly, left: 0.1, right: 0.05, frameCount: 1024 * 3)
        lowOnly.analyzeAvailableHops()
        let lowOnlyStereo = lowOnly.snapshot().stereo

        XCTAssertGreaterThan(combinedStereo.leftDb, lowOnlyStereo.leftDb)
        XCTAssertGreaterThan(combinedStereo.rightDb, lowOnlyStereo.rightDb)
    }

    func testStereoCaptureEnabledFalseGatesProducerSoStereoStaysAtFloor() {
        let meter = makeMeter()
        let floorStereo = meter.snapshot().stereo
        meter.stereoCaptureEnabled = false

        writeStereoDummyAudio(into: meter, left: 1.0, right: 1.0)
        meter.analyzeAvailableHops()

        XCTAssertEqual(meter.snapshot().stereo, floorStereo)
    }

    // MARK: - 取り込みのゲート

    func testCaptureEnabledFalseGatesCaptureEntirely() {
        let meter = makeMeter()
        let floor = LevelMeter.Snapshot.silent(bandCount: EQSpec.bandCount)
        meter.captureEnabled = false

        writeFullScaleDummyAudio(into: meter)
        _ = meter.analyzeAvailableHops()

        XCTAssertEqual(meter.snapshot(), floor, "captureEnabled=false の間は capture() が書き込まないため解析対象が無い")
    }

    // MARK: - 平滑化とピークの進行

    // L/R の対象値は捕捉した振幅から閉形式で求まるため、
    // smoothed(_:target:attack:release:) を hop の数だけ適用した理論値と突き合わせられる
    // (バンドは FFT を経るため理論値を閉形式で求められず、hopsAnalyzedForTesting による回数の一致で確認する)。
    func testStereoSmoothingRunsOncePerHopMatchingBandUpdateCount() {
        let meter = makeMeter()
        meter.attackCoef = 0.4
        meter.releaseCoef = 0.4
        let fftSize = LevelMeter.deriveFFTSize(sampleRate: meter.appliedSampleRate)
        let hopSize = LevelMeter.deriveHopSize(fftSize: fftSize)
        let totalHops = 3
        let amplitude: Float = 0.25

        writeStereoDummyAudio(into: meter, left: amplitude, right: amplitude, frameCount: hopSize * totalHops)
        meter.analyzeAvailableHops()

        XCTAssertEqual(meter.hopsAnalyzedForTesting, totalHops, "前提: バンドは hop の数だけ解析される")

        let target = Double(20 * log10(amplitude))
        var expected = LevelMeter.silentLevelDb
        for _ in 0..<totalHops {
            expected = LevelMeter.smoothed(prev: expected, target: target, attack: 0.4, release: 0.4)
        }
        let stereo = meter.snapshot().stereo
        XCTAssertEqual(stereo.leftDb, expected, accuracy: 1e-6)
        XCTAssertEqual(stereo.rightDb, expected, accuracy: 1e-6)
    }

    func testStereoConvergenceIsIndependentOfDrawCadence() {
        let rate = AudioConfig.appliedSampleRate
        let fftSize = LevelMeter.deriveFFTSize(sampleRate: rate)
        let hopSize = LevelMeter.deriveHopSize(fftSize: fftSize)
        let totalHops = 4
        let amplitude: Float = 0.6

        func makeInterleaved(frameCount: Int) -> [Float] {
            var interleaved = [Float](repeating: 0, count: frameCount * 2)
            for f in 0..<frameCount {
                interleaved[f * 2] = amplitude
                interleaved[f * 2 + 1] = amplitude
            }
            return interleaved
        }

        // 粗い刻み: 複数 hop ぶんを一度に溜めてから 1 回だけ解析を呼ぶ。
        let coarse = LevelMeter(bandFrequencies: EQSpec.FREQS, appliedSampleRate: rate)
        let coarseSamples = makeInterleaved(frameCount: hopSize * totalHops)
        coarseSamples.withUnsafeBufferPointer { ptr in
            coarse.capture(ptr.baseAddress!, frameCount: hopSize * totalHops, channels: 2)
        }
        _ = coarse.analyzeAvailableHops()

        // 細かい刻み: hop 到着のたびに解析を呼ぶ。
        let fine = LevelMeter(bandFrequencies: EQSpec.FREQS, appliedSampleRate: rate)
        for _ in 0..<totalHops {
            let hop = makeInterleaved(frameCount: hopSize)
            hop.withUnsafeBufferPointer { ptr in fine.capture(ptr.baseAddress!, frameCount: hopSize, channels: 2) }
            _ = fine.analyzeAvailableHops()
        }

        XCTAssertEqual(coarse.snapshot().stereo, fine.snapshot().stereo, "描く刻みによらず同じ実時間ぶんの進み方になること")
    }

    // MARK: - 組み直しと作り直し

    // 錠が守るのは実際の並行呼び出しだが、ここでは同一スレッド上で組み直しと解析を繰り返す。
    func testRebuildAcrossRateChangesKeepsInternalStateConsistent() {
        let meter = makeMeter()
        for rate in TestSampleRates.all + [AudioConfig.baseSampleRate] {
            meter.rebuild(appliedSampleRate: rate)
            XCTAssertEqual(meter.appliedSampleRate, rate)
            let hopSize = LevelMeter.deriveHopSize(fftSize: LevelMeter.deriveFFTSize(sampleRate: rate))
            writeFullScaleDummyAudio(into: meter, frameCount: hopSize * 2)
            _ = meter.analyzeAvailableHops()
            let snap = meter.snapshot()
            XCTAssertEqual(snap.levels.count, EQSpec.bandCount, "sampleRate=\(rate)")
            XCTAssertTrue(snap.levels.allSatisfy(\.isFinite), "sampleRate=\(rate)")
            XCTAssertTrue(snap.peaks.allSatisfy(\.isFinite), "sampleRate=\(rate)")
        }
    }

    func testResetForRestartDiscardsStaleDisplayValuesBeforeTheNextAnalysis() {
        let meter = makeMeter()
        let floor = LevelMeter.Snapshot.silent(bandCount: EQSpec.bandCount)
        writeFullScaleDummyAudio(into: meter)
        _ = meter.analyzeAvailableHops()
        XCTAssertNotEqual(meter.snapshot(), floor, "前提: 解析済みで非フロア")

        // 作り直しの契機を検知した回のシーケンス: 作り直し → (新しい音の) 解析。
        meter.resetForRestart()
        writeSilentDummyAudio(into: meter)
        _ = meter.analyzeAvailableHops()

        XCTAssertEqual(meter.snapshot(), floor, "作り直しを挟んだため、古い表示値が新しい解析へ接ぎ木されない")
    }
}
