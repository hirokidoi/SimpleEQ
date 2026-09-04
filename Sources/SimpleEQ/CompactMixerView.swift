import AppKit
import SwiftUI

/// コンパクトビューのミキサー。編集モードを持たず、行はアイコン・名前・ミュート・スライダーの 4 つ。
struct CompactMixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var viewModel: EQViewModel

    @State private var hostWindow: NSWindow?

    /// 設定が音へ届く経路があるか。EQ のバイパスとは連動しない (アプリ別ゲインは EQ の前段)。
    private var reachesAudio: Bool { viewModel.settingsReachAudio }

    private var inset: CGFloat { EQLayout.Mixer.compactColumnInset }

    var body: some View {
        VStack(spacing: 0) {
            dragStrip.frame(height: inset)
            HStack(spacing: 0) {
                dragStrip.frame(width: inset)
                column
                dragStrip.frame(width: inset)
            }
            dragStrip.frame(height: inset)
        }
        .background(RoundedRectangle(cornerRadius: EQLayout.windowCornerRadius).fill(EQLayout.textPanelBackground))
        .foregroundColor(EQLayout.Palette.text)
        .colorScheme(.dark)
        .background(WindowAccessor(window: $hostWindow).frame(width: 0, height: 0))
    }

    /// 行が窓を埋めると掴める場所が行の左帯しか残らないため、四辺の余白も移動を受ける。
    private var dragStrip: some View {
        WindowDragArea(viewModel: viewModel, mixer: model) { viewModel.viewMode = .normal }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var column: some View {
        if model.channels.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.channels) { channel in
                        row(channel)
                        separator
                    }
                }
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(EQLayout.Palette.line).frame(height: EQLayout.Mixer.separatorThickness)
    }

    private var emptyState: some View {
        ZStack {
            dragStrip
            MixerEmptyState()
        }
    }

    private func row(_ channel: MixerModel.Channel) -> some View {
        HStack(spacing: EQLayout.Mixer.rowSpacing) {
            identityBand(channel)
            MixerMuteButton(model: model, channel: channel)
            MixerRowControls(
                model: model, channel: channel, enabled: reachesAudio, showsLevel: false, clock: nil
            )
            .frame(height: EQLayout.Mixer.controlsHeight)
        }
        .padding(.trailing, EQLayout.Mixer.compactRowTrailingPadding)
        .frame(height: EQLayout.Mixer.rowHeight)
        .contentShape(Rectangle())
        .opacity(reachesAudio ? 1 : EQLayout.disabledOpacity)
        .disabled(!reachesAudio)
        .contextMenu { windowMenuItems }
    }

    /// 移動とビュー切り替えを受ける帯。右クリックは行に付けた側へ通す。
    private func identityBand(_ channel: MixerModel.Channel) -> some View {
        HStack(spacing: EQLayout.Mixer.rowSpacing) {
            MixerRowIcon(model: model, identity: channel.identity)
            MixerRowName(identity: channel.identity, width: EQLayout.Mixer.nameColumnWidth)
        }
        .padding(.leading, EQLayout.Mixer.rowHorizontalPadding)
        .frame(height: EQLayout.Mixer.rowHeight)
        .overlay {
            WindowDragArea(viewModel: viewModel, mixer: model, showsContextMenu: false) {
                viewModel.viewMode = .normal
            }
        }
    }

    private var windowMenuItems: some View {
        WindowContextMenuItems(viewModel: viewModel, mixer: model, hideWindow: { hostWindow?.close() })
    }
}
