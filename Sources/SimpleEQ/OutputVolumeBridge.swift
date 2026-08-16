import CoreAudio
import Foundation

protocol DeviceVolumeIO: Sendable {
    func volumeCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability
    func muteCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability
    func readVolume(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Float?
    @discardableResult
    func writeVolume(_ id: AudioDeviceID, _ value: Float, _ token: AudioWorldToken) -> Bool
    func readMute(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool?
    @discardableResult
    func writeMute(_ id: AudioDeviceID, _ value: Bool, _ token: AudioWorldToken) -> Bool
    func addVolumeMuteListener(_ id: AudioDeviceID, queue: DispatchQueue, _ block: @escaping AudioObjectPropertyListenerBlock)
    func removeVolumeMuteListener(_ id: AudioDeviceID, queue: DispatchQueue, _ block: @escaping AudioObjectPropertyListenerBlock)
}

final class CoreAudioDeviceVolumeIO: DeviceVolumeIO {
    func volumeCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability {
        deviceVolumeScalarCapability(id, token)
    }

    func muteCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability {
        deviceMuteCapability(id, token)
    }

    func readVolume(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Float? {
        readDeviceVolumeScalar(id, token)
    }

    @discardableResult
    func writeVolume(_ id: AudioDeviceID, _ value: Float, _ token: AudioWorldToken) -> Bool {
        writeDeviceVolumeScalar(id, value, token)
    }

    func readMute(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool? {
        readDeviceMute(id, token)
    }

    @discardableResult
    func writeMute(_ id: AudioDeviceID, _ value: Bool, _ token: AudioWorldToken) -> Bool {
        writeDeviceMute(id, value, token)
    }

    func addVolumeMuteListener(_ id: AudioDeviceID, queue: DispatchQueue, _ block: @escaping AudioObjectPropertyListenerBlock) {
        for var addr in volumeMuteListenerAddresses {
            AudioObjectAddPropertyListenerBlock(id, &addr, queue, block)
        }
    }

    func removeVolumeMuteListener(_ id: AudioDeviceID, queue: DispatchQueue, _ block: @escaping AudioObjectPropertyListenerBlock) {
        for var addr in volumeMuteListenerAddresses {
            AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
        }
    }
}

final class OutputVolumeBridge: @unchecked Sendable {
    private let audioWorld: AudioWorld
    private let deviceIO: DeviceVolumeIO

    var appGainDidChange: (@Sendable (Float) -> Void)?
    var driverVolumeWriteRequested: (@Sendable (Float, AudioWorldToken) -> Void)?
    var driverMuteWriteRequested: (@Sendable (Bool, AudioWorldToken) -> Void)?
    var realDeviceDidNotify: (@Sendable (AudioDeviceID, AudioWorldToken) -> Void)?

    private(set) var boundUID: String?
    private(set) var boundDeviceID: AudioDeviceID?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private(set) var listenerDeviceID: AudioDeviceID?
    private(set) var established = false

    private var hasAdoptedThisSession = false
    private var appVolumeByUID: [String: Float] = [:]

    private(set) var volumeMode: VolumeControlMode = .app
    private(set) var muteMode: VolumeControlMode = .app
    private(set) var volumeDowngraded = false
    private(set) var muteDowngraded = false

    private(set) var appVolume: Float = 1
    private(set) var appMuted = false
    private var lastPublishedGain: Float?

    init(audioWorld: AudioWorld, deviceIO: DeviceVolumeIO = CoreAudioDeviceVolumeIO()) {
        self.audioWorld = audioWorld
        self.deviceIO = deviceIO
    }

    // MARK: - 束ね直し

    @discardableResult
    func rebind(outputUID: String, outputDeviceID: AudioDeviceID, driverVolume: Float, driverMuted: Bool, _ token: AudioWorldToken) -> Bool {
        bind(
            outputUID: outputUID, outputDeviceID: outputDeviceID,
            driverVolume: driverVolume, driverMuted: driverMuted, forceAdopt: false, token
        )
    }

    @discardableResult
    func rebindWithAdoption(outputUID: String, outputDeviceID: AudioDeviceID, driverVolume: Float, driverMuted: Bool, _ token: AudioWorldToken) -> Bool {
        bind(
            outputUID: outputUID, outputDeviceID: outputDeviceID,
            driverVolume: driverVolume, driverMuted: driverMuted, forceAdopt: true, token
        )
    }

    @discardableResult
    private func bind(
        outputUID: String, outputDeviceID: AudioDeviceID,
        driverVolume: Float, driverMuted: Bool, forceAdopt: Bool, _ token: AudioWorldToken
    ) -> Bool {
        let actions = outputDeviceRebindActions(
            boundUID: boundUID, listenerDeviceID: listenerDeviceID,
            resolvedUID: outputUID, resolvedDeviceID: outputDeviceID
        )
        established = false
        applyListenerActions(actions, deviceID: outputDeviceID, token)
        boundUID = outputUID
        boundDeviceID = outputDeviceID

        guard actions.adopt || forceAdopt else {
            established = listenerDeviceID != nil
            return false
        }
        adopt(outputUID: outputUID, outputDeviceID: outputDeviceID, driverVolume: driverVolume, driverMuted: driverMuted, token)
        established = true
        return true
    }

    func unbind(_ token: AudioWorldToken) {
        let actions = outputDeviceRebindActions(
            boundUID: boundUID, listenerDeviceID: listenerDeviceID, resolvedUID: nil, resolvedDeviceID: nil
        )
        applyListenerActions(actions, deviceID: nil, token)
        boundUID = nil
        boundDeviceID = nil
        established = false
        volumeMode = .app
        muteMode = .app
        volumeDowngraded = false
        muteDowngraded = false
    }

    func routeObservation(_ token: AudioWorldToken) -> VolumeRouteObservation? {
        guard let id = boundDeviceID else { return nil }
        return VolumeRouteObservation(
            volumeMode: volumeMode,
            volumeDowngraded: volumeDowngraded,
            volume: volumeMode == .device ? deviceIO.readVolume(id, token) : appVolume,
            muteMode: muteMode,
            muteDowngraded: muteDowngraded,
            muted: muteMode == .device ? deviceIO.readMute(id, token) : appMuted
        )
    }

    private func applyListenerActions(_ actions: OutputDeviceRebindActions, deviceID: AudioDeviceID?, _ token: AudioWorldToken) {
        if actions.unregisterListener, let id = listenerDeviceID, let block = listenerBlock {
            deviceIO.removeVolumeMuteListener(id, queue: audioWorld.queue, block)
            listenerBlock = nil
            listenerDeviceID = nil
        }
        if actions.registerListener, let id = deviceID {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let t = self.audioWorld.assumingOnQueue()
                self.realDeviceDidNotify?(id, t)
            }
            deviceIO.addVolumeMuteListener(id, queue: audioWorld.queue, block)
            listenerBlock = block
            listenerDeviceID = id
        }
    }

    private func adopt(outputUID: String, outputDeviceID: AudioDeviceID, driverVolume: Float, driverMuted: Bool, _ token: AudioWorldToken) {
        volumeDowngraded = false
        muteDowngraded = false

        let volumeCap = deviceIO.volumeCapability(outputDeviceID, token)
        volumeMode = volumeControlModeFromCapability(exists: volumeCap.exists, settable: volumeCap.settable)
        if volumeMode == .device, let realVolume = deviceIO.readVolume(outputDeviceID, token) {
            appVolume = 1
            if mirrorWriteNeeded(current: driverVolume, target: realVolume) {
                driverVolumeWriteRequested?(realVolume, token)
            }
        } else {
            volumeDowngraded = volumeMode == .device
            volumeMode = .app
            let adopted = appModeVolumeAdoption(
                remembered: appVolumeByUID[outputUID], isFirstBindOfSession: !hasAdoptedThisSession, driverCurrentScalar: driverVolume
            )
            appVolume = adopted
            appVolumeByUID[outputUID] = adopted
            if mirrorWriteNeeded(current: driverVolume, target: adopted) {
                driverVolumeWriteRequested?(adopted, token)
            }
        }

        let muteCap = deviceIO.muteCapability(outputDeviceID, token)
        muteMode = volumeControlModeFromCapability(exists: muteCap.exists, settable: muteCap.settable)
        if muteMode == .device, let realMuted = deviceIO.readMute(outputDeviceID, token) {
            appMuted = false
            if mirrorWriteNeeded(current: driverMuted, target: realMuted) {
                driverMuteWriteRequested?(realMuted, token)
            }
        } else {
            muteDowngraded = muteMode == .device
            muteMode = .app
            appMuted = driverMuted
        }

        hasAdoptedThisSession = true
        publishGain()
    }

    // MARK: - 前方ミラー

    func handleDriverVolumeNotification(volume: Float, muted: Bool, _ token: AudioWorldToken) {
        guard established, let outputDeviceID = boundDeviceID else { return }
        forwardMirrorVolume(volume, outputDeviceID: outputDeviceID, token)
        forwardMirrorMute(muted, outputDeviceID: outputDeviceID, token)
        publishGain()
    }

    private func forwardMirrorVolume(_ volume: Float, outputDeviceID: AudioDeviceID, _ token: AudioWorldToken) {
        guard volumeMode == .device else {
            appVolume = volume
            if let boundUID { appVolumeByUID[boundUID] = volume }
            return
        }
        guard let before = deviceIO.readVolume(outputDeviceID, token) else {
            downgradeVolume(to: volume)
            return
        }
        guard mirrorWriteNeeded(current: before, target: volume) else { return }
        let writeSucceeded = deviceIO.writeVolume(outputDeviceID, volume, token)
        let readback = writeSucceeded ? deviceIO.readVolume(outputDeviceID, token) : nil
        switch writeReadbackJudgment(writeSucceeded: writeSucceeded, written: volume, readback: readback) {
        case .normal:
            appVolume = 1
        case .rounded(let actual):
            driverVolumeWriteRequested?(actual, token)
            appVolume = 1
        case .downgrade:
            downgradeVolume(to: volume)
        }
    }

    private func downgradeVolume(to volume: Float) {
        volumeMode = .app
        volumeDowngraded = true
        appVolume = volume
        if let boundUID { appVolumeByUID[boundUID] = volume }
    }

    private func forwardMirrorMute(_ muted: Bool, outputDeviceID: AudioDeviceID, _ token: AudioWorldToken) {
        guard muteMode == .device else {
            appMuted = muted
            return
        }
        guard let before = deviceIO.readMute(outputDeviceID, token) else {
            downgradeMute(to: muted)
            return
        }
        guard mirrorWriteNeeded(current: before, target: muted) else { return }
        let writeSucceeded = deviceIO.writeMute(outputDeviceID, muted, token)
        let readback = writeSucceeded ? deviceIO.readMute(outputDeviceID, token) : nil
        switch writeReadbackJudgment(writeSucceeded: writeSucceeded, written: muted, readback: readback) {
        case .normal:
            appMuted = false
        case .rounded, .downgrade:
            downgradeMute(to: muted)
        }
    }

    private func downgradeMute(to muted: Bool) {
        muteMode = .app
        muteDowngraded = true
        appMuted = muted
    }

    // MARK: - 後方ミラー

    func handleOutputDeviceNotification(deviceID: AudioDeviceID, driverVolume: Float, driverMuted: Bool, _ token: AudioWorldToken) {
        guard boundDeviceID == deviceID else { return }
        if volumeMode == .device, let realVolume = deviceIO.readVolume(deviceID, token), mirrorWriteNeeded(current: driverVolume, target: realVolume) {
            driverVolumeWriteRequested?(realVolume, token)
        }
        if muteMode == .device, let realMuted = deviceIO.readMute(deviceID, token), mirrorWriteNeeded(current: driverMuted, target: realMuted) {
            driverMuteWriteRequested?(realMuted, token)
        }
    }

    private func publishGain() {
        let gain = bridgeOutputGain(volumeMode: volumeMode, volume: appVolume, muteMode: muteMode, muted: appMuted)
        guard gain != lastPublishedGain else { return }
        lastPublishedGain = gain
        appGainDidChange?(gain)
    }
}
