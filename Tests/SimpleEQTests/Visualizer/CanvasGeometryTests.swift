import XCTest

@testable import SimpleEQ

/// EQ 側とメーター側の振り分け。誤ると、プリアンプのつもりの操作が末尾バンドのゲインを書き換える。
final class CanvasGeometryTests: XCTestCase {
    private func canvas(showLevelMeter: Bool = true) -> CanvasGeometry {
        CanvasGeometry(
            size: CGSize(width: 1000, height: 400), showLevelMeter: showLevelMeter,
            floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: EQLayout.PixelGrid(scale: 1)
        )
    }

    func testTheSeamSitsAtTheEQContentWidth() {
        XCTAssertEqual(
            canvas().eqWidth,
            EQLayout.eqContentWidth(totalWidth: canvas().size.width, showLevelMeter: true)
        )
        XCTAssertEqual(
            canvas(showLevelMeter: false).eqWidth, canvas().size.width,
            "メーター非表示なら EQ が全幅を占めること"
        )
    }

    func testPointsAreRoutedByTheSeam() {
        let c = canvas()
        let mid = c.size.height / 2
        XCTAssertFalse(c.isInMeter(CGPoint(x: c.eqWidth - 1, y: mid)))
        XCTAssertTrue(c.isInMeter(CGPoint(x: c.eqWidth, y: mid)))
        XCTAssertTrue(c.isInMeter(CGPoint(x: c.size.width - 1, y: mid)))
    }

    func testNothingIsRoutedToTheMeterWhileItIsHidden() {
        let c = canvas(showLevelMeter: false)
        XCTAssertFalse(c.isInMeter(CGPoint(x: c.size.width - 1, y: 0)))
    }

    // 縦の変換が両側で共通であることは、掴み判定と値の読み取りの双方が同じ軸を通る前提になっている。
    func testTheGainAxisIsSharedWithTheEQPlotGeometry() {
        let c = canvas()
        let geo = EQPlotGeometry(
            size: CGSize(width: c.eqWidth, height: c.size.height), floorDb: c.floorDb, pixelGrid: c.pixelGrid
        )
        XCTAssertEqual(c.gainAxis.top, geo.gainAxis.top)
        XCTAssertEqual(c.gainAxis.height, geo.gainAxis.height)
    }

    func testDistanceToHandleReadsThePreampOnTheMeterSideAndTheBandOnTheEQSide() {
        let c = canvas()
        var gains = [Double](repeating: 0, count: EQSpec.bandCount)
        let band = 3
        gains[band] = 6
        let preampDb = -6.0

        let geo = EQPlotGeometry(
            size: CGSize(width: c.eqWidth, height: c.size.height), floorDb: c.floorDb, pixelGrid: c.pixelGrid
        )
        let eqPoint = CGPoint(x: geo.columnCenterX(band), y: c.gainAxis.dbToY(6))
        XCTAssertEqual(c.bandIndex(at: eqPoint), band, "前提: 対象バンドを指していること")
        XCTAssertEqual(c.distanceToHandle(at: eqPoint, gains: gains, preampDb: preampDb), 0, accuracy: 0.5)

        let meterPoint = CGPoint(x: c.eqWidth + 10, y: c.gainAxis.dbToY(preampDb))
        XCTAssertEqual(c.distanceToHandle(at: meterPoint, gains: gains, preampDb: preampDb), 0, accuracy: 0.5)
    }
}
