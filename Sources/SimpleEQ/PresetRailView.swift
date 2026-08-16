import AppKit
import SwiftUI

enum PresetHoverPreview {
    static func showsHandles(hoveringGroup: Bool, previewing: Bool) -> Bool {
        hoveringGroup && previewing
    }
}

/// プリセットレール: プリセットボタンと Settings ボタン。
/// EQ が音に効いていない間はプリセットボタン群を減光して操作不能にする (Settings ボタンは
/// 減光も無効化もしない)。プリセットボタンは長押しで保存ダイアログを開く。
struct PresetRailView: View {
    @ObservedObject var viewModel: EQViewModel
    var onOpenWindow: (WindowDestination) -> Void

    // 長押し保存ダイアログの対象プリセット (nil = 非表示)。
    @State private var editingPreset: EQPreset?
    @State private var editingTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(spacing: 11) {
                ForEach(EQPreset.allCases, id: \.self) { preset in
                    presetButton(preset)
                }
            }
            .allowsHitTesting(viewModel.processingInEffect)
            // 減光はプリセット群だけにかける。レール全体へかけると、EQ に依存しない Settings ボタンまで
            // 効かないように見える。
            .opacity(viewModel.processingInEffect ? 1 : EQLayout.disabledOpacity)
            // ボタン群 (ボタン間の隙間含む) の hover でハンドル表示を継続し、ボタン間移動での点滅を防ぐ。
            // 群から完全に離れたらプレビューを解除して現在値へ戻す。
            .onHover { hovering in
                viewModel.hoveringPresetGroup = hovering
                if !hovering { viewModel.previewPreset = nil }
            }

            Spacer(minLength: 0)
            settingsButton
        }
        .padding(16)
        .frame(width: EQLayout.railWidth)
        .frame(maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(bottomTrailingRadius: EQLayout.windowCornerRadius)
                .fill(EQLayout.Palette.panel)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(EQLayout.Palette.line).frame(width: 1)
        }
        .alert(
            "プリセットを保存",
            isPresented: Binding(
                get: { editingPreset != nil },
                set: { if !$0 { closePresetDialog() } }
            ),
            presenting: editingPreset
        ) { preset in
            TextField("タイトル", text: editingTitleBinding)
                .foregroundColor(.primary)
            Button("保存") {
                viewModel.savePreset(preset, title: editingTitle)
                closePresetDialog()
            }
            .disabled(editingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("削除", role: .destructive) {
                viewModel.deletePreset(preset)
                closePresetDialog()
            }
            Button("キャンセル", role: .cancel) {
                closePresetDialog()
            }
        }
    }

    /// editingTitle への入力を上限に収まるよう制限する。
    private var editingTitleBinding: Binding<String> {
        Binding(
            get: { editingTitle },
            set: { editingTitle = EQLayout.clampToPresetTitleMaxWidth($0) }
        )
    }

    private func closePresetDialog() {
        editingPreset = nil
        viewModel.savingPreset = false
    }

    private func presetButton(_ preset: EQPreset) -> some View {
        // EQ OFF 時は選択中でもハイライトを解除して非アクティブ表示にする。
        // 全体の減光は上位の .opacity 修飾が担う。
        let isActive = viewModel.selectedPreset == preset && viewModel.processingInEffect
        return Button {
            // 長押し保存ダイアログを開いた直後の mouseUp でも Button の action は発火しうるため、
            // ダイアログ表示中 (このボタンが編集対象) はプリセット適用をスキップする。
            guard editingPreset == nil else { return }
            // タイトルが空 (削除済み) のスロットはクリックしても no-op。
            guard !viewModel.title(for: preset).isEmpty else { return }
            viewModel.applyPreset(preset)
        } label: {
            Text(viewModel.title(for: preset))
                .font(.system(size: 13.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(isActive ? EQLayout.Palette.cyanSoft : EQLayout.Palette.text)
                .frame(maxWidth: .infinity, minHeight: EQLayout.presetButtonMinHeight)
                // ラベルの余白部分もクリック対象にし、ボタン全域を押せるようにする (文字だけに限定しない)。
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? AnyShapeStyle(EQLayout.Palette.activeButtonGradient) : AnyShapeStyle(Color.white.opacity(0.02)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? EQLayout.Palette.cyan.opacity(0.6) : EQLayout.Palette.buttonLine, lineWidth: 1)
        )
        .onHover { hovering in
            guard !viewModel.title(for: preset).isEmpty else {
                if hovering { viewModel.previewPreset = nil }
                return
            }
            // hover 中はこのプリセットをプレビュー対象にする (群からの離脱時解除は上位の VStack が担う)。
            if hovering { viewModel.previewPreset = preset }
            // クリック可能を示す指差しカーソル。onHover の enter/exit は対で発火するため push/pop で釣り合う。
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: EQLayout.presetSaveLongPressDuration)
                .onEnded { _ in
                    // 保存対象を確定させる瞬間、プレビューをそのプリセットの保存済みカーブから
                    // 今ライブで鳴っているカーブ (= これから保存される値) へアニメーションで戻す。
                    viewModel.previewPreset = nil
                    // ダイアログ表示中はホバー状態が false になりうるため、保存中状態を別に立てて
                    // ハンドル表示条件を独立して保つ。
                    viewModel.savingPreset = true
                    editingTitle = viewModel.title(for: preset)
                    editingPreset = preset
                }
        )
    }

    private var settingsButton: some View {
        Button {
            // option を押しながらの操作では Diagnostics を開く (メニューバーの隠し項目と同じ条件)。
            onOpenWindow(DiagnosticsEntry.isRevealed ? .diagnostics : .settings)
        } label: {
            HStack(spacing: 8) {
                Text("⚙")
                Text("Settings")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(EQLayout.Palette.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            // ラベルの余白部分もクリック対象にし、ボタン全域を押せるようにする (文字だけに限定しない)。
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(EQLayout.Palette.line, lineWidth: 1))
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
