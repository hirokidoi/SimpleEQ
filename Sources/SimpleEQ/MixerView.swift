import AppKit
import SwiftUI

/// 掴んでいる行。ドラッグ中の書き換えでビュー更新を起こさないため参照で持つ。
@MainActor
final class MixerReorderAnchor {
    var key: String?
}

/// アプリ別ミキサー。ビジュアライザ領域を覆う面として出る。
struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var viewModel: EQViewModel
    let clock: MixerRenderClock?

    @State private var reorder = MixerReorderAnchor()
    @State private var hoveredEditKey: String?
    /// 掴んだ回と離した回にだけ動かす。ドラッグ中に動かすと更新が走る。
    @State private var grabbing = false

    /// 設定が音へ届く経路があるか。EQ のバイパスとは連動しない (アプリ別ゲインは EQ の前段)。
    private var reachesAudio: Bool { viewModel.settingsReachAudio }

    /// 一覧へ出すには何をすればよいか。0 件の面と編集モードの案内が同じ言い方を使う。
    private static let addHint = "To add an app, play audio in it."
    /// 編集モードでしか使えない操作を、その場で言う。
    private static let editHintText = "Checked apps stay in the mixer. Drag to reorder. \(addHint)"

    var body: some View {
        ScrollView {
            column
                .padding(.horizontal, EQLayout.Mixer.columnHorizontalInset)
        }
        .padding(.vertical, EQLayout.Mixer.columnVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: EQLayout.windowCornerRadius)
                .fill(EQLayout.textPanelBackground)
        )
        .foregroundColor(EQLayout.Palette.text)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private var column: some View {
        if model.editing {
            VStack(spacing: 0) {
                editHint
                // 送り先は行の並びの中の位置から決めるため、案内はジェスチャを受ける面の外へ置く。
                VStack(spacing: 0) {
                    ForEach(model.editRows) { row in
                        editRow(row)
                        separator
                    }
                }
                // 並べ替えは行ではなくこの面が受ける。行に付けると、並べ替えでその行の
                // ビューが作り直され、進行中のジェスチャが失われる。
                .gesture(reorderGesture)
            }
        } else if model.channels.isEmpty {
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

    private var separator: some View {
        Rectangle().fill(EQLayout.Palette.line).frame(height: EQLayout.Mixer.separatorThickness)
    }

    /// 編集モードの読み方と、一覧に出ていないアプリの出し方。行があるときも無いときも同じ場所に置く。
    private var editHint: some View {
        Text(Self.editHintText)
            .font(.system(size: 11))
            .foregroundColor(EQLayout.Palette.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EQLayout.Mixer.rowHorizontalPadding)
            .padding(.bottom, 10)
    }

    // MARK: - 0 件

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No channels")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(EQLayout.Palette.dim)
            Text(Self.addHint)
                .font(.system(size: 11.5))
                .foregroundColor(EQLayout.Palette.faint)
            Button { model.beginEditing() } label: {
                Text("Add")
                    .font(.system(size: 12))
                    .foregroundColor(EQLayout.Palette.cyan)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(EQLayout.Palette.cyan.opacity(0.45), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - 通常の行

    private func row(_ channel: MixerModel.Channel) -> some View {
        HStack(spacing: EQLayout.Mixer.rowSpacing) {
            icon(channel.identity)
            nameLabel(channel.identity, width: EQLayout.Mixer.nameColumnWidth)
            muteButton(channel)
            MixerRowControls(model: model, channel: channel, enabled: reachesAudio, clock: clock)
                .frame(height: EQLayout.Mixer.controlsHeight)
            ResetDotButton { model.resetToDefault(key: channel.key) }
                .opacity(channel.isDefault ? 0 : 1)
                .disabled(channel.isDefault)
        }
        .padding(.horizontal, EQLayout.Mixer.rowHorizontalPadding)
        .frame(height: EQLayout.Mixer.rowHeight)
        .contentShape(Rectangle())
        .opacity(reachesAudio ? 1 : EQLayout.disabledOpacity)
        .disabled(!reachesAudio)
        .contextMenu { editMenuItem }
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
        .help(channel.muted ? "Unmute" : "Mute")
    }

    // MARK: - 編集モードの行

    private func editRow(_ row: MixerModel.EditRow) -> some View {
        HStack(spacing: EQLayout.Mixer.rowSpacing) {
            // チェックが変わるのは指差しが出ているこの範囲だけ。左の余白ぶんも受ける。
            checkbox(row)
                .padding(.leading, EQLayout.Mixer.rowHorizontalPadding)
                .frame(height: EQLayout.Mixer.rowHeight)
                .contentShape(Rectangle())
                .pointerStyle(.link)
                .onTapGesture { model.toggleCheck(key: row.key) }
            HStack(spacing: EQLayout.Mixer.rowSpacing) {
                // 掴めることを示すだけの飾り。掴めるのはここから右。
                Text("⣿")
                    .font(.system(size: 11))
                    .foregroundColor(EQLayout.Palette.faint)
                    .frame(width: EQLayout.Mixer.gripWidth)
                icon(row.identity)
                nameLabel(row.identity, width: nil)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .pointerStyle(grabbing ? .grabActive : .grabIdle)
        }
        .padding(.trailing, EQLayout.Mixer.rowHorizontalPadding)
        .frame(height: EQLayout.Mixer.rowHeight)
        .background(hoveredEditKey == row.key ? EQLayout.Mixer.rowHoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredEditKey = row.key
            } else if hoveredEditKey == row.key {
                hoveredEditKey = nil
            }
        }
        .contextMenu { editMenuItem }
    }

    /// 自前で描く。OS の部品はウィンドウが非アクティブになると自分で灰色になる。
    private func checkbox(_ row: MixerModel.EditRow) -> some View {
        let shape = RoundedRectangle(cornerRadius: EQLayout.Mixer.checkboxCornerRadius)
        return shape
            .fill(row.checked ? EQLayout.Palette.cyan : Color.white.opacity(0.06))
            .overlay(shape.stroke(row.checked ? .clear : EQLayout.Palette.buttonLine, lineWidth: 1))
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(EQLayout.Palette.panel)
                    .opacity(row.checked ? 1 : 0)
            )
            .frame(width: EQLayout.Mixer.checkboxSize, height: EQLayout.Mixer.checkboxSize)
            .opacity(row.checked || model.canCheckMore ? 1 : EQLayout.disabledOpacity)
            .frame(width: EQLayout.Mixer.checkboxColumnWidth)
    }

    @ViewBuilder
    private var editMenuItem: some View {
        if model.editing {
            Button("Done") { model.endEditing() }
        } else {
            Button("Edit") { model.beginEditing() }
        }
    }

    // MARK: - 並べ替え

    /// チェックボックスの列より右だけを掴める範囲とする。
    private var reorderLeadingInset: CGFloat {
        EQLayout.Mixer.rowHorizontalPadding + EQLayout.Mixer.checkboxColumnWidth + EQLayout.Mixer.rowSpacing
    }

    /// 掴んだ行はキーで覚え、送り先はそのときのポインタ位置から決める。
    /// 送り量を積み上げないため、行とポインタがずれていかない。
    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: EQLayout.Mixer.reorderMinimumDrag, coordinateSpace: .local)
            .onChanged { value in
                guard value.startLocation.x >= reorderLeadingInset else { return }
                if !grabbing { grabbing = true }
                if reorder.key == nil {
                    reorder.key = rowIndex(atY: value.startLocation.y).map { model.editRows[$0].key }
                }
                guard let key = reorder.key,
                      let from = model.editRows.firstIndex(where: { $0.key == key }),
                      let to = rowIndex(atY: value.location.y), from != to else { return }
                model.moveEditRow(fromKey: key, toKey: model.editRows[to].key)
            }
            .onEnded { _ in
                reorder.key = nil
                grabbing = false
            }
    }

    private func rowIndex(atY y: CGFloat) -> Int? {
        guard !model.editRows.isEmpty else { return nil }
        let index = Int((y / EQLayout.Mixer.rowPitch).rounded(.down))
        return min(max(0, index), model.editRows.count - 1)
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
