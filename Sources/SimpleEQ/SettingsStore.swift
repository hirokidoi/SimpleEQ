import Darwin
import Foundation

extension EQPreset: Codable {}

/// プリセットの上書き内容を通常の JSON オブジェクト (キー=rawValue文字列) として
/// エンコード/デコードするために必要な適合。
extension EQPreset: CodingKeyRepresentable {}

/// EQ 設定と出力デバイス復帰状態の永続化。UserDefaults へ Codable モデル 1 件として保存する。
@MainActor
final class SettingsStore {
    struct WindowOrigin: Codable, Equatable {
        var x: Double
        var y: Double
    }

    private struct PresetOverride: Codable, Equatable {
        var title: String
        var curve: [Double]
        var preamp: Double
    }

    private struct Persisted: Codable {
        var gains: [Double]
        var preset: EQPreset
        var bypass: Bool
        /// 復帰対象デバイスの UID。nil は「復帰対象が未確定」を意味する。
        var savedDefaultOutputUID: String?
        var switchPending: Bool
        var alwaysOnTop: Bool
        var showWindowOnLaunch: Bool
        var showLevelMeter: Bool
        /// ユーザが手動固定した出力デバイスの UID。nil は起動時の自動選択を意味する。
        var outputDeviceUID: String?
        var adoptsSystemOutputSelection: Bool
        var visualizerFps: Double
        var floorDb: Double
        var attackLevel: Int
        var releaseLevel: Int
        var handleFadeLevel: Int
        var handlePreviewLevel: Int
        var peakHoldEnabled: Bool
        var peakHoldSeconds: Double
        var peakDecayDbPerSec: Double
        var peakCapBrightenAmount: Double

        /// プリセットの上書き保存内容。未保存の枠はここに存在せず、組み込みの初期値が使われる。
        var presetOverrides: [EQPreset: PresetOverride]
        /// ウィンドウ位置。未設定 (nil) は「保存済み位置なし」を意味する。
        var windowOrigin: WindowOrigin?
        var compactWindowOrigin: WindowOrigin?
        var viewMode: ViewMode
        var preampDb: Double
    }

    static let defaultsKey = "SimpleEQ.settings.v1"

    private let defaults: UserDefaults
    private var state: Persisted
    private var stateLock = os_unfair_lock_s()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = Self.normalized(decoded)
        } else {
            // キー欠損・型不一致などスキーマに互換性がない場合は、部分的な値の保持は行わず
            // 全項目を既定値で再構築する。
            state = Persisted(
                gains: EQSpec.builtInSeeds[.slot1]?.curve ?? Array(repeating: 0, count: EQSpec.bandCount),
                preset: .slot1,
                bypass: false,
                savedDefaultOutputUID: nil,
                switchPending: false,
                alwaysOnTop: false,
                showWindowOnLaunch: false,
                showLevelMeter: EQLayout.Tuning.showLevelMeterDefault,
                outputDeviceUID: nil,
                adoptsSystemOutputSelection: true,
                visualizerFps: EQLayout.Tuning.visualizerFpsDefault,
                floorDb: EQLayout.Tuning.floorDbDefault,
                attackLevel: EQLayout.Tuning.attack.defaultLevel,
                releaseLevel: EQLayout.Tuning.release.defaultLevel,
                handleFadeLevel: EQLayout.Tuning.handleFade.defaultLevel,
                handlePreviewLevel: EQLayout.Tuning.handlePreview.defaultLevel,
                peakHoldEnabled: EQLayout.Tuning.peakHoldEnabledDefault,
                peakHoldSeconds: EQLayout.Tuning.peakHoldSecondsDefault,
                peakDecayDbPerSec: EQLayout.Tuning.peakDecayDbPerSecDefault,
                peakCapBrightenAmount: EQLayout.Tuning.peakCapBrightenAmountDefault,
                presetOverrides: [:],
                windowOrigin: nil,
                compactWindowOrigin: nil,
                viewMode: .normal,
                preampDb: 0
            )
        }
    }

    /// 外から読んだ値を、そのまま使ってよい値へ揃える。
    private static func normalized(_ decoded: Persisted) -> Persisted {
        var p = decoded
        p.gains = normalizedCurve(p.gains)
        p.preampDb = EQSpec.clampDb(p.preampDb)
        p.visualizerFps = EQLayout.Tuning.visualizerFpsChoices.contains(p.visualizerFps)
            ? p.visualizerFps : EQLayout.Tuning.visualizerFpsDefault
        p.floorDb = clamped(p.floorDb, to: EQLayout.Tuning.floorDbRange)
        p.peakHoldSeconds = clamped(p.peakHoldSeconds, to: EQLayout.Tuning.peakHoldSecondsRange)
        p.peakDecayDbPerSec = clamped(p.peakDecayDbPerSec, to: EQLayout.Tuning.peakDecayDbPerSecRange)
        p.peakCapBrightenAmount = clamped(
            p.peakCapBrightenAmount, to: EQLayout.Tuning.peakCapBrightenAmountRange
        )
        p.attackLevel = clamped(p.attackLevel, to: EQLayout.Tuning.attack)
        p.releaseLevel = clamped(p.releaseLevel, to: EQLayout.Tuning.release)
        p.handleFadeLevel = clamped(p.handleFadeLevel, to: EQLayout.Tuning.handleFade)
        p.handlePreviewLevel = clamped(p.handlePreviewLevel, to: EQLayout.Tuning.handlePreview)
        p.presetOverrides = p.presetOverrides.mapValues {
            PresetOverride(
                title: EQLayout.clampToPresetTitleMaxWidth($0.title),
                curve: normalizedCurve($0.curve),
                preamp: EQSpec.clampDb($0.preamp)
            )
        }
        return p
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// 段は 1 始まりで、段の数は並びの長さが決める。
    private static func clamped(_ level: Int, to scale: EQLayout.Tuning.LevelScale) -> Int {
        max(1, min(scale.values.count, level))
    }

    private static func normalizedCurve(_ curve: [Double]) -> [Double] {
        (0..<EQSpec.bandCount).map { $0 < curve.count ? EQSpec.clampDb(curve[$0]) : 0 }
    }

    private func readState<T>(_ body: (Persisted) -> T) -> T {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return body(state)
    }

    private func writeState(_ body: (inout Persisted) -> Void) {
        os_unfair_lock_lock(&stateLock)
        body(&state)
        let data = try? JSONEncoder().encode(state)
        os_unfair_lock_unlock(&stateLock)
        guard let data else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// EQ ゲイン (dB)。
    var gains: [Double] {
        get { readState { $0.gains } }
        set { writeState { $0.gains = newValue } }
    }

    /// 選択中のプリセット。
    var preset: EQPreset {
        get { readState { $0.preset } }
        set { writeState { $0.preset = newValue } }
    }

    /// EQ バイパス (true = 素通し)。
    var bypass: Bool {
        get { readState { $0.bypass } }
        set { writeState { $0.bypass = newValue } }
    }

    var savedDefaultOutputUID: String? {
        get { readState { $0.savedDefaultOutputUID } }
        set { writeState { $0.savedDefaultOutputUID = newValue } }
    }

    /// 出力デバイスの切替が復帰未完了のまま終了した可能性を示す。単独では復帰の義務を表さない。
    var switchPending: Bool {
        get { readState { $0.switchPending } }
        set { writeState { $0.switchPending = newValue } }
    }

    /// EQ ウィンドウを常に最前面 (floating) に保つか。
    var alwaysOnTop: Bool {
        get { readState { $0.alwaysOnTop } }
        set { writeState { $0.alwaysOnTop = newValue } }
    }

    /// 起動時に EQ ウィンドウを自動表示するか。
    var showWindowOnLaunch: Bool {
        get { readState { $0.showWindowOnLaunch } }
        set { writeState { $0.showWindowOnLaunch = newValue } }
    }

    /// L/R レベルメーターの表示/非表示。
    var showLevelMeter: Bool {
        get { readState { $0.showLevelMeter } }
        set { writeState { $0.showLevelMeter = newValue } }
    }

    /// ユーザが手動固定した出力デバイスの UID。未設定 (nil) は起動時の自動選択を意味する。
    var outputDeviceUID: String? {
        get { readState { $0.outputDeviceUID } }
        set { writeState { $0.outputDeviceUID = newValue } }
    }

    /// OS 側でデフォルト出力が自ドライバ以外へ移ったとき、その出力先を SimpleEQ の出力先として引き継ぐか。
    var adoptsSystemOutputSelection: Bool {
        get { readState { $0.adoptsSystemOutputSelection } }
        set { writeState { $0.adoptsSystemOutputSelection = newValue } }
    }

    /// ビジュアライザの再描画上限フレームレート (fps)。
    var visualizerFps: Double {
        get { readState { $0.visualizerFps } }
        set { writeState { $0.visualizerFps = newValue } }
    }

    /// ビジュアライザ (バーレベル) の dBFS 下限。
    var floorDb: Double {
        get { readState { $0.floorDb } }
        set { writeState { $0.floorDb = newValue } }
    }

    /// レベルメーターの立ち上がり速度の段。
    var attackLevel: Int {
        get { readState { $0.attackLevel } }
        set { writeState { $0.attackLevel = newValue } }
    }

    /// レベルメーターの下がり速度の段。
    var releaseLevel: Int {
        get { readState { $0.releaseLevel } }
        set { writeState { $0.releaseLevel = newValue } }
    }

    /// ハンドル表示アルファのフェード速度の段。
    var handleFadeLevel: Int {
        get { readState { $0.handleFadeLevel } }
        set { writeState { $0.handleFadeLevel = newValue } }
    }

    /// ハンドルのプリセットプレビュー追従速度の段。
    var handlePreviewLevel: Int {
        get { readState { $0.handlePreviewLevel } }
        set { writeState { $0.handlePreviewLevel = newValue } }
    }

    /// ピークホールド表示の有効/無効。
    var peakHoldEnabled: Bool {
        get { readState { $0.peakHoldEnabled } }
        set { writeState { $0.peakHoldEnabled = newValue } }
    }

    /// ピーク到達後、減衰を始めるまで保持する時間 (秒)。
    var peakHoldSeconds: Double {
        get { readState { $0.peakHoldSeconds } }
        set { writeState { $0.peakHoldSeconds = newValue } }
    }

    /// ホールド終了後にピークが下がっていく速度 (dB/秒)。
    var peakDecayDbPerSec: Double {
        get { readState { $0.peakDecayDbPerSec } }
        set { writeState { $0.peakDecayDbPerSec = newValue } }
    }

    /// ピークホールド LED を白へ寄せる度合い (0=通常点灯と同色、1=白)。
    var peakCapBrightenAmount: Double {
        get { readState { $0.peakCapBrightenAmount } }
        set { writeState { $0.peakCapBrightenAmount = newValue } }
    }

    func windowOrigin(for mode: ViewMode) -> WindowOrigin? {
        readState { mode == .compact ? $0.compactWindowOrigin : $0.windowOrigin }
    }

    func setWindowOrigin(_ origin: WindowOrigin, for mode: ViewMode) {
        writeState {
            if mode == .compact {
                $0.compactWindowOrigin = origin
            } else {
                $0.windowOrigin = origin
            }
        }
    }

    var preampDb: Double {
        get { readState { $0.preampDb } }
        set { writeState { $0.preampDb = newValue } }
    }

    var viewMode: ViewMode {
        get { readState { $0.viewMode } }
        set { writeState { $0.viewMode = newValue } }
    }

    func curve(for preset: EQPreset) -> [Double] {
        readState { $0.presetOverrides[preset]?.curve } ?? EQSpec.builtInSeeds[preset]?.curve ?? Array(repeating: 0, count: EQSpec.bandCount)
    }

    func title(for preset: EQPreset) -> String {
        readState { $0.presetOverrides[preset]?.title } ?? EQSpec.builtInSeeds[preset]?.title ?? ""
    }

    func preamp(for preset: EQPreset) -> Double {
        readState { $0.presetOverrides[preset]?.preamp } ?? EQSpec.builtInSeeds[preset]?.preamp ?? 0
    }

    func resetAllPresets() {
        writeState { $0.presetOverrides = [:] }
    }

    /// タイトルが空の間、プリセットボタンは hover・クリックとも no-op になる。
    func deletePreset(_ preset: EQPreset) {
        writeState {
            $0.presetOverrides[preset] = PresetOverride(title: "", curve: Array(repeating: 0, count: EQSpec.bandCount), preamp: 0)
        }
    }

    func savePreset(_ preset: EQPreset, curve: [Double], title: String, preamp: Double) {
        writeState { $0.presetOverrides[preset] = PresetOverride(title: title, curve: curve, preamp: preamp) }
    }
}
