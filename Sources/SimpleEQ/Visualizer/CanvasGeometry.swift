import SwiftUI

/// ビジュアライザのキャンバス (EQ 本体と L/R レベルメーター) の幾何。
struct CanvasGeometry {
    let size: CGSize
    let showLevelMeter: Bool
    let floorDb: Double
    let pixelGrid: EQLayout.PixelGrid

    var eqWidth: CGFloat {
        EQLayout.eqContentWidth(totalWidth: size.width, showLevelMeter: showLevelMeter)
    }

    var gainAxis: EQLayout.GainAxis {
        EQLayout.GainAxis(canvasHeight: size.height, pixelGrid: pixelGrid)
    }

    private var eqGeometry: EQPlotGeometry {
        EQPlotGeometry(size: CGSize(width: eqWidth, height: size.height), floorDb: floorDb, pixelGrid: pixelGrid)
    }

    func isInMeter(_ location: CGPoint) -> Bool {
        showLevelMeter && location.x >= eqWidth
    }

    func bandIndex(at location: CGPoint) -> Int {
        eqGeometry.bandIndex(atX: location.x)
    }

    func db(at location: CGPoint) -> Double {
        gainAxis.yToDb(location.y)
    }

    func distanceToHandle(at location: CGPoint, gains: [Double], preampDb: Double) -> CGFloat {
        let handleDb = isInMeter(location) ? preampDb : gains[bandIndex(at: location)]
        return abs(location.y - gainAxis.dbToY(handleDb))
    }
}
