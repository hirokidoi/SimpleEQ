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
    @ObservedObject var mixer: MixerModel
    var onOpenWindow: (WindowDestination) -> Void

    // 長押し保存ダイアログの対象プリセット (nil = 非表示)。
    @State private var editingPreset: EQPreset?
    @State private var editingTitle: String = ""
    /// 長押しが成立した回の押下を 1 回だけ捨てるための印。
    @State private var swallowMixerClick = false

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
                viewModel.hoveringPresetGroup = hovering && !mixer.shown
                if !hovering { viewModel.previewPreset = nil }
            }

            Spacer(minLength: 0)
            // 既定のウィンドウ高ではプリセットの最低高が効いて縦 2 段が入らないため横並びにする。
            HStack(spacing: 8) {
                mixerButton
                railButton("gearshape", help: "Settings", width: EQLayout.railCompactButtonWidth) {
                    // option を押しながらの操作では Diagnostics を開く (メニューバーの隠し項目と同じ条件)。
                    onOpenWindow(DiagnosticsEntry.isRevealed ? .diagnostics : .settings)
                }
            }
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
            // 面が覆っている間はハンドルが見えないため、プレビューは求めない。
            if hovering, !mixer.shown { viewModel.previewPreset = preset }
        }
        .pointerStyle(.link)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: EQLayout.longPressDuration)
                .onEnded { _ in
                    // 保存するのは今のゲインカーブであり、それが見えない状態では保存させない。
                    guard !mixer.shown else { return }
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

    /// 面が出ていない / 出ている / 編集モードの 3 状態。色は 1 箇所で決める。
    private var mixerButtonColors: (foreground: Color, background: AnyShapeStyle, border: Color) {
        if mixer.editing {
            return (.white, AnyShapeStyle(EQLayout.Palette.editingButtonGradient), .white.opacity(0.7))
        }
        if mixer.shown {
            return (
                EQLayout.Palette.cyanSoft,
                AnyShapeStyle(EQLayout.Palette.activeButtonGradient),
                EQLayout.Palette.cyan.opacity(0.6)
            )
        }
        return (
            EQLayout.Palette.dim, AnyShapeStyle(Color.white.opacity(0.02)), EQLayout.Palette.buttonLine
        )
    }

    /// 面の出し入れと編集モードを同じボタンに載せる。長押しは、面が出ていなければ出すだけ。
    private var mixerButton: some View {
        let colors = mixerButtonColors
        return Button {
            if swallowMixerClick {
                swallowMixerClick = false
                return
            }
            if mixer.editing { mixer.endEditing() } else { mixer.toggleShown() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Mixer")
            }
            .foregroundColor(colors.foreground)
            .frame(maxWidth: .infinity)
            .modifier(RailButtonChrome(background: colors.background, border: colors.border))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: EQLayout.longPressDuration)
                .onEnded { _ in
                    swallowMixerClick = true
                    if mixer.editing {
                        mixer.endEditing()
                    } else if mixer.shown {
                        mixer.beginEditing()
                    } else {
                        mixer.setShown(true)
                    }
                }
        )
        .onHover { hovering in
            // 押下が届かないまま離れた回に印が残ると、次の押下を食う。
            if !hovering { swallowMixerClick = false }
        }
    }

    /// 記号だけで幅を詰めるため、行き先はツールチップで補う。
    private func railButton(
        _ symbolName: String, help: String, width: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .foregroundColor(EQLayout.Palette.dim)
                .frame(width: width)
                .modifier(RailButtonChrome(
                    background: AnyShapeStyle(Color.white.opacity(0.02)),
                    border: EQLayout.Palette.buttonLine
                ))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// レール下端のボタンの体裁。文字の大きさ・余白・枠を 1 箇所に集める。
private struct RailButtonChrome: ViewModifier {
    let background: AnyShapeStyle
    let border: Color

    private static let cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        return content
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 11)
            // 記号や文字の周りの余白もクリック対象にし、ボタン全域を押せるようにする。
            .contentShape(shape)
            .background(shape.fill(background))
            .overlay(shape.stroke(border, lineWidth: 1))
            .pointerStyle(.link)
    }
}
