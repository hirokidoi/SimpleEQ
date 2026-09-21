import XCTest
@testable import SimpleEQ

/// バンド↔ユニット分割ロジックを純関数レベルで検証する。
/// 1 ユニットのバンド数上限を超える構成でも全バンドが漏れ・重複なく割り当てられることを担保する
/// (境界誤割当はライブ検証では検出できないため)。
final class EQUnitTests: XCTestCase {

    // MARK: - distributeBands

    // 合計がちょうど total になり、各ユニットが上限以下で、できるだけ均等に分割される。
    func testDistributeBandsBasicCases() {
        let cases: [(total: Int, maxPerUnit: Int, expected: [Int])] = [
            (20, 16, [10, 10]),   // 実機構成 (20 バンド / 上限 16)
            (32, 16, [16, 16]),   // 上限ちょうどで割り切れる
            (20, 7, [7, 7, 6]),   // 3 ユニット・不均等
            (16, 16, [16]),       // 1 ユニットに収まる
            (1, 16, [1]),         // 最小
            (17, 16, [9, 8]),     // 上限を 1 超える → 2 分割で均等寄り
        ]
        for c in cases {
            let got = EQUnit.distributeBands(total: c.total, maxPerUnit: c.maxPerUnit)
            XCTAssertEqual(got, c.expected, "distributeBands(\(c.total), \(c.maxPerUnit))")
            XCTAssertEqual(got.reduce(0, +), c.total, "合計は total と一致すべき")
            XCTAssertTrue(got.allSatisfy { $0 <= c.maxPerUnit }, "各ユニットは上限以下であるべき")
            XCTAssertTrue(got.allSatisfy { $0 >= 1 }, "空ユニットを作らない")
            XCTAssertLessThanOrEqual((got.max() ?? 0) - (got.min() ?? 0), 1, "均等分割 (差は最大 1)")
        }
    }

    // 不正入力は空配列を返す。
    func testDistributeBandsInvalidInput() {
        XCTAssertEqual(EQUnit.distributeBands(total: 0, maxPerUnit: 16), [])
        XCTAssertEqual(EQUnit.distributeBands(total: 20, maxPerUnit: 0), [])
    }

    // MARK: - bandOffsets

    func testBandOffsetsIsPrefixSum() {
        XCTAssertEqual(EQUnit.bandOffsets(forCounts: [10, 10]), [0, 10])
        XCTAssertEqual(EQUnit.bandOffsets(forCounts: [7, 7, 6]), [0, 7, 14])
        XCTAssertEqual(EQUnit.bandOffsets(forCounts: [16]), [0])
    }

    // MARK: - unitAndLocal (band↔(unit,local) 変換)

    // 全 global band が一意の (unit, local) へ写り、局所範囲が prefix-sum と連続一致することを検証する。
    func testUnitAndLocalRoundTripAcrossPartitions() {
        let partitions: [[Int]] = [[10, 10], [16, 16], [7, 7, 6], [16], [9, 8]]
        for counts in partitions {
            let offsets = EQUnit.bandOffsets(forCounts: counts)
            let total = counts.reduce(0, +)

            // 各ユニットが担当する global band を local 昇順で再構成し、0..<total を過不足なく覆うか。
            var reconstructed: [Int] = []
            for band in 0..<total {
                let (u, local) = EQUnit.unitAndLocal(band: band, offsets: offsets)
                XCTAssertTrue(u >= 0 && u < counts.count, "unit が範囲内: band=\(band) counts=\(counts)")
                XCTAssertTrue(local >= 0 && local < counts[u], "local が担当バンド数未満: band=\(band) counts=\(counts)")
                // (unit, local) から global band を逆算すると元に戻る。
                XCTAssertEqual(offsets[u] + local, band, "往復整合: band=\(band) counts=\(counts)")
                reconstructed.append(band)
            }
            XCTAssertEqual(reconstructed, Array(0..<total), "全 band を漏れ・重複なく覆う: counts=\(counts)")

            // 各ユニットの先頭 band は local=0、ユニット境界で local がリセットされる。
            for (u, off) in offsets.enumerated() {
                let (unit0, local0) = EQUnit.unitAndLocal(band: off, offsets: offsets)
                XCTAssertEqual(unit0, u, "ユニット先頭 band=\(off) は unit \(u)")
                XCTAssertEqual(local0, 0, "ユニット先頭は local=0")
            }
        }
    }

    func testActualBandCountPartitionsCleanly() {
        let counts = EQUnit.distributeBands(total: EQSpec.bandCount, maxPerUnit: 16)
        XCTAssertEqual(counts.reduce(0, +), EQSpec.bandCount)
        let offsets = EQUnit.bandOffsets(forCounts: counts)
        var seen = Set<String>()
        for band in 0..<EQSpec.bandCount {
            let (u, local) = EQUnit.unitAndLocal(band: band, offsets: offsets)
            XCTAssertTrue(seen.insert("\(u):\(local)").inserted, "(unit,local) は一意: band=\(band)")
        }
        XCTAssertEqual(seen.count, EQSpec.bandCount)
    }
}
