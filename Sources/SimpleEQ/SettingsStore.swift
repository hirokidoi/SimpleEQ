import Darwin
import Foundation

extension EQPreset: Codable {}

/// プリセットの上書き内容を通常の JSON オブジェクト (キー=rawValue文字列) としてエンコード/デコードするために必要な適合。
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
    }

    private struct EQState: Codable {
        var gains: [Double] = EQSpec.builtInSeeds[.slot1]?.curve ?? Array(repeating: 0, count: EQSpec.bandCount)
        var preset: EQPreset = .slot1
        /// 上書き保存した内容。未保存の枠はここに存在せず、組み込みの初期値が使われる。
        var overrides: [EQPreset: PresetOverride] = [:]
    }

    private struct PreampState: Codable {
        var db: Double = 0
        var autoEnabled = true
        var autoTargetDb = AutoPreampSpec.targetDbDefault
    }

    private struct OutputState: Codable {
        /// 復帰対象デバイスの UID。nil は「復帰対象が未確定」を意味する。
        var savedDefaultUID: String?
        /// 切替が復帰未完了のまま終了した可能性を示す。単独では復帰の義務を表さない。
        var switchPending = false
        /// ユーザが手動固定した UID。nil は起動時の自動選択を意味する。
        var deviceUID: String?
        var adoptsSystemSelection = true
    }

    private struct WindowState: Codable {
        /// 保存済み位置。nil は「保存済み位置なし」を意味する。
        struct Origins: Codable {
            var normal: WindowOrigin?
            var compact: WindowOrigin?
        }

        var viewMode: ViewMode = .normal
        var alwaysOnTop = false
        var showOnLaunch = false
        var origin = Origins()
    }

    private struct PeakHoldState: Codable {
        var enabled = EQLayout.Tuning.peakHoldEnabledDefault
        var holdSeconds = EQLayout.Tuning.peakHoldSecondsDefault
        var decayDbPerSec = EQLayout.Tuning.peakDecayDbPerSecDefault
        var capBrightenAmount = EQLayout.Tuning.peakCapBrightenAmountDefault
    }

    private struct VisualizerState: Codable {
        var fps = EQLayout.Tuning.visualizerFpsDefault
        var floorDb = EQLayout.Tuning.floorDbDefault
        var showLevelMeter = EQLayout.Tuning.showLevelMeterDefault
        var attackLevel = EQLayout.Tuning.attack.defaultLevel
        var releaseLevel = EQLayout.Tuning.release.defaultLevel
        var peakHold = PeakHoldState()
    }

    private struct HandleState: Codable {
        var revealGesture: HandleRevealGesture = .default
        var fadeLevel = EQLayout.Tuning.handleFade.defaultLevel
        var previewLevel = EQLayout.Tuning.handlePreview.defaultLevel
        var ledDimAmount = EQLayout.Tuning.ledDimAmountDefault
    }

    private struct MixerState: Codable {
        /// ユーザーが並べたチャンネル。
        /// nil は「まだ一度も設定していない」= 初期セットを撒く合図で、空配列は「ユーザーが全部消した」。
        var channels: [MixerChannelEntry]?
    }

    private struct Persisted: Codable {
        /// EQ・プリアンプ・Sound Lab の加工をまとめて切る。
        var bypass = false
        var eq = EQState()
        var preamp = PreampState()
        var soundLab = SoundLabSettings()
        var output = OutputState()
        var window = WindowState()
        var visualizer = VisualizerState()
        var handles = HandleState()
        var mixer = MixerState()
    }

    struct MixerChannelEntry: Codable, Equatable {
        var key: String
        /// 線形ゲイン (0…1)。
        var gain: Double
        var muted: Bool
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
            // キー欠損・型不一致などスキーマに互換性がない場合は、部分的な値の保持は行わず全項目を既定値で再構築する。
            state = Persisted()
        }
    }

    /// 外から読んだ値を、そのまま使ってよい値へ揃える。
    private static func normalized(_ decoded: Persisted) -> Persisted {
        var p = decoded
        p.eq.gains = normalizedCurve(p.eq.gains)
        p.eq.overrides = p.eq.overrides.mapValues {
            PresetOverride(
                title: EQLayout.clampToPresetTitleMaxWidth($0.title),
                curve: normalizedCurve($0.curve)
            )
        }
        p.preamp.db = EQSpec.clampDb(p.preamp.db)
        p.preamp.autoTargetDb = AutoPreampSpec.normalizedTargetDb(p.preamp.autoTargetDb)
        p.soundLab = p.soundLab.normalized
        p.visualizer.fps = EQLayout.Tuning.visualizerFpsChoices.contains(p.visualizer.fps)
            ? p.visualizer.fps : EQLayout.Tuning.visualizerFpsDefault
        p.visualizer.floorDb = clamped(p.visualizer.floorDb, to: EQLayout.Tuning.floorDbRange)
        p.visualizer.attackLevel = clamped(p.visualizer.attackLevel, to: EQLayout.Tuning.attack)
        p.visualizer.releaseLevel = clamped(p.visualizer.releaseLevel, to: EQLayout.Tuning.release)
        p.visualizer.peakHold.holdSeconds = clamped(
            p.visualizer.peakHold.holdSeconds, to: EQLayout.Tuning.peakHoldSecondsRange
        )
        p.visualizer.peakHold.decayDbPerSec = clamped(
            p.visualizer.peakHold.decayDbPerSec, to: EQLayout.Tuning.peakDecayDbPerSecRange
        )
        p.visualizer.peakHold.capBrightenAmount = clamped(
            p.visualizer.peakHold.capBrightenAmount, to: EQLayout.Tuning.peakCapBrightenAmountRange
        )
        p.handles.fadeLevel = clamped(p.handles.fadeLevel, to: EQLayout.Tuning.handleFade)
        p.handles.previewLevel = clamped(p.handles.previewLevel, to: EQLayout.Tuning.handlePreview)
        p.handles.ledDimAmount = clamped(p.handles.ledDimAmount, to: EQLayout.Tuning.ledDimAmountRange)
        p.mixer.channels = p.mixer.channels.map(normalizedMixerChannels)
        return p
    }

    /// 未知の前置きのキーを落とし、重複キーを畳む。
    static func normalizedMixerChannels(_ entries: [MixerChannelEntry]) -> [MixerChannelEntry] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard MixerSpec.isValidKey(entry.key), seen.insert(entry.key).inserted else { return nil }
            return MixerChannelEntry(
                key: entry.key, gain: MixerGainScale.normalizedGain(entry.gain), muted: entry.muted
            )
        }
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

    func setGainsAndPreamp(_ gains: [Double], _ preampDb: Double) {
        writeState { $0.eq.gains = gains; $0.preamp.db = preampDb }
    }

    /// EQ ゲイン (dB)。
    var gains: [Double] {
        get { readState { $0.eq.gains } }
        set { writeState { $0.eq.gains = newValue } }
    }

    /// 選択中のプリセット。
    var preset: EQPreset {
        get { readState { $0.eq.preset } }
        set { writeState { $0.eq.preset = newValue } }
    }

    /// EQ バイパス (true = 素通し)。
    var bypass: Bool {
        get { readState { $0.bypass } }
        set { writeState { $0.bypass = newValue } }
    }

    var savedDefaultOutputUID: String? {
        get { readState { $0.output.savedDefaultUID } }
        set { writeState { $0.output.savedDefaultUID = newValue } }
    }

    /// 出力デバイスの切替が復帰未完了のまま終了した可能性を示す。単独では復帰の義務を表さない。
    var switchPending: Bool {
        get { readState { $0.output.switchPending } }
        set { writeState { $0.output.switchPending = newValue } }
    }

    /// EQ ウィンドウを常に最前面 (floating) に保つか。
    var alwaysOnTop: Bool {
        get { readState { $0.window.alwaysOnTop } }
        set { writeState { $0.window.alwaysOnTop = newValue } }
    }

    /// 起動時に EQ ウィンドウを自動表示するか。
    var showWindowOnLaunch: Bool {
        get { readState { $0.window.showOnLaunch } }
        set { writeState { $0.window.showOnLaunch = newValue } }
    }

    /// L/R レベルメーターの表示/非表示。
    var showLevelMeter: Bool {
        get { readState { $0.visualizer.showLevelMeter } }
        set { writeState { $0.visualizer.showLevelMeter = newValue } }
    }

    /// ユーザが手動固定した出力デバイスの UID。未設定 (nil) は起動時の自動選択を意味する。
    var outputDeviceUID: String? {
        get { readState { $0.output.deviceUID } }
        set { writeState { $0.output.deviceUID = newValue } }
    }

    /// OS 側でデフォルト出力が自ドライバ以外へ移ったとき、その出力先を SimpleEQ の出力先として引き継ぐか。
    var adoptsSystemOutputSelection: Bool {
        get { readState { $0.output.adoptsSystemSelection } }
        set { writeState { $0.output.adoptsSystemSelection = newValue } }
    }

    /// ビジュアライザの再描画上限フレームレート (fps)。
    var visualizerFps: Double {
        get { readState { $0.visualizer.fps } }
        set { writeState { $0.visualizer.fps = newValue } }
    }

    /// ビジュアライザ (バーレベル) の dBFS 下限。
    var floorDb: Double {
        get { readState { $0.visualizer.floorDb } }
        set { writeState { $0.visualizer.floorDb = newValue } }
    }

    /// レベルメーターの立ち上がり速度の段。
    var attackLevel: Int {
        get { readState { $0.visualizer.attackLevel } }
        set { writeState { $0.visualizer.attackLevel = newValue } }
    }

    /// レベルメーターの下がり速度の段。
    var releaseLevel: Int {
        get { readState { $0.visualizer.releaseLevel } }
        set { writeState { $0.visualizer.releaseLevel = newValue } }
    }

    /// ハンドル表示アルファのフェード速度の段。
    var handleFadeLevel: Int {
        get { readState { $0.handles.fadeLevel } }
        set { writeState { $0.handles.fadeLevel = newValue } }
    }

    /// ハンドルのプリセットプレビュー追従速度の段。
    var handlePreviewLevel: Int {
        get { readState { $0.handles.previewLevel } }
        set { writeState { $0.handles.previewLevel = newValue } }
    }

    /// ピークホールド表示の有効/無効。
    var peakHoldEnabled: Bool {
        get { readState { $0.visualizer.peakHold.enabled } }
        set { writeState { $0.visualizer.peakHold.enabled = newValue } }
    }

    /// ピーク到達後、減衰を始めるまで保持する時間 (秒)。
    var peakHoldSeconds: Double {
        get { readState { $0.visualizer.peakHold.holdSeconds } }
        set { writeState { $0.visualizer.peakHold.holdSeconds = newValue } }
    }

    /// ホールド終了後にピークが下がっていく速度 (dB/秒)。
    var peakDecayDbPerSec: Double {
        get { readState { $0.visualizer.peakHold.decayDbPerSec } }
        set { writeState { $0.visualizer.peakHold.decayDbPerSec = newValue } }
    }

    /// ピークホールド LED を白へ寄せる度合い (0=通常点灯と同色、1=白)。
    var peakCapBrightenAmount: Double {
        get { readState { $0.visualizer.peakHold.capBrightenAmount } }
        set { writeState { $0.visualizer.peakHold.capBrightenAmount = newValue } }
    }

    func windowOrigin(for mode: ViewMode) -> WindowOrigin? {
        readState { mode == .compact ? $0.window.origin.compact : $0.window.origin.normal }
    }

    func setWindowOrigin(_ origin: WindowOrigin, for mode: ViewMode) {
        writeState {
            if mode == .compact {
                $0.window.origin.compact = origin
            } else {
                $0.window.origin.normal = origin
            }
        }
    }

    var preampDb: Double {
        get { readState { $0.preamp.db } }
        set { writeState { $0.preamp.db = newValue } }
    }

    var preampAutoEnabled: Bool {
        get { readState { $0.preamp.autoEnabled } }
        set { writeState { $0.preamp.autoEnabled = newValue } }
    }

    var preampAutoTargetDb: Double {
        get { readState { $0.preamp.autoTargetDb } }
        set { writeState { $0.preamp.autoTargetDb = newValue } }
    }

    var viewMode: ViewMode {
        get { readState { $0.window.viewMode } }
        set { writeState { $0.window.viewMode = newValue } }
    }

    var handleRevealGesture: HandleRevealGesture {
        get { readState { $0.handles.revealGesture } }
        set { writeState { $0.handles.revealGesture = newValue } }
    }

    /// ハンドル表示中に LED を沈める量。
    var ledDimAmount: Double {
        get { readState { $0.handles.ledDimAmount } }
        set { writeState { $0.handles.ledDimAmount = newValue } }
    }

    /// Sound Lab の操作値。
    var soundLab: SoundLabSettings {
        get { readState { $0.soundLab } }
        set { writeState { $0.soundLab = newValue.normalized } }
    }

    /// nil は「まだ一度も設定していない」。初期化はこの値を nil へ戻すことで表す。
    var mixerChannels: [MixerChannelEntry]? {
        get { readState { $0.mixer.channels } }
        set { writeState { $0.mixer.channels = newValue.map(Self.normalizedMixerChannels) } }
    }

    func curve(for preset: EQPreset) -> [Double] {
        readState { $0.eq.overrides[preset]?.curve } ?? EQSpec.builtInSeeds[preset]?.curve ?? Array(repeating: 0, count: EQSpec.bandCount)
    }

    func title(for preset: EQPreset) -> String {
        readState { $0.eq.overrides[preset]?.title } ?? EQSpec.builtInSeeds[preset]?.title ?? ""
    }

    func resetAllPresets() {
        writeState { $0.eq.overrides = [:] }
    }

    /// タイトルが空の間、プリセットボタンは hover・クリックとも no-op になる。
    func deletePreset(_ preset: EQPreset) {
        writeState {
            $0.eq.overrides[preset] = PresetOverride(title: "", curve: Array(repeating: 0, count: EQSpec.bandCount))
        }
    }

    func savePreset(_ preset: EQPreset, curve: [Double], title: String) {
        writeState { $0.eq.overrides[preset] = PresetOverride(title: title, curve: curve) }
    }
}
