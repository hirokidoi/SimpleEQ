import AppKit
import SwiftUI

/// Diagnostics 画面。EQ ウィンドウ・Settings ウィンドウ・About ウィンドウとは独立したウィンドウとして開く。
/// 面は切り替えず縦に積む。行の並び・ラベル・値の文字列化はこのビューでは決めない。
struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    /// スクロールが要らなくなる高さをウィンドウ側が上限に置けるよう、内容の超過量を知らせる。
    var onScrollOverflowChange: (CGFloat) -> Void

    var body: some View {
        MeasuredScrollView(onOverflowChange: onScrollOverflowChange) {
            VStack(alignment: .leading, spacing: 0) {
                // 同じ見出しや同じ値が並びうるため、見た目の文字列ではなく位置で識別する。
                ForEach(Array(DiagnosticsReport.sections(model.snapshot).enumerated()), id: \.offset) { _, section in
                    PanelSection(section.title) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                diagnosticsRow(title: row.title, subtitle: row.subtitle) {
                                    rowContent(row)
                                }
                            }
                        }
                    }
                }
                operationsSection
            }
            .padding(.horizontal, 24)
        }
        .frame(
            minWidth: EQLayout.diagnosticsWindowWidth,
            idealWidth: EQLayout.diagnosticsWindowWidth,
            maxWidth: EQLayout.diagnosticsWindowWidth,
            minHeight: EQLayout.diagnosticsWindowMinHeight
        )
        .background(EQLayout.textPanelBackground)
        .foregroundColor(EQLayout.Palette.text)
        // ネイティブ由来のコントロールはシステムのカラースキームに従うため、常時ダーク固定のこのアプリに合わせて明示する。
        .colorScheme(.dark)
        // 定期更新の入口。body の中で依頼を投入すると自己駆動ループになるため、body の外に限定する。
        .task(id: model.active) {
            guard model.active else { return }
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    /// 診断表示の定期更新の周期 (秒)。
    private let refreshInterval: TimeInterval = 1

    // MARK: - 行の中身

    @ViewBuilder
    private func rowContent(_ row: DiagnosticsRow) -> some View {
        if let gauge = row.gauge {
            VStack(alignment: .trailing, spacing: 4) {
                OccupancyGaugeView(
                    currentFraction: OccupancyPolicy.occupancyGaugePosition(
                        frames: gauge.currentFrames, maxOccupancyFrames: gauge.maxFrames
                    ),
                    targetFraction: OccupancyPolicy.occupancyGaugePosition(
                        frames: gauge.targetFrames, maxOccupancyFrames: gauge.maxFrames
                    )
                )
                .frame(height: 14)
                values(row.values)
            }
        } else {
            values(row.values)
        }
    }

    /// 同じ行に同じ文字列が並ぶことがあるため (観測前はどちらも 0 になる組など)、位置で識別する。
    private func values(_ values: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in diagnosticsValue(value) }
        }
    }

    private func diagnosticsValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(EQLayout.Palette.cyanSoft)
    }

    /// この面の 1 行。副題を持たない行にもその 1 行ぶんの高さを確保する。
    @ViewBuilder
    private func diagnosticsRow<Control: View>(
        title: String, subtitle: String?, @ViewBuilder control: @escaping () -> Control
    ) -> some View {
        PanelRow(title: title, subtitle: subtitle ?? Self.reservedSubtitleSpace, control: control)
    }

    /// 副題の位置を空けたままにするための埋め。
    /// 空文字だと行の高さに数えられないことがあるため空白 1 文字を置く。
    private static let reservedSubtitleSpace = " "

    // MARK: - 操作

    private var operationsSection: some View {
        PanelSection("操作") {
            VStack(alignment: .leading, spacing: 0) {
                resetRow
                diagnosticsRow(title: "書き出し", subtitle: "現在のスナップショットを保存する") {
                    actionButton("書き出す") { model.export() }
                }
                diagnosticsRow(title: "書き出し先", subtitle: "起動中のみ保たれる") {
                    HStack(spacing: 10) {
                        Text(abbreviatedPath(model.exportDirectory))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(EQLayout.Palette.cyanSoft)
                        actionButton("変更", action: chooseExportDirectory)
                        actionButton("開く", action: openExportDirectory)
                    }
                }
                diagnosticsRow(title: "直近の書き出し", subtitle: nil) {
                    lastExportValue
                }
            }
        }
    }

    /// 経過時間は時間の経過そのもので変わるため、この行だけを時間で再描画される単位として切り出す。
    private var resetRow: some View {
        TimelineView(.periodic(from: Date(), by: refreshInterval)) { context in
            diagnosticsRow(title: "観測量のリセット", subtitle: resetSubtitle(at: context.date)) {
                actionButton("リセット") { model.reset() }
            }
        }
    }

    private func resetSubtitle(at now: Date) -> String? {
        guard let lastResetAt = model.snapshot.lastResetAt else { return nil }
        return "経過時間: " + OccupancyPolicy.formattedDuration(seconds: now.timeIntervalSince(lastResetAt))
    }

    @ViewBuilder
    private var lastExportValue: some View {
        switch model.lastExport {
        case .written(let fileName):
            diagnosticsValue(fileName)
        case .failed(let reason):
            Text("書き出せませんでした\n(\(reason))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(EQLayout.Palette.danger)
                .multilineTextAlignment(.trailing)
        case nil:
            diagnosticsValue("なし")
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(EQLayout.Palette.faint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(EQLayout.Palette.buttonLine, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setExportDirectory(url)
    }

    private func openExportDirectory() {
        model.revealExportDirectory { NSWorkspace.shared.open($0) }
    }

    /// ホーム配下は先頭を波記号へ畳んで、置き場が一目で読める長さに収める。
    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// バッファ量 (available) を空(左)〜上限バッファ量(右)の位置として見せるゲージ。
/// 位置の比率は呼び出し側が導出したものを渡す。
private struct OccupancyGaugeView: View {
    let currentFraction: Double
    let targetFraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 4)
                    .fill(EQLayout.Palette.cyan.opacity(0.55))
                    .frame(width: geometry.size.width * currentFraction)
                Rectangle()
                    .fill(EQLayout.Palette.cyanSoft)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * targetFraction - 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
