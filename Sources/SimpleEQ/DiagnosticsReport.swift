import Foundation

/// 診断の 1 行。値は複数を縦に並べることがある (バッファ量の現在・目標・上限など)。
struct DiagnosticsRow: Equatable {
    let title: String
    let subtitle: String?
    /// 右側へ縦に並べる表示値。書き出しもこの並びをそのまま使う。
    let values: [String]
    /// 画面がゲージを描くための生の値。書式化済みの値と同じ行が併せて持つことで、
    /// ゲージが観測量を別経路から取り直すことがなくなる。
    let gauge: Gauge?

    struct Gauge: Equatable {
        let currentFrames: Int
        let targetFrames: Int
        let maxFrames: Int
    }

    init(title: String, subtitle: String? = nil, values: [String], gauge: Gauge? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.values = values
        self.gauge = gauge
    }
}

/// 面 (行のまとまり)。
struct DiagnosticsSection: Equatable {
    let title: String
    let rows: [DiagnosticsRow]
}

/// 診断の項目定義。スナップショットを入力に面と行の並びを返すだけで、画面にも書き出しにも属さない。
/// 画面と書き出しの双方がここから作られるため、両者の項目が食い違うことが起こらない。
enum DiagnosticsReport {

    // MARK: - 面と行

    static func sections(_ s: AudioRuntimeMetrics.Snapshot) -> [DiagnosticsSection] {
        [identity(s), flow(s), traces(s)]
    }

    /// 今どういう構成で動いているか。
    private static func identity(_ s: AudioRuntimeMetrics.Snapshot) -> DiagnosticsSection {
        DiagnosticsSection(title: "状態", rows: [
            DiagnosticsRow(title: "アプリ version", values: [s.appVersion]),
            DiagnosticsRow(title: "ドライバ version", values: [readerValue(s, s.driverVersion.text)]),
            DiagnosticsRow(
                title: "レイアウト version", values: [readerValue(s, "\(s.driverLayoutVersion)")]
            ),
            DiagnosticsRow(
                title: "出力デバイスの実レート", subtitle: "音を出しているデバイスの公称レート",
                values: [hertzText(s.outputDeviceSampleRate)]
            ),
            DiagnosticsRow(
                title: "ドライバの実レート", subtitle: "アプリが適用中のレート",
                values: [hertzText(s.appliedSampleRate)]
            ),
            DiagnosticsRow(
                title: "音量経路", subtitle: "音量 / 消音",
                values: [
                    [
                        volumeRouteText(
                            mode: s.volumeRoute?.volumeMode, downgraded: s.volumeRoute?.volumeDowngraded,
                            value: s.volumeRoute?.volume.map { String(format: "%.3f", $0) }
                        ),
                        volumeRouteText(
                            mode: s.volumeRoute?.muteMode, downgraded: s.volumeRoute?.muteDowngraded,
                            value: s.volumeRoute?.muted.map { $0 ? "ON" : "OFF" }
                        ),
                    ].joined(separator: " / "),
                ]
            ),
            // 読み手が居ない間は、読み手が書いていた値を現在の状態として見せない。
            DiagnosticsRow(
                title: "ドライバの IO 稼働", subtitle: "ドライバの申告値",
                values: [readerValue(s, s.writerIOIsRunning ? "稼働中" : "停止中")]
            ),
            DiagnosticsRow(
                title: "ドライバの世代カウンタ (epoch)", subtitle: "IO 開始とレート変更で進む",
                values: [readerValue(s, "\(s.writerEpoch)")]
            ),
            DiagnosticsRow(
                title: "ドライバの IO サイクル長", subtitle: "ドライバの申告値 (直近サイクル)",
                values: [readerValue(s, framesText(s.writerIOCycleFrames, s))]
            ),
            DiagnosticsRow(
                title: "ドライバのブロック長", subtitle: "アプリ側の推定値 (観測窓から)",
                values: [readerValue(s, framesText(s.effectiveWriterBlockFrames, s))]
            ),
            DiagnosticsRow(
                title: "リング容量", subtitle: "共有メモリの収容量",
                values: [readerValue(s, framesText(s.ringCapacityFrames, s))]
            ),
            DiagnosticsRow(
                title: "目標バッファ量 / 上限バッファ量", subtitle: "追従先とその上限",
                values: [
                    readerValue(s, framesText(s.targetOccupancyFrames, s)),
                    readerValue(s, framesText(s.maxOccupancyFrames, s)),
                ]
            ),
        ])
    }

    /// 今きちんと流れているか。
    private static func flow(_ s: AudioRuntimeMetrics.Snapshot) -> DiagnosticsSection {
        // ゲージの現在位置は窓統計の中央値を使う (単発のサンプルはぶれを持つため)。
        let currentFrames = s.availableWindow?.medianFrames

        return DiagnosticsSection(title: "音の流れの健全性", rows: [
            DiagnosticsRow(
                title: "バッファ量", subtitle: "現在 / 目標 / 上限",
                values: [
                    "現在: " + readerValue(s, currentFrames.map { framesText($0, s) } ?? unobserved),
                    "目標: " + readerValue(s, framesText(s.targetOccupancyFrames, s)),
                    "上限: " + readerValue(s, framesText(s.maxOccupancyFrames, s)),
                ],
                gauge: DiagnosticsRow.Gauge(
                    currentFrames: s.readerObserved ? (currentFrames ?? 0) : 0,
                    targetFrames: s.readerObserved ? s.targetOccupancyFrames : 0,
                    maxFrames: s.readerObserved ? s.maxOccupancyFrames : 0
                )
            ),
            // 観測前も行数を変えない (観測が始まった瞬間に行の高さが変わると、その下の並び全体が動く)。
            DiagnosticsRow(
                title: "バッファ量 (窓統計)", subtitle: "直近の観測窓",
                values: [
                    "最小: " + readerValue(s, s.availableWindow.map { framesText($0.minFrames, s) } ?? unobserved),
                    "中央: " + readerValue(s, s.availableWindow.map { framesText($0.medianFrames, s) } ?? unobserved),
                    "最大: " + readerValue(s, s.availableWindow.map { framesText($0.maxFrames, s) } ?? unobserved),
                ]
            ),
            DiagnosticsRow(
                title: "目標バッファ量の走行最大値", subtitle: "これまでに目標が伸びた上限",
                values: [framesText(s.targetOccupancyFramesMax, s)]
            ),
            DiagnosticsRow(
                title: "ピーク", subtitle: "EQ・アプリ側ゲイン適用後の走行最大振幅",
                values: [peakText(s.peak)]
            ),
        ])
    }

    /// これまでに何が起きたか。
    private static func traces(_ s: AudioRuntimeMetrics.Snapshot) -> DiagnosticsSection {
        let primingSilenceSeconds = OccupancyPolicy.durationSeconds(
            frames: Int(clamping: s.primingSilenceFrameCount), sampleRate: s.appliedSampleRate
        )

        return DiagnosticsSection(title: "異常の痕跡", rows: [
            DiagnosticsRow(
                title: "ドライバの世代カウンタの変化", subtitle: "IO 開始・レート変更が起きた回数",
                values: ["+" + countText(s.writerEpochAdvanceCount)]
            ),
            DiagnosticsRow(
                title: "再プライミング", subtitle: "書き込みの停止 / 目標拡大",
                values: [countText(s.reprimeDueToWriterStallCount) + " / " + countText(s.reprimeDueToTargetGrowthCount)]
            ),
            DiagnosticsRow(
                title: "部分読み", subtitle: "発生回数 / 欠落フレーム数",
                values: [countText(s.partialReadCount) + " / " + framesOnlyText(s.missingFrameCount)]
            ),
            DiagnosticsRow(
                title: "プライミング待機 (無音期間)", subtitle: "無音の継続時間 / 発生回数",
                values: [OccupancyPolicy.formattedDuration(seconds: primingSilenceSeconds) + " / " + countText(s.primingSilenceCount)]
            ),
            DiagnosticsRow(
                title: "再同期", subtitle: "波形が途切れた回数 / 飛ばして捨てたフレーム数",
                values: [countText(s.resyncEventCount) + " / " + framesOnlyText(s.resyncDiscardedFrameCount)]
            ),
            DiagnosticsRow(
                title: "初回同期 (接続時のクリア)", subtitle: "発生回数 / 破棄フレーム数",
                values: [
                    countText(s.occupancyResetDueToInitialSyncCount)
                        + " / " + framesOnlyText(s.occupancyResetDueToInitialSyncDiscardedFrameCount)
                ]
            ),
            DiagnosticsRow(
                title: "ドリフトトリム", subtitle: "発生回数 / 破棄フレーム数",
                values: [countText(s.driftTrimEventCount) + " / " + framesOnlyText(s.driftTrimDiscardedFrameCount)]
            ),
            DiagnosticsRow(
                title: "プライミングの切り詰め", subtitle: "発生回数 / 破棄フレーム数",
                values: [countText(s.primingTrimEventCount) + " / " + framesOnlyText(s.primingTrimDiscardedFrameCount)]
            ),
            // ここが数えるのは捨てた側だけ (溜め直す側は再プライミングとプライミング待機が持つ)。
            DiagnosticsRow(
                title: "契機別バッファクリア回数", subtitle: "出力再起動 / 無音 / 継ぎ目",
                values: [
                    countText(s.occupancyResetDueToOutputRestartCount)
                        + " / " + countText(s.occupancyResetDueToSilenceCount)
                        + " / " + countText(s.occupancyResetDueToUnmixableSeamCount)
                ]
            ),
            DiagnosticsRow(
                title: "バッファクリアで捨てた量", subtitle: "初回同期を含む合計",
                values: [framesText(Int(clamping: s.occupancyResetDiscardedFrameCountTotal), s)]
            ),
            DiagnosticsRow(
                title: "直近クリアしたバッファ量", subtitle: "クリアした量 / そのときの目標",
                values: [
                    framesText(s.lastOccupancyResetAvailableFrames, s),
                    framesText(s.lastOccupancyResetTargetOccupancyFrames, s),
                ]
            ),
            DiagnosticsRow(
                title: "書き込み位置の観測",
                subtitle: "再生時刻の停滞 / 不整合\n締切超過 / 無音で埋めた欠落",
                values: [
                    countText(s.presentationStallCount) + " / " + countText(s.presentationDeltaUnexpectedCount),
                    countText(s.writeDeadlineMissedCount) + " / " + countText(s.silenceFilledGapCount),
                ]
            ),
        ])
    }

    // MARK: - 書き出しテキスト

    /// 画面と同じ項目定義から作る平文。行の副題を併記することで、複数の値が並ぶ行でも
    /// どの順序で何が並んでいるかが、この 1 通だけで読み取れる。
    static func text(_ s: AudioRuntimeMetrics.Snapshot, exportedAt: Date) -> String {
        let stamp = timestampFormatter
        var lines: [String] = ["書き出し: \(stamp.string(from: exportedAt))"]
        if let lastResetAt = s.lastResetAt {
            let elapsed = OccupancyPolicy.formattedDuration(seconds: exportedAt.timeIntervalSince(lastResetAt))
            lines.append("リセット: \(stamp.string(from: lastResetAt)) (経過時間: \(elapsed))")
        } else {
            lines.append("リセット: なし")
        }

        for section in sections(s) {
            lines.append("")
            lines.append("[\(section.title)]")
            for row in section.rows {
                let label = row.subtitle.map { "\(row.title) (\(singleLine($0)))" } ?? row.title
                lines.append("\(label): \(row.values.joined(separator: " / "))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 書式

    /// 本文の時刻。置き場に並ぶファイル名と同じ現地時刻で書き、時差の分だけずれて見えないようにする
    /// (どの時間帯の時刻かは併記する差分から読める)。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }()

    /// 読めていないことを表す表示。0 のような値と見分けが付き、欄が抜けたのとも区別できる形にする。
    private static let unobserved = unreadableValue

    /// ピークは振幅そのもの (単位を持たない) のため、バッファ量のミリ秒とは別の丸め桁数を持つ。
    private static let peakFractionDigits = 4
    /// 振幅を dBFS へ換算したときの丸め桁数。
    private static let peakDbFractionDigits = 1

    /// 走行最大振幅。振幅は無次元のため、フルスケールを基準にした dBFS を併記する。振幅 0 は
    /// 対数が定義できないため、数値ではなく下限であることを綴りで示す。
    private static func peakText(_ peak: Float) -> String {
        let amplitude = String(format: "%.\(peakFractionDigits)f", peak)
        guard peak > 0 else { return "\(amplitude) (-inf. dBFS)" }
        let db = 20 * log10(Double(peak))
        return "\(amplitude) (\(String(format: "%.\(peakDbFractionDigits)f", db)) dBFS)"
    }

    /// 読み手が書く値の表示。読み手が居ない間は、直前に読めていた値ではなく読めていないことを出す。
    /// 対象は「今どうなっているか」を表す値に限り、痕跡・累積はそのまま残す。
    private static func readerValue(_ s: AudioRuntimeMetrics.Snapshot, _ text: @autoclosure () -> String) -> String {
        s.readerObserved ? text() : unobserved
    }

    /// 回数。数字だけを並べると、隣に置いたフレーム数との区別が付かない。
    private static func countText(_ count: UInt64) -> String {
        "\(count) 回"
    }

    /// 時間長を併記しないフレーム数 (破棄量など、時間より量そのものを読む値)。
    private static func framesOnlyText(_ frames: UInt64) -> String {
        "\(frames) frames"
    }

    /// フレーム数と、その時間長を併記する。どちらが正しい単位かではなく、両方を保持する関係。
    private static func framesText(_ frames: Int, _ s: AudioRuntimeMetrics.Snapshot) -> String {
        let ms = OccupancyPolicy.formattedMilliseconds(frames: frames, sampleRate: s.appliedSampleRate)
        return "\(frames) frames (\(ms) ms)"
    }

    /// レートは未取得のとき 0 が入るため、数値をそのまま見せず未取得と分かる形にする。
    private static func hertzText(_ sampleRate: Double) -> String {
        guard sampleRate > 0 else { return unobserved }
        return "\(Int(sampleRate.rounded())) Hz"
    }

    private static func volumeRouteText(mode: VolumeControlMode?, downgraded: Bool?, value: String?) -> String {
        guard let mode, let downgraded else { return unreadableValue }
        let carrier: String
        switch mode {
        case .device: carrier = "デバイス"
        case .app: carrier = downgraded ? "アプリ (降格)" : "アプリ"
        }
        return carrier + " " + (value ?? unreadableValue)
    }

    /// 副題は画面で折り返して読ませることがあるが、書き出しでは 1 行に収める。
    private static func singleLine(_ text: String) -> String {
        text.split(separator: "\n").joined(separator: " / ")
    }
}
