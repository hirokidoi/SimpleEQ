import Foundation
import SimpleEQRingC

/// ドライバのクライアント表の表示値を、リアルタイム出力コールバックが折り込む器。
/// 単一生産者 (リアルタイムコールバック) / 単一消費者 (描画側)。確保もロックもログもしない。
final class MixerLevelStore {

    /// 描画側が 1 スロットから取り出す表示値。
    struct Sample: Equatable {
        var clientID: UInt32 = 0
        var processID: UInt32 = 0
        var outputCycleSeq: UInt32 = 0
        var peak: Float = 0
        var clipEventCount: UInt32 = 0
        var appliedGain: Float = 1

        var active: Bool { outputCycleSeq != 0 }
    }

    let slotCount: Int

    private let clientIDs: [AtomicUInt64]
    private let processIDs: [AtomicUInt64]
    private let outputCycleSeqs: [AtomicUInt64]
    private let clipEventCounts: [AtomicUInt64]
    private let peakBits: [AtomicUInt64]
    private let appliedGainBits: [AtomicUInt64]
    private let rosterRevisionStorage = AtomicUInt64(0)

    /// 折り込み側だけが読み書きする (リアルタイムの単一スレッド)。
    private var observedTableGeneration: UInt32?
    private var lastOutputCycleSeq: [UInt32]

    init(slotCount: Int = Int(simpleeq_mixer_slot_count())) {
        self.slotCount = slotCount
        clientIDs = (0..<slotCount).map { _ in AtomicUInt64(0) }
        processIDs = (0..<slotCount).map { _ in AtomicUInt64(0) }
        outputCycleSeqs = (0..<slotCount).map { _ in AtomicUInt64(0) }
        clipEventCounts = (0..<slotCount).map { _ in AtomicUInt64(0) }
        peakBits = (0..<slotCount).map { _ in AtomicUInt64(0) }
        appliedGainBits = (0..<slotCount).map { _ in AtomicUInt64(UInt64(Float(1).bitPattern)) }
        lastOutputCycleSeq = Array(repeating: 0, count: slotCount)
    }

    /// 表を見に行く価値があるかを、原子ロード 1 回で判定するための版数。
    var rosterRevision: UInt64 { rosterRevisionStorage.value }

    // MARK: - 折り込み (realtime)

    func beginFold(tableGeneration: UInt32) {
        guard observedTableGeneration != tableGeneration else { return }
        observedTableGeneration = tableGeneration
        rosterRevisionStorage.add(1)
    }

    func foldSlot(
        index: Int, clientID: UInt32, processID: UInt32, outputCycleSeq: UInt32,
        clipEventCount: UInt32, peak: Float, appliedGain: Float
    ) {
        guard index >= 0, index < slotCount else { return }
        clientIDs[index].store(UInt64(clientID))
        processIDs[index].store(UInt64(processID))
        outputCycleSeqs[index].store(UInt64(outputCycleSeq))
        clipEventCounts[index].store(UInt64(clipEventCount))
        appliedGainBits[index].store(UInt64(appliedGain.bitPattern))

        let previous = lastOutputCycleSeq[index]
        lastOutputCycleSeq[index] = outputCycleSeq
        // 席を取っただけのクライアントは行の母集合に入らない一方、鳴り始めは表の世代を動かさない。
        // ここで拾わないと、鳴り始めたアプリが候補プールに現れない。
        if previous == 0, outputCycleSeq != 0 { rosterRevisionStorage.add(1) }

        guard outputCycleSeq != previous else { return }
        if peak > Self.float(peakBits[index]) { peakBits[index].store(UInt64(peak.bitPattern)) }
    }

    // MARK: - 取り出し (描画側)

    func makeSampleBuffer() -> [Sample] { Array(repeating: Sample(), count: slotCount) }

    /// ピークは取り出しで 0 へ戻す (描画間隔に届いた分の最大を、判定ではなく表示のために使う)。
    /// クリップは取りこぼしてはならない判定なので、この最大とは別に clipEventCount の差分で見る。
    func takeSamples(into samples: inout [Sample]) {
        for index in 0..<min(slotCount, samples.count) {
            samples[index] = Sample(
                clientID: UInt32(truncatingIfNeeded: clientIDs[index].value),
                processID: UInt32(truncatingIfNeeded: processIDs[index].value),
                outputCycleSeq: UInt32(truncatingIfNeeded: outputCycleSeqs[index].value),
                peak: Self.float(peakBits[index]),
                clipEventCount: UInt32(truncatingIfNeeded: clipEventCounts[index].value),
                appliedGain: Self.float(appliedGainBits[index])
            )
            peakBits[index].store(0)
        }
    }

    private static func float(_ storage: AtomicUInt64) -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: storage.value))
    }
}
