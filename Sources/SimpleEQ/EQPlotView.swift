import AppKit
import SwiftUI

/// EQ 本体の chrome (周波数ラベル行)。
struct EQPlotView: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            freqRow
        }
    }

    // MARK: - 周波数ラベル行

    private var freqRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(EQSpec.FREQS.enumerated()), id: \.offset) { _, freq in
                Text(Self.formatFrequency(freq))
                    .font(.system(size: 11))
                    .foregroundColor(EQLayout.Palette.faint)
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
            }
        }
        .padding(.leading, EQLayout.Padding.left)
        .padding(.trailing, EQLayout.Padding.right)
        .frame(height: EQLayout.freqRowHeight)
    }

    /// 1000 以上は k 表記にする (整数なら小数点なし)。
    static func formatFrequency(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return f == f.rounded() ? "\(Int(f))" : "\(f)"
    }
}
