import AppKit
import SwiftUI

/// コンパクトビューの左上へ浮かべる非表示ボタン。ポインタが左上へ寄っている間だけ現れる。
struct CompactHideButton: View {
    let viewModel: EQViewModel
    let mixer: MixerModel

    @State private var revealed = false

    private static let hotZone = CGSize(width: 72, height: 56)
    private static let buttonOrigin = CGPoint(x: 10, y: 10)
    private static let buttonSize: CGFloat = 20
    private static let fadeDuration: Double = 0.12
    private static let ringColor = Color.white.opacity(0.35)
    private static let ringWidth: CGFloat = 1.5

    private static var buttonRect: CGRect {
        CGRect(origin: buttonOrigin, size: CGSize(width: buttonSize, height: buttonSize))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            mark
                .offset(x: Self.buttonOrigin.x, y: Self.buttonOrigin.y)
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: Self.fadeDuration), value: revealed)
        }
        .frame(width: Self.hotZone.width, height: Self.hotZone.height)
        .overlay {
            CompactHideHitArea(
                viewModel: viewModel, mixer: mixer, buttonRect: Self.buttonRect,
                onRevealChange: { revealed = $0 }
            )
        }
    }

    private var mark: some View {
        Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(EQLayout.Palette.text)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            // 明るいバーの上でもグリフが読めるよう、円は暗いまま残す。
            .background(Circle().fill(EQLayout.Palette.panel.opacity(0.85)))
            .overlay(Circle().strokeBorder(Self.ringColor, lineWidth: Self.ringWidth))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// 左上の非表示ボタンの表示条件と押下受理条件。
enum CompactHideButtonPolicy {
    static func revealed(windowVisible: Bool, pointer: CGPoint?, hotZone: CGRect) -> Bool {
        guard windowVisible, let pointer else { return false }
        return hotZone.contains(pointer)
    }

    static func acceptsPress(revealed: Bool, point: CGPoint, buttonRect: CGRect) -> Bool {
        revealed && buttonRect.contains(point)
    }
}

private struct CompactHideHitArea: NSViewRepresentable {
    let viewModel: EQViewModel
    let mixer: MixerModel
    let buttonRect: CGRect
    let onRevealChange: (Bool) -> Void

    func makeNSView(context: Context) -> CompactHideHitView {
        CompactHideHitView(
            viewModel: viewModel, mixer: mixer, buttonRect: buttonRect, onRevealChange: onRevealChange
        )
    }

    func updateNSView(_ nsView: CompactHideHitView, context: Context) {
        nsView.onRevealChange = onRevealChange
    }
}

final class CompactHideHitView: NSView {
    private let viewModel: EQViewModel
    private let mixer: MixerModel
    private let buttonRect: CGRect
    private var trackingArea: NSTrackingArea?
    private var windowVisibleObservation: NSKeyValueObservation?
    private var windowVisible = false
    private var revealed = false
    private var pressed = false
    var onRevealChange: (Bool) -> Void

    /// ポインタの現在位置の取得口。
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    init(
        viewModel: EQViewModel, mixer: MixerModel, buttonRect: CGRect,
        onRevealChange: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.mixer = mixer
        self.buttonRect = buttonRect
        self.onRevealChange = onRevealChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return CompactHideButtonPolicy.acceptsPress(revealed: revealed, point: local, buttonRect: buttonRect)
            ? self : nil
    }

    override func resetCursorRects() {
        guard revealed else { return }
        addCursorRect(buttonRect, cursor: .pointingHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        WindowContextMenu.nsMenu(viewModel: viewModel, mixer: mixer) { [weak self] in self?.window?.close() }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard CompactHideButtonPolicy.acceptsPress(revealed: revealed, point: local, buttonRect: buttonRect)
        else { return }
        window?.close()
    }

    override func mouseEntered(with event: NSEvent) { refreshReveal() }

    override func mouseMoved(with event: NSEvent) { refreshReveal() }

    override func mouseExited(with event: NSEvent) { refreshReveal() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        refreshReveal()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowVisibleObservation = nil
        guard let window else {
            windowVisible = false
            refreshReveal()
            return
        }
        windowVisibleObservation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.windowVisible = window.isVisible
                self?.refreshReveal()
            }
        }
    }

    private func refreshReveal() {
        setRevealed(CompactHideButtonPolicy.revealed(
            windowVisible: windowVisible, pointer: pointerInView(), hotZone: bounds
        ))
    }

    private func pointerInView() -> CGPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: pointerLocation()), from: nil)
    }

    private func setRevealed(_ value: Bool) {
        guard revealed != value else { return }
        revealed = value
        window?.invalidateCursorRects(for: self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onRevealChange(self.revealed)
        }
    }
}
