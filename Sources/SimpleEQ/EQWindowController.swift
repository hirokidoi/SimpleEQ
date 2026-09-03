import AppKit
import Combine
import SwiftUI

/// EQ ウィンドウの保持とビューモードの適用、メニューバーからの開閉トグルを担う。可視状態は
/// ビューモデル側の可視化状態へ連動させる。Settings/Diagnostics/About ウィンドウの開閉もここで担う。
final class EQWindowController: NSWindowController, NSWindowDelegate {
    private var appliedViewMode: ViewMode?
    private var cancellables = Set<AnyCancellable>()
    private var viewModel: EQViewModel!
    private var settings: SettingsStore!
    private var settingsWindowController: NSWindowController?
    private var diagnostics: DiagnosticsModel!
    private var diagnosticsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var mixer: MixerModel!
    private var mixerRenderClock: MixerRenderClock!
    /// Diagnostics ウィンドウ専用の delegate。NSWindow.delegate は weak 参照のため、ここで strong に
    /// 保持しないと解放され、delegate 経路が発火しなくなる。
    private var diagnosticsWindowDelegate: DiagnosticsWindowDelegate?
    /// 周期処理の駆動条件が使う可視状態。表示・非表示の各所はここだけを動かす。
    private var windowIsVisible = false {
        didSet {
            guard windowIsVisible != oldValue else { return }
            updateDrivenWork()
        }
    }

    convenience init(
        viewModel: EQViewModel, settings: SettingsStore, diagnostics: DiagnosticsModel, mixer: MixerModel
    ) {
        let window = EQMainWindow(
            contentRect: NSRect(origin: .zero, size: EQLayout.windowDefaultSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "SimpleEQ"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        self.init(window: window)
        self.viewModel = viewModel
        self.settings = settings
        self.diagnostics = diagnostics
        self.mixer = mixer
        self.mixerRenderClock = MixerRenderClock(levelStore: mixer.levelStore, viewModel: viewModel)
        window.delegate = self
        window.onCancel = { [weak mixer] in mixer?.endEditing() }
        applyViewMode(viewModel.viewMode)

        // 駆動条件はミキサーの状態が動くたびに導き直す。@Published は変更前に流すため、
        // モデルを読み直さず流れてきた値を使う。
        mixer.$shown.combineLatest(mixer.$editing)
            .sink { [weak self] shown, editing in
                MainActor.assumeIsolated { self?.applyDrivenWork(shown: shown, editing: editing) }
            }
            .store(in: &cancellables)

        applyAlwaysOnTop(viewModel.alwaysOnTop)
        viewModel.$alwaysOnTop
            .sink { [weak self] on in self?.applyAlwaysOnTop(on) }
            .store(in: &cancellables)
        // 配送中のビュー階層をその場で壊さないよう、次の実行機会へ回す。
        viewModel.$viewMode
            .dropFirst()
            .sink { mode in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.applyViewMode(mode) }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - ビューモード

    private func contentView(for mode: ViewMode) -> NSView {
        switch mode {
        case .normal:
            FirstMouseHostingView(rootView: RootView(
                viewModel: viewModel,
                mixer: mixer,
                mixerClock: mixerRenderClock,
                onOpenWindow: { [weak self] destination in
                    switch destination {
                    case .settings: self?.showSettings()
                    case .diagnostics: self?.showDiagnostics()
                    }
                }
            ))
        case .compact:
            NSHostingView(rootView: CompactRootView(viewModel: viewModel))
        }
    }

    static func contentSize(for mode: ViewMode) -> NSSize {
        switch mode {
        case .normal: EQLayout.windowDefaultSize
        case .compact: EQLayout.compactWindowDefaultSize
        }
    }

    private func applyViewMode(_ newMode: ViewMode) {
        guard let window, appliedViewMode != newMode else { return }
        // コンパクトビューには面を置く場所が無い。
        if newMode == .compact { mixer.setShown(false) }
        let previousMode = appliedViewMode
        if let previousMode { persistWindowOrigin(for: previousMode) }
        appliedViewMode = newMode

        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let size = EQWindowController.contentSize(for: newMode)
        window.contentView = contentView(for: newMode)
        window.setContentSize(size)
        if let restored = EQWindowController.restoredOrigin(saved: settings.windowOrigin(for: newMode), size: size) {
            window.setFrameOrigin(restored)
        } else if previousMode != nil {
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }

        guard previousMode != nil, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func restoredOrigin(saved: SettingsStore.WindowOrigin?, size: NSSize) -> NSPoint? {
        guard let saved, originIsOnScreen(saved, size: size) else { return nil }
        return NSPoint(x: saved.x, y: saved.y)
    }

    /// Settings ウィンドウを開く。EQ ウィンドウの上に重ねる sheet ではなく独立ウィンドウ
    /// (移動自由・幅は固定で高さのみ可変) にする。初回のみ生成し、以後は使い回す。
    func showSettings() {
        if settingsWindowController == nil {
            let width = EQLayout.settingsWindowWidth
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: EQLayout.settingsWindowDefaultHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SimpleEQ Settings"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: width, height: EQLayout.settingsWindowMinHeight)
            window.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            window.center()
            let controller = NSWindowController(window: window)
            let hosting = NSHostingView(rootView: SettingsView(
                viewModel: viewModel,
                mixer: mixer,
                onDone: { [weak window] in window?.close() },
                onScrollOverflowChange: { [weak self, weak window] overflow in
                    self?.applyHeightLimit(
                        to: window, scrollOverflow: overflow, minHeight: EQLayout.settingsWindowMinHeight
                    )
                }
            ))
            window.contentView = hosting
            settingsWindowController = controller
            applyAlwaysOnTop(viewModel.alwaysOnTop)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Diagnostics ウィンドウを開く。Settings ウィンドウと同じ流儀に倣う。位置は永続化しない。
    func showDiagnostics() {
        if diagnosticsWindowController == nil {
            let width = EQLayout.diagnosticsWindowWidth
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: EQLayout.diagnosticsWindowMinHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SimpleEQ Diagnostics"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: width, height: EQLayout.diagnosticsWindowMinHeight)
            window.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            window.center()
            let controller = NSWindowController(window: window)
            let hosting = NSHostingView(rootView: DiagnosticsView(
                model: diagnostics,
                onScrollOverflowChange: { [weak self, weak window] overflow in
                    self?.applyHeightLimit(
                        to: window, scrollOverflow: overflow, minHeight: EQLayout.diagnosticsWindowMinHeight
                    )
                }
            ))
            window.contentView = hosting
            diagnosticsWindowController = controller
            let delegate = DiagnosticsWindowDelegate(owner: self)
            diagnosticsWindowDelegate = delegate
            window.delegate = delegate
            applyAlwaysOnTop(viewModel.alwaysOnTop)
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindowController?.showWindow(nil)
        if let diagnosticsWindow = diagnosticsWindowController?.window {
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            updateDiagnosticsActive(
                isVisible: diagnosticsWindow.isVisible, isMiniaturized: diagnosticsWindow.isMiniaturized
            )
        }
    }

    /// メニューバーからのミキサーの導線。ノーマルビューでなければ切り替えてから出す。
    func showMixer() {
        viewModel.viewMode = .normal
        show()
        mixer.setShown(true)
    }

    /// About ウィンドウを開く。Settings / Diagnostics と同じ流儀に倣う。寸法は固定 (幅は定数、
    /// 高さは内容が要求する寸法をそのまま採る)。
    func showAbout() {
        if aboutWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: EQLayout.aboutWindowWidth, height: 0),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "About SimpleEQ"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AboutView())
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            aboutWindowController = NSWindowController(window: window)
            applyAlwaysOnTop(viewModel.alwaysOnTop)
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// スクロールが要らなくなる高さをウィンドウの高さ上限にする。内容の高さは外から測れないため、
    /// 内容側から報告される超過量 (scrollOverflow) を使う。
    private func applyHeightLimit(to window: NSWindow?, scrollOverflow: CGFloat, minHeight: CGFloat) {
        guard let window else { return }
        window.maxSize = NSSize(
            width: window.minSize.width,
            height: EQWindowController.heightLimit(
                currentHeight: window.frame.height, scrollOverflow: scrollOverflow, minHeight: minHeight
            )
        )
    }

    /// 高さの上限を決める準純粋関数。下限を下回る値は上限にしない。
    static func heightLimit(currentHeight: CGFloat, scrollOverflow: CGFloat, minHeight: CGFloat) -> CGFloat {
        max(currentHeight + scrollOverflow, minHeight)
    }

    /// 現在存在する自ウィンドウすべてへ適用する。
    private func applyAlwaysOnTop(_ on: Bool) {
        let level: NSWindow.Level = on ? .floating : .normal
        window?.level = level
        settingsWindowController?.window?.level = level
        diagnosticsWindowController?.window?.level = level
        aboutWindowController?.window?.level = level
    }

    /// メニューバーからの開閉トグル。可視状態を viewModel へ反映する。
    func toggle() {
        guard let window = window else { return }
        if window.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// ウィンドウを表示して最前面に持ってくる。起動時の自動表示とトグルの両方から呼ぶ。
    func show() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windowIsVisible = true
        promptDriverInstallIfNeeded()
    }

    /// 起動シーケンスの最初のスナップショットが確定した後に一度だけ呼ぶ。ウィンドウが可視でなければ
    /// 何もしない。
    func recheckDriverInstallPromptAfterStartupConfirmed() {
        guard let window, window.isVisible else { return }
        promptDriverInstallIfNeeded()
    }

    /// ウィンドウを隠す。
    func hide() {
        guard let window = window else { return }
        window.orderOut(nil)
        handleWindowHidden()
    }

    private func handleWindowHidden() {
        windowIsVisible = false
        // 次に開いたときはビジュアライザから始める。
        mixer.setShown(false)
        hideSettingsIfOpen()
        hideDiagnosticsIfOpen()
        hideAboutIfOpen()
        persistWindowOrigin()
    }

    /// Settings ウィンドウが表示中であれば隠す。破棄せず隠すだけの流儀に合わせ、close ではなく
    /// orderOut を使う。
    private func hideSettingsIfOpen() {
        guard let settingsWindow = settingsWindowController?.window, settingsWindow.isVisible else { return }
        settingsWindow.orderOut(nil)
    }

    /// Diagnostics ウィンドウが表示中であれば隠す (Settings と同じ扱い)。
    private func hideDiagnosticsIfOpen() {
        guard let diagnosticsWindow = diagnosticsWindowController?.window, diagnosticsWindow.isVisible else { return }
        diagnosticsWindow.orderOut(nil)
        // orderOut は delegate 通知を出さないため、可視状態の反映をここで直接行う。
        updateDiagnosticsActive(isVisible: false, isMiniaturized: false)
    }

    /// About ウィンドウが表示中であれば隠す (Settings と同じ扱い)。
    private func hideAboutIfOpen() {
        guard let aboutWindow = aboutWindowController?.window, aboutWindow.isVisible else { return }
        aboutWindow.orderOut(nil)
    }

    /// 現在の EQ ウィンドウ位置を保存する。handleWindowHidden() に加えて、
    /// Cmd+Q 等で終了するケースをカバーするため、アプリの終了処理からも呼ぶ。
    func persistWindowOrigin() {
        guard let mode = appliedViewMode else { return }
        persistWindowOrigin(for: mode)
    }

    private func persistWindowOrigin(for mode: ViewMode) {
        guard let window = window else { return }
        settings.setWindowOrigin(
            SettingsStore.WindowOrigin(x: window.frame.origin.x, y: window.frame.origin.y), for: mode
        )
    }

    /// 保存済み位置が現在のディスプレイ構成でも画面内に収まるか判定する。ウィンドウが画面外へ
    /// 配置されて操作不能になるのを避けるため、復元前にいずれかの画面と重なるかを確認する。
    static func originIsOnScreen(_ origin: SettingsStore.WindowOrigin, size: NSSize) -> Bool {
        let frame = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    // MARK: - 周期処理 (可視性連動)

    /// ウィンドウの可視・ミニマイズの状態から、そのウィンドウのための周期処理を有効にすべきかを
    /// 決める準純粋関数。
    static func wantsWindowDrivenWorkActive(isVisible: Bool, isMiniaturized: Bool) -> Bool {
        isVisible && !isMiniaturized
    }

    /// 上の結果を診断の保持側へ反映する単一の入口。
    /// fileprivate なのは同一ファイル内の別型からも呼ぶため。
    fileprivate func updateDiagnosticsActive(isVisible: Bool, isMiniaturized: Bool) {
        diagnostics.active = EQWindowController.wantsWindowDrivenWorkActive(
            isVisible: isVisible, isMiniaturized: isMiniaturized
        )
    }

    /// 可視状態とミキサーの状態から 2 つの駆動条件を導く純粋関数。
    static func drivenWork(
        windowIsVisible: Bool, mixerShown: Bool, editing: Bool
    ) -> (visualizer: Bool, mixerMeters: Bool) {
        (
            visualizer: windowIsVisible && !mixerShown,
            mixerMeters: windowIsVisible && mixerShown && !editing
        )
    }

    /// 上の結果を駆動側へ反映する単一の入口。
    private func applyDrivenWork(shown: Bool, editing: Bool) {
        let wants = EQWindowController.drivenWork(
            windowIsVisible: windowIsVisible, mixerShown: shown, editing: editing
        )
        viewModel.visualizerActive = wants.visualizer
        mixerRenderClock?.active = wants.mixerMeters
    }

    private func updateDrivenWork() {
        applyDrivenWork(shown: mixer.shown, editing: mixer.editing)
    }

    /// ドライバ未検出の間は EQ ウィンドウを開くたびにインストールを促す (TopBar の警告チップとは
    /// 別に、能動的に知らせる導線)。
    private func promptDriverInstallIfNeeded() {
        guard viewModel.driverAvailability == .notFound else { return }
        let alert = NSAlert()
        alert.messageText = "SimpleEQ 専用ドライバーのインストールが必要です"
        alert.informativeText = "インストールしますか？（管理者権限が必要です）"
        alert.addButton(withTitle: "インストールする")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        viewModel.installOrUpdateDriver { [weak self] result in
            self?.handleDriverInstallResult(result)
        }
    }

    private func handleDriverInstallResult(_ result: Result<Void, DriverInstallCoordinator.ActionError>) {
        switch result {
        case .success:
            let done = NSAlert()
            done.messageText = DriverOperationPrompt.restartHeadline(
                operationTitle: DriverOperationPrompt.actionTitle(for: .notFound)
            )
            done.informativeText = DriverOperationPrompt.restartMessage
            done.addButton(withTitle: DriverOperationPrompt.restartConfirmTitle)
            done.addButton(withTitle: "キャンセル")
            if done.runModal() == .alertFirstButtonReturn {
                AppRelaunch.relaunch()
            }
        case .failure(.executionFailed(.cancelled)):
            // 管理者パスワードダイアログのユーザキャンセルは意図的な中断であり、失敗表示はせず
            // 静かに無視する。
            break
        case .failure:
            let failed = NSAlert()
            failed.messageText = "インストールに失敗しました"
            failed.alertStyle = .warning
            failed.addButton(withTitle: "OK")
            failed.runModal()
        }
    }

    // MARK: - NSWindowDelegate (可視性の変化を拾う)

    func windowWillClose(_ notification: Notification) {
        handleWindowHidden()
    }
}

final class EQMainWindow: NSWindow {
    /// Esc の行き先。
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandW = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == String(WindowVisibilityMenu.hideCommandKey)
        guard isCommandW else { return super.performKeyEquivalent(with: event) }
        close()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Diagnostics ウィンドウ専用の NSWindowDelegate。可視状態の変化を転送するだけの薄い転送役。
private final class DiagnosticsWindowDelegate: NSObject, NSWindowDelegate {
    private weak var owner: EQWindowController?

    init(owner: EQWindowController) {
        self.owner = owner
    }

    func windowWillClose(_ notification: Notification) {
        owner?.updateDiagnosticsActive(isVisible: false, isMiniaturized: false)
    }

    /// isVisible はミニマイズ中も真のまま (macOS の仕様) だが、isMiniaturized が真である以上
    /// wantsDiagnosticsActive は偽を返す。
    func windowDidMiniaturize(_ notification: Notification) {
        owner?.updateDiagnosticsActive(isVisible: true, isMiniaturized: true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        owner?.updateDiagnosticsActive(isVisible: true, isMiniaturized: false)
    }
}
