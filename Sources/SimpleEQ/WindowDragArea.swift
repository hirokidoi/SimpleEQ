import AppKit
import SwiftUI

struct WindowDragArea: NSViewRepresentable {
    let viewModel: EQViewModel
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView(viewModel: viewModel, onDoubleClick: onDoubleClick)
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
    var onDoubleClick: () -> Void

    init(viewModel: EQViewModel, onDoubleClick: @escaping () -> Void) {
        self.viewModel = viewModel
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
        let menu = NSMenu()
        for item in WindowContextMenu.items(viewModel: viewModel, hideWindow: { [weak self] in self?.window?.close() }) {
            let menuItem = NSMenuItem(title: item.title, action: #selector(invoke(_:)), keyEquivalent: "")
            menuItem.setCommandShortcut(item.commandKey)
            menuItem.target = self
            switch item.kind {
            case .action(let perform):
                menuItem.representedObject = MenuAction(perform)
            case .toggle(let isOn):
                menuItem.state = isOn.wrappedValue ? .on : .off
                menuItem.representedObject = MenuAction { isOn.wrappedValue.toggle() }
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.perform()
    }
}

private final class MenuAction: NSObject {
    let perform: () -> Void

    init(_ perform: @escaping () -> Void) {
        self.perform = perform
    }
}
