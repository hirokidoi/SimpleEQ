import SwiftUI

/// Optional<String> (選択中の UID) を Picker の selection/tag に使う際の SwiftUI の癖を吸収する共有ヘルパー。
/// - autoLabel: 非nil なら「自動選択」疑似項目を候補の先頭に加える。nil ならこの疑似項目自体を出さない。
/// - fallbackLabel: 選択中の uid が options に含まれない場合の防御的な表示ラベル。
private let outputDeviceAutoTag = "__simpleeq_auto__"
private let outputDeviceUnresolvedTag = "__simpleeq_unresolved__"

/// 共有ピッカーに実際に表示する候補一覧を算出する (CoreAudio に触れない純粋関数、ユニットテスト対象)。
/// selection が options に含まれない場合、表示専用の fallback 行を候補の先頭に加える。
func resolvedOutputDevicePickerOptions(
    selection: String?, options: [OutputDeviceOption], fallbackLabel: String
) -> [OutputDeviceOption] {
    guard let selection, !options.contains(where: { $0.uid == selection }) else { return options }
    return [OutputDeviceOption(uid: selection, name: fallbackLabel)] + options
}

func sharedOutputDevicePicker(
    selection: Binding<String?>, options: [OutputDeviceOption], autoLabel: String?, fallbackLabel: String
) -> some View {
    let allOptions = resolvedOutputDevicePickerOptions(selection: selection.wrappedValue, options: options, fallbackLabel: fallbackLabel)
    // 実デバイスが1つも解決できておらず、自動選択の疑似項目も出さない場合、
    // 未解決センチネルの 1行を表示専用で加える (選び直す対象ではないため allOptions には含めない)。
    let showsUnresolvedRow = selection.wrappedValue == nil && autoLabel == nil
    let mapped = Binding<String>(
        get: {
            guard let current = selection.wrappedValue else {
                return autoLabel != nil ? outputDeviceAutoTag : outputDeviceUnresolvedTag
            }
            return current
        },
        set: { newValue in
            guard newValue != outputDeviceUnresolvedTag else { return }
            selection.wrappedValue = newValue == outputDeviceAutoTag ? nil : newValue
        }
    )
    return Picker("", selection: mapped) {
        if let autoLabel {
            Text(autoLabel).tag(outputDeviceAutoTag)
        }
        if showsUnresolvedRow {
            Text(fallbackLabel).tag(outputDeviceUnresolvedTag)
        }
        ForEach(allOptions, id: \.uid) { option in Text(option.name).tag(option.uid) }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    // 無効化は「選択可能な候補が1つも無いか」のみで決める。
    // 自動選択の疑似項目を出す呼び出し元はその疑似項目自体が常に選択可能な候補のため、実候補の有無に関わらず常に有効。
    .disabled(autoLabel == nil && allOptions.isEmpty)
    // Picker はネイティブ (AppKit 由来) コントロールで .foregroundColor を無視しシステムのカラースキームに従うため、
    // 常時ダーク固定のこのアプリでは明示的に指定する。
    .colorScheme(.dark)
    .frame(maxWidth: .infinity, alignment: .leading)
}

/// 破壊的 (取り消せない) 操作の実行前確認アラートを共通化するヘルパー。
extension View {
    func destructiveConfirmationAlert(
        _ titleKey: String, isPresented: Binding<Bool>, confirmTitle: String, onConfirm: @escaping () -> Void
    ) -> some View {
        alert(titleKey, isPresented: isPresented) {
            Button(confirmTitle, role: .destructive, action: onConfirm)
            Button("キャンセル", role: .cancel) {}
        }
    }

    /// 破壊的でない操作を尋ねるアラート。説明文を添えられる。
    func confirmationAlert(
        _ titleKey: String, message: String, isPresented: Binding<Bool>,
        confirmTitle: String, onConfirm: @escaping () -> Void
    ) -> some View {
        alert(titleKey, isPresented: isPresented) {
            Button(confirmTitle, action: onConfirm)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

/// トップバーの電源スイッチと Settings のトグルが共有する見た目 (カプセル+ノブ)。
/// タップ操作は持たず isOn に応じた静的な見た目のみを描く (タップ処理・Binding の扱いは呼び出し側の責務)。
struct ToggleTrack: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? EQLayout.Palette.cyan.opacity(0.55) : EQLayout.Palette.powerOffTrack)
                .frame(width: EQLayout.powerTrackSize.width, height: EQLayout.powerTrackSize.height)
            Circle()
                .fill(Color.white)
                .frame(width: EQLayout.powerKnobDiameter, height: EQLayout.powerKnobDiameter)
                .padding(2)
                .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
        }
    }
}

/// Binding<Bool> をタップでトグルする汎用スイッチ。
struct SettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ToggleTrack(isOn: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// Slider(value:in:step:) は macOS でティックマークを自動描画してしまうため、
/// 値のスナップを Binding 側で行うことでティックを出さずに刻み挙動だけ保つ。
func steppedBinding(_ value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> Binding<Double> {
    Binding<Double>(
        get: { value.wrappedValue },
        set: { newValue in
            let snapped = (newValue / step).rounded() * step
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, snapped))
        }
    )
}

enum PreampControl {
    static let range = EQSpec.DB_MIN...EQSpec.DB_MAX
    static let step: Double = 1
}

@MainActor
func preampSliderBinding(_ viewModel: EQViewModel) -> Binding<Double> {
    steppedBinding(
        Binding(get: { viewModel.preampDb }, set: { viewModel.overridePreamp(db: $0) }),
        range: PreampControl.range, step: PreampControl.step
    )
}

@MainActor
func preampAutoTargetBinding(_ viewModel: EQViewModel) -> Binding<Double> {
    Binding(get: { viewModel.preampAutoTargetDb }, set: { viewModel.setPreampAutoTargetDb($0) })
}

@MainActor
func preampAutoBinding(_ viewModel: EQViewModel) -> Binding<Bool> {
    Binding(get: { viewModel.preampAutoEnabled }, set: { viewModel.setPreampAutoEnabled($0) })
}

struct AutoToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text("AUTO")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundColor(isOn ? EQLayout.Palette.panel : EQLayout.Palette.faint)
                .frame(width: 46, height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(isOn ? EQLayout.Palette.cyan : Color.white.opacity(0.05))
        )
    }
}

/// 円形の "↺" リセットボタン。
struct ResetDotButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("↺")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(EQLayout.Palette.faint)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.white.opacity(0.05)))
    }
}

/// 見出し付きのセクション枠。行間の区切り線・グループ余白を統一する。
struct PanelSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(EQLayout.Palette.dim)
            content
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EQLayout.Palette.line).frame(height: 1)
        }
    }
}

/// セクション内の 1 行。左にタイトルと副題、右に値または操作を置き、下端に区切り線を敷く。
struct PanelRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundColor(EQLayout.Palette.faint)
                }
            }
            .frame(width: 220, alignment: .leading)
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.03)).frame(height: 1)
        }
    }
}

/// スクロールする内容の高さ。
private struct ScrollContentHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 内容が見えている範囲の高さ。
private struct ScrollViewportHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 縦スクロールの内容が、見えている範囲をどれだけ超えているかを呼び出し側へ知らせるスクロールビュー
/// (負なら収まっている)。ウィンドウの高さの上限を「スクロールが要らなくなる高さ」に置くために使う。
struct MeasuredScrollView<Content: View>: View {
    let onOverflowChange: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScrollContentHeightPreference.self, value: geometry.size.height)
                    }
                )
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ScrollViewportHeightPreference.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ScrollContentHeightPreference.self) { height in
            contentHeight = height
            reportOverflow()
        }
        .onPreferenceChange(ScrollViewportHeightPreference.self) { height in
            viewportHeight = height
            reportOverflow()
        }
    }

    /// どちらか一方しか測れていない間は報告しない (差が 0 になり、内容が収まっている状態と区別が付かない)。
    private func reportOverflow() {
        guard contentHeight > 0, viewportHeight > 0 else { return }
        onOverflowChange(contentHeight - viewportHeight)
    }
}
