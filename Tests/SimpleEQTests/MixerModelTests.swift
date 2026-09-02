import XCTest
@testable import SimpleEQ

@MainActor
final class MixerModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("MixerModelTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeModel(_ settings: SettingsStore) -> MixerModel {
        MixerModel(settings: settings, coordinator: nil, levelStore: MixerLevelStore(slotCount: 4))
    }

    private func identity(_ name: String) -> MixerAppIdentity { MixerAppIdentity(displayName: name) }

    private func update(
        identities: [String: MixerAppIdentity], playing: Set<String> = [],
        clientIDs: [String: [UInt32]] = [:]
    ) -> MixerCoordinatorUpdate {
        MixerCoordinatorUpdate(identities: identities, playingKeys: playing, clientIDsByChannelKey: clientIDs)
    }

    // MARK: - 初期セット

    func testEmptyStoredChannelsAreNotReseeded() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        XCTAssertTrue(makeModel(settings).channels.isEmpty, "全部消した状態へ撒き直さない")
    }

    func testInitialSeedSpreadsOnlyInstalledAppsInTheDefinedOrder() {
        let installed = Set(MixerSpec.initialSeedBundleIDs.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element))
        let keys = MixerSpec.initialSeedChannelKeys { installed.contains($0) }

        XCTAssertEqual(keys, MixerSpec.initialSeedBundleIDs.filter(installed.contains).map(MixerSpec.bundleKey))
        XCTAssertTrue(MixerSpec.initialSeedChannelKeys { _ in false }.isEmpty)
    }

    func testInitialSeedListHasNoDuplicates() {
        XCTAssertEqual(Set(MixerSpec.initialSeedBundleIDs).count, MixerSpec.initialSeedBundleIDs.count)
    }

    /// 「まだ設定していない」へ戻せば起動時と同じ経路が走る。
    func testResetToInitialStateReturnsTheStoredValueToUnset() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = [
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.a"), gain: 0.5, muted: true),
        ]
        let model = makeModel(settings)
        XCTAssertEqual(model.channels.count, 1)

        model.resetToInitialState()
        XCTAssertNil(settings.mixerChannels)
        XCTAssertEqual(
            model.channels.map(\.key),
            MixerSpec.initialSeedChannelKeys(isInstalled: MixerAppDirectory.isInstalled)
        )
    }

    // MARK: - 候補プール

    func testCandidatePoolExcludesKeysThatAreAlreadyChannels() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        let model = makeModel(settings)
        let a = MixerSpec.bundleKey("com.example.a")
        let b = MixerSpec.bundleKey("com.example.b")

        model.apply(update(identities: [a: identity("A"), b: identity("B")], playing: [a]))
        XCTAssertEqual(model.candidates.map(\.key).sorted(), [a, b].sorted())
        XCTAssertEqual(model.candidates.first { $0.key == a }?.playing, true)

        model.add(key: a)
        XCTAssertEqual(model.candidates.map(\.key), [b], "チャンネルになったキーは候補から外れる")

        model.remove(key: a)
        XCTAssertEqual(model.candidates.map(\.key).sorted(), [a, b].sorted(), "外した行は候補へ戻る")
    }

    /// パネルを開いていない間も辞書は貯まるため、開いた直後から正しい候補が出る。
    func testCandidatesArriveWithoutThePanelHavingBeenOpened() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        let model = makeModel(settings)
        let key = MixerSpec.bundleKey("com.example.a")

        model.apply(update(identities: [key: identity("A")]))
        model.editing = true
        XCTAssertEqual(model.candidates.map(\.key), [key])
    }

    /// 開き直したときに編集モードが残らない。
    func testClosingThePanelLeavesEditMode() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        let model = makeModel(settings)

        model.editing = true
        model.panelDidClose()
        XCTAssertFalse(model.editing)
    }

    func testChannelLimitStopsFurtherAdditions() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = (0..<MixerSpec.maxChannelCount).map {
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.\($0)"), gain: 1, muted: false)
        }
        let model = makeModel(settings)
        XCTAssertFalse(model.canAddChannel)

        model.add(key: MixerSpec.bundleKey("com.example.extra"))
        XCTAssertEqual(model.channels.count, MixerSpec.maxChannelCount)

        model.remove(key: MixerSpec.bundleKey("com.example.0"))
        XCTAssertTrue(model.canAddChannel)
    }

    // MARK: - 行の操作と永続化

    func testReorderIsPersistedAsTheOrderTheUserPut() {
        let settings = SettingsStore(defaults: defaults)
        let keys = ["a", "b", "c"].map { MixerSpec.bundleKey("com.example.\($0)") }
        settings.mixerChannels = keys.map {
            SettingsStore.MixerChannelEntry(key: $0, gain: 1, muted: false)
        }
        let model = makeModel(settings)

        model.move(fromKey: keys[2], toKey: keys[0])
        XCTAssertEqual(model.channels.map(\.key), [keys[2], keys[0], keys[1]])
        XCTAssertEqual(settings.mixerChannels?.map(\.key), [keys[2], keys[0], keys[1]])
    }

    /// ドラッグ中の値は確定するまで行へ書かない (音への反映だけ先に行う)。
    func testGainIsWrittenToTheChannelOnlyOnCommit() {
        let settings = SettingsStore(defaults: defaults)
        let key = MixerSpec.bundleKey("com.example.a")
        settings.mixerChannels = [SettingsStore.MixerChannelEntry(key: key, gain: 1, muted: false)]
        let model = makeModel(settings)
        let target = MixerGainScale.gain(atPosition: 0.5)

        model.updateGainDuringDrag(target, for: key)
        XCTAssertEqual(model.gain(for: key), target, "ドラッグ中の値はここから読める")
        XCTAssertEqual(model.channels.first?.gain, MixerGainScale.unityGain)

        model.commitGain(for: key)
        XCTAssertEqual(model.channels.first?.gain, target)
        XCTAssertEqual(settings.mixerChannels?.first?.gain ?? 0, target, accuracy: 1e-9)
    }

    func testMutedChannelReportsSilenceAsItsEffectiveGain() {
        let settings = SettingsStore(defaults: defaults)
        let key = MixerSpec.bundleKey("com.example.a")
        settings.mixerChannels = [SettingsStore.MixerChannelEntry(key: key, gain: 0.5, muted: false)]
        let model = makeModel(settings)

        model.toggleMute(key: key)
        XCTAssertEqual(model.channels.first?.effectiveGain, MixerGainScale.silentGain)
        XCTAssertFalse(model.channels.first?.isDefault ?? true)

        model.resetToDefault(key: key)
        XCTAssertTrue(model.channels.first?.isDefault ?? false, "既定へ戻すは 0dB かつ非ミュート")
    }
}
