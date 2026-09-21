import AppKit
import SwiftUI

/// ビジュアライザのキャンバス全体を 1 枚で受け持つポインタ操作面。
struct VisualizerInteractionView: View {
    @ObservedObject var viewModel: EQViewModel
    /// 当たり判定の幾何を物理ピクセル境界へ丸めるための拡大率。
    @Environment(\.displayScale) private var displayScale
    @State private var dragTarget: DragTarget?
    /// クリック列の 1 回目で決まるダブルクリックの対象。ハンドル線の上でなければ nil。
    @State private var clickSequenceResetTarget: ResetTarget?
    @State private var lastPressAt: Date?
    @State private var lastPressLocation: CGPoint?

    /// ドラッグ開始時に決め、終了まで固定する対象。X が対象の境目を越えても乗り換えない。
    private enum DragTarget {
        case eqBands(lockedBand: Int?)
        case preamp(grabbed: Bool)
    }

    private enum ResetTarget {
        case band(Int)
        case preamp
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                surface(CanvasGeometry(
                    size: proxy.size, showLevelMeter: viewModel.showLevelMeter,
                    floorDb: viewModel.floorDb, pixelGrid: EQLayout.PixelGrid(scale: displayScale)
                ))
            }
            Color.clear.frame(height: EQLayout.freqRowHeight)
        }
    }

    private func surface(_ canvas: CanvasGeometry) -> some View {
        Color.clear.modifier(HandleInteractionSurface(
            viewModel: viewModel,
            distanceToHandle: { distanceToHandle(at: $0, canvas) },
            onPress: { notePress(at: $0, canvas) },
            onDragBegin: { dragTarget = makeDragTarget(at: $0, canvas) },
            onDragChanged: { applyDrag(at: $0, canvas) },
            onDragEnded: {
                dragTarget = nil
                viewModel.endDrag()
                viewModel.endPreampDrag()
            },
            onDoubleClick: applyDoubleClick
        ))
    }

    private func distanceToHandle(at location: CGPoint, _ canvas: CanvasGeometry) -> CGFloat {
        canvas.distanceToHandle(at: location, gains: viewModel.gains, preampDb: viewModel.preampDb)
    }

    private func grabbable(at location: CGPoint, _ canvas: CanvasGeometry) -> Bool {
        EQPlotCursor.grabbable(
            handlesRevealed: viewModel.handlesRevealed,
            distanceToHandle: distanceToHandle(at: location, canvas)
        )
    }

    private func notePress(at location: CGPoint, _ canvas: CanvasGeometry) {
        let now = Date()
        let startsSequence = ClickSequencePolicy.startsNewSequence(
            now: now, location: location, lastPressAt: lastPressAt, lastPressLocation: lastPressLocation
        )
        lastPressAt = now
        lastPressLocation = location
        guard startsSequence else { return }
        clickSequenceResetTarget = resetTarget(at: location, canvas)
    }

    private func resetTarget(at location: CGPoint, _ canvas: CanvasGeometry) -> ResetTarget? {
        guard grabbable(at: location, canvas) else { return nil }
        return canvas.isInMeter(location) ? .preamp : .band(canvas.bandIndex(at: location))
    }

    private func makeDragTarget(at start: CGPoint, _ canvas: CanvasGeometry) -> DragTarget {
        let onHandle = grabbable(at: start, canvas)
        guard !canvas.isInMeter(start) else { return .preamp(grabbed: onHandle) }
        return .eqBands(lockedBand: onHandle ? canvas.bandIndex(at: start) : nil)
    }

    private func applyDrag(at location: CGPoint, _ canvas: CanvasGeometry) {
        switch dragTarget {
        case .eqBands(let lockedBand):
            viewModel.updateDrag(band: lockedBand ?? canvas.bandIndex(at: location), db: canvas.db(at: location))
        case .preamp(let grabbed):
            guard grabbed else { return }
            viewModel.updatePreampDrag(db: canvas.db(at: location))
        case nil:
            break
        }
    }

    private func applyDoubleClick() {
        switch clickSequenceResetTarget {
        case .band(let band): viewModel.resetGain(band: band)
        case .preamp: viewModel.resetPreamp()
        case nil: break
        }
    }
}
