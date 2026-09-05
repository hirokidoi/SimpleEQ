import XCTest
@testable import SimpleEQ

/// EQResponseProbe の実機統合テスト。実 AUNBandEQ を組む (出力デバイスは不要 — オフラインのエフェクトチェーンのみ)。
/// ウォームアップ長と内部状態の落とし方の妥当性をここで担保する。
final class EQResponseProbeTests: XCTestCase {
    private let perfect: [Double] = [-2, 0, 2, 4, 5, 6, 5, 4, 3, 2, 1, 2, 3, 4, 5, 6, 7, 8, 7, 5]
    private let eargasmExplosion: [Double] = [-2, 0, 2, 4, 5, 6, 5, 4, 3, 2, 1, 2, 3, 4, 5, 3, 0, 8, 7, 5]
    private var flat: [Double] { [Double](repeating: 0, count: EQSpec.bandCount) }

    // 検算 — Flat は全レートで加重・最悪ともに 0.00dB (許容 0.01)。
    func testFlatIsZeroDbAcrossSampleRates() {
        let probe = EQResponseProbe()
        for rate in [44100.0, 48000.0, 96000.0] {
            guard let response = probe.measure(curve: flat, sampleRate: rate) else {
                XCTFail("measure failed at fs=\(rate)")
                continue
            }
            XCTAssertEqual(response.energyWeightedGainDb, 0, accuracy: 0.01, "fs=\(rate)")
            XCTAssertEqual(response.worstCaseGainDb, 0, accuracy: 0.01, "fs=\(rate)")
        }
    }

    /// 期待値は実測値 (許容 0.1dB)。
    /// レートごとに測るのは、ウォームアップ長を秒で持っている以上レートによって不足しうるため。
    func testMatchesHarnessValuesAt48kHz() {
        let probe = EQResponseProbe()

        guard let perfectResponse = probe.measure(curve: perfect, sampleRate: 48000) else {
            XCTFail("measure failed (Perfect)")
            return
        }
        XCTAssertEqual(perfectResponse.energyWeightedGainDb, 6.51, accuracy: 0.1)
        XCTAssertEqual(perfectResponse.worstCaseGainDb, 12.06, accuracy: 0.1)

        guard let eeResponse = probe.measure(curve: eargasmExplosion, sampleRate: 48000) else {
            XCTFail("measure failed (Eargasm Explosion)")
            return
        }
        XCTAssertEqual(eeResponse.energyWeightedGainDb, 5.50, accuracy: 0.1)
        XCTAssertEqual(eeResponse.worstCaseGainDb, 10.71, accuracy: 0.1)

        let perfectByRate: [Double: (energy: Double, worst: Double)] = [
            44100: (6.53, 12.16),
            96000: (6.44, 11.82),
        ]
        for (rate, expected) in perfectByRate {
            guard let response = probe.measure(curve: perfect, sampleRate: rate) else {
                XCTFail("measure failed at fs=\(rate)")
                continue
            }
            XCTAssertEqual(response.energyWeightedGainDb, expected.energy, accuracy: 0.1, "fs=\(rate)")
            XCTAssertEqual(response.worstCaseGainDb, expected.worst, accuracy: 0.1, "fs=\(rate)")
        }
    }

    // 状態の持ち越しがないこと — Perfect → Flat → Perfect で 1 回目と 3 回目が一致 (許容 0.01)。
    func testNoCarryOverBetweenMeasurements() {
        let probe = EQResponseProbe()

        guard let first = probe.measure(curve: perfect, sampleRate: 48000) else {
            XCTFail("measure failed (1st Perfect)")
            return
        }
        guard probe.measure(curve: flat, sampleRate: 48000) != nil else {
            XCTFail("measure failed (Flat)")
            return
        }
        guard let third = probe.measure(curve: perfect, sampleRate: 48000) else {
            XCTFail("measure failed (2nd Perfect)")
            return
        }

        XCTAssertEqual(first.energyWeightedGainDb, third.energyWeightedGainDb, accuracy: 0.01)
        XCTAssertEqual(first.worstCaseGainDb, third.worstCaseGainDb, accuracy: 0.01)
    }

    /// レート追随。Flat は再構築が省かれても 0.00dB になるため、レートで応答が変わるカーブを使い、
    /// 新しいレートで組み直した測定器と値が一致することで判じる。
    func testChainRebuildsWhenRequestedSampleRateChanges() {
        let reused = EQResponseProbe()
        _ = reused.measure(curve: perfect, sampleRate: 48000)
        guard let afterRateChange = reused.measure(curve: perfect, sampleRate: 96000) else {
            XCTFail("measure failed at fs=96000 (reused)")
            return
        }

        guard let fresh = EQResponseProbe().measure(curve: perfect, sampleRate: 96000) else {
            XCTFail("measure failed at fs=96000 (fresh)")
            return
        }

        XCTAssertEqual(afterRateChange.energyWeightedGainDb, fresh.energyWeightedGainDb, accuracy: 0.01)
        XCTAssertEqual(afterRateChange.worstCaseGainDb, fresh.worstCaseGainDb, accuracy: 0.01)
    }

    // モノラル構成の成立 — 1ch でチェーンが組める (measure が nil を返さない)。
    func testMonoChainCanBeBuilt() {
        let probe = EQResponseProbe()
        XCTAssertNotNil(probe.measure(curve: flat, sampleRate: 48000))
    }
}
