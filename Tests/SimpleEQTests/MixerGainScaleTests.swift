import XCTest
@testable import SimpleEQ

final class MixerGainScaleTests: XCTestCase {

    func testPositionAndDbRoundTripAcrossTheAxis() {
        for db in MixerGainScale.detentsDb {
            let position = MixerGainScale.position(ofDb: db)
            XCTAssertEqual(MixerGainScale.db(atPosition: position), db, accuracy: 1e-9, "db=\(db)")
        }
    }

    func testDbIsSnappedToADetent() {
        for position in stride(from: 0.0, through: 1.0, by: 0.001) {
            let db = MixerGainScale.db(atPosition: position)
            XCTAssertTrue(
                MixerGainScale.detentsDb.contains { abs($0 - db) < 1e-9 },
                "position=\(position) db=\(db)"
            )
        }
    }

    /// 段は等幅で並ぶ。位置あたりの段数が全域で一定であることが軸の要件。
    func testDetentsAreEvenlySpacedInPosition() {
        let positions = MixerGainScale.detentsDb.map(MixerGainScale.position(ofDb:))
        let gaps = zip(positions.dropFirst(), positions).map(-)
        let expected = 1 / Double(MixerGainScale.stepCount - 1)
        for gap in gaps {
            XCTAssertEqual(gap, expected, accuracy: 1e-12)
        }
    }

    /// 0dB 側ほど 1 段の dB が小さい。等幅の段が細かい調整を担う根拠。
    func testStepSizeShrinksTowardUnity() {
        let detents = MixerGainScale.detentsDb
        XCTAssertEqual(detents.last, 0)
        XCTAssertEqual(detents.first, MixerGainScale.floorDb)
        let nearUnity = detents[detents.count - 1] - detents[detents.count - 2]
        let nearFloor = detents[1] - detents[0]
        XCTAssertLessThan(nearUnity, nearFloor)
    }

    func testBandBoundariesFallOnDetents() {
        for band in MixerGainScale.bands {
            XCTAssertTrue(
                MixerGainScale.detentsDb.contains { abs($0 - band.untilDb) < 1e-9 },
                "境界 \(band.untilDb) が段に乗っていない"
            )
        }
    }

    func testTopOfTheAxisIsUnityAndNeverAmplifies() {
        XCTAssertEqual(MixerGainScale.db(atPosition: 1), 0)
        XCTAssertEqual(MixerGainScale.gain(atPosition: 1), MixerGainScale.unityGain)
        for position in stride(from: 0.0, through: 1.0, by: 0.01) {
            XCTAssertLessThanOrEqual(MixerGainScale.gain(atPosition: position), MixerGainScale.unityGain)
        }
    }

    /// 最下端は下限の段の延長ではなく無音の別状態。
    func testBottomOfTheAxisIsSilenceRatherThanTheFloorStep() {
        XCTAssertEqual(MixerGainScale.gain(atPosition: 0), MixerGainScale.silentGain)
        XCTAssertGreaterThan(
            MixerGainScale.gain(atPosition: 0.05), MixerGainScale.silentGain,
            "下限のすぐ内側は無音ではない"
        )
        XCTAssertEqual(MixerGainScale.position(ofGain: MixerGainScale.silentGain), 0)
    }

    /// 下限そのものは位置 0 と重なり、そこは無音が占める (上の境界のテストを参照)。
    func testGainRoundTripsThroughPosition() {
        for db in MixerGainScale.detentsDb.dropFirst() {
            let gain = pow(10, db / 20)
            let position = MixerGainScale.position(ofGain: gain)
            XCTAssertEqual(MixerGainScale.gain(atPosition: position), gain, accuracy: 1e-9, "db=\(db)")
        }
    }

    func testStepCountMatchesTheDetentList() {
        XCTAssertEqual(MixerGainScale.stepCount, MixerGainScale.detentsDb.count)
    }

    func testNormalizedGainClampsIntoTheAxis() {
        XCTAssertEqual(MixerGainScale.normalizedGain(2), MixerGainScale.unityGain, "増幅させない")
        XCTAssertEqual(MixerGainScale.normalizedGain(-1), MixerGainScale.silentGain)
        XCTAssertEqual(MixerGainScale.normalizedGain(.nan), MixerGainScale.silentGain)
        XCTAssertEqual(
            MixerGainScale.normalizedGain(1e-9), MixerGainScale.silentGain,
            "下限を割る値は無音として扱う"
        )
        let coarse = MixerGainScale.normalizedGain(pow(10, -20.4 / 20))
        XCTAssertEqual(20 * log10(coarse), -20, accuracy: 1e-9, "1dB の帯へ揃える")
        let fine = MixerGainScale.normalizedGain(pow(10, -1.23 / 20))
        XCTAssertEqual(20 * log10(fine), -1.2, accuracy: 1e-9, "0.1dB の帯へ揃える")
    }

    func testTextCarriesOneDecimalAndSpellsOutSilence() {
        XCTAssertEqual(MixerGainScale.text(forGain: MixerGainScale.silentGain), MixerGainScale.silentText)
        XCTAssertEqual(MixerGainScale.text(forGain: 1), "0.0 dB")
        XCTAssertEqual(MixerGainScale.text(forGain: pow(10, -12.0 / 20)), "-12.0 dB")
        XCTAssertEqual(MixerGainScale.text(forGain: pow(10, -1.5 / 20)), "-1.5 dB")
    }
}
