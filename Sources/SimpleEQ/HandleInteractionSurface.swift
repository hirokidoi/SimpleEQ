import AppKit
import SwiftUI

/// ハンドル操作面の規律 (reveal/ドラッグ/ダブルクリック/カーソル出し分け)。
struct HandleInteractionSurface: ViewModifier {
    @ObservedObject var viewModel: EQViewModel
    /// ポインタ位置からハンドル線までの縦距離。
    let distanceToHandle: (CGPoint) -> CGFloat
    /// 押下のたびに呼ばれる (reveal のみのジェスチャを含む)。
    let onPress: (CGPoint) -> Void
    /// reveal のみのジェスチャでは呼ばれない。
    let onDragBegin: (CGPoint) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let onDoubleClick: () -> Void

    @State private var isDragging = false
    /// ハンドル非表示の状態で始まったジェスチャか。
    @State private var revealsHandlesOnly = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(doubleClickGesture)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    updateCursor(at: location)
                case .ended:
                    NSCursor.arrow.set()
                }
            }
    }

    /// ポインタ位置に応じてカーソルを出し分ける。onContinuousHover は連続発火するため push/pop
    /// でなく set() で更新する。
    private func updateCursor(at location: CGPoint) {
        let kind = EQPlotCursor.kind(
            processingInEffect: viewModel.processingInEffect,
            handleGrabbable: viewModel.handlesRevealed,
            distanceToHandle: distanceToHandle(location)
        )
        switch kind {
        case .arrow: NSCursor.arrow.set()
        case .grabHandle: NSCursor.resizeUpDown.set()
        case .clickToReveal: NSCursor.pointingHand.set()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard viewModel.processingInEffect else { return }
                if !isDragging {
                    isDragging = true
                    revealsHandlesOnly = !viewModel.handlesRevealed
                    viewModel.noteCanvasPointerDown()
                    onPress(value.startLocation)
                    guard !revealsHandlesOnly else { return }
                    onDragBegin(value.startLocation)
                }
                guard !revealsHandlesOnly else { return }
                onDragChanged(value.location)
            }
            .onEnded { _ in
                isDragging = false
                revealsHandlesOnly = false
                onDragEnded()
            }
    }

    private var doubleClickGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { _ in
                guard viewModel.processingInEffect else { return }
                onDoubleClick()
            }
    }
}

/// EQ 描画域のカーソルの出し分け。
enum EQPlotCursor {
    enum Kind { case arrow, grabHandle, clickToReveal }

    static func isOnHandle(distanceToHandle: CGFloat) -> Bool {
        distanceToHandle <= EQLayout.handleHitTolerance
    }

    static func kind(processingInEffect: Bool, handleGrabbable: Bool, distanceToHandle: CGFloat) -> Kind {
        guard processingInEffect else { return .arrow }
        let onHandle = handleGrabbable && isOnHandle(distanceToHandle: distanceToHandle)
        return onHandle ? .grabHandle : .clickToReveal
    }
}
