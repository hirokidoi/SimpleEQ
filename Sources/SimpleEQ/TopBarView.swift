import AppKit
import SwiftUI

/// 上部バー: ブランド表示・出力チップ・EQ ON/OFF スイッチ・(異常時のみ) 警告チップ。
/// 稼働状態は ON/OFF スイッチに一本化し、別途の状態チップは持たない。
/// 警告チップはこの「稼働状態表示」とは別種のもので、専用ドライバ未検出・音声取得失敗など
/// 異常時にのみ現れる。
struct TopBarView: View {
    @ObservedObject var viewModel: EQViewModel
    /// 警告チップからは Settings だけを開く (原因を取り除く出口がそこにあるため)。
    var onOpenWindow: (WindowDestination) -> Void

    @State private var showingPreampPopover = false
    @State private var hostWindow: NSWindow?
    @State private var dragAnchor = WindowDragAnchor()

    private static let horizontalPadding: CGFloat = 20
    private static let brandGap: CGFloat = 9
    private static let brandMarkHitInset: CGFloat = 6

    var body: some View {
        HStack(spacing: 12) {
            brand
            Spacer()
            warningChip
            outputDevicePicker
            powerSwitch.modifier(BottomAlignedInBar())
        }
        .padding(.leading, Self.horizontalPadding - Self.brandMarkHitInset)
        .padding(.trailing, Self.horizontalPadding)
        .frame(height: EQLayout.topBarHeight)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: EQLayout.windowCornerRadius, topTrailingRadius: EQLayout.windowCornerRadius
            )
            .fill(EQLayout.Palette.panel)
            .modifier(chrome)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(EQLayout.Palette.line).frame(height: 1)
        }
        .contextMenu {
            ForEach(WindowContextMenu.items(viewModel: viewModel, hideWindow: { hostWindow?.close() })) { item in
                Group {
                    switch item.kind {
                    case .action(let perform): Button(item.title, action: perform)
                    case .toggle(let isOn): Toggle(item.title, isOn: isOn)
                    }
                }
                .modifier(CommandShortcut(key: item.commandKey))
            }
        }
        .background(WindowAccessor(window: $hostWindow).frame(width: 0, height: 0))
    }

    private var chrome: TopBarChrome {
        TopBarChrome(viewModel: viewModel, window: hostWindow, anchor: dragAnchor)
    }

    private var brand: some View {
        HStack(spacing: Self.brandGap - Self.brandMarkHitInset) {
            brandMarkButton
            brandText.modifier(chrome)
        }
    }

    private var brandMarkButton: some View {
        Button {
            hostWindow?.close()
        } label: {
            brandMark.padding(Self.brandMarkHitInset).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var brandText: some View {
        HStack(spacing: 9) {
            Text("SimpleEQ")
                .font(.system(size: 16, weight: .bold))
                .tracking(0.4)
                .foregroundColor(EQLayout.Palette.text)
            Text("20-band graphic equalizer")
                .font(.system(size: 11))
                .foregroundColor(EQLayout.Palette.faint)
        }
    }

    /// アプリアイコン・メニューバーアイコンと同じバーモチーフの縮小版。
    private var brandMark: some View {
        let heights = EQLayout.IconMotif.barHeightRatios
        let barWidth: CGFloat = 2.4
        let height: CGFloat = 16
        return HStack(alignment: .bottom, spacing: barWidth * EQLayout.IconMotif.barGapRatio) {
            ForEach(heights.indices, id: \.self) { i in
                let color = EQLayout.segmentColor(atRatio: Double(i) / Double(heights.count - 1)).opacity(1)
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: height * heights[i])
                    .shadow(color: color.opacity(0.85), radius: 2.5)
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    /// ドライバ未検出 / ドライバ更新要 / 出力先の選び直し要 / 再起動要 / 音声取得失敗を知らせる警告
    /// チップ。優先順位・文言・誘導先はすべてビューモデル側が決める。正常時は何も表示しない。
    @ViewBuilder
    private var warningChip: some View {
        if let warning = viewModel.topBarWarning {
            if warning.destination == .settings {
                chip(text: warning.message)
                    .contentShape(Capsule())
                    .onTapGesture { onOpenWindow(.settings) }
            } else {
                chip(text: warning.message).modifier(chrome)
            }
        }
    }

    private func chip(text: String) -> some View {
        HStack(spacing: 6) {
            Text("⚠").font(.system(size: 11))
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(EQLayout.Palette.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(EQLayout.Palette.danger.opacity(0.12)))
        .overlay(Capsule().stroke(EQLayout.Palette.danger.opacity(0.5), lineWidth: 1))
    }

    /// 出力先チップ。実際に採用されている出力デバイス名を表示しつつ、その場から選び直せる。
    /// 選択はセッション限定 (非永続) で、選び直しは即座に実デバイスへ反映される。
    private var outputDevicePicker: some View {
        HStack(spacing: 6) {
            preampIconButton
            sharedOutputDevicePicker(
                selection: $viewModel.sessionOutputDeviceUID,
                options: viewModel.availableOutputDeviceOptions,
                autoLabel: nil,
                fallbackLabel: viewModel.resolvedOutputDeviceName
            )
            .disabled(!viewModel.canSelectOutputDevice)
        }
        .font(.system(size: 12))
        .foregroundColor(EQLayout.Palette.dim)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.02))
                .modifier(chrome)
        )
        .overlay(Capsule().stroke(EQLayout.Palette.line, lineWidth: 1))
    }

    /// プリアンプ調整ポップオーバーを開くアイコン。
    private var preampIconButton: some View {
        Button {
            showingPreampPopover = true
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(EQLayout.Palette.dim)
        .popover(isPresented: $showingPreampPopover, arrowEdge: .bottom) {
            PreampPopoverView(viewModel: viewModel)
        }
    }

    private var powerSwitch: some View {
        Button {
            viewModel.bypass.toggle()
        } label: {
            HStack(spacing: 10) {
                ToggleTrack(isOn: !viewModel.bypass)
                // 固定幅ラベル: ON/OFF 切替時にラベル文字数差でレイアウトが揺れないようにする。
                Text(viewModel.bypass ? "EQ OFF" : "EQ ON")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(viewModel.bypass ? EQLayout.Palette.dim : EQLayout.Palette.cyan)
                    .frame(minWidth: EQLayout.powerLabelMinWidth, alignment: .leading)
            }
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(viewModel.bypass ? Color.white.opacity(0.02) : EQLayout.Palette.cyan.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(viewModel.bypass ? EQLayout.Palette.line : EQLayout.Palette.cyan.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // 音に効きようが無い間は受け付けない。ラベルとつまみは設定値のまま残し、灰色と減光だけで
        // 「今は効いていない」を表す。
        .unavailableAppearance(!viewModel.canToggleBypass)
    }
}

private struct TopBarChrome: ViewModifier {
    let viewModel: EQViewModel
    let window: NSWindow?
    let anchor: WindowDragAnchor

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { viewModel.viewMode = viewModel.viewMode.toggled }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        guard let window else { return }
                        let mouse = NSEvent.mouseLocation
                        let start = anchor.begin(mouse: mouse, origin: window.frame.origin)
                        window.setFrameOrigin(NSPoint(
                            x: start.origin.x + (mouse.x - start.mouse.x),
                            y: start.origin.y + (mouse.y - start.mouse.y)
                        ))
                    }
                    .onEnded { _ in anchor.clear() }
            )
            .onDisappear { anchor.clear() }
    }
}

private struct CommandShortcut: ViewModifier {
    let key: Character?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

private struct BottomAlignedInBar: ViewModifier {
    private let bottomInset: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomInset)
    }
}

extension View {
    /// 「今は効かない」ことを表す見た目 (彩度を落として減光し、操作を受け付けない)。効く側では
    /// 修飾を一切付けない (恒等の値でも修飾を付けると合成の経路が変わるため)。
    @ViewBuilder
    func unavailableAppearance(_ unavailable: Bool) -> some View {
        if unavailable {
            grayscale(1).opacity(EQLayout.disabledOpacity).allowsHitTesting(false)
        } else {
            self
        }
    }
}

/// プリアンプ調整ポップオーバーの中身。EQ OFF (バイパス) 中はプリアンプが効かないため、中身全体を
/// グレーアウトし、スライダーとリセットのみ操作不能にする (見出し・現在値は残す)。
private struct PreampPopoverView: View {
    @ObservedObject var viewModel: EQViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PREAMP")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(EQLayout.Palette.cyanSoft)
                Spacer()
                Text(EQLayout.formatSignedDb(viewModel.preampDb))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(EQLayout.Palette.cyanSoft)
            }
            HStack(spacing: 10) {
                // ネイティブ Slider は開き直すたびにハンドルが黒く描画される AppKit 側の癖があり
                // (実機で複数回確認)、自前描画に置き換えて回避する。
                DraggableDbSlider(
                    value: steppedBinding($viewModel.preampDb, range: EQSpec.DB_MIN...EQSpec.DB_MAX, step: 1),
                    range: EQSpec.DB_MIN...EQSpec.DB_MAX
                )
                ResetDotButton { viewModel.preampDb = 0 }
            }
            // 自前の DragGesture を使うスライダーのため、明示的に
            // allowsHitTesting でヒットテストを止める必要がある。
            .allowsHitTesting(viewModel.processingInEffect)
        }
        .padding(16)
        .frame(width: 232)
        .grayscale(viewModel.processingInEffect ? 0 : 1)
        .opacity(viewModel.processingInEffect ? 1 : EQLayout.disabledOpacity)
        // .popover は既定でシステムのマテリアル背景 (ライトモード相当) を使うため、明示的に
        // 不透明な背景を敷かないと本文の明色テキストが読めなくなる。
        .background(EQLayout.Palette.panel)
        .preferredColorScheme(.dark)
    }
}

/// AppKit の Slider (NSSlider) を使わない、SwiftUI のみで描画するスライダー。
/// 刻みスナップ・範囲クランプは呼び出し側が渡す value を共有コントロールの刻みスナップ経由でラップ
/// する前提で、ここでは行わない。
private struct DraggableDbSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var ratio: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = width * ratio
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 4)
                Capsule()
                    .fill(EQLayout.Palette.cyan)
                    .frame(width: max(0, thumbX), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: EQLayout.Palette.cyan.opacity(0.6), radius: 4)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .offset(x: thumbX - 7)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in update(atX: drag.location.x, width: width) }
            )
        }
        .frame(height: 14)
    }

    private func update(atX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let newRatio = min(max(0, x / width), 1)
        // 刻みスナップ・範囲クランプは value (共有コントロールの刻みスナップでラップされた Binding) の setter が行う。
        value = range.lowerBound + Double(newRatio) * (range.upperBound - range.lowerBound)
    }
}
