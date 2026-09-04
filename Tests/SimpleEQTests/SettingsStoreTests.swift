import XCTest
@testable import SimpleEQ

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    // 非同期版の setUp を使う (同期版はこの検証が要る隔離を持たない)。
    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("SettingsStoreTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// 既定値 (初回起動、またはスキーマ非互換によるデコード失敗時の再構築) を検証する共通アサーション。
    private func assertResetToDefaults(_ store: SettingsStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.gains, EQSpec.builtInSeeds[.slot1]?.curve, file: file, line: line)
        XCTAssertEqual(store.preset, .slot1, file: file, line: line)
        XCTAssertFalse(store.bypass, file: file, line: line)
        XCTAssertNil(store.savedDefaultOutputUID, file: file, line: line)
        XCTAssertFalse(store.switchPending, file: file, line: line)
        XCTAssertTrue(store.preampAutoEnabled, file: file, line: line)
        XCTAssertEqual(store.preampAutoTargetDb, AutoPreampSpec.targetDbDefault, file: file, line: line)
        XCTAssertFalse(store.alwaysOnTop, file: file, line: line)
        XCTAssertFalse(store.showWindowOnLaunch, file: file, line: line)
        XCTAssertNil(store.outputDeviceUID, file: file, line: line)
        XCTAssertEqual(store.visualizerFps, EQLayout.Tuning.visualizerFpsDefault, file: file, line: line)
        XCTAssertEqual(store.attackLevel, EQLayout.Tuning.attack.defaultLevel, file: file, line: line)
        XCTAssertEqual(store.handleRevealGesture, .longPress, file: file, line: line)
    }

    func testDefaultsAreFlatPresetAndNoRestoreState() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.gains, EQSpec.builtInSeeds[.slot1]?.curve)
        XCTAssertEqual(store.preset, .slot1)
        XCTAssertFalse(store.bypass)
        XCTAssertNil(store.savedDefaultOutputUID)
        XCTAssertFalse(store.switchPending)
    }

    func testGainsPresetBypassRoundTripAcrossInstances() {
        let store = SettingsStore(defaults: defaults)
        let gains = (0..<EQSpec.bandCount).map { Double($0) - 10 }
        store.gains = gains
        store.preset = .slot3
        store.bypass = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.gains, gains)
        XCTAssertEqual(reloaded.preset, .slot3)
        XCTAssertTrue(reloaded.bypass)
    }

    func testSavedDefaultOutputUIDAndSwitchPendingRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.savedDefaultOutputUID = "OtherDevice_UID_00000000"
        store.switchPending = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.savedDefaultOutputUID, "OtherDevice_UID_00000000")
        XCTAssertTrue(reloaded.switchPending)
    }

    func testSwitchPendingClearsIndependentlyOfSavedUID() {
        let store = SettingsStore(defaults: defaults)
        store.savedDefaultOutputUID = "some-uid"
        store.switchPending = true
        store.switchPending = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.savedDefaultOutputUID, "some-uid")
        XCTAssertFalse(reloaded.switchPending)
    }

    func testAlwaysOnTopDefaultsFalse() {
        XCTAssertFalse(SettingsStore(defaults: defaults).alwaysOnTop)
    }

    func testAlwaysOnTopRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.alwaysOnTop = true
        XCTAssertTrue(SettingsStore(defaults: defaults).alwaysOnTop)
    }

    func testLoadingSchemaFromBeforeAlwaysOnTopResetsAllSettingsToDefaults() {
        let gains = (0..<EQSpec.bandCount).map { Double($0) }
        let oldSchema: [String: Any] = [
            "gains": gains,
            "preset": EQPreset.slot3.rawValue,
            "bypass": true,
            "savedDefaultOutputUID": "old-uid",
            "switchPending": true
            // alwaysOnTop 以降のキーは意図的に含めない (最古スキーマ再現)
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
    }

    func testShowWindowOnLaunchDefaultsFalse() {
        XCTAssertFalse(SettingsStore(defaults: defaults).showWindowOnLaunch)
    }

    func testShowWindowOnLaunchRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.showWindowOnLaunch = true
        XCTAssertTrue(SettingsStore(defaults: defaults).showWindowOnLaunch)
    }

    func testLoadingSchemaFromBeforeShowWindowOnLaunchResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": true
            // showWindowOnLaunch 以降のキーは意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
    }

    func testViewModeDefaultsToNormal() {
        XCTAssertEqual(SettingsStore(defaults: defaults).viewMode, .normal)
    }

    func testViewModeRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.viewMode = .compact
        XCTAssertEqual(SettingsStore(defaults: defaults).viewMode, .compact)
    }

    // この項目を持たない保存データを読むと、構造体まるごとの復号に失敗し全項目が既定値へ戻ること。
    func testLoadingDataWithoutViewModeResetsAllSettingsToDefaults() throws {
        let store = SettingsStore(defaults: defaults)
        store.alwaysOnTop = true
        store.showWindowOnLaunch = true
        store.viewMode = .compact

        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "viewMode"), "前提: 保存データにこの項目が載っていること")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertEqual(SettingsStore(defaults: defaults).viewMode, .normal)
    }

    func testHandleRevealGestureDefaultsToTheLongPress() {
        XCTAssertEqual(SettingsStore(defaults: defaults).handleRevealGesture, .longPress)
    }

    func testHandleRevealGestureRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.handleRevealGesture = .click
        XCTAssertEqual(SettingsStore(defaults: defaults).handleRevealGesture, .click)
    }

    // この項目を持たない保存データを読むと、構造体まるごとの復号に失敗し全項目が既定値へ戻ること。
    func testLoadingDataWithoutHandleRevealGestureResetsAllSettingsToDefaults() throws {
        let store = SettingsStore(defaults: defaults)
        store.alwaysOnTop = true
        store.showWindowOnLaunch = true
        store.handleRevealGesture = .click

        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "handleRevealGesture"), "前提: 保存データにこの項目が載っていること")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
    }

    // 出力デバイス UID の既定は未設定 (nil)。
    func testOutputDeviceUIDDefaultsToNil() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.outputDeviceUID)
    }

    func testOutputDeviceUIDRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.outputDeviceUID = "vg280k-uid"
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.outputDeviceUID, "vg280k-uid")
    }

    func testLoadingSchemaWithOutputDeviceNameKeyResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "outputDeviceName": "VG280K"
            // outputDeviceUID 以降のキーは意図的に含めない (最古スキーマ再現)
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
    }

    func testDirectValueTuningDefaultsMatchEQLayoutTuning() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.visualizerFps, EQLayout.Tuning.visualizerFpsDefault)
        XCTAssertEqual(store.floorDb, EQLayout.Tuning.floorDbDefault)
        XCTAssertEqual(store.peakHoldSeconds, EQLayout.Tuning.peakHoldSecondsDefault)
        XCTAssertEqual(store.peakDecayDbPerSec, EQLayout.Tuning.peakDecayDbPerSecDefault)
        XCTAssertEqual(store.peakCapBrightenAmount, EQLayout.Tuning.peakCapBrightenAmountDefault)
    }

    func testDirectValueTuningRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        // 既定値そのものを書くと、保存されていなくても一致してしまうため隣の段を使う。
        let probeFps = EQLayout.Tuning.visualizerFpsChoices.first { $0 != EQLayout.Tuning.visualizerFpsDefault }!
        store.visualizerFps = probeFps
        store.floorDb = -90
        store.peakHoldSeconds = 0.5
        store.peakDecayDbPerSec = 50
        store.peakCapBrightenAmount = 0.8
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.visualizerFps, probeFps)
        XCTAssertEqual(reloaded.floorDb, -90)
        XCTAssertEqual(reloaded.peakHoldSeconds, 0.5)
        XCTAssertEqual(reloaded.peakDecayDbPerSec, 50)
        XCTAssertEqual(reloaded.peakCapBrightenAmount, 0.8)
    }

    // MARK: - 外から読んだ値の健全化

    /// 全キーが揃った保存データを書き、指定したキーだけを差し替える。
    private func writeStoredPayload(overriding overrides: [String: Any]) {
        var payload: [String: Any] = [
            "gains": Array(repeating: 0.0, count: EQSpec.bandCount),
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "showLevelMeter": true,
            "adoptsSystemOutputSelection": true,
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault,
            "floorDb": EQLayout.Tuning.floorDbDefault,
            "attackLevel": EQLayout.Tuning.attack.defaultLevel,
            "releaseLevel": EQLayout.Tuning.release.defaultLevel,
            "handleFadeLevel": EQLayout.Tuning.handleFade.defaultLevel,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.defaultLevel,
            "peakHoldEnabled": true,
            "peakHoldSeconds": EQLayout.Tuning.peakHoldSecondsDefault,
            "peakDecayDbPerSec": EQLayout.Tuning.peakDecayDbPerSecDefault,
            "peakCapBrightenAmount": EQLayout.Tuning.peakCapBrightenAmountDefault,
            "presetOverrides": [String: Any](),
            "preampDb": 0.0,
            "viewMode": ViewMode.normal.rawValue,
            "preampAutoEnabled": true,
            "preampAutoTargetDb": AutoPreampSpec.targetDbDefault,
            "handleRevealGesture": HandleRevealGesture.default.rawValue
        ]
        overrides.forEach { payload[$0.key] = $0.value }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: SettingsStore.defaultsKey)
    }

    // デコードに失敗すると、以降の検証が既定値と一致しただけで通ってしまう。
    func testStoredPayloadFixtureDecodes() {
        let probe = EQLayout.Tuning.floorDbDefault - EQLayout.Tuning.floorDbStep
        XCTAssertTrue(EQLayout.Tuning.floorDbRange.contains(probe), "前提: 隣の段がレンジに収まること")
        writeStoredPayload(overriding: ["floorDb": probe])
        XCTAssertEqual(SettingsStore(defaults: defaults).floorDb, probe)
    }

    func testOutOfRangeDirectValuesAreSanitizedPerItemRule() {
        writeStoredPayload(overriding: [
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault + 1,
            "floorDb": EQLayout.Tuning.floorDbRange.lowerBound - 30,
            "peakHoldSeconds": EQLayout.Tuning.peakHoldSecondsRange.upperBound + 10,
            "peakDecayDbPerSec": EQLayout.Tuning.peakDecayDbPerSecRange.lowerBound - 10,
            "peakCapBrightenAmount": EQLayout.Tuning.peakCapBrightenAmountRange.upperBound + 1
        ])
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.visualizerFps, EQLayout.Tuning.visualizerFpsDefault)
        XCTAssertEqual(store.floorDb, EQLayout.Tuning.floorDbRange.lowerBound)
        XCTAssertEqual(store.peakHoldSeconds, EQLayout.Tuning.peakHoldSecondsRange.upperBound)
        XCTAssertEqual(store.peakDecayDbPerSec, EQLayout.Tuning.peakDecayDbPerSecRange.lowerBound)
        XCTAssertEqual(store.peakCapBrightenAmount, EQLayout.Tuning.peakCapBrightenAmountRange.upperBound)
    }

    // 段は 1 始まりで、上端は並びの長さが決める。
    func testOutOfRangeLevelsClampToScaleEnds() {
        writeStoredPayload(overriding: [
            "attackLevel": 0,
            "releaseLevel": EQLayout.Tuning.release.values.count + 5,
            "handleFadeLevel": -3,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.values.count + 1
        ])
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.attackLevel, 1)
        XCTAssertEqual(store.releaseLevel, EQLayout.Tuning.release.values.count)
        XCTAssertEqual(store.handleFadeLevel, 1)
        XCTAssertEqual(store.handlePreviewLevel, EQLayout.Tuning.handlePreview.values.count)
    }

    // 表示側はバンド数ぶんの添字アクセスを行うため、要素数の不足は読み込みの時点で埋める。
    func testShortGainsArrayIsPaddedToBandCount() {
        let head = [1.0, 2.0, 3.0]
        writeStoredPayload(overriding: ["gains": head])
        let gains = SettingsStore(defaults: defaults).gains
        XCTAssertEqual(gains.count, EQSpec.bandCount)
        XCTAssertEqual(Array(gains.prefix(head.count)), head)
        XCTAssertEqual(
            Array(gains.dropFirst(head.count)),
            Array(repeating: 0, count: EQSpec.bandCount - head.count)
        )
    }

    func testLongGainsArrayIsTruncatedToBandCount() {
        writeStoredPayload(overriding: [
            "gains": Array(repeating: 1.0, count: EQSpec.bandCount + 7)
        ])
        XCTAssertEqual(SettingsStore(defaults: defaults).gains.count, EQSpec.bandCount)
    }

    func testGainsAndPreampOutsideDbRangeAreClamped() {
        writeStoredPayload(overriding: [
            "gains": Array(repeating: EQSpec.DB_MAX + 50, count: EQSpec.bandCount),
            "preampDb": EQSpec.DB_MIN - 50
        ])
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.gains, Array(repeating: EQSpec.DB_MAX, count: EQSpec.bandCount))
        XCTAssertEqual(store.preampDb, EQSpec.DB_MIN)
    }

    func testPresetOverrideCurveIsNormalized() {
        writeStoredPayload(overriding: [
            "presetOverrides": [
                EQPreset.slot4.rawValue: ["title": "Short", "curve": [EQSpec.DB_MAX + 50]]
            ]
        ])
        let store = SettingsStore(defaults: defaults)
        let curve = store.curve(for: .slot4)
        XCTAssertEqual(curve.count, EQSpec.bandCount)
        XCTAssertEqual(curve.first, EQSpec.DB_MAX)
        XCTAssertEqual(Array(curve.dropFirst()), Array(repeating: 0, count: EQSpec.bandCount - 1))
    }

    // 入力の口・保存の口と同じ規則で切り詰める。
    func testPresetOverrideTitleIsClampedToMaxWidth() {
        // 全角は幅 2 として数えるため、上限と同じ文字数でも幅は上限を超える。
        let long = String(repeating: "あ", count: EQLayout.presetTitleMaxWidth)
        writeStoredPayload(overriding: [
            "presetOverrides": [
                EQPreset.slot4.rawValue: [
                    "title": long,
                    "curve": Array(repeating: 0.0, count: EQSpec.bandCount)
                ]
            ]
        ])
        let title = SettingsStore(defaults: defaults).title(for: .slot4)
        XCTAssertNotEqual(title, long)
        XCTAssertTrue(long.hasPrefix(title), "先頭から切り詰めること")
        XCTAssertEqual(title, EQLayout.clampToPresetTitleMaxWidth(long), "保存の口と同じ規則を通すこと")
    }

    func testPeakHoldEnabledDefaultsTrue() {
        XCTAssertTrue(SettingsStore(defaults: defaults).peakHoldEnabled)
    }

    func testPeakHoldEnabledRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.peakHoldEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).peakHoldEnabled)
    }

    // レベル系の既定は項目ごとに持つ (立ち上がりだけ最も機敏な段、残りは真ん中の段)。
    func testLevelTuningDefaultsToDefaultLevel() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.attackLevel, EQLayout.Tuning.attack.defaultLevel)
        XCTAssertEqual(store.releaseLevel, EQLayout.Tuning.release.defaultLevel)
        XCTAssertEqual(store.handleFadeLevel, EQLayout.Tuning.handleFade.defaultLevel)
        XCTAssertEqual(store.handlePreviewLevel, EQLayout.Tuning.handlePreview.defaultLevel)
    }

    func testLevelTuningRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.attackLevel = 5
        store.releaseLevel = 1
        store.handleFadeLevel = 4
        store.handlePreviewLevel = 2
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.attackLevel, 5)
        XCTAssertEqual(reloaded.releaseLevel, 1)
        XCTAssertEqual(reloaded.handleFadeLevel, 4)
        XCTAssertEqual(reloaded.handlePreviewLevel, 2)
    }

    func testLoadingSchemaFromBeforeSettingsScreenKeysResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false
            // Settings 画面向けの新規キー (presetOverrides 含む) は意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
    }

    func testShowLevelMeterDefaultsToTrueAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.showLevelMeter)
        store.showLevelMeter = false
        XCTAssertFalse(SettingsStore(defaults: defaults).showLevelMeter)
    }

    func testLoadingSchemaFromBeforeLevelMeterToggleResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "outputDeviceUID": NSNull(),
            "autoRestoreOnExit": true,
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault,
            "floorDb": EQLayout.Tuning.floorDbDefault,
            "attackLevel": EQLayout.Tuning.attack.defaultLevel,
            "releaseLevel": EQLayout.Tuning.release.defaultLevel,
            "handleFadeLevel": EQLayout.Tuning.handleFade.defaultLevel,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.defaultLevel,
            "presetOverrides": [String: Any](),
            "windowOrigin": NSNull(),
            "preampDb": 0,
            "peakHoldEnabled": true,
            "peakHoldSeconds": EQLayout.Tuning.peakHoldSecondsDefault,
            "peakDecayDbPerSec": EQLayout.Tuning.peakDecayDbPerSecDefault,
            "peakCapBrightenAmount": EQLayout.Tuning.peakCapBrightenAmountDefault
            // showLevelMeter は意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertTrue(SettingsStore(defaults: defaults).showLevelMeter)
    }

    func testAdoptsSystemOutputSelectionDefaultsToTrueAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.adoptsSystemOutputSelection)
        store.adoptsSystemOutputSelection = false
        XCTAssertFalse(SettingsStore(defaults: defaults).adoptsSystemOutputSelection)
    }

    func testLoadingSchemaFromBeforeOutputAdoptionToggleResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "showLevelMeter": true,
            "outputDeviceUID": NSNull(),
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault,
            "floorDb": EQLayout.Tuning.floorDbDefault,
            "attackLevel": EQLayout.Tuning.attack.defaultLevel,
            "releaseLevel": EQLayout.Tuning.release.defaultLevel,
            "handleFadeLevel": EQLayout.Tuning.handleFade.defaultLevel,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.defaultLevel,
            "presetOverrides": [String: Any](),
            "windowOrigin": NSNull(),
            "viewMode": ViewMode.normal.rawValue,
            "preampDb": 0,
            "peakHoldEnabled": true,
            "peakHoldSeconds": EQLayout.Tuning.peakHoldSecondsDefault,
            "peakDecayDbPerSec": EQLayout.Tuning.peakDecayDbPerSecDefault,
            "peakCapBrightenAmount": EQLayout.Tuning.peakCapBrightenAmountDefault
            // adoptsSystemOutputSelection は意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertTrue(SettingsStore(defaults: defaults).adoptsSystemOutputSelection)
    }

    func testUnsavedPresetUsesDefaultTitleAndCurve() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.title(for: .slot4), "")
        XCTAssertEqual(store.curve(for: .slot1), EQSpec.builtInSeeds[.slot1]?.curve)
        XCTAssertEqual(store.curve(for: .slot4), Array(repeating: 0, count: EQSpec.bandCount))
    }

    /// 枠ごとに異なる値を持ち、ゲインの範囲に収まるカーブ。範囲外の値を含めると、読み込み時の
    /// 健全化で丸められて往復の検証にならない。
    private static func distinctCurve() -> [Double] {
        (0..<EQSpec.bandCount).map { EQSpec.clampDb(EQSpec.DB_MIN + Double($0)) }
    }

    func testSavePresetOverridesTitleAndCurve() {
        let store = SettingsStore(defaults: defaults)
        let curve = Self.distinctCurve()
        store.savePreset(.slot4, curve: curve, title: "My Curve")

        XCTAssertEqual(store.title(for: .slot4), "My Curve")
        XCTAssertEqual(store.curve(for: .slot4), curve)
        // 他プリセットは影響を受けない。
        XCTAssertEqual(store.title(for: .slot1), EQSpec.builtInSeeds[.slot1]?.title)
        XCTAssertEqual(store.curve(for: .slot1), EQSpec.builtInSeeds[.slot1]?.curve)
    }

    func testDeletePresetClearsTitleAndCurve() {
        let store = SettingsStore(defaults: defaults)
        let curve = Self.distinctCurve()
        store.savePreset(.slot4, curve: curve, title: "My Curve")

        store.deletePreset(.slot4)

        XCTAssertEqual(store.title(for: .slot4), "")
        XCTAssertEqual(store.curve(for: .slot4), Array(repeating: 0, count: EQSpec.bandCount))
    }

    func testResetAllPresetsRestoresBuiltInDefaults() {
        let store = SettingsStore(defaults: defaults)
        let curve = Self.distinctCurve()
        store.savePreset(.slot2, curve: curve, title: "Renamed")
        store.savePreset(.slot4, curve: curve, title: "My Curve")

        store.resetAllPresets()

        // 組み込みの識別を持つ枠はその既定タイトル・カーブへ完全復元する。
        for preset in [EQPreset.slot1, .slot2, .slot3] {
            XCTAssertEqual(store.title(for: preset), EQSpec.builtInSeeds[preset]?.title)
            XCTAssertEqual(store.curve(for: preset), EQSpec.builtInSeeds[preset]?.curve)
        }
        // 組み込みカーブを持たない枠は、削除済みと同じ空状態に戻る。
        for preset in [EQPreset.slot4, .slot5] {
            XCTAssertEqual(store.title(for: preset), "")
            XCTAssertEqual(store.curve(for: preset), Array(repeating: 0, count: EQSpec.bandCount))
        }
    }

    func testSavePresetOverrideRoundTripsAcrossInstances() {
        let store = SettingsStore(defaults: defaults)
        let curve = Self.distinctCurve()
        store.savePreset(.slot2, curve: curve, title: "Renamed")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.title(for: .slot2), "Renamed")
        XCTAssertEqual(reloaded.curve(for: .slot2), curve)
    }

    // ウィンドウ位置の既定は未設定 (nil)。
    func testWindowOriginDefaultsToNil() {
        let store = SettingsStore(defaults: defaults)
        for mode in ViewMode.allCases {
            XCTAssertNil(store.windowOrigin(for: mode))
        }
    }

    // ビューごとに別々の位置を持つ。片方を保存してももう片方へ混ざらない。
    func testWindowOriginIsKeptPerViewMode() {
        let store = SettingsStore(defaults: defaults)
        store.setWindowOrigin(SettingsStore.WindowOrigin(x: 120, y: 340), for: .normal)
        store.setWindowOrigin(SettingsStore.WindowOrigin(x: 900, y: 20), for: .compact)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.windowOrigin(for: .normal)?.x, 120)
        XCTAssertEqual(reloaded.windowOrigin(for: .normal)?.y, 340)
        XCTAssertEqual(reloaded.windowOrigin(for: .compact)?.x, 900)
        XCTAssertEqual(reloaded.windowOrigin(for: .compact)?.y, 20)
    }

    func testPreampDbDefaultsToZero() {
        XCTAssertEqual(SettingsStore(defaults: defaults).preampDb, 0)
    }

    func testPreampDbRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.preampDb = -3
        XCTAssertEqual(SettingsStore(defaults: defaults).preampDb, -3)
    }

    func testPreampAutoEnabledDefaultsTrueAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.preampAutoEnabled)
        store.preampAutoEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).preampAutoEnabled)
    }

    func testPreampAutoTargetDbDefaultsAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.preampAutoTargetDb, AutoPreampSpec.targetDbDefault)
        store.preampAutoTargetDb = AutoPreampSpec.targetDbRange.upperBound
        XCTAssertEqual(SettingsStore(defaults: defaults).preampAutoTargetDb, AutoPreampSpec.targetDbRange.upperBound)
    }

    // 各キーを 1 つ落とした保存データで全項目が既定へ戻ること (2 本)。
    func testLoadingDataWithoutPreampAutoEnabledResetsAllSettingsToDefaults() throws {
        writeStoredPayload(overriding: [:])
        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "preampAutoEnabled"), "前提: 保存データにこの項目が載っていること")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertTrue(SettingsStore(defaults: defaults).preampAutoEnabled)
    }

    func testLoadingDataWithoutPreampAutoTargetDbResetsAllSettingsToDefaults() throws {
        writeStoredPayload(overriding: [:])
        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "preampAutoTargetDb"), "前提: 保存データにこの項目が載っていること")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertEqual(SettingsStore(defaults: defaults).preampAutoTargetDb, AutoPreampSpec.targetDbDefault)
    }

    func testPreampAutoTargetDbOutOfRangeIsClampedOnLoad() {
        writeStoredPayload(overriding: ["preampAutoTargetDb": AutoPreampSpec.targetDbRange.upperBound + 50])
        XCTAssertEqual(SettingsStore(defaults: defaults).preampAutoTargetDb, AutoPreampSpec.targetDbRange.upperBound)

        writeStoredPayload(overriding: ["preampAutoTargetDb": AutoPreampSpec.targetDbRange.lowerBound - 50])
        XCTAssertEqual(SettingsStore(defaults: defaults).preampAutoTargetDb, AutoPreampSpec.targetDbRange.lowerBound)
    }

    func testPreampAutoTargetDbOffStepValueSnapsToNearestStep() {
        let step = AutoPreampSpec.targetDbStep
        let base = AutoPreampSpec.targetDbRange.lowerBound + step
        writeStoredPayload(overriding: ["preampAutoTargetDb": base + step * 0.3])
        XCTAssertEqual(SettingsStore(defaults: defaults).preampAutoTargetDb, base)
    }

    func testLoadingSchemaFromBeforePreampDbResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "outputDeviceUID": NSNull(),
            "autoRestoreOnExit": true,
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault,
            "floorDb": EQLayout.Tuning.floorDbDefault,
            "attackLevel": EQLayout.Tuning.attack.defaultLevel,
            "releaseLevel": EQLayout.Tuning.release.defaultLevel,
            "handleFadeLevel": EQLayout.Tuning.handleFade.defaultLevel,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.defaultLevel,
            "presetOverrides": [String: Any](),
            "windowOrigin": NSNull()
            // preampDb は意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertEqual(SettingsStore(defaults: defaults).preampDb, 0)
    }

    func testLoadingSchemaFromBeforePeakHoldResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "outputDeviceUID": NSNull(),
            "autoRestoreOnExit": true,
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault,
            "floorDb": EQLayout.Tuning.floorDbDefault,
            "attackLevel": EQLayout.Tuning.attack.defaultLevel,
            "releaseLevel": EQLayout.Tuning.release.defaultLevel,
            "handleFadeLevel": EQLayout.Tuning.handleFade.defaultLevel,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.defaultLevel,
            "presetOverrides": [String: Any](),
            "windowOrigin": NSNull(),
            "preampDb": 0
            // peakHoldEnabled/peakHoldSeconds/peakDecayDbPerSec は意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertTrue(SettingsStore(defaults: defaults).peakHoldEnabled)
        XCTAssertEqual(SettingsStore(defaults: defaults).peakHoldSeconds, EQLayout.Tuning.peakHoldSecondsDefault)
        XCTAssertEqual(SettingsStore(defaults: defaults).peakDecayDbPerSec, EQLayout.Tuning.peakDecayDbPerSecDefault)
    }

    func testLoadingSchemaFromBeforePeakCapBrightenResetsAllSettingsToDefaults() {
        let oldSchema: [String: Any] = [
            "gains": EQSpec.builtInSeeds[.slot1]!.curve,
            "preset": EQPreset.slot1.rawValue,
            "bypass": false,
            "savedDefaultOutputUID": NSNull(),
            "switchPending": false,
            "alwaysOnTop": false,
            "showWindowOnLaunch": false,
            "outputDeviceUID": NSNull(),
            "autoRestoreOnExit": true,
            "visualizerFps": EQLayout.Tuning.visualizerFpsDefault,
            "floorDb": EQLayout.Tuning.floorDbDefault,
            "attackLevel": EQLayout.Tuning.attack.defaultLevel,
            "releaseLevel": EQLayout.Tuning.release.defaultLevel,
            "handleFadeLevel": EQLayout.Tuning.handleFade.defaultLevel,
            "handlePreviewLevel": EQLayout.Tuning.handlePreview.defaultLevel,
            "presetOverrides": [String: Any](),
            "windowOrigin": NSNull(),
            "preampDb": 0,
            "peakHoldEnabled": true,
            "peakHoldSeconds": EQLayout.Tuning.peakHoldSecondsDefault,
            "peakDecayDbPerSec": EQLayout.Tuning.peakDecayDbPerSecDefault
            // peakCapBrightenAmount は意図的に含めない
        ]
        let data = try! JSONSerialization.data(withJSONObject: oldSchema)
        defaults.set(data, forKey: SettingsStore.defaultsKey)

        assertResetToDefaults(SettingsStore(defaults: defaults))
        XCTAssertEqual(SettingsStore(defaults: defaults).peakCapBrightenAmount, EQLayout.Tuning.peakCapBrightenAmountDefault)
    }

    // MARK: - ミキサーのチャンネル

    /// 足したのが Optional 1 件だけであることの検証。ここが崩れると旧データが全項目既定へ戻る。
    func testLoadingDataWithoutMixerChannelsKeepsEveryOtherSetting() throws {
        let gains = (0..<EQSpec.bandCount).map { Double($0 % 7) - 3 }
        writeStoredPayload(overriding: ["gains": gains, "preset": EQPreset.slot3.rawValue, "bypass": true])
        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(json["mixerChannels"], "前提: この項目を持たない保存データであること")

        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.mixerChannels, "不在は「まだ一度も設定していない」")
        XCTAssertEqual(store.gains, gains, "他の項目が既定へ戻らない")
        XCTAssertEqual(store.preset, .slot3)
        XCTAssertTrue(store.bypass)
    }

    /// 空配列は「ユーザーが全部消した」であり、初回判定には使わない。
    func testEmptyMixerChannelsIsDistinctFromNeverConfigured() {
        let store = SettingsStore(defaults: defaults)
        store.mixerChannels = []
        XCTAssertEqual(SettingsStore(defaults: defaults).mixerChannels, [])

        store.mixerChannels = nil
        XCTAssertNil(SettingsStore(defaults: defaults).mixerChannels)
    }

    func testMixerChannelOrderAndValuesRoundTripAcrossInstances() {
        let sixDbDown = pow(10, -6.0 / 20)
        let entries = [
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.b"), gain: sixDbDown, muted: false),
            SettingsStore.MixerChannelEntry(key: MixerSpec.processKey("afplay"), gain: 1, muted: true),
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.a"), gain: 0, muted: false),
        ]
        SettingsStore(defaults: defaults).mixerChannels = entries

        let reloaded = SettingsStore(defaults: defaults).mixerChannels
        XCTAssertEqual(reloaded?.map(\.key), entries.map(\.key), "並び順そのものが保存される")
        XCTAssertEqual(reloaded?.map(\.muted), entries.map(\.muted))
        XCTAssertEqual(reloaded?.first?.gain ?? 0, sixDbDown, accuracy: 1e-9, "刻みに乗った値はそのまま戻る")
        XCTAssertEqual(reloaded?.last?.gain, 0, "無音はそのまま残る")
    }

    func testMixerChannelsAreSanitizedOnLoad() {
        SettingsStore(defaults: defaults).mixerChannels = [
            SettingsStore.MixerChannelEntry(key: "unknown:com.example.a", gain: 1, muted: false),
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.b"), gain: 4, muted: false),
            SettingsStore.MixerChannelEntry(key: MixerSpec.bundleKey("com.example.b"), gain: 0.5, muted: true),
        ]

        let reloaded = SettingsStore(defaults: defaults).mixerChannels
        XCTAssertEqual(reloaded?.count, 1, "未知の前置きを落とし、重複キーを畳む")
        XCTAssertEqual(reloaded?.first?.key, MixerSpec.bundleKey("com.example.b"))
        XCTAssertEqual(reloaded?.first?.gain, MixerGainScale.unityGain, "上限 0dB を超えない")
        XCTAssertEqual(reloaded?.first?.muted, false, "先に現れた側を残す")
    }
}
