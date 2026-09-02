import AppKit
import SwiftUI

/// アプリ別ミキサー。Settings と同じ流儀の独立ウィンドウとして開く。
struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var viewModel: EQViewModel
    let clock: MixerRenderClock?

    @State private var dragKey: String?
    @State private var dragBaseline: CGFloat = 0

    /// 設定が音へ届く経路があるか。EQ のバイパスとは連動しない (アプリ別ゲインは EQ の前段)。
    private var reachesAudio: Bool { viewModel.settingsReachAudio }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let warning = viewModel.topBarWarning { notice(warning.message) }
            channelList
            if model.editing { candidatePool }
            footer
        }
        // 高さの ideal は与えない (スクロールビューの測りに影響するため)。
        .frame(
            minWidth: EQLayout.Mixer.windowWidth,
            idealWidth: EQLayout.Mixer.windowWidth,
            maxWidth: EQLayout.Mixer.windowWidth,
            minHeight: EQLayout.Mixer.windowMinHeight
        )
        .background(EQLayout.textPanelBackground)
        .foregroundColor(EQLayout.Palette.text)
        .colorScheme(.dark)
        .onAppear { model.panelDidAppear() }
    }

    // MARK: - ヘッダ / 通知 / フッタ

    private var header: some View {
        HStack {
            Text("Mixer").font(.system(size: 15, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(EQLayout.Palette.panel)
        .overlay(alignment: .bottom) { separator }
    }

    private func notice(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(EQLayout.Palette.danger)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(EQLayout.Palette.danger.opacity(0.08))
        .overlay(alignment: .bottom) { separator }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("SimpleEQ \(AppVersion.text)")
                .font(.system(size: 12.5))
                .foregroundColor(EQLayout.Palette.faint)
            Spacer()
            editButton
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { separator }
    }

    private var editButton: some View {
        Button {
            model.editing.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(model.editing ? "完了" : "追加・編集")
                if !model.editing, !model.candidates.isEmpty {
                    Text("\(model.candidates.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(EQLayout.Palette.panel)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(EQLayout.Palette.cyan))
                }
            }
            .font(.system(size: 12))
            .foregroundColor(model.editing ? EQLayout.Palette.cyan : EQLayout.Palette.dim)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(
                    model.editing ? EQLayout.Palette.cyan.opacity(0.45) : EQLayout.Palette.buttonLine, lineWidth: 1
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        Rectangle().fill(EQLayout.Palette.line).frame(height: EQLayout.Mixer.separatorThickness)
    }

    // MARK: - チャンネル

    private var channelList: some View {
        ScrollView {
            if model.channels.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(model.channels) { channel in
                        row(channel)
                        separator
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("チャンネルがありません")
                .font(.system(size: 13.5, weight: .semibold))
                .padding(.bottom, 2)
            Text("音声再生中のアプリを「追加・編集」から追加できます。")
        }
        .font(.system(size: 11.5))
        .foregroundColor(EQLayout.Palette.dim)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func row(_ channel: MixerModel.Channel) -> some View {
        HStack(spacing: EQLayout.Mixer.rowSpacing) {
            if model.editing {
                Text("⣿")
                    .font(.system(size: 11))
                    .foregroundColor(EQLayout.Palette.faint)
                    .frame(width: EQLayout.Mixer.gripWidth)
            }
            icon(channel.identity)
            nameLabel(channel.identity, width: model.editing ? nil : EQLayout.Mixer.nameColumnWidth)
            if model.editing {
                Spacer(minLength: 0)
                removeButton(channel)
            } else {
                muteButton(channel)
                MixerRowControls(model: model, channel: channel, enabled: reachesAudio, clock: clock)
                    .frame(height: EQLayout.Mixer.controlsHeight)
                ResetDotButton { model.resetToDefault(key: channel.key) }
                    .opacity(channel.isDefault ? 0 : 1)
                    .disabled(channel.isDefault)
            }
        }
        .padding(.horizontal, EQLayout.Mixer.rowHorizontalPadding)
        .frame(height: EQLayout.Mixer.rowHeight)
        .contentShape(Rectangle())
        .opacity(reachesAudio ? 1 : EQLayout.disabledOpacity)
        .disabled(!reachesAudio)
        .opacity(dragKey == channel.key ? 0.35 : 1)
        .gesture(reorderGesture(channel), including: model.editing ? .all : .subviews)
    }

    private func reorderGesture(_ channel: MixerModel.Channel) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragKey != channel.key {
                    dragKey = channel.key
                    dragBaseline = 0
                }
                advanceReorder(of: channel.key, translation: value.translation.height)
            }
            .onEnded { _ in
                dragKey = nil
                dragBaseline = 0
            }
    }

    private func advanceReorder(of key: String, translation: CGFloat) {
        guard let index = model.channels.firstIndex(where: { $0.key == key }) else { return }
        let steps = Int(((translation - dragBaseline) / EQLayout.Mixer.rowPitch).rounded(.towardZero))
        guard steps != 0 else { return }
        let target = min(max(0, index + steps), model.channels.count - 1)
        guard target != index else { return }
        model.move(fromKey: key, toKey: model.channels[target].key)
        dragBaseline += CGFloat(target - index) * EQLayout.Mixer.rowPitch
    }

    private func muteButton(_ channel: MixerModel.Channel) -> some View {
        Button { model.toggleMute(key: channel.key) } label: {
            Image(systemName: channel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundColor(channel.muted ? EQLayout.Palette.faint : EQLayout.Palette.text)
                .frame(width: EQLayout.Mixer.muteButtonSize.width, height: EQLayout.Mixer.muteButtonSize.height)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(channel.muted ? 0.02 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(EQLayout.Palette.buttonLine, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(channel.muted ? "ミュート解除" : "ミュート")
    }

    private func removeButton(_ channel: MixerModel.Channel) -> some View {
        Button { model.remove(key: channel.key) } label: {
            Text("×")
                .font(.system(size: 14))
                .foregroundColor(EQLayout.Palette.dim)
                .frame(width: EQLayout.Mixer.removeButtonSize, height: EQLayout.Mixer.removeButtonSize)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().stroke(EQLayout.Palette.buttonLine, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("チャンネルを外す")
    }

    // MARK: - 候補プール

    private var candidatePool: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("追加できるアプリ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(EQLayout.Palette.dim)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 7)

            if model.candidates.isEmpty {
                Text("音声再生中のアプリはありません。")
                    .font(.system(size: 11))
                    .foregroundColor(EQLayout.Palette.faint)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.candidates) { candidate in
                            candidateRow(candidate)
                            separator
                        }
                    }
                }
                // 枠が取る高さのぶんだけ行の領域が縮む。件数から決めないとスクロール面が
                // 上限まで貪欲に広がる。
                .frame(height: min(
                    EQLayout.Mixer.candidatePoolMaxHeight,
                    CGFloat(model.candidates.count) * EQLayout.Mixer.candidateRowPitch
                ))
            }
        }
        .background(EQLayout.Palette.panel)
        .overlay(alignment: .top) { separator }
    }

    private func candidateRow(_ candidate: MixerModel.Candidate) -> some View {
        HStack(spacing: EQLayout.Mixer.rowSpacing) {
            icon(candidate.identity)
            nameLabel(candidate.identity, width: nil)
            Spacer(minLength: 0)
            if candidate.playing {
                Text("● 再生中").font(.system(size: 10)).foregroundColor(EQLayout.Palette.cyan)
            }
            Button { model.add(key: candidate.key) } label: {
                Text("追加")
                    .font(.system(size: 11))
                    .foregroundColor(EQLayout.Palette.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(EQLayout.Palette.cyan.opacity(0.3), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddChannel)
            .opacity(model.canAddChannel ? 1 : EQLayout.disabledOpacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, EQLayout.Mixer.candidateVerticalPadding)
    }

    // MARK: - 行の共通部品

    @ViewBuilder
    private func icon(_ identity: MixerAppIdentity?) -> some View {
        if let image = model.icon(for: identity) {
            Image(nsImage: image)
                .resizable()
                .frame(width: EQLayout.Mixer.iconSize, height: EQLayout.Mixer.iconSize)
        } else {
            Text("?")
                .font(.system(size: 11))
                .foregroundColor(EQLayout.Palette.faint)
                .frame(width: EQLayout.Mixer.iconSize, height: EQLayout.Mixer.iconSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(
                        EQLayout.Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
                )
        }
    }

    private func nameLabel(_ identity: MixerAppIdentity?, width: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(identity?.displayName ?? "")
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle = identity?.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(EQLayout.Palette.faint)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}
