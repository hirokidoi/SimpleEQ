import CoreAudio
import Foundation
import SimpleEQRingC

// --- 音声経路の判定・変換の本体 (CoreAudio に触れない純粋関数、ユニットテスト対象) ----------

/// 除外理由の OR: 取り込み口 (自ドライバ) を出力先に選ぶとフィードバックループになる、
/// AirPlay は選んだ時点でデバイス自体が消え、あるべき状態を保持できない。
func isExcludedFromOutputPicker(uid: String, driverDeviceUID: String?, containsDriver: Bool, isAirPlay: Bool) -> Bool {
    if let driverDeviceUID, uid == driverDeviceUID { return true }
    return containsDriver || isAirPlay
}

/// 判定には頭打ちも平滑化もしていない生のピーク振幅を渡すこと (表示用のレベル値は表示レンジで頭打ちにされ超過を表せない)。
/// ちょうどフルスケールは超過に含めない。
func outputExceedsFullScale(peakAmplitude: Float) -> Bool {
    peakAmplitude > 1
}

/// 出力先の切替要否 (outputSwitchDecision の結果)。
enum OutputSwitchDecision: Equatable {
    /// 現在の出力先が既にあるべき状態と一致している。
    case notNeeded
    /// 切り替える必要がある。
    case needed
}

/// 判定は AudioDeviceID ではなく UID で行う (ID は入れ替わるため一致が「同じデバイス」を意味しない)。
/// 現在の UID を取得できない場合は確証が無いため切替要へ倒す。
func outputSwitchDecision(intendedUID: String, currentUID: String?) -> OutputSwitchDecision {
    guard let currentUID, currentUID == intendedUID else { return .needed }
    return .notNeeded
}

/// 判定は共有ヘッダの読み取りだけで完結し、HAL への問い合わせを含まない。誰も再生していない
/// (書き手が稼働していない) 間は経過時間に関わらず停止とみなさない (正常な無音)。
func isRingStalled(writerIOIsRunning: Bool, elapsedSinceLastWrite: TimeInterval, threshold: TimeInterval) -> Bool {
    writerIOIsRunning && elapsedSinceLastWrite > threshold
}

/// キューへのハートビートが返ってこないことを表す。
/// now/lastResponse/waitingSince はシステムスリープ中に進まない時計で測ること (壁時計だと、復帰直後に必ず応答なしと判定される)。
func isAudioWorldUnresponsive(
    now: TimeInterval, lastResponse: TimeInterval?, waitingSince: TimeInterval, threshold: TimeInterval
) -> Bool {
    now - max(lastResponse ?? waitingSince, waitingSince) > threshold
}

/// タイマーが飛ぶ原因 (省電力による間引き・タイマーの合体) はキューの詰まりでは起きないため、
/// 飛んだ区間の経過を応答なしの根拠にしない。
func audioWorldHeartbeatTickIsContinuous(
    now: TimeInterval, lastTick: TimeInterval?, interval: TimeInterval, tolerance: Double
) -> Bool {
    guard let lastTick else { return true }
    return now - lastTick <= interval * tolerance
}

private let driverVolumeMinDb: Float = simpleeq_ring_volume_min_db()
private let driverVolumeMaxDb: Float = simpleeq_ring_volume_max_db()

/// VolumeScalar (0...1) をドライバの declared dB レンジへ線形変換したのち振幅へ変換する
/// (聴感上の効きをスライダー全域で均す)。scalar==0 は dB カーブに乗せず明示的に振幅 0 を返す
/// (driverVolumeMinDb はゼロではなくわずかに振幅が残るため)。
func effectiveOutputGain(volume: Float, muted: Bool) -> Float {
    guard !muted else { return 0 }
    let scalar = max(0, min(1, volume))
    guard scalar > 0 else { return 0 }
    let db = driverVolumeMinDb + scalar * (driverVolumeMaxDb - driverVolumeMinDb)
    return Float(pow(10, Double(db) / 20))
}

func preampLinearGain(db: Double) -> Float {
    Float(pow(10, EQSpec.clampDb(db) / 20))
}

/// EQ バイパス中はプリアンプ設定値によらずユニティにする。
func effectivePreampGain(preampDb: Double, bypassed: Bool) -> Float {
    bypassed ? 1 : preampLinearGain(db: preampDb)
}

/// 登録先と解決済み ID が食い違ったら張り替え、未登録で ID が解決できていれば登録する。
func driverDeviceListenerRebindActions(
    monitoringDesired: Bool, registeredID: AudioDeviceID?, resolvedID: AudioDeviceID?
) -> (unregister: Bool, register: Bool) {
    guard monitoringDesired else { return (registeredID != nil, false) }
    if registeredID == resolvedID { return (false, false) }
    return (registeredID != nil, resolvedID != nil)
}

/// 現在のあるべき出力先があれば最新値として採用し、無ければ直前に保持していた値をそのまま残す。
func intendedOutputDeviceUIDAtSuspensionCapture(current: String?, previouslyCaptured: String?) -> String? {
    current ?? previouslyCaptured
}

/// 出力デバイスの解決方針 (outputDeviceResolutionPolicy の結果)。
enum OutputDeviceResolution: Equatable {
    /// 手動固定 (ユーザが選択した UID を解決して使う)。
    case configured(uid: String)
    /// 自動選択 (起動直前のシステム既定出力相当を使う)。
    case auto
}

/// configuredUID が nil、または現在解決できない場合は自動選択へフォールバックする。
func outputDeviceResolutionPolicy(configuredUID: String?, configuredUIDResolvable: Bool) -> OutputDeviceResolution {
    guard let configuredUID, configuredUIDResolvable else { return .auto }
    return .configured(uid: configuredUID)
}

/// 1 回のレンダ要求に対するバッファサイズの判定 (renderBufferSizing の結果)。
enum RenderBufferSizing: Equatable {
    /// 要求フレーム数が事前確保容量を超えている (レンダを打ち切るべき)。
    case exceedsCapacity
    /// レンダ可能。値は planar 1 チャンネルぶんのバイト数 (今回の要求フレーム数ぶんであり、
    /// 事前確保容量ぶんではない)。
    case renderable(bytesPerChannel: UInt32)
}

func renderBufferSizing(frames: UInt32, capacityFrames: Int) -> RenderBufferSizing {
    guard Int(frames) <= capacityFrames else { return .exceedsCapacity }
    return .renderable(bytesPerChannel: frames * UInt32(MemoryLayout<Float>.size))
}

/// 読み手の生存は稼働状態と対で動くため、これが偽の間は HAL への問い合わせ相手が居ない。
func runsPeriodicDeviceQueries(processingState: ProcessingState) -> Bool {
    processingState == .active
}

// MARK: - 音量経路 (OutputVolumeBridge が使う純粋関数)

enum VolumeControlMode: Equatable {
    case device
    case app
}

struct VolumeRouteObservation: Equatable {
    let volumeMode: VolumeControlMode
    let volumeDowngraded: Bool
    let volume: Float?
    let muteMode: VolumeControlMode
    let muteDowngraded: Bool
    let muted: Bool?
}

func volumeControlModeFromCapability(exists: Bool, settable: Bool) -> VolumeControlMode {
    exists && settable ? .device : .app
}

enum WriteReadbackJudgment<Value: Equatable>: Equatable {
    case normal
    case rounded(Value)
    case downgrade
}

func writeReadbackJudgment<Value: Equatable>(
    writeSucceeded: Bool, written: Value, readback: Value?
) -> WriteReadbackJudgment<Value> {
    guard writeSucceeded, let readback else { return .downgrade }
    return readback == written ? .normal : .rounded(readback)
}

func mirrorWriteNeeded<Value: Equatable>(current: Value, target: Value) -> Bool {
    current != target
}

func appModeVolumeAdoption(remembered: Float?, isFirstBindOfSession: Bool, driverCurrentScalar: Float) -> Float {
    if let remembered { return remembered }
    return isFirstBindOfSession ? driverCurrentScalar : 1
}

struct OutputDeviceRebindActions: Equatable {
    let unregisterListener: Bool
    let registerListener: Bool
    let adopt: Bool
}

func outputDeviceRebindActions(
    boundUID: String?, listenerDeviceID: AudioDeviceID?,
    resolvedUID: String?, resolvedDeviceID: AudioDeviceID?
) -> OutputDeviceRebindActions {
    guard let resolvedUID, let resolvedDeviceID else {
        return OutputDeviceRebindActions(unregisterListener: listenerDeviceID != nil, registerListener: false, adopt: false)
    }
    let sameDevice = boundUID == resolvedUID
    let listenerNeedsRebind = listenerDeviceID != resolvedDeviceID
    return OutputDeviceRebindActions(
        unregisterListener: listenerDeviceID != nil && listenerNeedsRebind,
        registerListener: listenerNeedsRebind,
        adopt: !sameDevice
    )
}

func bridgeOutputGain(volumeMode: VolumeControlMode, volume: Float, muteMode: VolumeControlMode, muted: Bool) -> Float {
    effectiveOutputGain(
        volume: volumeMode == .device ? 1 : volume,
        muted: muteMode == .device ? false : muted
    )
}
