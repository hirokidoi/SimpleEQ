import SwiftUI

/// EQ プロットの座標変換と、バンドごとのバー矩形の物理ピクセル境界への丸めを担う。
/// CALayer 側の描画と当たり判定の双方がここを経由することで、chrome とバー矩形の位置関係が常に一致する。
struct EQPlotGeometry {
    let size: CGSize
    /// ビジュアライザ (バーレベル) の dBFS 下限。Settings で調整可能なため呼び出し側から受け取る。
    let floorDb: Double
    let pixelGrid: EQLayout.PixelGrid
    let compact: Bool

    init(
        size: CGSize, floorDb: Double, pixelGrid: EQLayout.PixelGrid = EQLayout.PixelGrid(scale: 1),
        compact: Bool = false
    ) {
        self.size = size
        self.floorDb = floorDb
        self.pixelGrid = pixelGrid
        self.compact = compact
    }

    /// EQ 本体と L/R レベルメーターが共有する縦方向の変換。
    var gainAxis: EQLayout.GainAxis { EQLayout.GainAxis(canvasHeight: size.height, pixelGrid: pixelGrid, compact: compact) }

    /// 画素境界へ丸めたプロット矩形。バー矩形・段の矩形・当たり判定が共有する。
    var plotRect: CGRect {
        let axis = gainAxis
        let horizontal = EQLayout.horizontalPadding(compact: compact)
        return CGRect(
            x: pixelGrid.snap(horizontal.left),
            y: axis.top,
            width: pixelGrid.snap(max(0, size.width - horizontal.left - horizontal.right)),
            height: axis.height
        )
    }

    var columnWidth: CGFloat { plotRect.width / CGFloat(EQSpec.bandCount) }

    /// バー幅 (列幅×比率を上限で頭打ちしたのち画素境界へ1回だけ丸め、全列で共有する)。
    var barWidth: CGFloat { pixelGrid.snap(min(columnWidth * EQLayout.barWidthRatio, EQLayout.barWidthMax)) }

    /// バンド index の点灯・消灯・キャップの描画で共有する矩形。幅は 1 回だけ丸めて全列で共有し、
    /// 列ごとに丸めるのは原点だけにする (幅を列ごとに丸めると 1 画素ずれて不揃いに見える)。
    func barRect(_ index: Int) -> CGRect {
        let width = barWidth
        let rawCenterX = plotRect.minX + (CGFloat(index) + 0.5) * columnWidth
        let x = pixelGrid.snap(rawCenterX - width / 2)
        return CGRect(x: x, y: plotRect.minY, width: width, height: plotRect.height)
    }

    /// 左余白の中央 x 座標。gutter (+/−/0 記号) と dBFS 軸目盛りの共通の描画中心。
    var gutterCenterX: CGFloat { EQLayout.Padding.left / 2 }

    /// バー矩形 (丸め済み) の中心 x。ハンドル線・ドラッグバッジなどの chrome が基準として読む。
    func columnCenterX(_ index: Int) -> CGFloat { barRect(index).midX }

    func dbToY(_ db: Double) -> CGFloat { gainAxis.dbToY(db) }

    func levelDbToY(_ db: Double) -> CGFloat {
        let r = plotRect
        let f = (db - floorDb) / (0 - floorDb)
        return r.maxY - CGFloat(f) * r.height
    }

    func yToDb(_ y: CGFloat) -> Double { gainAxis.yToDb(y) }

    func bandIndex(atX x: CGFloat) -> Int {
        guard columnWidth > 0 else { return 0 }
        let i = Int(((x - plotRect.minX) / columnWidth).rounded(.down))
        return max(0, min(EQSpec.bandCount - 1, i))
    }
}
