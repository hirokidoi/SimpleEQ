import CoreAudio
import Darwin
import Foundation
import SimpleEQRingC

/// 値の実体はレイアウトヘッダの 1 箇所のみで、ここでは薄い C 関数経由で取得するだけで複製しない。
enum DriverConfig {
    /// 表示専用であり、デバイスの解決キーとしての用途は無い
    /// (表示名は実行時に変更でき同名のデバイスも同時に存在しうるため、解決キーには常に deviceUID を使う)。
    static let deviceName = String(cString: simpleeq_driver_device_name())

    /// 識別・永続化・解決の唯一のキー。
    static let deviceUID = String(cString: simpleeq_driver_device_uid())

    static let visibilityOverrideSelector =
        AudioObjectPropertySelector(simpleeq_driver_visibility_override_selector())

    static let nameOverrideSelector =
        AudioObjectPropertySelector(simpleeq_driver_name_override_selector())

    static let nameOverrideMaxLength = Int(simpleeq_driver_name_override_max_length())

    static let mixerGainSelector =
        AudioObjectPropertySelector(simpleeq_mixer_gain_selector())

    /// 制御リースの長さ (秒)。押し込みの間隔はこの値から導く。
    static let mixerControlLeaseSeconds = simpleeq_mixer_control_lease_seconds()

    static var sharedMemoryPath: String {
        String(cString: simpleeq_ring_directory_path()) + "/" + String(cString: simpleeq_ring_file_name())
    }

    static let ownershipSelector =
        AudioObjectPropertySelector(simpleeq_ownership_selector())

    /// 所有権リースの長さ (秒)。更新間隔はこの値から導く。
    static let ownershipLeaseSeconds = simpleeq_ownership_lease_seconds()
    /// 要求リースの長さ (秒)。更新間隔はこの値から導く。
    static let ownershipRequestLeaseSeconds = simpleeq_ownership_request_lease_seconds()
}

/// 所有権プロパティの Set が受ける操作。
enum OwnershipOperation {
    case claim, request, cancel, release, renew

    var rawValue: String {
        switch self {
        case .claim: return String(cString: simpleeq_ownership_operation_claim())
        case .request: return String(cString: simpleeq_ownership_operation_request())
        case .cancel: return String(cString: simpleeq_ownership_operation_cancel())
        case .release: return String(cString: simpleeq_ownership_operation_release())
        case .renew: return String(cString: simpleeq_ownership_operation_renew())
        }
    }
}

enum OwnershipPropertyKey {
    static let operation = String(cString: simpleeq_ownership_operation_key())
    static let uid = String(cString: simpleeq_ownership_uid_key())
}

/// ヘッダから読んだ所有権。所有者/要求者ともに不在は pid 0。リース残りは読み取り時点からの換算値。
struct OwnershipSnapshot: Equatable {
    var ownerProcessID: UInt32 = 0
    var ownerUID: UInt32 = 0
    /// nil はリースを持っていない状態 (所有者なし)。
    var ownershipLeaseRemainingSeconds: Double?
    var requestProcessID: UInt32 = 0
    var requestUID: UInt32 = 0
    /// nil はリースを持っていない状態 (要求なし)。
    var requestLeaseRemainingSeconds: Double?
}

enum DriverAvailability: Equatable {
    /// 起動シーケンスの最初のスナップショットが届く前の、まだ確認できていない状態。
    /// init(openResult:) がこの値を生成することはない。
    case checking
    case ok
    case notFound
    case versionMismatch

    /// fileNotFound/headerInvalid はどちらも「有効なドライバが見当たらない」という同じ対処につながるため notFound へまとめる。
    init(openResult: Result<SharedRingReader, SharedRingReader.OpenFailure>) {
        switch openResult {
        case .success:
            self = .ok
        case .failure(.fileNotFound), .failure(.headerInvalid):
            self = .notFound
        case .failure(.versionMismatch):
            self = .versionMismatch
        }
    }
}

/// 人が読む識別子であり、共有ヘッダのレイアウトバージョンとは連動しない。
struct DriverVersion: Equatable {
    let major: UInt16
    let minor: UInt16

    var text: String { "\(major).\(minor)" }
}

struct DriverProbe: Equatable {
    let availability: DriverAvailability
    /// レイアウトバージョンが一致した場合にのみ読める。
    /// 読めないこと自体が「再インストールが要る」ことを表す。
    let driverVersion: DriverVersion?
    let layoutVersion: UInt32?

    var hasReadableVersions: Bool { driverVersion != nil || layoutVersion != nil }

    static func versionsUnreadable(_ availability: DriverAvailability) -> DriverProbe {
        DriverProbe(availability: availability, driverVersion: nil, layoutVersion: nil)
    }

    init(openResult: Result<SharedRingReader, SharedRingReader.OpenFailure>) {
        availability = DriverAvailability(openResult: openResult)
        switch openResult {
        case .success(let reader):
            driverVersion = reader.driverReportedVersion
            layoutVersion = reader.driverReportedLayoutVersion
        case .failure(.versionMismatch(let found, _)):
            driverVersion = nil
            layoutVersion = found
        case .failure(.fileNotFound), .failure(.headerInvalid):
            driverVersion = nil
            layoutVersion = nil
        }
    }

    init(availability: DriverAvailability, driverVersion: DriverVersion?, layoutVersion: UInt32?) {
        self.availability = availability
        self.driverVersion = driverVersion
        self.layoutVersion = layoutVersion
    }
}

/// 専用ドライバが書き込む共有メモリリングを読む唯一の窓口。
final class SharedRingReader {
    enum OpenFailure: Error, Equatable {
        case fileNotFound
        case headerInvalid
        case versionMismatch(found: UInt32, expected: UInt32)
    }

    private let fileDescriptor: Int32
    private let mappedBase: UnsafeRawPointer
    private let mappedSize: Int
    private let cursor: OccupancyCursor

    var metrics: AudioRuntimeMetrics { cursor.metrics }

    /// seqlock 経由 (書き込み中に読んでしまい破棄した回は更新しない)。realtime スレッドの読み出しカーソルとは別。
    private var lastTimeSnapshot: (writeCounter: UInt64, hostTime: UInt64)?

    private init(
        fileDescriptor: Int32, mappedBase: UnsafeRawPointer, mappedSize: Int, cursor: OccupancyCursor
    ) {
        self.fileDescriptor = fileDescriptor
        self.mappedBase = mappedBase
        self.mappedSize = mappedSize
        self.cursor = cursor
    }

    /// 呼び出しは出力 AUHAL 停止中の 1 回に限る。
    func applySampleRate(_ rate: Double) {
        cursor.applySampleRate(rate)
    }

    /// 都度読み直す (レート変更の検知に使う)。
    var driverReportedSampleRate: Double { simpleeq_ring_sample_rate(mappedBase) }

    /// 共有メモリファイルは残ったままドライバだけ入れ替わりうるため、都度読み直す。
    var driverReportedVersion: DriverVersion {
        DriverVersion(
            major: simpleeq_ring_driver_version_major(mappedBase),
            minor: simpleeq_ring_driver_version_minor(mappedBase)
        )
    }

    var driverReportedLayoutVersion: UInt32 { simpleeq_ring_layout_version(mappedBase) }

    /// このプロセス自身の識別値。所有権の同定はこの値との比較でのみ行う。
    static let selfProcessID = UInt32(bitPattern: getpid())

    /// realtime レンダー経路が読む。ロックも再試行も伴わない単発のアトミック読み出し。
    var isSelfOwner: Bool {
        simpleeq_ownership_owner_process_id_relaxed(mappedBase) == Self.selfProcessID
    }

    private static let ownershipReadMaxAttempts = 8

    /// 制御経路が読む。世代の対で内容の整合を確かめ、崩れていれば再試行してよい値として扱う。
    /// 整合が最後まで取れなければ nil (呼び出し側は「読めなかった」側へ倒すこと)。
    func readOwnershipSnapshot() -> OwnershipSnapshot? {
        let now = mach_absolute_time()
        for _ in 0..<Self.ownershipReadMaxAttempts {
            let generation1 = simpleeq_ownership_load_generation_acquire(mappedBase)
            let requestGeneration1 = simpleeq_ownership_load_request_generation_acquire(mappedBase)
            // 奇数は書き換え中。読んでも中身が揃っていないので、その回は捨てる。
            if generation1 % 2 != 0 || requestGeneration1 % 2 != 0 { continue }
            let ownerProcessID = simpleeq_ownership_owner_process_id_relaxed(mappedBase)
            let ownerUID = simpleeq_ownership_owner_uid_relaxed(mappedBase)
            let leaseDeadline = simpleeq_ownership_lease_deadline_host_time_relaxed(mappedBase)
            let requestProcessID = simpleeq_ownership_request_process_id_relaxed(mappedBase)
            let requestUID = simpleeq_ownership_request_uid_relaxed(mappedBase)
            let requestLeaseDeadline = simpleeq_ownership_request_lease_deadline_host_time_relaxed(mappedBase)
            simpleeq_ring_acquire_fence()
            let generation2 = simpleeq_ownership_load_generation_acquire(mappedBase)
            let requestGeneration2 = simpleeq_ownership_load_request_generation_acquire(mappedBase)
            if generation1 == generation2, requestGeneration1 == requestGeneration2 {
                return OwnershipSnapshot(
                    ownerProcessID: ownerProcessID,
                    ownerUID: ownerUID,
                    ownershipLeaseRemainingSeconds: leaseDeadline == 0 ? nil : HostTime.seconds(from: now, to: leaseDeadline),
                    requestProcessID: requestProcessID,
                    requestUID: requestUID,
                    requestLeaseRemainingSeconds: requestLeaseDeadline == 0 ? nil : HostTime.seconds(from: now, to: requestLeaseDeadline)
                )
            }
        }
        return nil
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: mappedBase), mappedSize)
        close(fileDescriptor)
    }

    /// 検証できるのはヘッダを書き終えているかのみで、実際の音声書き込み開始とは独立。
    static func open(
        path: String,
        primingEnabled: Bool = true,
        initialWriterBlockFrames: Int = OccupancyPolicy.bootstrapWriterBlockFrames,
        metrics: AudioRuntimeMetrics = AudioRuntimeMetrics()
    ) -> Result<SharedRingReader, OpenFailure> {
        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else { return .failure(.fileNotFound) }

        // --- 第1段: 初期化フィールドだけが収まるぶんをマップして検証する ---
        let stage1Size = simpleeq_ring_header_size()

        // mmap はファイル長超過でも成功し、EOF 越えは SIGBUS で落ちるため事前に確認する。
        var stage1Status = stat()
        guard fstat(fd, &stage1Status) == 0, UInt64(stage1Status.st_size) >= UInt64(stage1Size) else {
            close(fd)
            return .failure(.headerInvalid)
        }

        guard let stage1Mapped = mmap(nil, stage1Size, PROT_READ, MAP_SHARED, fd, 0), stage1Mapped != MAP_FAILED else {
            close(fd)
            return .failure(.headerInvalid)
        }
        let stage1Base = UnsafeRawPointer(stage1Mapped)

        // acquire ロードが「他の初期化フィールドも既に可視」であることの根拠。
        // これより後でなければ layoutVersion 以降を読んではならない。
        guard simpleeq_ring_load_magic_acquire(stage1Base) == simpleeq_ring_expected_magic() else {
            munmap(stage1Mapped, stage1Size)
            close(fd)
            return .failure(.headerInvalid)
        }

        let foundVersion = simpleeq_ring_layout_version(stage1Base)
        let expectedVersion = simpleeq_ring_expected_layout_version()
        guard foundVersion == expectedVersion else {
            munmap(stage1Mapped, stage1Size)
            close(fd)
            return .failure(.versionMismatch(found: foundVersion, expected: expectedVersion))
        }

        let headerBytes = simpleeq_ring_header_bytes(stage1Base)
        let ringFrames = simpleeq_ring_frames(stage1Base)
        let channels = simpleeq_ring_channels(stage1Base)

        // headerBytes が第1段のマップ長未満だと、既に読んだ初期化フィールド自身がはみ出しうる。
        guard headerBytes >= UInt32(stage1Size), ringFrames > 0, channels > 0 else {
            munmap(stage1Mapped, stage1Size)
            close(fd)
            return .failure(.headerInvalid)
        }
        let (bytesPerFrame, bytesPerFrameOverflow) = UInt64(channels).multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.size))
        let (ringBytes, ringBytesOverflow) = bytesPerFrame.multipliedReportingOverflow(by: UInt64(ringFrames))
        let (totalSize64, totalSizeOverflow) = UInt64(headerBytes).addingReportingOverflow(ringBytes)
        guard !bytesPerFrameOverflow, !ringBytesOverflow, !totalSizeOverflow, totalSize64 <= UInt64(Int.max) else {
            munmap(stage1Mapped, stage1Size)
            close(fd)
            return .failure(.headerInvalid)
        }

        // 申告長がファイル長を上回った状態でマップすると realtime スレッドでアクセス違反になりうる
        // (古い共有メモリファイルが残っている場合を想定する)。
        var fileStatus = stat()
        guard fstat(fd, &fileStatus) == 0, UInt64(fileStatus.st_size) >= totalSize64 else {
            munmap(stage1Mapped, stage1Size)
            close(fd)
            return .failure(.headerInvalid)
        }

        // --- 第2段: 実サイズでマップし直す ---
        munmap(stage1Mapped, stage1Size)
        let totalSize = Int(totalSize64)
        guard let stage2Mapped = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0), stage2Mapped != MAP_FAILED else {
            close(fd)
            return .failure(.headerInvalid)
        }
        let base = UnsafeRawPointer(stage2Mapped)

        // 識別値の acquire ロードを通過済みのため実レートも可視。
        let cursor = OccupancyCursor(
            ringFrames: Int(ringFrames), channels: Int(channels),
            primingEnabled: primingEnabled, initialWriterBlockFrames: initialWriterBlockFrames,
            appliedSampleRate: simpleeq_ring_sample_rate(base), metrics: metrics
        )
        return .success(SharedRingReader(fileDescriptor: fd, mappedBase: base, mappedSize: totalSize, cursor: cursor))
    }

    /// 呼び出しは realtime コールバック開始前に限る。
    func adopt(metrics: AudioRuntimeMetrics) {
        cursor.adopt(metrics: metrics)
    }

    // --- realtime 経路の内部状態の参照と、経路外からの要求 -------------------------------------

    /// 読む側も同じ realtime 経路に限る (非アトミック)。
    var silentOutputFrameCount: Int { cursor.silentOutputFrameCount }

    /// realtime スレッド外から呼ぶ。
    func requestOccupancyReset() {
        cursor.requestOccupancyReset()
    }

    // --- realtime 読み取り (出力 AUHAL 側 realtime スレッドから呼ばれる) ---------------------
    // ロック・メモリ確保・print はここでは一切行わない。

    func observeOutputLevel(peak: Float, effectiveOutputGain: Float, frames: Int) {
        cursor.observeOutputLevel(peak: peak, effectiveOutputGain: effectiveOutputGain, frames: frames)
    }

    /// 実際に読めたフレーム数を返す (呼び出し側がアンダーラン検知に使う)。
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        cursor.read(
            into: dst, frames: frames,
            // acquire ロード: この値までの ring[] 書き込みが可視であることの根拠。
            writeCounter: simpleeq_ring_load_counter_acquire(mappedBase),
            epoch: simpleeq_ring_load_epoch_acquire(mappedBase),
            payload: simpleeq_ring_data_ptr(mappedBase)
        )
    }

    /// realtime の読み出しからは呼ばない。
    /// 値の実体は共有ヘッダにあり、この reader インスタンスには保持しない。
    func refreshDriverObservations() {
        metrics.recordDriverWritePositionObservations(
            presentationStallCount: simpleeq_ring_presentation_stall_count(mappedBase),
            presentationDeltaUnexpectedCount: simpleeq_ring_presentation_delta_unexpected_count(mappedBase),
            writeDeadlineMissedCount: simpleeq_ring_write_deadline_missed_count(mappedBase),
            silenceFilledGapCount: simpleeq_ring_silence_filled_gap_count(mappedBase)
        )
        metrics.recordWriterState(
            epoch: UInt64(simpleeq_ring_load_epoch_acquire(mappedBase)),
            ioIsRunning: simpleeq_ring_load_writer_io_is_running_acquire(mappedBase) != 0,
            ioCycleFrames: Int(simpleeq_ring_io_cycle_frames(mappedBase))
        )
        metrics.recordDriverVersions(
            driverVersion: driverReportedVersion, layoutVersion: driverReportedLayoutVersion
        )
    }

    // --- ミキサーのクライアント表 -------------------------------------------------------

    /// realtime 出力コールバックから呼ぶ。緩和ロードと事前確保済みの器への書き込みだけを行う。
    /// 文字列 (バンドル ID) はここでは触らない。
    func foldMixerClients(into store: MixerLevelStore) {
        store.beginFold(tableGeneration: simpleeq_mixer_load_table_generation_relaxed(mappedBase))
        for index in 0..<store.slotCount {
            let slot = UInt32(index)
            store.foldSlot(
                index: index,
                clientID: simpleeq_mixer_load_slot_client_id_acquire(mappedBase, slot),
                processID: simpleeq_mixer_slot_process_id(mappedBase, slot),
                outputCycleSeq: simpleeq_mixer_load_slot_output_cycle_seq(mappedBase, slot),
                clipEventCount: simpleeq_mixer_load_slot_clip_event_count(mappedBase, slot),
                peak: simpleeq_mixer_load_slot_last_cycle_peak(mappedBase, slot),
                appliedGain: simpleeq_mixer_load_slot_applied_gain(mappedBase, slot)
            )
        }
    }

    /// 名簿は毎フレームの値ではないため、低頻度の依頼としてオーディオ世界のキュー上から読む。
    func readMixerRoster() -> [MixerRosterEntry] {
        let capacity = Int(simpleeq_mixer_bundle_id_max_bytes())
        var storage = [CChar](repeating: 0, count: capacity)
        var entries: [MixerRosterEntry] = []
        for index in 0..<Int(simpleeq_mixer_slot_count()) {
            let slot = UInt32(index)
            let clientID = simpleeq_mixer_load_slot_client_id_acquire(mappedBase, slot)
            guard clientID != 0 else { continue }
            let bundleID = storage.withUnsafeMutableBufferPointer { buffer -> String in
                guard let base = buffer.baseAddress else { return "" }
                _ = simpleeq_mixer_slot_bundle_id(mappedBase, slot, base, capacity)
                return String(cString: base)
            }
            entries.append(MixerRosterEntry(
                clientID: clientID,
                processID: simpleeq_mixer_slot_process_id(mappedBase, slot),
                bundleID: bundleID,
                // 席を取ってから一度でも ProcessOutput が来たか。
                active: simpleeq_mixer_load_slot_output_cycle_seq(mappedBase, slot) != 0
            ))
        }
        return entries
    }

    func readMixerDriverObservation(now: UInt64 = mach_absolute_time()) -> MixerDriverObservation {
        let slotCount = Int(simpleeq_mixer_slot_count())
        var slotsInUse = 0
        for index in 0..<slotCount where simpleeq_mixer_load_slot_client_id_acquire(mappedBase, UInt32(index)) != 0 {
            slotsInUse += 1
        }
        let deadline = simpleeq_mixer_load_control_lease_deadline_host_time(mappedBase)
        return MixerDriverObservation(
            slotsInUse: slotsInUse,
            slotCount: slotCount,
            // 見たいのは「ドライバが今どう思っているか」なので、アプリ側の最終押し込み時刻からは導かない。
            leaseRemainingSeconds: deadline == 0 ? nil : HostTime.seconds(from: now, to: deadline),
            slotOverflowCount: simpleeq_mixer_slot_overflow_count(mappedBase),
            neutralizedCount: simpleeq_mixer_neutralized_count(mappedBase),
            gainEntryDroppedCount: simpleeq_mixer_gain_entry_dropped_count(mappedBase)
        )
    }

    // --- 定期検算の監視 (オーディオ世界のキュー上から周期的に 1 回だけ読む想定) ---------------------

    /// 仮の値 (実機確認で調整すること)。読み手停止の最悪値と同程度のオーダーを置く。
    private static let writerStallSafetyFactor: Double = 8

    /// IO サイクル長が未確定の間は読み手停止の最悪値をそのまま使う。
    static func writerStallThreshold(ioCycleFrames: UInt32, sampleRate: Double) -> TimeInterval {
        guard ioCycleFrames > 0, sampleRate > 0 else { return OccupancyPolicy.readerStopWorstCaseSeconds }
        return Double(ioCycleFrames) / sampleRate * writerStallSafetyFactor
    }

    /// seqlock 読み取り。
    /// 前後の連番が一致しなければ書き込み中に読んでしまったとして再試行せず、直前の有効値を使う。
    private func readTimeSnapshot() -> (writeCounter: UInt64, hostTime: UInt64)? {
        let seq1 = simpleeq_ring_load_ts_seq_acquire(mappedBase)
        if seq1 % 2 == 0 {
            let writeCounter = simpleeq_ring_ts_write_counter(mappedBase)
            let hostTime = simpleeq_ring_ts_host_time(mappedBase)
            // acquire ロードだけでは先行する平文ロードの後退を妨げないため、明示的な fence を挟む。
            simpleeq_ring_acquire_fence()
            let seq2 = simpleeq_ring_load_ts_seq_acquire(mappedBase)
            if seq1 == seq2 {
                lastTimeSnapshot = (writeCounter, hostTime)
            }
        }
        return lastTimeSnapshot
    }

    /// 判定はヘッダの読み取りのみで完結する (HAL への問い合わせを含まない)。
    /// 非稼働の間は経過が伸びても停止とみなさない。
    func checkWriterStalled(now: UInt64 = mach_absolute_time()) -> Bool {
        let running = simpleeq_ring_load_writer_io_is_running_acquire(mappedBase) != 0
        guard let snapshot = readTimeSnapshot() else {
            // スナップショットが無い場合は稼働中なら安全側 (停止とみなす) に倒す。
            return running
        }
        let elapsed = HostTime.seconds(from: snapshot.hostTime, to: now)
        let threshold = Self.writerStallThreshold(
            ioCycleFrames: simpleeq_ring_io_cycle_frames(mappedBase), sampleRate: simpleeq_ring_sample_rate(mappedBase)
        )
        return isRingStalled(writerIOIsRunning: running, elapsedSinceLastWrite: elapsed, threshold: threshold)
    }
}
