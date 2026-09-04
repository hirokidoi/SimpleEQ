import AppKit

enum PresetMenuEntries {
    static func visiblePresets(title: (EQPreset) -> String) -> [EQPreset] {
        EQPreset.allCases.filter { !title($0).isEmpty }
    }
}

enum OutputDeviceMenuEntries {
    static func visibleOptions(
        canSelect: Bool, selection: String?, options: [OutputDeviceOption], fallbackLabel: String
    ) -> [OutputDeviceOption] {
        guard canSelect else { return [] }
        return resolvedOutputDevicePickerOptions(selection: selection, options: options, fallbackLabel: fallbackLabel)
    }
}

@MainActor
private final class MenuSection {
    struct Entry {
        let title: String
        let representedObject: Any?
        let isChecked: Bool
    }

    private let menu: NSMenu
    private let separator: NSMenuItem
    private let header: NSMenuItem
    private var items: [NSMenuItem] = []

    init(menu: NSMenu, title: String) {
        self.menu = menu
        separator = .separator()
        header = .sectionHeader(title: title)
        menu.addItem(separator)
        menu.addItem(header)
    }

    func rebuild(entries: [Entry], target: AnyObject, action: Selector) {
        for item in items { menu.removeItem(item) }
        items = []
        separator.isHidden = entries.isEmpty
        header.isHidden = entries.isEmpty
        let headerIndex = menu.index(of: header)
        guard headerIndex >= 0 else { return }
        for (offset, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = entry.representedObject
            item.state = entry.isChecked ? .on : .off
            menu.insertItem(item, at: headerIndex + 1 + offset)
            items.append(item)
        }
    }
}

/// メニューバー常駐アイコンとメニューを薄く配線する。クリックはメニューを開くだけでウィンドウの
/// 表示状態には触れない。表示/非表示はメニュー項目のトグルで操作する。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem: NSStatusItem
    private let windowController: EQWindowController
    private let viewModel: EQViewModel
    private let mixer: MixerModel
    private let diagnostics: DiagnosticsModel
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem!
    private var viewModeItem: NSMenuItem!
    private var mixerItem: NSMenuItem!
    private var presetSection: MenuSection!
    private var outputSection: MenuSection!
    /// option 押下時だけ見せる項目 (診断の項目群とその区切り線)。
    private var diagnosticsItems: [NSMenuItem] = []

    init(
        windowController: EQWindowController, viewModel: EQViewModel, mixer: MixerModel,
        diagnostics: DiagnosticsModel
    ) {
        self.windowController = windowController
        self.viewModel = viewModel
        self.mixer = mixer
        self.diagnostics = diagnostics
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = Self.makeMenuBarIcon()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private static func makeMenuBarIcon() -> NSImage {
        let heights = EQLayout.IconMotif.barHeightRatios
        let gapRatio = EQLayout.IconMotif.barGapRatio
        let size = NSSize(width: 20, height: 15)

        let image = NSImage(size: size, flipped: false) { rect in
            let barW = rect.width / (CGFloat(heights.count) + CGFloat(heights.count - 1) * gapRatio)
            let step = barW * (1 + gapRatio)
            NSColor.black.setFill()
            for (i, h) in heights.enumerated() {
                let barH = rect.height * h
                let barRect = NSRect(x: CGFloat(i) * step, y: 0, width: barW, height: barH)
                let cap = min(barW, barH) / 2
                NSBezierPath(roundedRect: barRect, xRadius: cap, yRadius: cap).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SimpleEQ"
        return image
    }

    private func buildMenu() {
        let item = NSMenuItem(title: "", action: #selector(toggleWindow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        toggleItem = item

        let modeItem = NSMenuItem(title: "", action: #selector(toggleViewMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)
        viewModeItem = modeItem

        let mixerMenuItem = NSMenuItem(title: "", action: #selector(toggleMixer), keyEquivalent: "")
        mixerMenuItem.target = self
        menu.addItem(mixerMenuItem)
        mixerItem = mixerMenuItem

        // action 名を openSettings にすると OS が標準の設定コマンドと見なして歯車アイコンを添える。
        let settingsItem = NSMenuItem(title: "EQ Settings", action: #selector(openSettingsWindow), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        presetSection = MenuSection(menu: menu, title: "プリセット")
        outputSection = MenuSection(menu: menu, title: "出力デバイス")

        menu.addItem(.separator())

        // option 押下時のみ現れる隠し導線。
        addDiagnosticsItem("Diagnostics を開く", #selector(openDiagnostics))
        addDiagnosticsItem("観測量をリセット", #selector(resetDiagnostics))
        addDiagnosticsItem("書き出し", #selector(exportDiagnostics))
        addDiagnosticsSeparator()

        let aboutItem = NSMenuItem(title: "About SimpleEQ", action: #selector(openAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func rebuildPresetItems() {
        let presets = viewModel.processingInEffect
            ? PresetMenuEntries.visiblePresets { viewModel.title(for: $0) }
            : []
        presetSection.rebuild(
            entries: presets.map {
                MenuSection.Entry(
                    title: viewModel.title(for: $0),
                    representedObject: $0,
                    isChecked: viewModel.selectedPreset == $0
                )
            },
            target: self,
            action: #selector(applyPreset(_:))
        )
    }

    private func rebuildOutputDeviceItems() {
        let selection = viewModel.sessionOutputDeviceUID
        let options = OutputDeviceMenuEntries.visibleOptions(
            canSelect: viewModel.canSelectOutputDevice,
            selection: selection,
            options: viewModel.availableOutputDeviceOptions,
            fallbackLabel: viewModel.resolvedOutputDeviceName
        )
        outputSection.rebuild(
            entries: options.map {
                MenuSection.Entry(title: $0.name, representedObject: $0.uid, isChecked: $0.uid == selection)
            },
            target: self,
            action: #selector(selectOutputDevice(_:))
        )
    }

    private func addDiagnosticsItem(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        diagnosticsItems.append(item)
    }

    private func addDiagnosticsSeparator() {
        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        diagnosticsItems.append(separator)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let toggle = WindowVisibilityMenu.toggle(isVisible: windowController.window?.isVisible ?? false)
        toggleItem.title = toggle.title
        toggleItem.setCommandShortcut(toggle.commandKey)
        viewModeItem.title = viewModel.viewMode.toggled.switchActionTitle
        mixerItem.title = MixerVisibilityMenu.toggle(isShown: mixer.shown)
        rebuildPresetItems()
        rebuildOutputDeviceItems()
        let showsDiagnostics = DiagnosticsEntry.isRevealed
        for item in diagnosticsItems { item.isHidden = !showsDiagnostics }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === viewModeItem else { return true }
        return windowController.window?.isVisible ?? false
    }

    @objc private func toggleWindow() {
        windowController.toggle()
    }

    @objc private func toggleViewMode() {
        viewModel.viewMode = viewModel.viewMode.toggled
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? EQPreset else { return }
        viewModel.applyPreset(preset)
    }

    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        viewModel.sessionOutputDeviceUID = uid
    }

    @objc private func openSettingsWindow() {
        windowController.showSettings()
    }

    @objc private func toggleMixer() {
        windowController.toggleMixer()
    }

    @objc private func openAboutWindow() {
        windowController.showAbout()
    }

    @objc private func openDiagnostics() {
        windowController.showDiagnostics()
    }

    /// 画面を開いていなくても撃てる (観測量の積み上げも書き出しも画面の開閉に依存しない)。
    @objc private func resetDiagnostics() {
        diagnostics.reset()
    }

    /// 撃った結果は Diagnostics 画面の「直近の書き出し」に残るため、ここでは何も表示しない。
    @objc private func exportDiagnostics() {
        diagnostics.export()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
