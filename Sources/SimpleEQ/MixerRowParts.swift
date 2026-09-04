import AppKit
import SwiftUI

/// ノーマルの面とコンパクトの面が共有する、行の見た目と 0 件の案内。
enum MixerRowParts {
    /// 一覧へ出すには何をすればよいか。0 件の面と編集モードの案内が同じ言い方を使う。
    static let addHint = "To add an app, play audio in it."
    static let emptyTitle = "No channels"
}

struct MixerRowIcon: View {
    let model: MixerModel
    let identity: MixerAppIdentity?

    var body: some View {
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
}

struct MixerRowName: View {
    let identity: MixerAppIdentity?
    let width: CGFloat?

    var body: some View {
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

struct MixerMuteButton: View {
    let model: MixerModel
    let channel: MixerModel.Channel

    var body: some View {
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
}

/// 0 件の案内。渡されなかった面では追加の導線を出さない。
struct MixerEmptyState: View {
    var onAdd: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Text(MixerRowParts.emptyTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(EQLayout.Palette.dim)
            Text(MixerRowParts.addHint)
                .font(.system(size: 11.5))
                .foregroundColor(EQLayout.Palette.faint)
            if let onAdd {
                Button(action: onAdd) {
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
        }
        .frame(maxWidth: .infinity)
    }
}
