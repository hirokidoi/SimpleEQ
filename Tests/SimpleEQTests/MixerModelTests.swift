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
        identities: [String: MixerAppIdentity], clientIDs: [String: [UInt32]] = [:]
    ) -> MixerCoordinatorUpdate {
        MixerCoordinatorUpdate(identities: identities, clientIDsByChannelKey: clientIDs)
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

        model.apply(update(identities: [a: identity("A"), b: identity("B")]))
        XCTAssertEqual(model.candidates.map(\.key).sorted(), [a, b].sorted())

        model.setShown(true)
        model.beginEditing()
        model.toggleCheck(key: a)
        model.endEditing()
        XCTAssertEqual(model.candidates.map(\.key), [b], "チャンネルになったキーは候補から外れる")

        model.beginEditing()
        model.toggleCheck(key: a)
        model.endEditing()
        XCTAssertEqual(model.candidates.map(\.key).sorted(), [a, b].sorted(), "外した行は候補へ戻る")
    }

    /// 面を出していない間も辞書は貯まるため、出した直後から正しい候補が出る。
    func testCandidatesArriveWithoutTheMixerHavingBeenShown() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        let model = makeModel(settings)
        let key = MixerSpec.bundleKey("com.example.a")

        model.apply(update(identities: [key: identity("A")]))
        XCTAssertEqual(model.candidates.map(\.key), [key])
    }

    // MARK: - 編集モード

    private func makeShownModel(_ settings: SettingsStore) -> MixerModel {
        let model = makeModel(settings)
        model.setShown(true)
        return model
    }

    /// 抜けるまで一覧も永続化も動かない。
    func testNothingIsAppliedUntilEditingEnds() {
        let settings = SettingsStore(defaults: defaults)
        let key = MixerSpec.bundleKey("com.example.a")
        settings.mixerChannels = [SettingsStore.MixerChannelEntry(key: key, gain: 1, muted: false)]
        let model = makeShownModel(settings)

        model.beginEditing()
        model.toggleCheck(key: key)
        XCTAssertEqual(model.channels.map(\.key), [key])
        XCTAssertEqual(settings.mixerChannels?.map(\.key), [key])

        model.endEditing()
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(settings.mixerChannels?.isEmpty, true)
    }

    /// 残るのはチェックの入っている行で、並びは編集モードで置いたとおり。
    func testEndingEditingKeepsCheckedRowsInTheOrderTheyWerePut() {
        let settings = SettingsStore(defaults: defaults)
        let keys = ["a", "b", "c"].map { MixerSpec.bundleKey("com.example.\($0)") }
        settings.mixerChannels = keys.map {
            SettingsStore.MixerChannelEntry(key: $0, gain: 1, muted: false)
        }
        let model = makeShownModel(settings)

        model.beginEditing()
        model.moveEditRow(fromKey: keys[2], toKey: keys[0])
        model.endEditing()
        XCTAssertEqual(model.channels.map(\.key), [keys[2], keys[0], keys[1]])
        XCTAssertEqual(settings.mixerChannels?.map(\.key), [keys[2], keys[0], keys[1]])
    }

    /// 残した行の音量とミュートは編集モードを通っても変わらない。
    func testCheckedRowKeepsItsSettings() throws {
        let settings = SettingsStore(defaults: defaults)
        let key = MixerSpec.bundleKey("com.example.a")
        settings.mixerChannels = [SettingsStore.MixerChannelEntry(key: key, gain: 0.5, muted: true)]
        let model = makeShownModel(settings)
        // 保存の段へ丸められた値がそのまま残ることを見る (丸めた先の値は決め打ちしない)。
        let gainBefore = try XCTUnwrap(model.channels.first?.gain)

        model.beginEditing()
        model.endEditing()
        XCTAssertEqual(model.channels.first?.gain, gainBefore)
        XCTAssertEqual(model.channels.first?.muted, true)
    }

    /// 外した行の音量とミュートは残さない。
    func testUncheckedRowLosesItsSettings() {
        let settings = SettingsStore(defaults: defaults)
        let key = MixerSpec.bundleKey("com.example.a")
        settings.mixerChannels = [SettingsStore.MixerChannelEntry(key: key, gain: 0.5, muted: true)]
        let model = makeShownModel(settings)
        model.apply(update(identities: [key: identity("A")]))

        model.beginEditing()
        model.toggleCheck(key: key)
        model.endEditing()

        model.beginEditing()
        model.toggleCheck(key: key)
        model.endEditing()
        XCTAssertEqual(model.channels.first?.gain, MixerGainScale.unityGain)
        XCTAssertEqual(model.channels.first?.muted, false)
    }

    /// 編集モードの間は候補の顔ぶれを差し替えない。
    func testCandidatesAreFrozenWhileEditing() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        let model = makeShownModel(settings)
        let a = MixerSpec.bundleKey("com.example.a")
        let b = MixerSpec.bundleKey("com.example.b")

        model.apply(update(identities: [a: identity("A")]))
        model.beginEditing()
        XCTAssertEqual(model.editRows.map(\.key), [a])

        model.apply(update(identities: [a: identity("A"), b: identity("B")]))
        XCTAssertEqual(model.editRows.map(\.key), [a], "編集モードの間は増えない")
        XCTAssertEqual(model.candidates.map(\.key), [a])

        model.endEditing()
        model.beginEditing()
        XCTAssertEqual(model.editRows.map(\.key).sorted(), [a, b].sorted(), "抜けてから入り直せば増える")
    }

    func testChannelLimitStopsFurtherChecks() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = (0..<MixerSpec.maxChannelCount).map {
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.\($0)"), gain: 1, muted: false)
        }
        let model = makeShownModel(settings)
        let extra = MixerSpec.bundleKey("com.example.extra")
        model.apply(update(identities: [extra: identity("Extra")]))

        model.beginEditing()
        XCTAssertFalse(model.canCheckMore)
        model.toggleCheck(key: extra)
        XCTAssertEqual(model.editRows.filter(\.checked).count, MixerSpec.maxChannelCount)

        model.toggleCheck(key: MixerSpec.bundleKey("com.example.0"))
        XCTAssertTrue(model.canCheckMore)
        model.toggleCheck(key: extra)
        XCTAssertTrue(model.editRows.first { $0.key == extra }?.checked == true)
    }

    /// 面を降ろす操作は確定を通って編集モードを終える。
    func testEndingTheSurfaceCommitsThroughTheSameEntry() {
        let settings = SettingsStore(defaults: defaults)
        let key = MixerSpec.bundleKey("com.example.a")
        settings.mixerChannels = [SettingsStore.MixerChannelEntry(key: key, gain: 1, muted: false)]
        let model = makeShownModel(settings)

        model.beginEditing()
        model.toggleCheck(key: key)
        model.setShown(false)
        XCTAssertFalse(model.editing)
        XCTAssertFalse(model.shown)
        XCTAssertTrue(model.channels.isEmpty, "降ろす操作でも確定する")
    }

    /// 面が出ていなければ編集モードへ入らない。
    func testEditingRequiresTheSurfaceToBeShown() {
        let settings = SettingsStore(defaults: defaults)
        settings.mixerChannels = []
        let model = makeModel(settings)

        model.beginEditing()
        XCTAssertFalse(model.editing)
    }

    // MARK: - 行の操作と永続化

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
