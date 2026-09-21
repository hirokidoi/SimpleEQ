import XCTest
@testable import SimpleEQ

final class MixerLevelStoreTests: XCTestCase {
    private let slotCount = 4

    private func makeStore() -> MixerLevelStore { MixerLevelStore(slotCount: slotCount) }

    /// 1 サイクルぶんの折り込み。省略した項目は据え置きの値を書く。
    private func fold(
        _ store: MixerLevelStore, tableGeneration: UInt32 = 0, index: Int = 0,
        clientID: UInt32 = 7, processID: UInt32 = 100, outputCycleSeq: UInt32,
        clipEventCount: UInt32 = 0, peak: Float = 0, appliedGain: Float = 1
    ) {
        store.beginFold(tableGeneration: tableGeneration)
        store.foldSlot(
            index: index, clientID: clientID, processID: processID, outputCycleSeq: outputCycleSeq,
            clipEventCount: clipEventCount, peak: peak, appliedGain: appliedGain
        )
    }

    private func take(_ store: MixerLevelStore) -> [MixerLevelStore.Sample] {
        var samples = store.makeSampleBuffer()
        store.takeSamples(into: &samples)
        return samples
    }

    // MARK: - 表示値

    func testFoldedValuesReachTheDrawingSide() {
        let store = makeStore()
        fold(store, clientID: 42, processID: 501, outputCycleSeq: 1, clipEventCount: 3, peak: 0.5, appliedGain: 0.25)

        let sample = take(store)[0]
        XCTAssertEqual(sample.clientID, 42)
        XCTAssertEqual(sample.processID, 501)
        XCTAssertTrue(sample.active)
        XCTAssertEqual(sample.peak, 0.5)
        XCTAssertEqual(sample.clipEventCount, 3)
        XCTAssertEqual(sample.appliedGain, 0.25)
    }

    func testPeakHoldsTheRunningMaximumAndClearsOnTakeOut() {
        let store = makeStore()
        fold(store, outputCycleSeq: 1, peak: 0.3)
        fold(store, outputCycleSeq: 2, peak: 0.9)
        fold(store, outputCycleSeq: 3, peak: 0.4)

        XCTAssertEqual(take(store)[0].peak, 0.9, "取り出しまでの最大が残る")
        XCTAssertEqual(take(store)[0].peak, 0, "取り出しでクリアされる")
    }

    /// 同じサイクルを 2 度読んだ回のピークは、その回に届いた値ではない。
    func testPeakIsNotFoldedWhenTheOutputCycleDidNotAdvance() {
        let store = makeStore()
        fold(store, outputCycleSeq: 5, peak: 0.2)
        fold(store, outputCycleSeq: 5, peak: 0.8)

        XCTAssertEqual(take(store)[0].peak, 0.2)
    }

    /// クリップは取りこぼしてはならない判定なので、取り出しの周期に依らずカウンタの差分で読める。
    func testClipCountSurvivesRegardlessOfTheTakeOutPeriod() {
        let store = makeStore()
        for cycle in 1...10 { fold(store, outputCycleSeq: UInt32(cycle), clipEventCount: UInt32(cycle)) }
        XCTAssertEqual(take(store)[0].clipEventCount, 10)

        for cycle in 11...13 { fold(store, outputCycleSeq: UInt32(cycle), clipEventCount: UInt32(cycle)) }
        XCTAssertEqual(take(store)[0].clipEventCount, 13, "取り出しでクリアされない")
    }

    // MARK: - 名簿の版数

    func testRosterRevisionAdvancesOnTableGenerationChange() {
        let store = makeStore()
        fold(store, tableGeneration: 1, outputCycleSeq: 1)
        let before = store.rosterRevision

        fold(store, tableGeneration: 1, outputCycleSeq: 2)
        XCTAssertEqual(store.rosterRevision, before, "同じ世代のままでは進まない")

        fold(store, tableGeneration: 2, outputCycleSeq: 3)
        XCTAssertGreaterThan(store.rosterRevision, before, "席の増減で進む")
    }

    /// 鳴り始めは表の世代を動かさないため、ここで拾わないと候補プールに現れない。
    func testRosterRevisionAdvancesWhenASlotStartsPlaying() {
        let store = makeStore()
        fold(store, tableGeneration: 1, outputCycleSeq: 0)
        let seated = store.rosterRevision

        fold(store, tableGeneration: 1, outputCycleSeq: 1)
        XCTAssertGreaterThan(store.rosterRevision, seated, "0 から非 0 への初回出力で進む")

        let playing = store.rosterRevision
        fold(store, tableGeneration: 1, outputCycleSeq: 2)
        fold(store, tableGeneration: 1, outputCycleSeq: 3)
        XCTAssertEqual(store.rosterRevision, playing, "鳴り続けているだけでは進まない")
    }

    func testEmptySlotsAreReportedAsInactive() {
        let store = makeStore()
        store.beginFold(tableGeneration: 1)
        for index in 0..<slotCount {
            store.foldSlot(
                index: index, clientID: 0, processID: 0, outputCycleSeq: 0,
                clipEventCount: 0, peak: 0, appliedGain: 1
            )
        }
        for sample in take(store) {
            XCTAssertEqual(sample.clientID, 0)
            XCTAssertFalse(sample.active)
        }
    }
}
