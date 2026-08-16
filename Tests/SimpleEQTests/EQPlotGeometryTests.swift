import XCTest
@testable import SimpleEQ

/// バー矩形・プロット矩形が画素境界に丸められることを検証する。
final class EQPlotGeometryTests: XCTestCase {
    /// 出荷時サイズ相当 (寸法定数から導出、実寸をハードコードしない)。
    private let size = CGSize(
        width: EQLayout.windowDefaultSize.width,
        height: EQLayout.windowDefaultSize.height - EQLayout.topBarHeight - EQLayout.freqRowHeight
    )
    private let scalesUnderTest: [CGFloat] = [1, 2, 1.5, 3]

    func testAllBandBarRectsShareTheSameWidth() {
        for scale in scalesUnderTest {
            let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: scale))
            let widths = Set((0..<EQSpec.bandCount).map { geo.barRect($0).width })
            XCTAssertEqual(widths.count, 1, "scale=\(scale)")
        }
    }

    // 拡大率を掛けると各辺が整数になる。整数倍だけでは丸めが恒等でも通るため、非整数倍も含める。
    func testBarRectAndPlotRectEdgesLandOnPixelBoundaries() {
        for scale in scalesUnderTest {
            let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: scale))
            var edges: [CGFloat] = []
            let plotRect = geo.plotRect
            edges += [plotRect.minX, plotRect.maxX, plotRect.minY, plotRect.maxY]
            for band in 0..<EQSpec.bandCount {
                let bar = geo.barRect(band)
                edges += [bar.minX, bar.maxX, bar.minY, bar.maxY]
            }
            for edge in edges {
                let scaled = edge * scale
                XCTAssertEqual(scaled, scaled.rounded(), accuracy: 1e-9, "scale=\(scale) edge=\(edge)")
            }
        }
    }

    func testBarWidthDoesNotDropBelowOnePixelAtShippedSize() {
        for scale in scalesUnderTest {
            let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: scale))
            XCTAssertGreaterThanOrEqual(geo.barWidth, 1 / scale, "scale=\(scale)")
        }
    }

    // EQ のドラッグを右へ伸ばしても書き込み先がメーター列側 (バンド範囲の外) へ移らないことの根拠。
    func testBandIndexClampsToTheLastBandBeyondThePlotRightEdge() {
        for scale in scalesUnderTest {
            let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: scale))
            XCTAssertEqual(geo.bandIndex(atX: geo.plotRect.maxX + 1000), EQSpec.bandCount - 1, "scale=\(scale)")
        }
    }

    func testInvalidScaleFallsBackToOneWithoutBreakingAlignment() {
        let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: -1))
        XCTAssertEqual(geo.pixelGrid.scale, 1)
        XCTAssertEqual(geo.plotRect.minX, EQLayout.Padding.left)
    }

    // 列中心 x はハンドル等の基準にも使われるため、バー矩形の中点と一致させる。
    func testColumnCenterXMatchesRoundedBarRectMidpoint() {
        let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: 1.5))
        for band in 0..<EQSpec.bandCount {
            XCTAssertEqual(geo.columnCenterX(band), geo.barRect(band).midX, "band=\(band)")
        }
    }

    // 列の間隔は原点の丸めにより最大 1 画素ばらつく。素朴な等間隔計算との差が 1 画素未満に収まること。
    func testPerColumnOriginRoundingStaysWithinOnePixel() {
        for scale in scalesUnderTest {
            let pixelGrid = EQLayout.PixelGrid(scale: scale)
            let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: pixelGrid)
            let columnWidth = geo.columnWidth
            for band in 0..<EQSpec.bandCount {
                let rawCenterX = geo.plotRect.minX + (CGFloat(band) + 0.5) * columnWidth
                let rawX = rawCenterX - geo.barWidth / 2
                let diff = abs(geo.barRect(band).minX - rawX)
                XCTAssertLessThan(diff, 1 / scale, "scale=\(scale) band=\(band)")
            }
        }
    }
}
