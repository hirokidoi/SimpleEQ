import XCTest
@testable import SimpleEQ

final class EQSpecTests: XCTestCase {
    func testFreqsHasTwentyBandsMatchingSpec() {
        let expected: [Double] = [
            22, 31.5, 44, 63, 87, 125, 175, 250, 350, 500,
            700, 1000, 1400, 2000, 2800, 4000, 5600, 8000, 11000, 16000
        ]
        XCTAssertEqual(EQSpec.FREQS, expected)
        XCTAssertEqual(EQSpec.bandCount, 20)
    }

    func testAllBuiltInSeedsHaveOneGainPerBand() {
        for seed in EQSpec.builtInSeeds.values {
            XCTAssertEqual(seed.curve.count, EQSpec.bandCount)
        }
    }

    func testOnlyFirstThreeSlotsHaveBuiltInSeeds() {
        XCTAssertEqual(Set(EQSpec.builtInSeeds.keys), [.slot1, .slot2, .slot3])
    }

    func testFlatPresetIsAllZero() {
        XCTAssertEqual(EQSpec.builtInSeeds[.slot1]?.curve, Array(repeating: 0, count: EQSpec.bandCount))
        XCTAssertEqual(EQSpec.builtInSeeds[.slot1]?.preamp, 0)
    }

    func testAllBuiltInSeedPreampsAreWithinRange() {
        for seed in EQSpec.builtInSeeds.values {
            XCTAssertTrue((EQSpec.DB_MIN...EQSpec.DB_MAX).contains(seed.preamp))
        }
    }

    func testPerfectAndEargasmShareTheSamePreampDifferingFromFlat() {
        XCTAssertEqual(EQSpec.builtInSeeds[.slot2]?.preamp, EQSpec.builtInSeeds[.slot3]?.preamp)
        XCTAssertNotEqual(EQSpec.builtInSeeds[.slot2]?.preamp, EQSpec.builtInSeeds[.slot1]?.preamp)
    }

    func testPerfectAndEargasmDifferOnlyAt4kAnd5600Hz() {
        guard let perfect = EQSpec.builtInSeeds[.slot2]?.curve, let eargasm = EQSpec.builtInSeeds[.slot3]?.curve else {
            return XCTFail("slot2/slot3 の組み込みシードが存在しない")
        }
        let expectedDifferingFreqs: Set<Double> = [4000, 5600]
        var actualDifferingFreqs: Set<Double> = []
        for i in 0..<EQSpec.bandCount where perfect[i] != eargasm[i] {
            actualDifferingFreqs.insert(EQSpec.FREQS[i])
        }
        XCTAssertEqual(actualDifferingFreqs, expectedDifferingFreqs)
    }

    func testClampDbStaysWithinRange() {
        XCTAssertEqual(EQSpec.clampDb(0), 0)
        XCTAssertEqual(EQSpec.clampDb(EQSpec.DB_MAX), EQSpec.DB_MAX)
        XCTAssertEqual(EQSpec.clampDb(EQSpec.DB_MIN), EQSpec.DB_MIN)
        XCTAssertEqual(EQSpec.clampDb(EQSpec.DB_MAX + 100), EQSpec.DB_MAX)
        XCTAssertEqual(EQSpec.clampDb(EQSpec.DB_MIN - 100), EQSpec.DB_MIN)
    }
}
