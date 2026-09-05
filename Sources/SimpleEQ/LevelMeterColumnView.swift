import SwiftUI

/// L/R マスターレベルの帯の chrome (L/R ラベル行・左境界線・列幅)。
struct LevelMeterColumnView: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: LevelMeterRenderer.channelGap(compact: false)) {
                channelLabel("L")
                channelLabel("R")
            }
            .frame(maxWidth: .infinity)
            .frame(height: EQLayout.freqRowHeight)
        }
        .frame(width: EQLayout.levelMeterColumnWidth)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) {
            Rectangle().fill(EQLayout.Palette.line).frame(width: 1).allowsHitTesting(false)
        }
    }

    private func channelLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundColor(EQLayout.Palette.faint)
            .frame(width: LevelMeterRenderer.barWidth(compact: false))
    }
}

/// L/R マスターレベル帯の寸法とレベル換算。描画本体は持たない。
enum LevelMeterRenderer {
    /// EQ バーの上限幅に対する比。
    static let barWidthRatio: CGFloat = 1.0 / 2
    static let compactBarWidthRatio: CGFloat = 1.0 / 3
    /// バー幅に対する比。
    static let channelGapRatio: CGFloat = 0.6

    /// L/R 1本ぶんのバー幅。
    static func barWidth(compact: Bool) -> CGFloat {
        EQLayout.barWidthMax * (compact ? compactBarWidthRatio : barWidthRatio)
    }
    /// L/R バー間のギャップ。
    static func channelGap(compact: Bool) -> CGFloat {
        barWidth(compact: compact) * channelGapRatio
    }
    static var compactBarsWidth: CGFloat {
        barWidth(compact: true) * 2 + channelGap(compact: true)
    }

    /// dBFS を 0 (下限) ... 1 (0dB) の充填比率へ変換する。
    /// 下限値は Settings で調整可能な現在値を使い、各バンドビジュアライザと同じ設定に追従させる。
    @MainActor
    static func levelRatio(_ db: Double, viewModel: EQViewModel) -> Double {
        let floor = viewModel.floorDb
        guard db > floor else { return 0 }
        return min(1, max(0, (db - floor) / -floor))
    }
}
