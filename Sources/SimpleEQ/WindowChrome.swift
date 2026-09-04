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

enum MixerVisibilityMenu {
    static let showTitle = "EQ Mixer を表示"
    static let closeTitle = "EQ Mixer を閉じる"

    static func toggle(isShown: Bool) -> String {
        isShown ? closeTitle : showTitle
    }
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

    static func items(
        viewModel: EQViewModel, mixer: MixerModel, hideWindow: @escaping () -> Void
    ) -> [Item] {
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
            Item(id: 3, title: MixerVisibilityMenu.toggle(isShown: mixer.shown), kind: .action {
                mixer.toggleShown()
            }),
        ]
    }
}

/// WindowContextMenu の項目を SwiftUI のメニューとして並べる。
struct WindowContextMenuItems: View {
    let viewModel: EQViewModel
    let mixer: MixerModel
    let hideWindow: () -> Void

    var body: some View {
        ForEach(WindowContextMenu.items(viewModel: viewModel, mixer: mixer, hideWindow: hideWindow)) { item in
            Group {
                switch item.kind {
                case .action(let perform): Button(item.title, action: perform)
                case .toggle(let isOn): Toggle(item.title, isOn: isOn)
                }
            }
            .modifier(CommandShortcut(key: item.commandKey))
        }
    }
}

struct CommandShortcut: ViewModifier {
    let key: Character?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
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
