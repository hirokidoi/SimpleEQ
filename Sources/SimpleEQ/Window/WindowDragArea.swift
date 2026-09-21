import AppKit
import SwiftUI

struct WindowDragArea: NSViewRepresentable {
    let viewModel: EQViewModel
    let mixer: MixerModel
    /// 偽にすると右クリックに応じない。NSView 自身のメニューはその領域で必ず勝つため、
    /// 外側が付けたメニューへ通したい面はこちらを黙らせる。
    var showsContextMenu = true
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView(
            viewModel: viewModel, mixer: mixer, showsContextMenu: showsContextMenu,
            onDoubleClick: onDoubleClick
        )
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

enum WindowDragClick {
    static func invokesDoubleClick(clickCount: Int) -> Bool { clickCount == 2 }
}

final class WindowDragView: NSView {
    private let viewModel: EQViewModel
    private let mixer: MixerModel
    private let showsContextMenu: Bool
    var onDoubleClick: () -> Void

    init(
        viewModel: EQViewModel, mixer: MixerModel, showsContextMenu: Bool,
        onDoubleClick: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.mixer = mixer
        self.showsContextMenu = showsContextMenu
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard WindowDragClick.invokesDoubleClick(clickCount: event.clickCount) else {
            window?.performDrag(with: event)
            return
        }
        onDoubleClick()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsContextMenu else { return nil }
        return WindowContextMenu.nsMenu(viewModel: viewModel, mixer: mixer) { [weak self] in
            self?.window?.close()
        }
    }
}
