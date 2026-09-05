import AppKit
import SwiftUI

/// About 画面。EQ ウィンドウ・Settings ウィンドウ・Diagnostics ウィンドウとは独立したウィンドウとして開く。
/// 出すのはアプリの素性と、どの条項の誰のものかまで。
/// 条項の本文はバンドルへ同梱したファイルそのものが持つため、この面はスクロールする対象を持たない。
struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            licenseSection
            creditsSection
        }
        .padding(.horizontal, 24)
        .frame(width: EQLayout.aboutWindowWidth)
        .background(EQLayout.textPanelBackground)
        .foregroundColor(EQLayout.Palette.text)
        // このアプリは常時ダーク固定のため、面ごとに明示する。
        .colorScheme(.dark)
    }

    // MARK: - 素性

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSide, height: iconSide)
            Text("SimpleEQ")
                .font(.system(size: 20, weight: .semibold))
            // 文字列リテラルへ差し込むと LocalizedStringKey として扱われ、差し込んだ側の記号が装飾として解釈される。
            // バンドルから読んだ値は組み立ててから文字列として渡す。
            Text(versionLabelPrefix + AppVersion.text)
                .font(.system(size: 12.5))
                .foregroundColor(EQLayout.Palette.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private let iconSide: CGFloat = 96

    private let versionLabelPrefix = "Version "

    // MARK: - 条項

    /// 条項の名前と著作権表示。
    private var licenseSection: some View {
        PanelSection("License") {
            Text(AppLicense.nameAndCopyright)
                .font(.system(size: 12.5))
                .foregroundColor(EQLayout.Palette.faint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 土台にしたもの

    /// 土台にしたものへの帰属表示。その条項の全文はドライバ側のバンドルが単体で持つ。
    private var creditsSection: some View {
        PanelSection("Credits") {
            VStack(alignment: .leading, spacing: 5) {
                Text(DriverCredit.origin)
                Text(DriverCredit.copyright)
            }
            .font(.system(size: 12.5))
            .foregroundColor(EQLayout.Palette.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
