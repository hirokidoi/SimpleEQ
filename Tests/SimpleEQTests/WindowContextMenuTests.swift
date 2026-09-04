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
}
