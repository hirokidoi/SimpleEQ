import CoreAudio

/// 出力を持つデバイスの一覧。差分から「新しく現れた出力デバイス」を読む。
struct OutputDeviceListSnapshot {
    let outputUIDs: Set<String>
    /// 現れたら出力先として追う種別のもの。
    let followableUIDs: Set<String>
}

/// HDMI/DisplayPort はディスプレイの復帰で消えて現れ直すため含めない。
func isFollowableOutputTransport(_ transport: UInt32?) -> Bool {
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth,
         kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
        return true
    default:
        return false
    }
}

/// 出力先が前の一覧に無い (coreaudiod の再起動などで一覧ごと入れ替わった) ときは追わない。
/// 同時に複数現れたときは、どれを選ぶか決められないため追わない。
func outputDeviceToFollow(
    previous: OutputDeviceListSnapshot?, current: OutputDeviceListSnapshot, intendedUID: String?
) -> String? {
    guard let previous, let intendedUID, previous.outputUIDs.contains(intendedUID) else { return nil }
    let appeared = current.followableUIDs.subtracting(previous.outputUIDs)
    guard appeared.count == 1 else { return nil }
    return appeared.first
}

/// 追従で決まった出力先と、それが消えたときの戻り先。
struct OutputDeviceFollowReturn {
    private struct Previous {
        let uid: String
        let wasFollowed: Bool
    }

    private(set) var followedUID: String?
    private var previous: Previous?
    var launchUID: String?

    mutating func noteFollowed(to uid: String, from previousUID: String?) {
        previous = previousUID.map { Previous(uid: $0, wasFollowed: $0 == followedUID) }
        followedUID = uid
    }

    /// 追従で選ばれていた先へ戻ったときだけ、戻った先を追従の結果として引き継ぐ。
    mutating func noteReturned(to uid: String) {
        followedUID = previous.flatMap { $0.uid == uid && $0.wasFollowed ? uid : nil }
        previous = nil
    }

    mutating func disarm() {
        followedUID = nil
        previous = nil
    }

    /// 消えた出力先が追従で決まったものでなければ空。優先順。
    func candidates(forVanished uid: String?) -> [String?] {
        guard let uid, uid == followedUID else { return [] }
        return [previous?.uid, launchUID]
    }
}
