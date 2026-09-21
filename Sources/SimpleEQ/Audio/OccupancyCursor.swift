import Darwin
import Foundation

enum HostTime {
    /// 型の初回アクセス時 (スレッドセーフな静的初期化) に 1 度だけ算出する。
    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end > start else { return 0 }
        return Double(end - start) * ticksToSeconds
    }
}

/// SPSC リングを占有量制御付きで読むカーソル。リングの読み口は呼び出し側が 1 回の読み出しごとに渡す。
///
/// N_p = 書き手のブロック長、N_c = クライアントの実要求フレーム数 (以下のコメントで使う略記)。
final class OccupancyCursor {
    static let writerBlockObservationWindowCalls = 64

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

    /// 導出結果。N_p/N_c の観測値が変わるたびに read(into:frames:writeCounter:epoch:payload:) 内で再計算する。
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

    /// realtime 読み出しはこの値だけを読み、他の場所の値を直接読まない。
    /// 書き換えはレート適用の単一入口 (出力 AUHAL 停止中の 1 回) からのみ行う。
    private var appliedSampleRate: Double
    /// 不連続の再同期で混ぜる 2 音のクロスフェード長 (無音との継ぎ目には使わない)。
    private var seamFadeTotalFrames: Int
    /// 無音との継ぎ目のフェード長。
    /// EQ が扱う最も低い帯域の周期より遅く動かす (速いとその帯域にエネルギーが残る)。
    private var silenceSeamFadeTotalFrames: Int
    private var resyncFadeFramesRemaining = 0
    /// フェード中、再同期していなければ次に読んでいたはずの旧カーソル位置。
    private var resyncFadeOldSourceCounter: UInt64 = 0

    /// 継ぎ目の包絡ゲイン (0…1)。read(into:frames:writeCounter:epoch:payload:) のみが読み書きする。
    private var seamEnvelopeGain: Float = 0
    /// 直近に出力した 1 フレーム (包絡を掛ける前の値)。read(into:frames:writeCounter:epoch:payload:) のみが読み書きする。
    private let lastEmittedFrame: UnsafeMutablePointer<Float>

    /// realtime スレッド外からの store と、read(into:frames:writeCounter:epoch:payload:) からの load/clear が異なるスレッドで起こるため atomic。
    private let occupancyResetRequestFlag = AtomicUInt64(0)

    /// 積む側 (observeOutputLevel) と読む側 (read(into:frames:writeCounter:epoch:payload:)) は同じ realtime スレッドで動くため atomic にしない。
    private var silentOutputFrames = 0

    private(set) var metrics: AudioRuntimeMetrics

    /// read(into:frames:writeCounter:epoch:payload:) (realtime) のみが読み書きする。
    private var lastObservedEpoch: UInt32?

    init(
        ringFrames: Int, channels: Int, primingEnabled: Bool, initialWriterBlockFrames: Int,
        appliedSampleRate: Double, metrics: AudioRuntimeMetrics
    ) {
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

    deinit {
        lastEmittedFrame.deallocate()
    }

    /// 呼び出しは出力 AUHAL 停止中の 1 回に限る。
    func applySampleRate(_ rate: Double) {
        appliedSampleRate = rate
        seamFadeTotalFrames = OccupancyPolicy.seamFadeFrames(sampleRate: rate)
        silenceSeamFadeTotalFrames = OccupancyPolicy.silenceSeamFadeFrames(sampleRate: rate)
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

    /// 要求はキューイングしない (連続する事象は 1 回のリセットへ束ねてよい)。realtime スレッド外から呼ぶ。
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

    /// 実際に読めたフレーム数を返す (呼び出し側がアンダーラン検知に使う)。
    /// 不足分は直前フレームへ継ぎ目の包絡ゲインを掛けた値で埋める。
    /// writeCounter はこの値までのペイロード書き込みが可視であることを保証する読み方で読んだ値を渡す。
    func read(
        into dst: UnsafeMutablePointer<Float>, frames: Int,
        writeCounter: UInt64, epoch currentEpoch: UInt32, payload dataPtr: UnsafePointer<Float>?
    ) -> Int {
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

        // 世代カウンタは書き手の IO 再起動 (レート変更含む) のたびに進む。
        // 初回呼び出しは比較対象が無いため記録のみ行う。
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
        // 上限超過を伴わないリセット契機の評価はここに置く
        // (涸れ検知より後段だと、自分がリセットしたバッファ量を同じ回の涸れ検知が読み、原因の切り分けができなくなる)。
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
                let elapsed = HostTime.seconds(from: previousReadHostTime, to: now)
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
            let overshootElapsed = overshootStartHostTime.map { HostTime.seconds(from: $0, to: now) }
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

        // プライミング: バッファ量が targetOccupancy に達するまで消費を止める (再生開始直後のクリックノイズ防止)。
        // primingEnabled: false は常に消費する (テスト用)。
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
            // 着地の切り詰め: 推定と食い違う回は目標を超えた位置で完了しうるため、超過をここで捨てる (削り過ぎる側には倒れない)。
            // 混ぜる相手は要らない。
            // この時点までは実データを出しておらず (上の分岐が包絡を掛けた値を返している)、継ぎ目は戻る側の包絡が担う。
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
}
