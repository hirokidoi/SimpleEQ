import XCTest
import SimpleEQRingC
@testable import SimpleEQ

/// クライアント表の読み出しを、実際の共有メモリファイルを模したフィクスチャを開いて検証する。
/// 呼び出しの検証だけで済ませず、ドライバが書いたはずのバイト列をそのまま通す。
final class MixerClientTableTests: XCTestCase {
    private static let magicOffset = 0
    private static let layoutVersionOffset = 4
    private static let headerBytesOffset = 12
    private static let ringFramesOffset = 16
    private static let channelsOffset = 20

    private static let mixerTableGenerationOffset = 144
    private static let mixerControlLeaseDeadlineOffset = 152
    private static let mixerSlotOverflowCountOffset = 160
    private static let mixerNeutralizedCountOffset = 168
    private static let mixerGainEntryDroppedCountOffset = 176
    private static let mixerClientsOffset = 184

    private static let slotStride = 120
    private static let slotClientIDOffset = 0
    private static let slotProcessIDOffset = 4
    private static let slotBundleIDOffset = 8
    private static let slotOutputCycleSeqOffset = 104
    private static let slotClipEventCountOffset = 108
    private static let slotPeakOffset = 112
    private static let slotAppliedGainOffset = 116

    private static let structSize = Int(simpleeq_ring_header_size())
    private static let slotCount = Int(simpleeq_mixer_slot_count())
    private static let bundleIDCapacity = Int(simpleeq_mixer_bundle_id_max_bytes())

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs.removeAll()
        super.tearDown()
    }

    // MARK: - フィクスチャ

    struct Slot {
        var index: Int
        var clientID: UInt32
        var processID: UInt32 = 0
        var bundleID: [UInt8] = []
        var outputCycleSeq: UInt32 = 0
        var clipEventCount: UInt32 = 0
        var peak: Float = 0
        var appliedGain: Float = 1
    }

    private func makeFixture(
        slots: [Slot] = [], tableGeneration: UInt32 = 0, leaseDeadline: UInt64 = 0,
        slotOverflowCount: UInt64 = 0, neutralizedCount: UInt64 = 0, gainEntryDroppedCount: UInt64 = 0
    ) -> URL {
        let ringFrames: UInt32 = 64
        let channels: UInt32 = 1
        let totalSize = Self.structSize + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size
        var data = Data(count: totalSize)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            raw.storeBytes(of: simpleeq_ring_expected_magic(), toByteOffset: Self.magicOffset, as: UInt32.self)
            raw.storeBytes(
                of: simpleeq_ring_expected_layout_version(), toByteOffset: Self.layoutVersionOffset, as: UInt32.self
            )
            raw.storeBytes(of: UInt32(Self.structSize), toByteOffset: Self.headerBytesOffset, as: UInt32.self)
            raw.storeBytes(of: ringFrames, toByteOffset: Self.ringFramesOffset, as: UInt32.self)
            raw.storeBytes(of: channels, toByteOffset: Self.channelsOffset, as: UInt32.self)
            raw.storeBytes(of: tableGeneration, toByteOffset: Self.mixerTableGenerationOffset, as: UInt32.self)
            raw.storeBytes(of: leaseDeadline, toByteOffset: Self.mixerControlLeaseDeadlineOffset, as: UInt64.self)
            raw.storeBytes(of: slotOverflowCount, toByteOffset: Self.mixerSlotOverflowCountOffset, as: UInt64.self)
            raw.storeBytes(of: neutralizedCount, toByteOffset: Self.mixerNeutralizedCountOffset, as: UInt64.self)
            raw.storeBytes(
                of: gainEntryDroppedCount, toByteOffset: Self.mixerGainEntryDroppedCountOffset, as: UInt64.self
            )
            for slot in slots {
                let base = Self.mixerClientsOffset + slot.index * Self.slotStride
                raw.storeBytes(of: slot.clientID, toByteOffset: base + Self.slotClientIDOffset, as: UInt32.self)
                raw.storeBytes(of: slot.processID, toByteOffset: base + Self.slotProcessIDOffset, as: UInt32.self)
                for (i, byte) in slot.bundleID.prefix(Self.bundleIDCapacity).enumerated() {
                    raw.storeBytes(of: byte, toByteOffset: base + Self.slotBundleIDOffset + i, as: UInt8.self)
                }
                raw.storeBytes(
                    of: slot.outputCycleSeq, toByteOffset: base + Self.slotOutputCycleSeqOffset, as: UInt32.self
                )
                raw.storeBytes(
                    of: slot.clipEventCount, toByteOffset: base + Self.slotClipEventCountOffset, as: UInt32.self
                )
                raw.storeBytes(of: slot.peak.bitPattern, toByteOffset: base + Self.slotPeakOffset, as: UInt32.self)
                raw.storeBytes(
                    of: slot.appliedGain.bitPattern, toByteOffset: base + Self.slotAppliedGainOffset, as: UInt32.self
                )
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixerClientTableTests-\(UUID().uuidString).shm")
        try! data.write(to: url)
        tempURLs.append(url)
        return url
    }

    private func makeReader(_ url: URL) throws -> SharedRingReader {
        try XCTUnwrap(try? SharedRingReader.open(path: url.path).get(), "フィクスチャを開けること")
    }

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }

    // MARK: - 名簿

    func testRosterSkipsSlotsWithNoIdentifyingValue() throws {
        let reader = try makeReader(makeFixture(slots: [
            Slot(index: 0, clientID: 0, processID: 999, bundleID: Self.bytes("com.example.ghost")),
            Slot(index: 3, clientID: 11, processID: 501, bundleID: Self.bytes("com.example.app"), outputCycleSeq: 4),
        ]))

        let roster = reader.readMixerRoster()
        XCTAssertEqual(roster.count, 1, "識別値 0 のスロットは読まない")
        XCTAssertEqual(roster.first?.clientID, 11)
        XCTAssertEqual(roster.first?.processID, 501)
        XCTAssertEqual(roster.first?.bundleID, "com.example.app")
        XCTAssertTrue(roster.first?.active ?? false)
    }

    /// 席を取ってから一度も ProcessOutput が来ていないクライアントは行の母集合に入らない。
    func testSeatedButSilentSlotIsReportedAsInactive() throws {
        let reader = try makeReader(makeFixture(slots: [
            Slot(index: 0, clientID: 5, processID: 501, bundleID: Self.bytes("com.example.app"), outputCycleSeq: 0),
        ]))
        XCTAssertEqual(reader.readMixerRoster().first?.active, false)
    }

    /// ドライバへ NULL で届いた場合と上限に収まらなかった場合はどちらも空文字で、pid で突き合わせる。
    func testSlotWithoutABundleIDIsMatchedByPID() throws {
        let reader = try makeReader(makeFixture(slots: [
            Slot(index: 0, clientID: 5, processID: 777, outputCycleSeq: 1),
        ]))
        let entry = try XCTUnwrap(reader.readMixerRoster().first)
        XCTAssertEqual(entry.bundleID, "")
        XCTAssertEqual(
            MixerSpec.matchKey(bundleID: entry.bundleID, processID: entry.processID),
            String(cString: simpleeq_mixer_match_key_pid_prefix()) + "777"
        )
    }

    /// 終端されていない値を書かれても、スロットの容量を越えて読まない。
    func testUnterminatedBundleIDDoesNotReadPastTheSlot() throws {
        let filled = [UInt8](repeating: UInt8(ascii: "a"), count: Self.bundleIDCapacity)
        let reader = try makeReader(makeFixture(slots: [
            Slot(index: 0, clientID: 5, processID: 501, bundleID: filled, outputCycleSeq: 1),
            Slot(index: 1, clientID: 6, processID: 502, bundleID: Self.bytes("com.example.next"), outputCycleSeq: 1),
        ]))
        let roster = reader.readMixerRoster()
        XCTAssertEqual(roster.first?.bundleID.count, Self.bundleIDCapacity - 1, "必ず終端して返す")
        XCTAssertEqual(roster.last?.bundleID, "com.example.next", "隣のスロットを侵食しない")
    }

    func testRosterStopsAtTheSlotLimit() throws {
        let slots = (0..<Self.slotCount).map {
            Slot(index: $0, clientID: UInt32($0 + 1), processID: UInt32(500 + $0), outputCycleSeq: 1)
        }
        let reader = try makeReader(makeFixture(slots: slots))
        XCTAssertEqual(reader.readMixerRoster().count, Self.slotCount)
    }

    // MARK: - 表示値の折り込み

    func testFoldedPeakAndGainRoundTripThroughTheBitPattern() throws {
        let reader = try makeReader(makeFixture(slots: [
            Slot(
                index: 0, clientID: 9, processID: 501, outputCycleSeq: 1,
                clipEventCount: 2, peak: 0.7071, appliedGain: 0.125
            ),
        ]))
        let store = MixerLevelStore()
        reader.foldMixerClients(into: store)

        var samples = store.makeSampleBuffer()
        store.takeSamples(into: &samples)
        XCTAssertEqual(samples[0].clientID, 9)
        XCTAssertEqual(samples[0].peak, 0.7071)
        XCTAssertEqual(samples[0].appliedGain, 0.125)
        XCTAssertEqual(samples[0].clipEventCount, 2)
    }

    // MARK: - 診断が読む値

    func testDriverObservationReportsSlotsInUseAndCounters() throws {
        let reader = try makeReader(makeFixture(
            slots: [Slot(index: 0, clientID: 1), Slot(index: 5, clientID: 2)],
            slotOverflowCount: 3, neutralizedCount: 4, gainEntryDroppedCount: 5
        ))
        let observation = reader.readMixerDriverObservation()
        XCTAssertEqual(observation.slotsInUse, 2)
        XCTAssertEqual(observation.slotCount, Self.slotCount)
        XCTAssertEqual(observation.slotOverflowCount, 3)
        XCTAssertEqual(observation.neutralizedCount, 4)
        XCTAssertEqual(observation.gainEntryDroppedCount, 5)
    }

    func testLeaseDeadlineOfZeroReadsAsUnarmed() throws {
        let reader = try makeReader(makeFixture(leaseDeadline: 0))
        XCTAssertNil(reader.readMixerDriverObservation(now: 1000).leaseRemainingSeconds)
    }

    func testLeaseRemainingIsDerivedFromTheDeadlineAndNeverGoesNegative() throws {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = Double(timebase.denom) / Double(timebase.numer) * 1_000_000_000
        let now: UInt64 = 1_000_000_000
        let deadline = now + UInt64(ticksPerSecond)

        let reader = try makeReader(makeFixture(leaseDeadline: deadline))
        XCTAssertEqual(
            try XCTUnwrap(reader.readMixerDriverObservation(now: now).leaseRemainingSeconds), 1, accuracy: 1e-6
        )
        XCTAssertEqual(
            reader.readMixerDriverObservation(now: deadline + 1_000_000).leaseRemainingSeconds, 0,
            "過ぎた期限で負にならない"
        )
    }
}
