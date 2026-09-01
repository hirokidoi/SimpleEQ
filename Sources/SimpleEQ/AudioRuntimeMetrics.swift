import Foundation
import SimpleEQAtomicC

/// realtime 書き込み側 (release store) / 非 realtime 読み取り側 (acquire load) 間で単一の UInt64 を
/// 受け渡す最小のアトミックカウンタ。
final class AtomicUInt64 {
    private let storage: UnsafeMutableRawPointer

    init(_ initial: UInt64 = 0) {
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: simpleeq_atomic_storage_size(), alignment: simpleeq_atomic_storage_alignment()
        )
        simpleeq_atomic_init(storage, initial)
    }

    deinit { storage.deallocate() }

    var value: UInt64 { simpleeq_atomic_load_acquire(storage) }

    func store(_ newValue: UInt64) { simpleeq_atomic_store_release(storage, newValue) }

    /// 単一の realtime スレッドからのみ呼ぶこと (load→store の間に割り込まれると加算が失われる)。
    func add(_ delta: UInt64) { store(value + delta) }
}

/// 音声ランタイムの内部観測量。realtime からの書き込みは単一 store または SPSC 前提の
/// load+store add のみ。ロック・メモリ確保・print は realtime 経路に持ち込まない。
final class AudioRuntimeMetrics {

    private let appVersion: String

    init(appVersion: String = AppVersion.text) {
        self.appVersion = appVersion
    }

    /// オーディオ世界の直列キューのみが読み書きするため atomic である必要がない。
    private struct ResetBaseline {
        var partialReadCount: UInt64 = 0
        var missingFrameCount: UInt64 = 0
        var primingSilenceCount: UInt64 = 0
        var primingSilenceFrameCount: UInt64 = 0
        var resyncEventCount: UInt64 = 0
        var resyncDiscardedFrameCount: UInt64 = 0
        var driftTrimEventCount: UInt64 = 0
        var driftTrimDiscardedFrameCount: UInt64 = 0
        var primingTrimEventCount: UInt64 = 0
        var primingTrimDiscardedFrameCount: UInt64 = 0
        var occupancyResetDueToInitialSyncCount: UInt64 = 0
        var occupancyResetDueToInitialSyncDiscardedFrameCount: UInt64 = 0
        var occupancyResetDueToOutputRestartCount: UInt64 = 0
        var occupancyResetDueToSilenceCount: UInt64 = 0
        var occupancyResetDueToUnmixableSeamCount: UInt64 = 0
        var occupancyResetDiscardedFrameCountTotal: UInt64 = 0
        var writerEpoch: UInt64 = 0
        var reprimeDueToWriterStallCount: UInt64 = 0
        var reprimeDueToTargetGrowthCount: UInt64 = 0
        var availableWindowWriteCount: UInt64 = 0
        var presentationStallCount: UInt64 = 0
        var presentationDeltaUnexpectedCount: UInt64 = 0
        var writeDeadlineMissedCount: UInt64 = 0
        var silenceFilledGapCount: UInt64 = 0
    }

    private var resetBaseline = ResetBaseline()

    private(set) var lastResetAt: Date?

    /// カウンタは単調増加のため通常は負にならないが、実装として保証する。
    private static func sinceBaseline(_ current: UInt64, _ baseline: UInt64) -> UInt64 {
        current >= baseline ? current - baseline : 0
    }

    // MARK: - available (バッファ量) の窓統計

    /// 診断表示の平滑化窓。N_p 確定窓とは別の目的のため独立した値として持つ。
    private static let availableWindowCapacity = 64

    private let availableWindowSlots: [AtomicUInt64] = (0..<availableWindowCapacity).map { _ in AtomicUInt64(0) }
    private let availableWindowWriteCount = AtomicUInt64(0)

    func recordAvailable(_ frames: Int) {
        let index = Int(availableWindowWriteCount.value % UInt64(Self.availableWindowCapacity))
        availableWindowSlots[index].store(UInt64(max(0, frames)))
        availableWindowWriteCount.add(1)
    }

    struct AvailableWindowStats: Equatable {
        let minFrames: Int
        let maxFrames: Int
        let medianFrames: Int
    }

    /// ソートを伴うためオーディオ世界の直列キュー専用 (realtime では呼ばない)。reset() 以降の
    /// 書き込みだけを対象にする。
    var availableWindowStats: AvailableWindowStats? {
        let totalWrites = availableWindowWriteCount.value
        let baselineWrites = min(resetBaseline.availableWindowWriteCount, totalWrites)
        let writesSinceReset = totalWrites - baselineWrites
        guard writesSinceReset > 0 else { return nil }
        let countToConsider = Int(min(writesSinceReset, UInt64(Self.availableWindowCapacity)))
        let startGlobalIndex = totalWrites - UInt64(countToConsider)
        let values = (0..<countToConsider).map { i -> Int in
            let slot = Int((startGlobalIndex + UInt64(i)) % UInt64(Self.availableWindowCapacity))
            return Int(availableWindowSlots[slot].value)
        }.sorted()
        guard let minFrames = values.first, let maxFrames = values.last else { return nil }
        return AvailableWindowStats(minFrames: minFrames, maxFrames: maxFrames, medianFrames: values[values.count / 2])
    }

    // MARK: - 再プライミング回数 (判別フラグ: 書き手停止起因か目標拡大起因か)

    private let reprimeDueToWriterStallCounter = AtomicUInt64(0)
    private let reprimeDueToTargetGrowthCounter = AtomicUInt64(0)

    var reprimeDueToWriterStallCount: UInt64 {
        Self.sinceBaseline(reprimeDueToWriterStallCounter.value, resetBaseline.reprimeDueToWriterStallCount)
    }
    var reprimeDueToTargetGrowthCount: UInt64 {
        Self.sinceBaseline(reprimeDueToTargetGrowthCounter.value, resetBaseline.reprimeDueToTargetGrowthCount)
    }

    /// 充填済み状態が true → false へ実際に遷移した回だけを渡すこと。
    func recordReprime(dueToWriterStall: Bool) {
        if dueToWriterStall {
            reprimeDueToWriterStallCounter.add(1)
        } else {
            reprimeDueToTargetGrowthCounter.add(1)
        }
    }

    // MARK: - 部分読み回数と欠落フレーム数 (本当のアンダーラン)

    private let partialReadCounter = AtomicUInt64(0)
    private let missingFrameCounter = AtomicUInt64(0)

    var partialReadCount: UInt64 { Self.sinceBaseline(partialReadCounter.value, resetBaseline.partialReadCount) }
    var missingFrameCount: UInt64 { Self.sinceBaseline(missingFrameCounter.value, resetBaseline.missingFrameCount) }

    // MARK: - プライミング中の無音返却の回数とフレーム数

    /// 読み出しカーソルは進んでいないため、部分読み (本当のアンダーラン) とは別の観測量として持つ。
    private let primingSilenceCounter = AtomicUInt64(0)
    private let primingSilenceFrameCounter = AtomicUInt64(0)

    var primingSilenceCount: UInt64 { Self.sinceBaseline(primingSilenceCounter.value, resetBaseline.primingSilenceCount) }
    var primingSilenceCountSinceLaunch: UInt64 { primingSilenceCounter.value }
    var primingSilenceFrameCount: UInt64 {
        Self.sinceBaseline(primingSilenceFrameCounter.value, resetBaseline.primingSilenceFrameCount)
    }

    /// 配信フレーム数が 0 かどうかでプライミング中の無音返却と本当のアンダーランを判別する。
    func recordRead(requestedFrames: Int, deliveredFrames: Int) {
        guard deliveredFrames < requestedFrames else { return }
        if deliveredFrames == 0 {
            primingSilenceCounter.add(1)
            primingSilenceFrameCounter.add(UInt64(requestedFrames))
        } else {
            partialReadCounter.add(1)
            missingFrameCounter.add(UInt64(requestedFrames - deliveredFrames))
        }
    }

    // MARK: - 再同期・ドリフトトリムの発火回数と破棄フレーム数 (経路別)

    private let resyncEventCounter = AtomicUInt64(0)
    private let resyncDiscardedFramesCounter = AtomicUInt64(0)
    private let driftTrimEventCounter = AtomicUInt64(0)
    private let driftTrimDiscardedFramesCounter = AtomicUInt64(0)

    var resyncEventCount: UInt64 { Self.sinceBaseline(resyncEventCounter.value, resetBaseline.resyncEventCount) }
    var resyncDiscardedFrameCount: UInt64 {
        Self.sinceBaseline(resyncDiscardedFramesCounter.value, resetBaseline.resyncDiscardedFrameCount)
    }
    var driftTrimEventCount: UInt64 { Self.sinceBaseline(driftTrimEventCounter.value, resetBaseline.driftTrimEventCount) }
    var driftTrimDiscardedFrameCount: UInt64 {
        Self.sinceBaseline(driftTrimDiscardedFramesCounter.value, resetBaseline.driftTrimDiscardedFrameCount)
    }

    func recordResync(discardedFrames: Int) {
        resyncEventCounter.add(1)
        resyncDiscardedFramesCounter.add(UInt64(discardedFrames))
    }

    func recordDriftTrim(discardedFrames: Int) {
        driftTrimEventCounter.add(1)
        driftTrimDiscardedFramesCounter.add(UInt64(discardedFrames))
    }

    // MARK: - プライミングの着地の切り詰め

    /// 目標バッファ量を超えて着地したぶんを捨てた回数と量 (切り詰めが働いたのか超過がそもそも無かった
    /// のかを切り分けるための計数)。
    private let primingTrimEventCounter = AtomicUInt64(0)
    private let primingTrimDiscardedFramesCounter = AtomicUInt64(0)

    var primingTrimEventCount: UInt64 {
        Self.sinceBaseline(primingTrimEventCounter.value, resetBaseline.primingTrimEventCount)
    }
    var primingTrimDiscardedFrameCount: UInt64 {
        Self.sinceBaseline(primingTrimDiscardedFramesCounter.value, resetBaseline.primingTrimDiscardedFrameCount)
    }

    func recordPrimingTrim(discardedFrames: Int) {
        primingTrimEventCounter.add(1)
        primingTrimDiscardedFramesCounter.add(UInt64(discardedFrames))
    }

    // MARK: - バッファ量のリセット (契機別の発火回数・破棄フレーム数・直近イベントの値)

    /// バッファ量を作り直す契機。後始末は契機によらず同一で、観測量の計上先だけが分かれる。
    enum OccupancyResetCause {
        /// 接続時の初回同期 (運用中の契機とは原因が異なるため専用の観測量を持つ)。
        case initialSync
        /// 出力 AUHAL の停止をまたいだ再開 (出力先の切替・レート変更の再構築)。
        case outputRestart
        /// 出力段の無音の継続とバッファ量のずれ (目標超過) の両立。
        case silence
        /// 混ぜる相手が無い段差 (バッファ量がリング容量に迫り、旧カーソル側が書き直されうる回)。
        case unmixableSeam
    }

    private let occupancyResetDueToInitialSyncCounter = AtomicUInt64(0)
    private let occupancyResetDueToInitialSyncDiscardedFramesCounter = AtomicUInt64(0)
    private let occupancyResetDueToOutputRestartCounter = AtomicUInt64(0)
    private let occupancyResetDueToSilenceCounter = AtomicUInt64(0)
    private let occupancyResetDueToUnmixableSeamCounter = AtomicUInt64(0)
    private let occupancyResetDiscardedFramesTotalCounter = AtomicUInt64(0)
    private let lastOccupancyResetAvailableStorage = AtomicUInt64(0)
    private let lastOccupancyResetTargetStorage = AtomicUInt64(0)

    var occupancyResetDueToInitialSyncCount: UInt64 {
        Self.sinceBaseline(occupancyResetDueToInitialSyncCounter.value, resetBaseline.occupancyResetDueToInitialSyncCount)
    }
    /// 契機別に分けて持つ唯一の破棄フレーム数。
    var occupancyResetDueToInitialSyncDiscardedFrameCount: UInt64 {
        Self.sinceBaseline(
            occupancyResetDueToInitialSyncDiscardedFramesCounter.value,
            resetBaseline.occupancyResetDueToInitialSyncDiscardedFrameCount
        )
    }
    var occupancyResetDueToOutputRestartCount: UInt64 {
        Self.sinceBaseline(occupancyResetDueToOutputRestartCounter.value, resetBaseline.occupancyResetDueToOutputRestartCount)
    }
    var occupancyResetDueToSilenceCount: UInt64 {
        Self.sinceBaseline(occupancyResetDueToSilenceCounter.value, resetBaseline.occupancyResetDueToSilenceCount)
    }
    var occupancyResetDueToUnmixableSeamCount: UInt64 {
        Self.sinceBaseline(occupancyResetDueToUnmixableSeamCounter.value, resetBaseline.occupancyResetDueToUnmixableSeamCount)
    }
    /// 契機を問わない破棄フレーム数の合計 (原因の切り分けは契機別の回数が担う)。
    var occupancyResetDiscardedFrameCountTotal: UInt64 {
        Self.sinceBaseline(occupancyResetDiscardedFramesTotalCounter.value, resetBaseline.occupancyResetDiscardedFrameCountTotal)
    }

    /// 直近のリセットで破棄する直前のバッファ量と、その回の目標バッファ量。累積ではなく直近の値のため
    /// reset() では 0 へ戻す。
    var lastOccupancyResetAvailableFrames: Int { Int(lastOccupancyResetAvailableStorage.value) }
    var lastOccupancyResetTargetOccupancyFrames: Int { Int(lastOccupancyResetTargetStorage.value) }

    /// discardedFrames は呼び出し側がリング容量を超えないよう切り詰めた値を渡すこと。
    func recordOccupancyReset(
        cause: OccupancyResetCause, discardedFrames: Int, targetOccupancyFrames: Int
    ) {
        switch cause {
        case .initialSync:
            occupancyResetDueToInitialSyncCounter.add(1)
            occupancyResetDueToInitialSyncDiscardedFramesCounter.add(UInt64(discardedFrames))
        case .outputRestart:
            occupancyResetDueToOutputRestartCounter.add(1)
        case .silence:
            occupancyResetDueToSilenceCounter.add(1)
        case .unmixableSeam:
            occupancyResetDueToUnmixableSeamCounter.add(1)
        }
        occupancyResetDiscardedFramesTotalCounter.add(UInt64(discardedFrames))
        lastOccupancyResetAvailableStorage.store(UInt64(max(0, discardedFrames)))
        lastOccupancyResetTargetStorage.store(UInt64(targetOccupancyFrames))
    }

    // MARK: - ドライバの書き込み位置決定 (SimpleEQRingComputeWritePlan) が残す観測量

    /// 値の実体は共有メモリ (ドライバ側) にあり、読み出した値をそのまま写し取る (単一 store のみ)。
    private let presentationStallCountStorage = AtomicUInt64(0)
    private let presentationDeltaUnexpectedCountStorage = AtomicUInt64(0)
    private let writeDeadlineMissedCountStorage = AtomicUInt64(0)
    private let silenceFilledGapCountStorage = AtomicUInt64(0)

    /// HAL から渡される提示時刻が前サイクルと同じだった (書き込み位置が進まなかった) サイクルの
    /// 累計回数。
    var presentationStallCount: UInt64 {
        Self.sinceBaseline(presentationStallCountStorage.value, resetBaseline.presentationStallCount)
    }
    /// 提示時刻の前サイクルからの差分が想定外だったサイクルの累計回数。
    var presentationDeltaUnexpectedCount: UInt64 {
        Self.sinceBaseline(presentationDeltaUnexpectedCountStorage.value, resetBaseline.presentationDeltaUnexpectedCount)
    }
    /// 締切超過のため、その回の書き込みを行わなかったサイクルの累計回数。
    var writeDeadlineMissedCount: UInt64 {
        Self.sinceBaseline(writeDeadlineMissedCountStorage.value, resetBaseline.writeDeadlineMissedCount)
    }

    /// 書き始めの手前の未書き込み区間を無音で埋めたサイクルの累計回数。
    var silenceFilledGapCount: UInt64 {
        Self.sinceBaseline(silenceFilledGapCountStorage.value, resetBaseline.silenceFilledGapCount)
    }

    /// 取り込む値がストレージの現在値を下回った回はドライバ側が 0 へ戻った合図とみなし、基準値も
    /// 0 へ立て直す。
    private static func reanchoredBaseline(storedValue: UInt64, incomingValue: UInt64, baseline: UInt64) -> UInt64 {
        incomingValue < storedValue ? 0 : baseline
    }

    func recordDriverWritePositionObservations(
        presentationStallCount: UInt64,
        presentationDeltaUnexpectedCount: UInt64, writeDeadlineMissedCount: UInt64,
        silenceFilledGapCount: UInt64
    ) {
        resetBaseline.presentationStallCount = Self.reanchoredBaseline(
            storedValue: presentationStallCountStorage.value, incomingValue: presentationStallCount,
            baseline: resetBaseline.presentationStallCount
        )
        resetBaseline.presentationDeltaUnexpectedCount = Self.reanchoredBaseline(
            storedValue: presentationDeltaUnexpectedCountStorage.value, incomingValue: presentationDeltaUnexpectedCount,
            baseline: resetBaseline.presentationDeltaUnexpectedCount
        )
        resetBaseline.writeDeadlineMissedCount = Self.reanchoredBaseline(
            storedValue: writeDeadlineMissedCountStorage.value, incomingValue: writeDeadlineMissedCount,
            baseline: resetBaseline.writeDeadlineMissedCount
        )
        resetBaseline.silenceFilledGapCount = Self.reanchoredBaseline(
            storedValue: silenceFilledGapCountStorage.value, incomingValue: silenceFilledGapCount,
            baseline: resetBaseline.silenceFilledGapCount
        )

        presentationStallCountStorage.store(presentationStallCount)
        presentationDeltaUnexpectedCountStorage.store(presentationDeltaUnexpectedCount)
        writeDeadlineMissedCountStorage.store(writeDeadlineMissedCount)
        silenceFilledGapCountStorage.store(silenceFilledGapCount)
    }

    // MARK: - 書き手 (ドライバ) が共有ヘッダで申告する状態

    private let writerEpochStorage = AtomicUInt64(0)
    /// 世代番号を一度でも観測したか。最初の観測でリセット基準値も立てる。
    private var hasObservedWriterEpoch = false
    private let writerIOIsRunningStorage = AtomicUInt64(0)
    private let writerIOCycleFramesStorage = AtomicUInt64(0)
    private let readerObservedStorage = AtomicUInt64(0)

    /// 読み手が居て、読み手が書く値を今の状態として読めているか。実効書き手ブロック長・目標／上限バッファ量・
    /// リング容量も読み手が書くため、読み手が居ない間はそれらを現在の状態として見せないための判別に使う。
    var readerObserved: Bool { readerObservedStorage.value != 0 }

    var writerIOIsRunning: Bool { writerIOIsRunningStorage.value != 0 }
    var writerIOCycleFrames: Int { Int(writerIOCycleFramesStorage.value) }
    /// ドライバが共有領域を用意し直すたびに 0 から始まるため、離れた 2 時点の値を比べても
    /// 増分にはならない。
    var writerEpoch: UInt64 { writerEpochStorage.value }
    var writerEpochAdvanceCount: UInt64 { Self.sinceBaseline(writerEpochStorage.value, resetBaseline.writerEpoch) }

    func recordWriterState(epoch: UInt64, ioIsRunning: Bool, ioCycleFrames: Int) {
        // 最初の観測で基準値も立てる (立てないとドライバが動き出す前に進めていたぶんが「変化」として出る)。
        if !hasObservedWriterEpoch {
            hasObservedWriterEpoch = true
            resetBaseline.writerEpoch = epoch
        }
        resetBaseline.writerEpoch = Self.reanchoredBaseline(
            storedValue: writerEpochStorage.value, incomingValue: epoch, baseline: resetBaseline.writerEpoch
        )
        writerEpochStorage.store(epoch)
        writerIOIsRunningStorage.store(ioIsRunning ? 1 : 0)
        writerIOCycleFramesStorage.store(UInt64(max(0, ioCycleFrames)))
    }

    func recordReaderObserved(_ observed: Bool) {
        readerObservedStorage.store(observed ? 1 : 0)
    }

    // MARK: - ドライババージョン (現在の状態)

    private let driverVersionMajorStorage = AtomicUInt64(0)
    private let driverVersionMinorStorage = AtomicUInt64(0)
    private let driverLayoutVersionStorage = AtomicUInt64(0)

    var driverVersion: DriverVersion {
        DriverVersion(
            major: UInt16(truncatingIfNeeded: driverVersionMajorStorage.value),
            minor: UInt16(truncatingIfNeeded: driverVersionMinorStorage.value)
        )
    }

    var driverLayoutVersion: UInt32 { UInt32(truncatingIfNeeded: driverLayoutVersionStorage.value) }

    /// ドライバだけが入れ替わる経路があるため、書き手の申告と同じく
    /// 転記のたびに読み直した値で上書きする。
    func recordDriverVersions(driverVersion: DriverVersion, layoutVersion: UInt32) {
        driverVersionMajorStorage.store(UInt64(driverVersion.major))
        driverVersionMinorStorage.store(UInt64(driverVersion.minor))
        driverLayoutVersionStorage.store(UInt64(layoutVersion))
    }

    // MARK: - 出力デバイスの実レート (現在の状態)

    private let outputDeviceSampleRateStorage = AtomicUInt64(0)

    /// ドライバ側の適用中レートと突き合わせるために持つ (両者の不一致は音の異常の主因)。
    /// 未取得の間は 0。
    var outputDeviceSampleRate: Double { Double(bitPattern: outputDeviceSampleRateStorage.value) }

    func recordOutputDeviceSampleRate(_ sampleRate: Double) {
        outputDeviceSampleRateStorage.store(sampleRate.bitPattern)
    }

    // MARK: - 実効書き手ブロック長 (N_p) の推定値、目標／上限バッファ量、リング容量 (現在の状態)

    private let effectiveWriterBlockFramesStorage = AtomicUInt64(0)
    private let targetOccupancyStorage = AtomicUInt64(0)
    private let targetOccupancyRunningMaxStorage = AtomicUInt64(0)
    private let maxOccupancyStorage = AtomicUInt64(0)
    private let ringCapacityStorage = AtomicUInt64(0)

    /// 累積ではなく現在の状態のため reset() の対象にしない。
    var effectiveWriterBlockFrames: Int { Int(effectiveWriterBlockFramesStorage.value) }
    var targetOccupancyFrames: Int { Int(targetOccupancyStorage.value) }
    /// 目標は一過性に跳ねうるが現在値だけでは跳ねた事実が残らないため、最大値を別に持つ。
    /// リセットの時点で現在の目標を起点として置く (現在値を下回らないようにする)。
    var targetOccupancyFramesMax: Int { Int(targetOccupancyRunningMaxStorage.value) }
    var maxOccupancyFrames: Int { Int(maxOccupancyStorage.value) }
    var ringCapacityFrames: Int { Int(ringCapacityStorage.value) }

    /// 呼び出し側が値の変化を検出した回だけ呼ぶこと。
    func recordEffectiveWriterBlockFrames(_ frames: Int) {
        effectiveWriterBlockFramesStorage.store(UInt64(frames))
    }

    /// 呼び出し側が値の変化を検出した回だけ呼ぶこと。
    func recordOccupancyBounds(targetFrames: Int, maxFrames: Int) {
        targetOccupancyStorage.store(UInt64(targetFrames))
        maxOccupancyStorage.store(UInt64(maxFrames))
        if UInt64(targetFrames) > targetOccupancyRunningMaxStorage.value {
            targetOccupancyRunningMaxStorage.store(UInt64(targetFrames))
        }
    }

    /// 呼び出し側が接続時・観測量の差し替え時の 1 回だけ呼ぶこと。
    func recordRingCapacity(_ frames: Int) {
        ringCapacityStorage.store(UInt64(frames))
    }

    // MARK: - ピーク (出力振幅の走行最大値)

    private let peakStorage = AtomicUInt64(0)
    private let peakBeforeVolumeStorage = AtomicUInt64(0)

    private var rawPeak: Float { Float(bitPattern: UInt32(truncatingIfNeeded: peakStorage.value)) }

    private var rawPeakBeforeVolume: Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: peakBeforeVolumeStorage.value))
    }

    var peak: Float { rawPeak }

    var peakBeforeVolume: Float { rawPeakBeforeVolume }

    func recordPeak(_ peak: Float) {
        if peak > rawPeak { peakStorage.store(UInt64(peak.bitPattern)) }
    }

    func recordPeakBeforeVolume(_ peak: Float) {
        if peak > rawPeakBeforeVolume { peakBeforeVolumeStorage.store(UInt64(peak.bitPattern)) }
    }

    // MARK: - リセット (累積カウンタ・窓統計は基準値方式、走行最大値と直近イベントの値は書き直し)

    /// 基準値 (reset 時点の値) を控えるだけで、カウンタそのものには書き込まない (直接 0 書き込みは
    /// realtime 側の加算と競合しうる)。走行最大値・直近イベントの値・現在の状態を表す値は基準値
    /// 方式の対象にしない (「現在値 − 基準値」に意味がないため)。
    func reset() {
        resetBaseline.partialReadCount = partialReadCounter.value
        resetBaseline.missingFrameCount = missingFrameCounter.value
        resetBaseline.primingSilenceCount = primingSilenceCounter.value
        resetBaseline.primingSilenceFrameCount = primingSilenceFrameCounter.value
        resetBaseline.resyncEventCount = resyncEventCounter.value
        resetBaseline.resyncDiscardedFrameCount = resyncDiscardedFramesCounter.value
        resetBaseline.driftTrimEventCount = driftTrimEventCounter.value
        resetBaseline.driftTrimDiscardedFrameCount = driftTrimDiscardedFramesCounter.value
        resetBaseline.primingTrimEventCount = primingTrimEventCounter.value
        resetBaseline.primingTrimDiscardedFrameCount = primingTrimDiscardedFramesCounter.value
        resetBaseline.occupancyResetDueToInitialSyncCount = occupancyResetDueToInitialSyncCounter.value
        resetBaseline.occupancyResetDueToInitialSyncDiscardedFrameCount =
            occupancyResetDueToInitialSyncDiscardedFramesCounter.value
        resetBaseline.occupancyResetDueToOutputRestartCount = occupancyResetDueToOutputRestartCounter.value
        resetBaseline.occupancyResetDueToSilenceCount = occupancyResetDueToSilenceCounter.value
        resetBaseline.occupancyResetDueToUnmixableSeamCount = occupancyResetDueToUnmixableSeamCounter.value
        resetBaseline.occupancyResetDiscardedFrameCountTotal = occupancyResetDiscardedFramesTotalCounter.value
        resetBaseline.writerEpoch = writerEpochStorage.value
        resetBaseline.reprimeDueToWriterStallCount = reprimeDueToWriterStallCounter.value
        resetBaseline.reprimeDueToTargetGrowthCount = reprimeDueToTargetGrowthCounter.value
        peakStorage.store(0)
        peakBeforeVolumeStorage.store(0)
        // 0 ではなくリセット時点の目標を起点にする (現在値を下回らないため)。読めていない間は
        // 0 から数え直す。
        targetOccupancyRunningMaxStorage.store(readerObserved ? UInt64(max(0, targetOccupancyFrames)) : 0)
        lastOccupancyResetAvailableStorage.store(0)
        lastOccupancyResetTargetStorage.store(0)
        resetBaseline.availableWindowWriteCount = availableWindowWriteCount.value
        resetBaseline.presentationStallCount = presentationStallCountStorage.value
        resetBaseline.presentationDeltaUnexpectedCount = presentationDeltaUnexpectedCountStorage.value
        resetBaseline.writeDeadlineMissedCount = writeDeadlineMissedCountStorage.value
        resetBaseline.silenceFilledGapCount = silenceFilledGapCountStorage.value
        lastResetAt = Date()
    }

    // MARK: - スナップショット (診断の表示・書き出し用)

    struct Snapshot: Equatable {
        /// アプリバージョンだけは観測ではないため、読み手の生存に関わらず値を持つ。
        let appVersion: String
        let driverVersion: DriverVersion
        let driverLayoutVersion: UInt32
        /// フレーム数を時間へ換算するのはこの値 (バッファ量はリングのフレーム数のため)。
        let appliedSampleRate: Double
        /// 未取得の間は 0。換算には使わない。
        let outputDeviceSampleRate: Double
        let volumeRoute: VolumeRouteObservation?
        let readerObserved: Bool
        let writerIOIsRunning: Bool
        let writerIOCycleFrames: Int
        let writerEpoch: UInt64
        let writerEpochAdvanceCount: UInt64
        let availableWindow: AvailableWindowStats?
        let reprimeDueToWriterStallCount: UInt64
        let reprimeDueToTargetGrowthCount: UInt64
        let partialReadCount: UInt64
        let missingFrameCount: UInt64
        let primingSilenceCount: UInt64
        let primingSilenceFrameCount: UInt64
        let resyncEventCount: UInt64
        let resyncDiscardedFrameCount: UInt64
        let driftTrimEventCount: UInt64
        let driftTrimDiscardedFrameCount: UInt64
        let primingTrimEventCount: UInt64
        let primingTrimDiscardedFrameCount: UInt64
        let occupancyResetDueToInitialSyncCount: UInt64
        let occupancyResetDueToInitialSyncDiscardedFrameCount: UInt64
        let occupancyResetDueToOutputRestartCount: UInt64
        let occupancyResetDueToSilenceCount: UInt64
        let occupancyResetDueToUnmixableSeamCount: UInt64
        let occupancyResetDiscardedFrameCountTotal: UInt64
        let lastOccupancyResetAvailableFrames: Int
        let lastOccupancyResetTargetOccupancyFrames: Int
        let presentationStallCount: UInt64
        let presentationDeltaUnexpectedCount: UInt64
        let writeDeadlineMissedCount: UInt64
        let silenceFilledGapCount: UInt64
        let effectiveWriterBlockFrames: Int
        let targetOccupancyFrames: Int
        let targetOccupancyFramesMax: Int
        let maxOccupancyFrames: Int
        let ringCapacityFrames: Int
        let peak: Float
        let peakBeforeVolume: Float
        let lastResetAt: Date?
    }

    /// この型は自分でレートの置き場も音量経路の状態も読みに行かない。
    func snapshot(appliedSampleRate: Double, volumeRoute: VolumeRouteObservation? = nil) -> Snapshot {
        Snapshot(
            appVersion: appVersion,
            driverVersion: driverVersion,
            driverLayoutVersion: driverLayoutVersion,
            appliedSampleRate: appliedSampleRate,
            outputDeviceSampleRate: outputDeviceSampleRate,
            volumeRoute: volumeRoute,
            readerObserved: readerObserved,
            writerIOIsRunning: writerIOIsRunning,
            writerIOCycleFrames: writerIOCycleFrames,
            writerEpoch: writerEpoch,
            writerEpochAdvanceCount: writerEpochAdvanceCount,
            availableWindow: availableWindowStats,
            reprimeDueToWriterStallCount: reprimeDueToWriterStallCount,
            reprimeDueToTargetGrowthCount: reprimeDueToTargetGrowthCount,
            partialReadCount: partialReadCount,
            missingFrameCount: missingFrameCount,
            primingSilenceCount: primingSilenceCount,
            primingSilenceFrameCount: primingSilenceFrameCount,
            resyncEventCount: resyncEventCount,
            resyncDiscardedFrameCount: resyncDiscardedFrameCount,
            driftTrimEventCount: driftTrimEventCount,
            driftTrimDiscardedFrameCount: driftTrimDiscardedFrameCount,
            primingTrimEventCount: primingTrimEventCount,
            primingTrimDiscardedFrameCount: primingTrimDiscardedFrameCount,
            occupancyResetDueToInitialSyncCount: occupancyResetDueToInitialSyncCount,
            occupancyResetDueToInitialSyncDiscardedFrameCount: occupancyResetDueToInitialSyncDiscardedFrameCount,
            occupancyResetDueToOutputRestartCount: occupancyResetDueToOutputRestartCount,
            occupancyResetDueToSilenceCount: occupancyResetDueToSilenceCount,
            occupancyResetDueToUnmixableSeamCount: occupancyResetDueToUnmixableSeamCount,
            occupancyResetDiscardedFrameCountTotal: occupancyResetDiscardedFrameCountTotal,
            lastOccupancyResetAvailableFrames: lastOccupancyResetAvailableFrames,
            lastOccupancyResetTargetOccupancyFrames: lastOccupancyResetTargetOccupancyFrames,
            presentationStallCount: presentationStallCount,
            presentationDeltaUnexpectedCount: presentationDeltaUnexpectedCount,
            writeDeadlineMissedCount: writeDeadlineMissedCount,
            silenceFilledGapCount: silenceFilledGapCount,
            effectiveWriterBlockFrames: effectiveWriterBlockFrames,
            targetOccupancyFrames: targetOccupancyFrames,
            targetOccupancyFramesMax: targetOccupancyFramesMax,
            maxOccupancyFrames: maxOccupancyFrames,
            ringCapacityFrames: ringCapacityFrames,
            peak: peak,
            peakBeforeVolume: peakBeforeVolume,
            lastResetAt: lastResetAt
        )
    }
}

extension AudioRuntimeMetrics.Snapshot {
    /// realtime 読み出しを一度も経ていない状態の既定値 (全項目が未観測・未計上を表す)。
    static func initial(appliedSampleRate: Double) -> AudioRuntimeMetrics.Snapshot {
        AudioRuntimeMetrics().snapshot(appliedSampleRate: appliedSampleRate)
    }
}
