import CoreAudio
import Darwin
import Foundation
import SimpleEQRingC

/// 値の実体はレイアウトヘッダの 1 箇所のみで、ここでは薄い C 関数経由で取得するだけで複製しない。
enum DriverConfig {
    /// 表示専用であり、デバイスの解決キーとしての用途は無い (表示名は実行時に変更でき同名の
    /// デバイスも同時に存在しうるため、解決キーには常に deviceUID を使う)。
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
}

enum DriverAvailability: Equatable {
    /// 起動シーケンスの最初のスナップショットが届く前の、まだ確認できていない状態。
    /// init(openResult:) がこの値を生成することはない。
    case checking
    case ok
    case notFound
    case versionMismatch

    /// fileNotFound/headerInvalid はどちらも「有効なドライバが見当たらない」という同じ対処に
    /// つながるため notFound へまとめる。
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
    /// レイアウトバージョンが一致した場合にのみ読める。読めないこと自体が「再インストールが
    /// 要る」ことを表す。
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
///
/// N_p = 書き手のブロック長、N_c = クライアントの実要求フレーム数 (以下のコメントで使う略記)。
final class SharedRingReader {
    enum OpenFailure: Error, Equatable {
        case fileNotFound
        case headerInvalid
        case versionMismatch(found: UInt32, expected: UInt32)
    }

    private static let writerBlockObservationWindowCalls = 64

    private let fileDescriptor: Int32
    private let mappedBase: UnsafeRawPointer
    private let mappedSize: Int
    private let ringFrames: Int
    private let channels: Int

    /// 無効時は判定に使わない (占有量の導出自体は行う、テスト用)。
    private let primingEnabled: Bool

    /// N_p の現在の推定値。
    private var writerBlockFramesEstimate: Int
    private var windowMinPositiveWriteDelta: Int?
    private var lastObservedWriteCounterForBlockSize: UInt64?
    private var windowSampleCount = 0

    private static let clientRequestObservationWindowCalls = writerBlockObservationWindowCalls

    /// N_c の観測値。
    private var clientRequestFramesEstimate: Int
    private var clientRequestWindowSampleCount = 0

    /// 導出結果。N_p/N_c の観測値が変わるたびに read(into:frames:) 内で
    /// 再計算する。
    private var targetOccupancy: Int
    private var maxOccupancy: Int

    private var lastRecordedEffectiveWriterBlockFrames: Int?
    private var lastRecordedOccupancyBounds: (target: Int, max: Int)?

    /// バッファ量が 0 になるたびに false へ戻り、targetOccupancy に達するまで消費を再開しない。
    private var primed: Bool

    /// realtime (出力 AUHAL 側スレッド) のみが読み書きする。
    private var readCounter: UInt64 = 0

    private var lastReadHostTime: UInt64?
    /// バッファ量が上限を超え続けている継続時間の起点。上限以下に戻ったら nil に戻す。
    private var overshootStartHostTime: UInt64?

    /// realtime 読み出しはこの値だけを読み、他の場所の値を直接読まない。書き換えは
    /// レート適用の単一入口 (出力 AUHAL 停止中の 1 回) からのみ行う。
    private var appliedSampleRate: Double
    /// 不連続の再同期で混ぜる 2 音のクロスフェード長 (無音との継ぎ目には使わない)。
    private var seamFadeTotalFrames: Int
    /// 無音との継ぎ目のフェード長。EQ が扱う最も低い帯域の周期より遅く動かす (速いとその帯域に
    /// エネルギーが残る)。
    private var silenceSeamFadeTotalFrames: Int
    private var resyncFadeFramesRemaining = 0
    /// フェード中、再同期していなければ次に読んでいたはずの旧カーソル位置。
    private var resyncFadeOldSourceCounter: UInt64 = 0

    /// 継ぎ目の包絡ゲイン (0…1)。read(into:frames:) のみが読み書きする。
    private var seamEnvelopeGain: Float = 0
    /// 直近に出力した 1 フレーム (包絡を掛ける前の値)。read(into:frames:) のみが読み書きする。
    private let lastEmittedFrame: UnsafeMutablePointer<Float>

    /// realtime スレッド外からの store と、read(into:frames:) からの load/clear が異なる
    /// スレッドで起こるため atomic。
    private let occupancyResetRequestFlag = AtomicUInt64(0)

    /// 積む側 (observeOutputLevel) と読む側 (read(into:frames:)) は同じ realtime スレッドで
    /// 動くため atomic にしない。
    private var silentOutputFrames = 0

    private(set) var metrics: AudioRuntimeMetrics

    /// seqlock 経由 (書き込み中に読んでしまい破棄した回は更新しない)。realtime スレッドの
    /// readCounter とは別カーソル。
    private var lastTimeSnapshot: (writeCounter: UInt64, hostTime: UInt64)?

    /// read(into:frames:) (realtime) のみが読み書きする。
    private var lastObservedEpoch: UInt32?

    private init(
        fileDescriptor: Int32, mappedBase: UnsafeRawPointer, mappedSize: Int,
        ringFrames: Int, channels: Int, primingEnabled: Bool, initialWriterBlockFrames: Int,
        appliedSampleRate: Double, metrics: AudioRuntimeMetrics
    ) {
        self.fileDescriptor = fileDescriptor
        self.mappedBase = mappedBase
        self.mappedSize = mappedSize
        self.ringFrames = ringFrames
        self.channels = channels
        self.primingEnabled = primingEnabled
        self.writerBlockFramesEstimate = initialWriterBlockFrames
        self.clientRequestFramesEstimate = 0
        self.primed = !primingEnabled
        self.metrics = metrics
        self.appliedSampleRate = appliedSampleRate
        self.seamFadeTotalFrames = OccupancyPolicy.seamFadeFrames(sampleRate: appliedSampleRate)
        self.silenceSeamFadeTotalFrames = OccupancyPolicy.silenceSeamFadeFrames(sampleRate: appliedSampleRate)
        self.lastEmittedFrame = UnsafeMutablePointer<Float>.allocate(capacity: channels)
        self.lastEmittedFrame.initialize(repeating: 0, count: channels)
        self.targetOccupancy = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: initialWriterBlockFrames, clientRequestFrames: 0, sampleRate: appliedSampleRate
        )
        self.maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: targetOccupancy, writerBlockFrames: initialWriterBlockFrames,
            sampleRate: appliedSampleRate
        )
        self.metrics.recordRingCapacity(ringFrames)
    }

    /// 呼び出しは出力 AUHAL 停止中の 1 回に限る。
    func applySampleRate(_ rate: Double) {
        appliedSampleRate = rate
        seamFadeTotalFrames = OccupancyPolicy.seamFadeFrames(sampleRate: rate)
        silenceSeamFadeTotalFrames = OccupancyPolicy.silenceSeamFadeFrames(sampleRate: rate)
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

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: mappedBase), mappedSize)
        close(fileDescriptor)
        lastEmittedFrame.deallocate()
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

        // acquire ロードが「他の初期化フィールドも既に可視」であることの根拠。これより後でなければ
        // layoutVersion 以降を読んではならない。
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
        let reader = SharedRingReader(
            fileDescriptor: fd, mappedBase: base, mappedSize: totalSize,
            ringFrames: Int(ringFrames), channels: Int(channels),
            primingEnabled: primingEnabled, initialWriterBlockFrames: initialWriterBlockFrames,
            appliedSampleRate: simpleeq_ring_sample_rate(base), metrics: metrics
        )
        return .success(reader)
    }

    /// 呼び出しは realtime コールバック開始前に限る。
    func adopt(metrics: AudioRuntimeMetrics) {
        self.metrics = metrics
        lastRecordedEffectiveWriterBlockFrames = nil
        lastRecordedOccupancyBounds = nil
        metrics.recordRingCapacity(ringFrames)
    }

    // --- realtime 経路の内部状態の参照と、経路外からの要求 -------------------------------------

    /// 読む側も同じ realtime 経路に限る (非アトミック)。
    var silentOutputFrameCount: Int { silentOutputFrames }

    /// 要求はキューイングしない (連続する事象は 1 回のリセットへ束ねてよい)。realtime スレッド外
    /// から呼ぶ。
    func requestOccupancyReset() {
        occupancyResetRequestFlag.store(1)
    }

    // --- realtime 読み取り (出力 AUHAL 側 realtime スレッドから呼ばれる) ---------------------
    // ロック・メモリ確保・print はここでは一切行わない。

    func observeOutputLevel(peak: Float, effectiveOutputGain: Float, frames: Int) {
        if OccupancyPolicy.isOutputSilent(peak: peak, effectiveOutputGain: effectiveOutputGain) {
            silentOutputFrames += frames
        } else {
            silentOutputFrames = 0
        }
    }

    /// N_c の観測窓は再出発させ、N_p の観測窓は据え置く (N_c は出力先依存、N_p は書き手依存のため)。
    private func performOccupancyReset(
        cause: AudioRuntimeMetrics.OccupancyResetCause, writeCounter: UInt64,
        available: inout Int, requestedFrames: Int
    ) {
        let availableBeforeDiscard = available
        readCounter = writeCounter
        available = 0
        if primingEnabled { primed = false }
        resyncFadeFramesRemaining = 0
        overshootStartHostTime = nil
        clientRequestFramesEstimate = requestedFrames
        clientRequestWindowSampleCount = 0
        // 破棄量はリング容量で切り詰める (カウンタ上の差分はリング容量を超えることがある)。
        metrics.recordOccupancyReset(
            cause: cause, discardedFrames: min(availableBeforeDiscard, ringFrames),
            targetOccupancyFrames: targetOccupancy
        )
    }

    /// 要求ラッチは観測した回に消費する。
    private func pendingOccupancyResetCause(available: Int) -> AudioRuntimeMetrics.OccupancyResetCause? {
        if occupancyResetRequestFlag.value != 0 {
            occupancyResetRequestFlag.store(0)
            return .outputRestart
        }
        if OccupancyPolicy.requiresSilenceReset(
            silentFrames: silentOutputFrames, available: available,
            targetOccupancyFrames: targetOccupancy, writerBlockFrames: writerBlockFramesEstimate,
            sampleRate: appliedSampleRate
        ) {
            return .silence
        }
        return nil
    }

    /// 混ぜる相手がある経路 (即時再同期・ドリフトトリム) が共有する。常にクロスフェードを立てる。
    private func discardToTargetOccupancy(available: inout Int) -> Int {
        let discard = OccupancyPolicy.framesToDiscard(available: available, targetOccupancyFrames: targetOccupancy)
        // 「旧」側の起点は破棄前の readCounter (段差の手前側)。
        resyncFadeOldSourceCounter = readCounter
        resyncFadeFramesRemaining = seamFadeTotalFrames
        readCounter += UInt64(discard)
        available -= discard
        // 目標バッファ量ぶんを残して着地するため、プライミングは済んだ状態になる。
        if primingEnabled { primed = true }
        overshootStartHostTime = nil
        return discard
    }

    /// 実際に読めたフレーム数を返す (呼び出し側がアンダーラン検知に使う)。不足分は直前フレームへ
    /// 継ぎ目の包絡ゲインを掛けた値で埋める。
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let now = mach_absolute_time()

        // 初回呼び出しか (「鳴っていた音の続き」という概念がまだ無い唯一の時点)。
        let previousReadHostTime = lastReadHostTime
        let isInitialSync = previousReadHostTime == nil
        lastReadHostTime = now

        if clientRequestWindowSampleCount >= Self.clientRequestObservationWindowCalls {
            clientRequestFramesEstimate = frames
            clientRequestWindowSampleCount = 0
        } else if frames > clientRequestFramesEstimate {
            clientRequestFramesEstimate = frames
        }
        clientRequestWindowSampleCount += 1

        // acquire ロード: この値までの ring[] 書き込みが可視であることの根拠。
        let writeCounter = simpleeq_ring_load_counter_acquire(mappedBase)

        // 世代カウンタは書き手の IO 再起動 (レート変更含む) のたびに進む。初回呼び出しは比較対象が
        // 無いため記録のみ行う。
        let currentEpoch = simpleeq_ring_load_epoch_acquire(mappedBase)
        let epochChanged = lastObservedEpoch.map { $0 != currentEpoch } ?? false
        lastObservedEpoch = currentEpoch

        // カウンタ後退はエラーでなく正常系 (coreaudiod 再起動で 0 から再開する)。
        if writeCounter < readCounter {
            readCounter = writeCounter
        }

        if let previous = lastObservedWriteCounterForBlockSize, writeCounter > previous {
            let positiveDelta = Int(writeCounter - previous)
            windowMinPositiveWriteDelta = min(windowMinPositiveWriteDelta ?? positiveDelta, positiveDelta)
        }
        lastObservedWriteCounterForBlockSize = writeCounter
        windowSampleCount += 1
        if windowSampleCount >= Self.writerBlockObservationWindowCalls {
            if let confirmed = windowMinPositiveWriteDelta {
                writerBlockFramesEstimate = confirmed
            }
            windowMinPositiveWriteDelta = nil
            windowSampleCount = 0
        }

        var available = Int(writeCounter - readCounter)

        metrics.recordAvailable(available)
        if lastRecordedEffectiveWriterBlockFrames != writerBlockFramesEstimate {
            metrics.recordEffectiveWriterBlockFrames(writerBlockFramesEstimate)
            lastRecordedEffectiveWriterBlockFrames = writerBlockFramesEstimate
        }

        // targetOccupancy が拡大しバッファ量がまだ届いていないなら、瞬時下限を割らないよう消費を止めて待つ。
        let previousTarget = targetOccupancy
        targetOccupancy = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFramesEstimate, clientRequestFrames: clientRequestFramesEstimate,
            sampleRate: appliedSampleRate
        )
        maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: targetOccupancy, writerBlockFrames: writerBlockFramesEstimate,
            sampleRate: appliedSampleRate
        )
        if lastRecordedOccupancyBounds?.target != targetOccupancy || lastRecordedOccupancyBounds?.max != maxOccupancy {
            metrics.recordOccupancyBounds(targetFrames: targetOccupancy, maxFrames: maxOccupancy)
            lastRecordedOccupancyBounds = (targetOccupancy, maxOccupancy)
        }
        // 上限超過を伴わないリセット契機の評価はここに置く (涸れ検知より後段だと、自分がリセット
        // したバッファ量を同じ回の涸れ検知が読み、原因の切り分けができなくなる)。
        if let cause = pendingOccupancyResetCause(available: available) {
            performOccupancyReset(
                cause: cause, writeCounter: writeCounter, available: &available, requestedFrames: frames
            )
        } else {
            let wasPrimedBeforeReprimeCheck = primed
            if primingEnabled, OccupancyPolicy.requiresReprime(
                currentAvailable: available, newTargetOccupancyFrames: targetOccupancy,
                previousTargetOccupancyFrames: previousTarget
            ) {
                primed = false
            }

            if primingEnabled, available == 0 {
                primed = false
            }

            if wasPrimedBeforeReprimeCheck, !primed {
                metrics.recordReprime(dueToWriterStall: available == 0)
            }

            // 初回呼び出しは間隔を測れないため安全側 (不連続) に倒す。書き手の IO 再起動も同じ扱い。
            var discontinuityDetected = epochChanged
            if let previousReadHostTime {
                let elapsed = Self.seconds(from: previousReadHostTime, to: now)
                let threshold = OccupancyPolicy.discontinuityIntervalThreshold(
                    clientRequestFrames: clientRequestFramesEstimate, sampleRate: appliedSampleRate
                )
                if elapsed > threshold { discontinuityDetected = true }
            } else {
                discontinuityDetected = true
            }

            if available > maxOccupancy {
                if overshootStartHostTime == nil { overshootStartHostTime = now }
            } else {
                overshootStartHostTime = nil
            }
            let overshootElapsed = overshootStartHostTime.map { Self.seconds(from: $0, to: now) }
            let trimHoldDuration = OccupancyPolicy.trimHoldDuration(
                targetOccupancyFrames: targetOccupancy, maxOccupancyFrames: maxOccupancy,
                sampleRate: appliedSampleRate, driftCorrectionMaxRateFraction: AudioConfig.driftCorrectionMaxRateFraction
            )
            let mixable = OccupancyPolicy.hasMixableSource(
                available: available, ringFrames: ringFrames, writerBlockFrames: writerBlockFramesEstimate
            )

            // 段差は即座に再同期し、緩やかなドリフトだけ保留時間の対象にする。
            switch OccupancyPolicy.classifyOverflow(
                discontinuityDetected: discontinuityDetected, available: available, maxOccupancyFrames: maxOccupancy,
                overshootElapsed: overshootElapsed, trimHoldDuration: trimHoldDuration
            ) {
            case .withinBounds:
                break
            case .immediateResync:
                if isInitialSync {
                    // 接続時は書き手の現在位置まで捨てる (目標バッファ量ぶん残すと前回稼働時の残骸を鳴らしうる)。
                    performOccupancyReset(
                        cause: .initialSync, writeCounter: writeCounter,
                        available: &available, requestedFrames: frames
                    )
                } else if !mixable {
                    // 混ぜる相手が無い段差はフェードを立てられないため、位相ごと作り直す。
                    performOccupancyReset(
                        cause: .unmixableSeam, writeCounter: writeCounter,
                        available: &available, requestedFrames: frames
                    )
                } else {
                    let discarded = discardToTargetOccupancy(available: &available)
                    metrics.recordResync(discardedFrames: discarded)
                }
            case .sustainedDriftTrim:
                if !mixable {
                    performOccupancyReset(
                        cause: .unmixableSeam, writeCounter: writeCounter,
                        available: &available, requestedFrames: frames
                    )
                } else {
                    let discarded = discardToTargetOccupancy(available: &available)
                    metrics.recordDriftTrim(discardedFrames: discarded)
                }
            }
        }

        // プライミング: バッファ量が targetOccupancy に達するまで消費を止める (再生開始直後のクリック
        // ノイズ防止)。primingEnabled: false は常に消費する (テスト用)。
        if !primed {
            if available < targetOccupancy {
                // 掛ける前の値 (lastEmittedFrame) を控える: dst の値を控えるとゼロ埋め中にゲインが2乗で掛かる。
                for f in 0..<frames {
                    let dstBase = f * channels
                    for c in 0..<channels {
                        dst[dstBase + c] = lastEmittedFrame[c] * seamEnvelopeGain
                    }
                    seamEnvelopeGain = OccupancyPolicy.fallingSeamGain(current: seamEnvelopeGain, totalFrames: silenceSeamFadeTotalFrames)
                }
                silentOutputFrames = 0
                return 0
            }
            // 着地の切り詰め: 推定と食い違う回は目標を超えた位置で完了しうるため、超過をここで
            // 捨てる (削り過ぎる側には倒れない)。
            // 混ぜる相手は要らない。この時点までは実データを出しておらず (上の分岐が包絡を掛けた
            // 値を返している)、継ぎ目は戻る側の包絡が担う。
            let excess = OccupancyPolicy.framesToDiscard(
                available: available, targetOccupancyFrames: targetOccupancy
            )
            if excess > 0 {
                readCounter += UInt64(excess)
                available -= excess
                metrics.recordPrimingTrim(discardedFrames: excess)
            }
            primed = true
        }

        let dataPtr = simpleeq_ring_data_ptr(mappedBase)
        let toRead = dataPtr != nil ? min(frames, available) : 0
        if toRead > 0, let dataPtr {
            let ringFramesU64 = UInt64(ringFrames)
            for f in 0..<toRead {
                let ringIndex = Int((readCounter + UInt64(f)) % ringFramesU64)
                let srcBase = ringIndex * channels
                let dstBase = f * channels
                if resyncFadeFramesRemaining > 0 {
                    // 新カーソル側の重みを 0→1 で上げながら旧カーソル側と混ぜ、段差を数msの傾斜へ均す。
                    let denominator = max(1, seamFadeTotalFrames - 1)
                    let progressed = seamFadeTotalFrames - resyncFadeFramesRemaining
                    let newWeight = Float(progressed) / Float(denominator)
                    let oldIndex = Int(resyncFadeOldSourceCounter % ringFramesU64)
                    let oldBase = oldIndex * channels
                    for c in 0..<channels {
                        let mixed = dataPtr[oldBase + c] * (1 - newWeight) + dataPtr[srcBase + c] * newWeight
                        lastEmittedFrame[c] = mixed
                        dst[dstBase + c] = mixed * seamEnvelopeGain
                    }
                    resyncFadeOldSourceCounter += 1
                    resyncFadeFramesRemaining -= 1
                } else {
                    // 定常再生ではゲインが1で飽和するため乗算は原音と一致する。
                    for c in 0..<channels {
                        let raw = dataPtr[srcBase + c]
                        lastEmittedFrame[c] = raw
                        dst[dstBase + c] = raw * seamEnvelopeGain
                    }
                }
                seamEnvelopeGain = OccupancyPolicy.risingSeamGain(current: seamEnvelopeGain, totalFrames: silenceSeamFadeTotalFrames)
            }
            readCounter += UInt64(toRead)
        }
        if toRead < frames {
            for f in toRead..<frames {
                let dstBase = f * channels
                for c in 0..<channels {
                    dst[dstBase + c] = lastEmittedFrame[c] * seamEnvelopeGain
                }
                seamEnvelopeGain = OccupancyPolicy.fallingSeamGain(current: seamEnvelopeGain, totalFrames: silenceSeamFadeTotalFrames)
            }
        }

        if toRead == 0 { silentOutputFrames = 0 }
        return toRead
    }

    /// realtime の読み出しからは呼ばない。値の実体は共有ヘッダにあり、この reader インスタンスには
    /// 保持しない。
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
            leaseRemainingSeconds: deadline == 0 ? nil : Self.seconds(from: now, to: deadline),
            slotOverflowCount: simpleeq_mixer_slot_overflow_count(mappedBase),
            neutralizedCount: simpleeq_mixer_neutralized_count(mappedBase),
            gainEntryDroppedCount: simpleeq_mixer_gain_entry_dropped_count(mappedBase)
        )
    }

    // --- 定期検算の監視 (オーディオ世界のキュー上から周期的に 1 回だけ読む想定) ---------------------

    /// 仮の値 (実機確認で調整すること)。読み手停止の最悪値と同程度のオーダーを置く。
    private static let writerStallSafetyFactor: Double = 8

    /// IO サイクル長が未確定の間は読み手停止の最悪値をそのまま使う。
    private static func writerStallThreshold(ioCycleFrames: UInt32, sampleRate: Double) -> TimeInterval {
        guard ioCycleFrames > 0, sampleRate > 0 else { return OccupancyPolicy.readerStopWorstCaseSeconds }
        return Double(ioCycleFrames) / sampleRate * writerStallSafetyFactor
    }

    /// seqlock 読み取り。前後の連番が一致しなければ書き込み中に読んでしまったとして再試行せず、
    /// 直前の有効値を使う。
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

    /// 判定はヘッダの読み取りのみで完結する (HAL への問い合わせを含まない)。非稼働の間は経過が
    /// 伸びても停止とみなさない。
    func checkWriterStalled(now: UInt64 = mach_absolute_time()) -> Bool {
        let running = simpleeq_ring_load_writer_io_is_running_acquire(mappedBase) != 0
        guard let snapshot = readTimeSnapshot() else {
            // スナップショットが無い場合は稼働中なら安全側 (停止とみなす) に倒す。
            return running
        }
        let elapsed = Self.seconds(from: snapshot.hostTime, to: now)
        let threshold = Self.writerStallThreshold(
            ioCycleFrames: simpleeq_ring_io_cycle_frames(mappedBase), sampleRate: simpleeq_ring_sample_rate(mappedBase)
        )
        return isRingStalled(writerIOIsRunning: running, elapsedSinceLastWrite: elapsed, threshold: threshold)
    }

    // --- host time ヘルパー -------------------------------------------------------------

    /// 型の初回アクセス時 (スレッドセーフな静的初期化) に 1 度だけ算出する。
    private static let hostTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end > start else { return 0 }
        return Double(end - start) * hostTicksToSeconds
    }
}
