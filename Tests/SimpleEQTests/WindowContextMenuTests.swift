import AppKit
import XCTest
@testable import SimpleEQ

@MainActor
final class WindowContextMenuTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("WindowContextMenuTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeModels() -> (viewModel: EQViewModel, mixer: MixerModel) {
        let settings = SettingsStore(defaults: defaults)
        let viewModel = EQViewModel(
            engine: AudioEngine(), settings: settings,
            outputController: OutputDeviceController(settings: settings, targetDeviceUID: "test-driver-uid"),
            audioWorld: makeTestAudioWorld()
        )
        let mixer = MixerModel(settings: settings, coordinator: nil, levelStore: MixerLevelStore(slotCount: 4))
        return (viewModel, mixer)
    }

    /// 並びの末尾ではなく文言で引く。項目が足されたときに別の項目を検証してしまわないため。
    private func mixerItem(viewModel: EQViewModel, mixer: MixerModel) throws -> WindowContextMenu.Item {
        let titles = [MixerVisibilityMenu.showTitle, MixerVisibilityMenu.closeTitle]
        let items = WindowContextMenu.items(viewModel: viewModel, mixer: mixer, hideWindow: {})
        let matched = items.filter { titles.contains($0.title) }
        XCTAssertEqual(matched.count, 1, "ミキサーの項目がちょうど 1 つあること")
        return try XCTUnwrap(matched.first)
    }

    // MARK: - MixerVisibilityMenu

    func testMixerMenuTitleNamesWhatTheOperationDoes() {
        XCTAssertEqual(MixerVisibilityMenu.toggle(isShown: false), MixerVisibilityMenu.showTitle)
        XCTAssertEqual(MixerVisibilityMenu.toggle(isShown: true), MixerVisibilityMenu.closeTitle)
        XCTAssertNotEqual(
            MixerVisibilityMenu.showTitle, MixerVisibilityMenu.closeTitle,
            "開くときと閉じるときで文言が入れ替わること"
        )
    }

    // MARK: - WindowContextMenu.items

    func testEveryItemCarriesADistinctIdentifier() {
        let models = makeModels()
        let items = WindowContextMenu.items(viewModel: models.viewModel, mixer: models.mixer, hideWindow: {})
        let titles = [
            WindowVisibilityMenu.hideTitle, AlwaysOnTopMenu.title,
            models.viewModel.viewMode.toggled.switchActionTitle,
            MixerVisibilityMenu.toggle(isShown: models.mixer.shown),
        ]
        XCTAssertEqual(items.map(\.title), titles, "並びと文言がこの 4 つであること")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "識別値が重なると項目が取り違えられる")
    }

    func testMixerItemTitleFollowsWhetherTheSurfaceIsShown() throws {
        let models = makeModels()
        XCTAssertEqual(
            try mixerItem(viewModel: models.viewModel, mixer: models.mixer).title,
            MixerVisibilityMenu.showTitle,
            "面が出ていないうちは出す側の文言"
        )

        models.mixer.setShown(true)
        XCTAssertEqual(
            try mixerItem(viewModel: models.viewModel, mixer: models.mixer).title,
            MixerVisibilityMenu.closeTitle,
            "面が出ている間は閉じる側の文言"
        )
    }

    func testMixerItemTogglesTheSurface() throws {
        let models = makeModels()
        guard case .action(let perform) = try mixerItem(viewModel: models.viewModel, mixer: models.mixer).kind else {
            return XCTFail("ミキサーの項目は押して働く種類であること")
        }
        perform()
        XCTAssertTrue(models.mixer.shown, "押すと面が出ること")

        guard case .action(let close) = try mixerItem(viewModel: models.viewModel, mixer: models.mixer).kind else {
            return XCTFail("ミキサーの項目は押して働く種類であること")
        }
        close()
        XCTAssertFalse(models.mixer.shown, "もう一度押すと閉じること")
    }

    // ビューモードを動かすのは切り替えの項目だけ。ミキサーの項目はどちらのビューでも面だけを動かす。
    func testMixerItemLeavesTheViewModeAlone() throws {
        for mode in ViewMode.allCases {
            let models = makeModels()
            models.viewModel.viewMode = mode
            guard case .action(let perform) =
                try mixerItem(viewModel: models.viewModel, mixer: models.mixer).kind else {
                return XCTFail("ミキサーの項目は押して働く種類であること")
            }
            perform()
            XCTAssertEqual(models.viewModel.viewMode, mode, "\(mode) のまま面だけが動くこと")
            XCTAssertTrue(models.mixer.shown)
        }
    }

    // MARK: - WindowContextMenu.nsMenu

    func testTheMenuCarriesTheSameItemsAsTheDefinition() {
        let models = makeModels()
        let items = WindowContextMenu.items(viewModel: models.viewModel, mixer: models.mixer, hideWindow: {})
        let menu = WindowContextMenu.nsMenu(viewModel: models.viewModel, mixer: models.mixer, hideWindow: {})

        XCTAssertEqual(menu.items.map(\.title), items.map(\.title), "並びと文言が定義どおりであること")
        XCTAssertEqual(
            menu.items.map(\.keyEquivalent),
            items.map { $0.commandKey.map(String.init) ?? "" },
            "ショートカットが定義どおりであること"
        )
    }

    func testTheToggleItemCarriesTheCurrentState() {
        let models = makeModels()
        models.viewModel.alwaysOnTop = true
        let onMenu = WindowContextMenu.nsMenu(viewModel: models.viewModel, mixer: models.mixer, hideWindow: {})
        XCTAssertEqual(onMenu.item(withTitle: AlwaysOnTopMenu.title)?.state, .on)

        models.viewModel.alwaysOnTop = false
        let offMenu = WindowContextMenu.nsMenu(viewModel: models.viewModel, mixer: models.mixer, hideWindow: {})
        XCTAssertEqual(offMenu.item(withTitle: AlwaysOnTopMenu.title)?.state, .off)
    }

    /// 項目を実際に送って効果まで見る。
    /// 押して働くものと状態を持つもののどちらも、送り先が生きていなければここで落ちる。
    func testSendingAnItemReachesWhatItStandsFor() throws {
        let models = makeModels()
        var hidden = false
        let menu = WindowContextMenu.nsMenu(viewModel: models.viewModel, mixer: models.mixer) { hidden = true }

        try send(menu.item(withTitle: WindowVisibilityMenu.hideTitle))
        XCTAssertTrue(hidden, "非表示の項目が渡された処理へ届くこと")

        try send(menu.item(withTitle: MixerVisibilityMenu.toggle(isShown: models.mixer.shown)))
        XCTAssertTrue(models.mixer.shown, "ミキサーの項目が面を出すこと")

        XCTAssertFalse(models.viewModel.alwaysOnTop)
        try send(menu.item(withTitle: AlwaysOnTopMenu.title))
        XCTAssertTrue(models.viewModel.alwaysOnTop, "状態を持つ項目が値を反転させること")
    }

    private func send(_ item: NSMenuItem?) throws {
        let item = try XCTUnwrap(item, "項目が見つかること")
        let target = try XCTUnwrap(item.target as? NSObject, "送り先が生きていること")
        let action = try XCTUnwrap(item.action, "動作が決まっていること")
        XCTAssertTrue(target.responds(to: action), "送り先がその動作に応じること")
        target.perform(action, with: item)
    }
}
