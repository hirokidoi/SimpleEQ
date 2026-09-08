import XCTest
@testable import SimpleEQ

@MainActor
final class SoundLabPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("SoundLabPersistenceTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func edited() -> SoundLabSettings {
        var s = SoundLabSettings()
        s.liveSimulation.enabled = true
        s.liveSimulation.room = .dome
        s.liveSimulation.mix = 60
        s.stereoExpander.enabled = true
        s.stereoExpander.width = 3.1
        s.stereoExpander.crossover = 1200
        s.stereoExpander.diffusionEnabled = false
        s.stereoExpander.diffusionAmount = 0.2
        s.bassHarmonics.enabled = true
        s.bassHarmonics.cutoff = 80
        s.bassHarmonics.drive = 9
        s.bassHarmonics.mix = 55
        s.trebleExciter.enabled = true
        s.trebleExciter.cutoff = 8000
        s.trebleExciter.drive = 3
        s.trebleExciter.mix = 45
        s.loudness.enabled = true
        s.loudness.amountDb = 9
        s.loudness.bassFrequency = 200
        s.loudness.trebleFrequency = 4000
        return s
    }

    func testDefaultsWhenNothingIsSaved() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.soundLab, SoundLabSettings())
    }

    func testSurvivesAcrossStores() {
        let written = edited()
        SettingsStore(defaults: defaults).soundLab = written
        XCTAssertEqual(SettingsStore(defaults: defaults).soundLab, written)
    }

    /// 保存形式は構造体をまるごと符号化するため、項が欠ければ全体が既定値へ戻る。
    /// 項目を足すときはこの代償を承知して足すこと。
    func testAnAbsentItemTakesTheWholeOfTheSettingsBackToDefaults() throws {
        let seeded = SettingsStore(defaults: defaults)
        let curve = (0..<EQSpec.bandCount).map { Double($0 % 7) - 3 }
        seeded.gains = curve
        seeded.savePreset(.slot2, curve: curve, title: "keep me")

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "soundLab")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: SettingsStore.defaultsKey)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.soundLab, SoundLabSettings())
        XCTAssertNotEqual(reloaded.gains, curve, "カーブも道連れになる")
        XCTAssertNotEqual(reloaded.title(for: .slot2), "keep me", "プリセットも道連れになる")
    }

    /// 操作値を足すと、保存済みの内容を読めなくなる。
    func testAddingAnItemToTheSettingsBreaksWhatIsAlreadySaved() throws {
        let seeded = SettingsStore(defaults: defaults)
        let curve = (0..<EQSpec.bandCount).map { Double($0 % 5) - 2 }
        seeded.gains = curve
        seeded.soundLab = edited()

        // 操作値がひとつ増える前の保存内容を作る。
        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var lab = try XCTUnwrap(object["soundLab"] as? [String: Any])
        var loudness = try XCTUnwrap(lab["loudness"] as? [String: Any])
        XCTAssertNotNil(loudness.removeValue(forKey: "amountDb"), "前提: 保存データにこの項目が載っていること")
        lab["loudness"] = loudness
        object["soundLab"] = lab
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: SettingsStore.defaultsKey)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.soundLab, SoundLabSettings())
        XCTAssertNotEqual(reloaded.gains, curve, "操作値の追加が保存済みの内容を丸ごと落とす")
    }

    func testValuesOutsideTheRangeAreBroughtBackIn() {
        var wild = SoundLabSettings()
        wild.stereoExpander.width = 99
        wild.stereoExpander.crossover = -5
        wild.bassHarmonics.drive = 1000
        wild.loudness.amountDb = -20
        wild.trebleExciter.mix = 900

        SettingsStore(defaults: defaults).soundLab = wild
        let read = SettingsStore(defaults: defaults).soundLab
        XCTAssertEqual(read.stereoExpander.width, StereoExpanderSettings.widthRange.bounds.upperBound)
        XCTAssertEqual(read.stereoExpander.crossover, StereoExpanderSettings.crossoverRange.bounds.lowerBound)
        XCTAssertEqual(read.bassHarmonics.drive, BassHarmonicsSettings.driveRange.bounds.upperBound)
        XCTAssertEqual(read.loudness.amountDb, LoudnessSettings.amountRange.bounds.lowerBound)
        XCTAssertEqual(read.trebleExciter.mix, TrebleExciterSettings.mixRange.bounds.upperBound)
    }

    /// 面を出すときは必ず App Mixer から始まるため、どのタブを見ていたかは保存しない。
    func testTheSurfaceTabIsNotPersisted() {
        func makeModel() -> MixerModel {
            MixerModel(
                settings: SettingsStore(defaults: defaults),
                coordinator: nil,
                levelStore: MixerLevelStore(slotCount: 4)
            )
        }
        let model = makeModel()
        model.select(tab: .soundLab(.bassHarmonics))
        XCTAssertEqual(model.tab, .soundLab(.bassHarmonics), "前提: 切り替わっている")
        XCTAssertEqual(makeModel().tab, .appMixer)
    }
}
