import AppKit
import XCTest
@testable import SimpleEQ

/// 引数のみに依存する部分だけ検証する。
@MainActor
final class EQWindowControllerTests: XCTestCase {
    private let size = EQLayout.windowDefaultSize

    func testViewModeTogglesBetweenTheTwoViews() {
        XCTAssertEqual(ViewMode.normal.toggled, .compact)
        XCTAssertEqual(ViewMode.compact.toggled, .normal)
    }

    // メニュー項目は「切り替えた先」を名乗る。
    func testSwitchActionTitleNamesTheDestinationView() {
        XCTAssertEqual(ViewMode.compact.switchActionTitle, "コンパクトビューに切り替え")
        XCTAssertEqual(ViewMode.normal.switchActionTitle, "ノーマルビューに切り替え")
    }

    // 段は下端から積むため、領域に満たないぶんは上端の余りになる。拡大率で刻みが変わると
    // ディスプレイによって余白が変わる。
    func testCompactSegmentsFillTheAreaAtEveryScale() {
        let height = EQLayout.compactLedHeight
        var steps: [CGFloat] = []
        for scale in [CGFloat(1), 2, 3] {
            let grid = EQLayout.SegmentGrid(
                height: height, bottomY: height,
                pixelGrid: EQLayout.PixelGrid(scale: scale), rowCount: EQLayout.compactRowCount
            )
            XCTAssertEqual(
                CGFloat(grid.rowCount) * grid.rowStep, height,
                "拡大率 \(scale) で段が領域をちょうど埋めること (上端に余りを残さない)"
            )
            steps.append(grid.rowStep)
        }
        XCTAssertEqual(Set(steps).count, 1, "拡大率によって刻みが変わらないこと")
    }

    func testEmptySlotHoverDoesNotShowHandles() {
        XCTAssertTrue(PresetHoverPreview.showsHandles(hoveringGroup: true, previewing: true))
        XCTAssertFalse(
            PresetHoverPreview.showsHandles(hoveringGroup: true, previewing: false),
            "プレビュー対象が無い (未登録の枠の上) ときは出さないこと"
        )
        XCTAssertFalse(PresetHoverPreview.showsHandles(hoveringGroup: false, previewing: true))
    }

    func testContentSizeFollowsTheViewMode() {
        XCTAssertEqual(EQWindowController.contentSize(for: .normal), EQLayout.windowDefaultSize)
        XCTAssertEqual(EQWindowController.contentSize(for: .compact), EQLayout.compactWindowDefaultSize)
    }

    // 復元では左上を保たない。保つと、コンパクトで保存した位置が起動ごとに上へずれて積み上がる。
    func testRestoredOriginIsTakenAsSavedOrDroppedWhenOffScreen() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("実行環境にディスプレイが存在しない")
        }
        let visible = screen.visibleFrame
        let inside = SettingsStore.WindowOrigin(x: Double(visible.midX), y: Double(visible.midY))
        let restored = try XCTUnwrap(
            EQWindowController.restoredOrigin(saved: inside, size: EQLayout.compactWindowDefaultSize)
        )
        XCTAssertEqual(restored.x, inside.x, "保存した位置をそのまま採ること")
        XCTAssertEqual(restored.y, inside.y, "保存した位置をそのまま採ること")

        let faraway = SettingsStore.WindowOrigin(x: Double(visible.maxX) + 10_000, y: Double(visible.maxY) + 10_000)
        XCTAssertNil(
            EQWindowController.restoredOrigin(saved: faraway, size: EQLayout.compactWindowDefaultSize),
            "画面に掛からない位置は捨てること"
        )
        XCTAssertNil(EQWindowController.restoredOrigin(saved: nil, size: EQLayout.windowDefaultSize))
    }

    func testPresetMenuOmitsSlotsWithoutTitle() {
        let titled: Set<EQPreset> = [.slot1, .slot3]
        let visible = PresetMenuEntries.visiblePresets { titled.contains($0) ? "名前" : "" }
        XCTAssertEqual(visible, [.slot1, .slot3], "タイトルの無い枠は並べないこと")

        XCTAssertEqual(
            PresetMenuEntries.visiblePresets { _ in "名前" }, EQPreset.allCases,
            "全部に名前があれば全部並ぶこと"
        )
        XCTAssertTrue(
            PresetMenuEntries.visiblePresets { _ in "" }.isEmpty,
            "1 つも名前が無ければ空になること (呼び出し側が区切り線ごと省く根拠になる)"
        )
    }

    func testOutputDeviceMenuOmitsSectionWhenUnselectable() {
        let options = [OutputDeviceOption(uid: "a", name: "スピーカー")]
        XCTAssertTrue(
            OutputDeviceMenuEntries.visibleOptions(
                canSelect: false, selection: "a", options: options, fallbackLabel: "解決済み"
            ).isEmpty,
            "選び直せない間は候補があっても空になること (呼び出し側が見出しごと省く根拠になる)"
        )
        XCTAssertTrue(
            OutputDeviceMenuEntries.visibleOptions(
                canSelect: true, selection: nil, options: [], fallbackLabel: "未設定"
            ).isEmpty,
            "候補も選択も無ければ空になること"
        )
    }

    func testOutputDeviceMenuMatchesPickerOptions() {
        let options = [OutputDeviceOption(uid: "a", name: "スピーカー"), OutputDeviceOption(uid: "b", name: "ヘッドホン")]
        XCTAssertEqual(
            OutputDeviceMenuEntries.visibleOptions(
                canSelect: true, selection: "b", options: options, fallbackLabel: "解決済み"
            ),
            resolvedOutputDevicePickerOptions(selection: "b", options: options, fallbackLabel: "解決済み"),
            "上部バーのピッカーと同じ並びになること"
        )
        XCTAssertEqual(
            OutputDeviceMenuEntries.visibleOptions(
                canSelect: true, selection: "missing", options: options, fallbackLabel: "解決済み"
            ).first,
            OutputDeviceOption(uid: "missing", name: "解決済み"),
            "候補に無い選択中の出力先は表示用の行として先頭に出ること"
        )
    }

    // ダブルクリック直後の 1 クリックは回数 3 として届く。ここを「2 以上」で見ると、その 1 回で
    // もう一度モードが切り替わる。
    func testOnlyExactlyTwoClicksInvokesDoubleClick() {
        XCTAssertFalse(WindowDragClick.invokesDoubleClick(clickCount: 1), "単発の押下は移動に使う")
        XCTAssertTrue(WindowDragClick.invokesDoubleClick(clickCount: 2), "ちょうど 2 回だけが対象")
        for count in 3...5 {
            XCTAssertFalse(WindowDragClick.invokesDoubleClick(clickCount: count), "\(count) 回目は対象にしない")
        }
    }

    func testVisibilityToggleCarriesShortcutOnlyWhenHiding() {
        let hiding = WindowVisibilityMenu.toggle(isVisible: true)
        XCTAssertEqual(hiding.title, WindowVisibilityMenu.hideTitle)
        XCTAssertEqual(hiding.commandKey, WindowVisibilityMenu.hideCommandKey)

        let showing = WindowVisibilityMenu.toggle(isVisible: false)
        XCTAssertEqual(showing.title, WindowVisibilityMenu.showTitle)
        XCTAssertNil(showing.commandKey, "表示側にショートカットを添えると、押しても開かないキーを見せることになる")
    }

    func testCommandShortcutClearsKeyEquivalentWhenAbsent() {
        let item = NSMenuItem()
        item.setCommandShortcut(WindowVisibilityMenu.hideCommandKey)
        XCTAssertEqual(item.keyEquivalent, String(WindowVisibilityMenu.hideCommandKey))
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)

        item.setCommandShortcut(nil)
        XCTAssertEqual(item.keyEquivalent, "", "付け外しを繰り返しても綴りが残らないこと")
    }

    func testOriginWithinVisibleFrameIsOnScreen() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("実行環境にディスプレイが存在しない")
        }
        let visible = screen.visibleFrame
        let origin = SettingsStore.WindowOrigin(x: visible.origin.x, y: visible.origin.y)
        XCTAssertTrue(EQWindowController.originIsOnScreen(origin, size: size))
    }

    func testOriginFarOffAllScreensIsNotOnScreen() throws {
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("実行環境にディスプレイが存在しない")
        }
        let farOutside = NSScreen.screens.reduce(0.0) { max($0, $1.frame.maxX) } + 100_000
        let origin = SettingsStore.WindowOrigin(x: farOutside, y: farOutside)
        XCTAssertFalse(EQWindowController.originIsOnScreen(origin, size: size))
    }

    // MARK: - heightLimit(currentHeight:scrollOverflow:minHeight:)

    func testHeightLimitIsTheHeightAtWhichScrollingIsNoLongerNeeded() {
        XCTAssertEqual(EQWindowController.heightLimit(currentHeight: 600, scrollOverflow: 300, minHeight: 420), 900)
        XCTAssertEqual(EQWindowController.heightLimit(currentHeight: 800, scrollOverflow: 100, minHeight: 420), 900)
    }

    func testHeightLimitShrinksWhenContentAlreadyFits() {
        XCTAssertEqual(EQWindowController.heightLimit(currentHeight: 900, scrollOverflow: -200, minHeight: 420), 700)
    }

    func testHeightLimitNeverFallsBelowTheMinimum() {
        XCTAssertEqual(EQWindowController.heightLimit(currentHeight: 450, scrollOverflow: -200, minHeight: 420), 420)
    }

    // MARK: - wantsWindowDrivenWorkActive(isVisible:isMiniaturized:)

    // isVisible/isMiniaturized の全組み合わせを網羅する。AppKit 配線自体の検証は対象外。
    func testWantsWindowDrivenWorkActiveIsTrueOnlyWhenVisibleAndNotMiniaturized() throws {
        for isVisible in [true, false] {
            for isMiniaturized in [true, false] {
                let expected = isVisible && !isMiniaturized
                XCTAssertEqual(
                    EQWindowController.wantsWindowDrivenWorkActive(
                        isVisible: isVisible, isMiniaturized: isMiniaturized
                    ),
                    expected,
                    "isVisible=\(isVisible) isMiniaturized=\(isMiniaturized)"
                )
            }
        }
    }

    // MARK: - drivenWork(windowIsVisible:mixerShown:editing:)

    // 3 つの入力の全組み合わせを網羅する。AppKit 配線自体の検証は対象外。
    func testDrivenWorkFollowsVisibilityAndTheMixerState() {
        for windowIsVisible in [true, false] {
            for mixerShown in [true, false] {
                for editing in [true, false] {
                    let wants = EQWindowController.drivenWork(
                        windowIsVisible: windowIsVisible, mixerShown: mixerShown, editing: editing
                    )
                    let label = "visible=\(windowIsVisible) shown=\(mixerShown) editing=\(editing)"
                    XCTAssertEqual(wants.visualizer, windowIsVisible && !mixerShown, "ビジュアライザ \(label)")
                    XCTAssertEqual(
                        wants.mixerMeters, windowIsVisible && mixerShown && !editing, "行のメーター \(label)"
                    )
                    XCTAssertFalse(
                        wants.visualizer && wants.mixerMeters, "両方が同時に回ることはない \(label)"
                    )
                }
            }
        }
    }
}
