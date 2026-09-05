import AudioToolbox
import CoreAudio
import Foundation

// --- デバイス検索 -------------------------------------------------
// デバイスの解決キーは常に UID (表示名は表示専用で、解決キーにはしない)。

func allDeviceIDs(_ token: AudioWorldToken) -> [AudioDeviceID] {
    var propSize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
    ) == noErr else { return [] }
    let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &ids
    ) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID, _ token: AudioWorldToken) -> String? {
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfName: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfName) == noErr else { return nil }
    return cfName?.takeRetainedValue() as String?
}

func deviceUID(_ id: AudioDeviceID, _ token: AudioWorldToken) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfUID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfUID) == noErr else { return nil }
    return cfUID?.takeRetainedValue() as String?
}

func deviceHasStreams(_ id: AudioDeviceID, needsOutput: Bool, _ token: AudioWorldToken) -> Bool {
    let scope = needsOutput ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    var streamAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr else { return false }
    return streamSize > 0
}

/// 公称サンプルレート (Hz)。
func nominalSampleRate(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Double? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
    return rate
}

/// UID から一般出力デバイスを解決する (列挙+UID照合、可視デバイスのみ解決できる)。
func findVisibleDeviceID(forUID target: String, needsOutput: Bool, _ token: AudioWorldToken) -> AudioDeviceID? {
    allDeviceIDs(token).first { deviceUID($0, token) == target && deviceHasStreams($0, needsOutput: needsOutput, token) }
}

/// UID からデバイスを解決する。
/// 非表示デバイスも列挙を経由せず解決できるが、環境によって全デバイスで解決に失敗しうるため、
/// 非表示解決能力が必要な場合に限って使う。
func translateUIDToDeviceID(forUID targetUID: String, _ token: AudioWorldToken) -> AudioDeviceID? {
    var uidCF = targetUID as CFString
    var resolvedID = AudioDeviceID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<CFString>.size), uidPtr,
            &size, &resolvedID
        )
    }
    guard st == noErr, resolvedID != kAudioObjectUnknown else { return nil }
    return resolvedID
}

/// デバイスの転送種別 (kAudioDevicePropertyTransportType)。読めなければ nil。
func transportType(_ id: AudioDeviceID, _ token: AudioWorldToken) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

/// AirPlay のデバイスは出力先の選択がその端末から外れると HAL から消えるため、出力先として使わない。
func isAirPlayDevice(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
    transportType(id, token) == kAudioDeviceTransportTypeAirPlay
}

/// 専用ドライバ内包の Aggregate/Multi-Output を出力先に選ぶと EQ 出力が取り込み口へ回り込みうる。
func containsDriverDevice(_ id: AudioDeviceID, driverDeviceUID: String, _ token: AudioWorldToken) -> Bool {
    guard transportType(id, token) == kAudioDeviceTransportTypeAggregate else { return false }

    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfArray: Unmanaged<CFArray>?
    var arraySize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
    guard AudioObjectGetPropertyData(id, &listAddr, 0, nil, &arraySize, &cfArray) == noErr,
          let subDeviceUIDs = (cfArray?.takeRetainedValue() as NSArray?) as? [String] else { return false }
    return subDeviceUIDs.contains(driverDeviceUID)
}

/// AudioDeviceID はディスプレイスリープ復帰や coreaudiod 再起動で総入れ替えになるため、
/// あるべき状態そのものは常に uid が担う。
struct ResolvedOutputDevice: Equatable {
    let uid: String
    let deviceID: AudioDeviceID
}

/// ユーザ選択可能な出力候補専用のデバイス解決ラッパー。除外対象なら nil を返す。
func resolveSelectableOutputDevice(uid target: String, needsOutput: Bool, driverDeviceUID: String, _ token: AudioWorldToken) -> ResolvedOutputDevice? {
    guard let id = findVisibleDeviceID(forUID: target, needsOutput: needsOutput, token) else { return nil }
    let containsDriver = containsDriverDevice(id, driverDeviceUID: driverDeviceUID, token)
    guard !isExcludedFromOutputPicker(
        uid: target, driverDeviceUID: driverDeviceUID,
        containsDriver: containsDriver, isAirPlay: isAirPlayDevice(id, token)
    ) else { return nil }
    return ResolvedOutputDevice(uid: target, deviceID: id)
}

/// 出力候補一覧の1件 (UID + 表示名)。識別・照合には uid のみを使い、name は表示ラベル専用
/// (この値自体を識別キーとして保持・比較しないこと)。
struct OutputDeviceOption: Equatable {
    let uid: String
    let name: String
}

/// 指定スコープにストリームを持つ全デバイスを列挙する。除外対象・UID 未取得のデバイスは除く。
func enumerateOutputDeviceOptions(needsOutput: Bool, driverDeviceUID: String, _ token: AudioWorldToken) -> [OutputDeviceOption] {
    allDeviceIDs(token).compactMap { id in
        guard deviceHasStreams(id, needsOutput: needsOutput, token) else { return nil }
        guard let uid = deviceUID(id, token), let name = deviceName(id, token) else { return nil }
        let containsDriver = containsDriverDevice(id, driverDeviceUID: driverDeviceUID, token)
        if isExcludedFromOutputPicker(
            uid: uid, driverDeviceUID: driverDeviceUID,
            containsDriver: containsDriver, isAirPlay: isAirPlayDevice(id, token)
        ) { return nil }
        return OutputDeviceOption(uid: uid, name: name)
    }
}

// MARK: - 音量経路 (VolumeScalar / Mute、master element / output scope)

struct DevicePropertyCapability: Equatable {
    let exists: Bool
    let settable: Bool
}

func outputMasterAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
    )
}

private func capability(_ id: AudioDeviceID, at address: AudioObjectPropertyAddress?) -> DevicePropertyCapability {
    guard var addr = address else { return DevicePropertyCapability(exists: false, settable: false) }
    var settable: DarwinBoolean = false
    let st = AudioObjectIsPropertySettable(id, &addr, &settable)
    return DevicePropertyCapability(exists: true, settable: st == noErr && settable.boolValue)
}

private func existingOutputMasterAddress(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress? {
    var addr = outputMasterAddress(selector)
    return AudioObjectHasProperty(id, &addr) ? addr : nil
}

private func deviceVolumeScalarAddress(_ id: AudioDeviceID) -> AudioObjectPropertyAddress? {
    existingOutputMasterAddress(id, kAudioDevicePropertyVolumeScalar)
        ?? existingOutputMasterAddress(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
}

private func deviceMuteAddress(_ id: AudioDeviceID) -> AudioObjectPropertyAddress? {
    existingOutputMasterAddress(id, kAudioDevicePropertyMute)
}

let volumeMuteListenerAddresses: [AudioObjectPropertyAddress] = [
    outputMasterAddress(kAudioDevicePropertyVolumeScalar),
    outputMasterAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
    outputMasterAddress(kAudioDevicePropertyMute),
]

func deviceVolumeScalarCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability {
    capability(id, at: deviceVolumeScalarAddress(id))
}

func deviceMuteCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability {
    capability(id, at: deviceMuteAddress(id))
}

func readDeviceVolumeScalar(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Float? {
    guard var addr = deviceVolumeScalarAddress(id) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

@discardableResult
func writeDeviceVolumeScalar(_ id: AudioDeviceID, _ value: Float, _ token: AudioWorldToken) -> Bool {
    guard var addr = deviceVolumeScalarAddress(id) else { return false }
    var v = value
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
}

func readDeviceMute(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool? {
    guard var addr = deviceMuteAddress(id) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

@discardableResult
func writeDeviceMute(_ id: AudioDeviceID, _ value: Bool, _ token: AudioWorldToken) -> Bool {
    guard var addr = deviceMuteAddress(id) else { return false }
    var v: UInt32 = value ? 1 : 0
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
}

// MARK: - カスタムプロパティ

/// 値そのものの大きさを渡すと弾かれる (受け取るのは参照 1 つぶん)。
@discardableResult
func setDeviceCustomProperty(
    _ selector: AudioObjectPropertySelector, _ value: CFTypeRef,
    forDeviceID id: AudioDeviceID, _ token: AudioWorldToken
) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var boxed = value
    let size = UInt32(MemoryLayout<CFTypeRef>.size)
    return withUnsafeMutablePointer(to: &boxed) {
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, UnsafeMutableRawPointer($0)) == noErr
    }
}

// デバイス側のプロパティ変更であり、アプリ終了後も値が残りうる。
func setBufferFrameSize(_ device: AudioDeviceID, _ frames: UInt32, _ token: AudioWorldToken) {
    var v = frames
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let st = AudioObjectSetPropertyData(device, &addr, 0, nil, 4, &v)
    if st != noErr { print("[warn] set buffer frame size (\(device)) failed: \(st)") }
}
