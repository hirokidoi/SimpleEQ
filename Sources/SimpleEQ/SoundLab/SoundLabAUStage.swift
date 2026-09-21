import AudioToolbox
import CoreAudio

/// ライブシミュレーターを受け持つ AU の段。EQ チェーンの後ろに付く。
final class SoundLabAUStage {
    /// 書式を拒否されて落ちた場合は nil になり、その機能は効かない。
    private var reverb: AudioUnit?
    /// ユニットへ実際に書いた値。まだ書いていないものは nil。
    private var appliedBypass: Bool?
    private var appliedRoom: LiveSimulationRoom?
    private var appliedMix: Double?

    var outputUnit: AudioUnit? { reverb }

    init?() {
        guard let rv = Self.makeReverbUnit() else {
            print("[ERROR] SoundLabAUStage instantiate")
            return nil
        }
        reverb = rv
    }

    /// 書式を拒否されたらその機能ごと落とす。拒否の条件はチャンネル数であり、
    /// モノラルで組む測定の経路はこの段を付けずに呼ぶ。
    func setup(after source: AudioUnit, format: EQStreamFormat, maxFrames: UInt32) -> Bool {
        guard let unit = reverb else { return false }
        var asbd = AudioConfig.makePlanarASBD(channels: format.channels, sampleRate: format.sampleRate)
        guard acceptsFormat(unit, &asbd, maxFrames: maxFrames) else {
            print("[WARN] SoundLabAUStage reverb rejected the stream format; dropped")
            AudioComponentInstanceDispose(unit)
            reverb = nil
            return false
        }

        var conn = AudioUnitConnection(sourceAudioUnit: source, sourceOutputNumber: 0, destInputNumber: 0)
        let stConnect = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0,
            &conn, UInt32(MemoryLayout<AudioUnitConnection>.size)
        )
        guard stConnect == noErr else {
            print("[ERROR] SoundLabAUStage connect: \(stConnect)")
            return false
        }

        let stInit = AudioUnitInitialize(unit)
        guard stInit == noErr else {
            print("[ERROR] SoundLabAUStage initialize: \(stInit)")
            return false
        }

        // ユニット自身は切りの状態で始まらないため、ここで置く。
        apply(LiveSimulationSettings())
        return true
    }

    private func acceptsFormat(
        _ unit: AudioUnit, _ asbd: inout AudioStreamBasicDescription, maxFrames: UInt32
    ) -> Bool {
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let stIn = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize)
        let stOut = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, asbdSize)
        guard stIn == noErr, stOut == noErr else { return false }
        var frames = maxFrames
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &frames, UInt32(MemoryLayout<UInt32>.size)
        )
        return true
    }

    /// 空間の書き換えはユニットの構成に触れて響きを断つ。動いた値だけを書く。
    func apply(_ settings: LiveSimulationSettings) {
        guard let u = reverb else { return }
        let bypass = !settings.enabled
        if appliedBypass != bypass {
            appliedBypass = bypass
            setBypass(u, bypass)
        }
        guard settings.enabled else { return }
        if appliedRoom != settings.room {
            var roomType = settings.room.reverbRoomType.rawValue
            let st = AudioUnitSetProperty(
                u, kAudioUnitProperty_ReverbRoomType, kAudioUnitScope_Global, 0,
                &roomType, UInt32(MemoryLayout<UInt32>.size)
            )
            if st == noErr {
                appliedRoom = settings.room
            } else {
                print("[ERROR] SoundLabAUStage reverb room type: \(st)")
            }
        }
        if appliedMix != settings.mix {
            appliedMix = settings.mix
            AudioUnitSetParameter(
                u, kReverbParam_DryWetMix, kAudioUnitScope_Global, 0,
                AudioUnitParameterValue(settings.mix), 0
            )
        }
    }

    private func setBypass(_ u: AudioUnit, _ bypass: Bool) {
        var value: UInt32 = bypass ? 1 : 0
        AudioUnitSetProperty(
            u, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0,
            &value, UInt32(MemoryLayout<UInt32>.size)
        )
    }

    /// 残響の尾を落とす。チェーンを使い回す測定では、前回の尾が次の入力に混ざる。
    func reset() {
        guard let u = reverb else { return }
        AudioUnitReset(u, kAudioUnitScope_Global, 0)
    }

    func dispose() {
        guard let u = reverb else { return }
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        reverb = nil
        appliedBypass = nil
        appliedRoom = nil
        appliedMix = nil
    }

    private static func makeReverbUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_MatrixReverb,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(comp, &created) == noErr, let u = created else { return nil }
        return u
    }
}
