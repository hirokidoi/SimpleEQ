import AppKit
import SwiftUI

enum WindowVisibilityMenu {
    static let hideTitle = "EQ ウィンドウを非表示"
    static let showTitle = "EQ ウィンドウを表示"
    static let hideCommandKey: Character = "w"

    static func toggle(isVisible: Bool) -> (title: String, commandKey: Character?) {
        isVisible ? (hideTitle, hideCommandKey) : (showTitle, nil)
    }
}

enum AlwaysOnTopMenu {
    static let title = "常に最前面に表示"
}

@MainActor
enum WindowContextMenu {
    enum Kind {
        case action(() -> Void)
        case toggle(Binding<Bool>)
    }

    struct Item: Identifiable {
        let id: Int
        let title: String
        let kind: Kind
        var commandKey: Character?
    }

    static func items(viewModel: EQViewModel, hideWindow: @escaping () -> Void) -> [Item] {
        [
            Item(
                id: 0, title: WindowVisibilityMenu.hideTitle, kind: .action(hideWindow),
                commandKey: WindowVisibilityMenu.hideCommandKey
            ),
            Item(
                id: 1, title: AlwaysOnTopMenu.title,
                kind: .toggle(Binding(get: { viewModel.alwaysOnTop }, set: { viewModel.alwaysOnTop = $0 }))
            ),
            Item(id: 2, title: viewModel.viewMode.toggled.switchActionTitle, kind: .action {
                viewModel.viewMode = viewModel.viewMode.toggled
            }),
        ]
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSMenuItem {
    func setCommandShortcut(_ key: Character?) {
        guard let key else {
            keyEquivalent = ""
            return
        }
        keyEquivalent = String(key)
        keyEquivalentModifierMask = .command
    }
}

final class WindowDragAnchor {
    private var start: (mouse: NSPoint, origin: NSPoint)?

    func begin(mouse: NSPoint, origin: NSPoint) -> (mouse: NSPoint, origin: NSPoint) {
        if let start { return start }
        let value = (mouse: mouse, origin: origin)
        start = value
        return value
    }

    func clear() {
        start = nil
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindowChange = { found in
            DispatchQueue.main.async { window = found }
        }
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
}

final class WindowAccessorView: NSView {
    var onWindowChange: (NSWindow?) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
    }
}
