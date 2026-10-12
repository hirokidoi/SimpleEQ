import CoreAudio
import Foundation

/// 専用ドライバが内蔵ヘッドホンと名乗った直後に、OS が専用ドライバへ移したサウンドエフェクトの再生装置を戻す。
final class SoundEffectsOutputKeeper: @unchecked Sendable {
    /// 名乗りから OS が再生装置を移すまでを覆う時間。設計値。
    static let holdWindow: TimeInterval = 5

    private let directory: AudioDeviceDirectory
    private let audioWorld: AudioWorld
    private let driverDeviceUID: String
    private let schedule: DeviceRoutingScheduler

    private var heldUID: String?
    private var holdGeneration: UInt64 = 0
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init(
        directory: AudioDeviceDirectory, audioWorld: AudioWorld, driverDeviceUID: String,
        schedule: @escaping DeviceRoutingScheduler
    ) {
        self.directory = directory
        self.audioWorld = audioWorld
        self.driverDeviceUID = driverDeviceUID
        self.schedule = schedule
    }

    /// claim が名乗りの書き込み。成功したときだけ窓を開く。
    @discardableResult
    func keepingSoundEffectsOutput(across claim: () -> Bool, _ token: AudioWorldToken) -> Bool {
        let beganHolding = heldUID == nil
        // 窓の中の名乗り直しでは読み直さない (OS が既に移しているかもしれない)。
        if beganHolding {
            // 既定出力と同じ再生装置は既定出力に合わせているとみなし、覚えない。
            guard let uid = currentSoundEffectsOutputUID(token), uid != driverDeviceUID,
                  uid != directory.defaultOutputDeviceID(token).flatMap({ directory.uid(forDeviceID: $0, token) })
            else { return claim() }
            heldUID = uid
        }
        // 名乗りより先に購読する (OS の移動は名乗りの直後に非同期で来る)。
        subscribeIfNeeded()
        let claimed = claim()
        guard claimed else {
            if beganHolding { releaseHold() }
            return false
        }
        holdGeneration &+= 1
        let generation = holdGeneration
        schedule(Self.holdWindow) { [weak self] token in
            self?.endHold(generation: generation, token)
        }
        return true
    }

    func soundEffectsOutputDidChange(_ token: AudioWorldToken) {
        guard let heldUID else { return }
        guard currentSoundEffectsOutputUID(token) == driverDeviceUID else { return }
        guard let heldID = directory.deviceID(forUID: heldUID, token) else { return }
        directory.setDefaultSystemOutputDeviceID(heldID, token)
    }

    private func currentSoundEffectsOutputUID(_ token: AudioWorldToken) -> String? {
        directory.defaultSystemOutputDeviceID(token).flatMap { directory.uid(forDeviceID: $0, token) }
    }

    private func subscribeIfNeeded() {
        guard listenerBlock == nil else { return }
        let block = audioWorld.propertyListener { [weak self] token in
            self?.soundEffectsOutputDidChange(token)
        }
        listenerBlock = block
        directory.addDefaultSystemOutputListener(queue: audioWorld.listenerQueue, block)
    }

    private func endHold(generation: UInt64, _ token: AudioWorldToken) {
        guard generation == holdGeneration else { return }
        releaseHold()
    }

    private func releaseHold() {
        if let block = listenerBlock {
            directory.removeDefaultSystemOutputListener(queue: audioWorld.listenerQueue, block)
        }
        listenerBlock = nil
        heldUID = nil
    }
}
