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
            .simultaneousGesture(revealLongPressGesture)
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

    /// ポインタ位置に応じてカーソルを出し分ける。
    /// onContinuousHover は連続発火するため push/pop でなく set() で更新する。
    private func updateCursor(at location: CGPoint) {
        let kind = EQPlotCursor.kind(
            processingInEffect: viewModel.processingInEffect,
            handlesRevealed: viewModel.handlesRevealed,
            distanceToHandle: distanceToHandle(location)
        )
        switch kind {
        case .arrow: NSCursor.arrow.set()
        case .grabHandle: NSCursor.resizeUpDown.set()
        case .pressToReveal: NSCursor.pointingHand.set()
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

    private var revealLongPressGesture: some Gesture {
        LongPressGesture(minimumDuration: EQLayout.longPressDuration)
            .onEnded { _ in
                guard viewModel.processingInEffect else { return }
                viewModel.revealHandles()
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

/// EQ 描画域のハンドルの当たり判定とカーソルの出し分け。
enum EQPlotCursor {
    enum Kind { case arrow, grabHandle, pressToReveal }

    static func isOnHandle(distanceToHandle: CGFloat) -> Bool {
        distanceToHandle <= EQLayout.handleHitTolerance
    }

    /// 見えていないハンドルは掴めない。掴む操作はすべてここを読む。
    static func grabbable(handlesRevealed: Bool, distanceToHandle: CGFloat) -> Bool {
        handlesRevealed && isOnHandle(distanceToHandle: distanceToHandle)
    }

    static func kind(processingInEffect: Bool, handlesRevealed: Bool, distanceToHandle: CGFloat) -> Kind {
        guard processingInEffect else { return .arrow }
        return grabbable(handlesRevealed: handlesRevealed, distanceToHandle: distanceToHandle)
            ? .grabHandle : .pressToReveal
    }
}
