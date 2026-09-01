import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// --- realtime レンダ実体の補助 -------------------------------------

/// AudioUnitRender は mDataByteSize を実生成バイト数へ書き下げる。復元しないと要求フレーム数が
/// 増えた回から render が失敗し続ける。
func restorePlanarBufferByteSize(_ ioData: UnsafeMutablePointer<AudioBufferList>, bytesPerChannel: UInt32) {
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    for c in 0..<abl.count { abl[c].mDataByteSize = bytesPerChannel }
}

/// 共有メモリリング → EQ (AUNBandEQ) → 出力 AUHAL のオーディオエンジン。
/// 共有メモリリングは読み取り専用 (書き込み/出力ターゲットにしない)。
final class AudioEngine: @unchecked Sendable {
    private var outputUnit: AudioUnit?
    private var eqUnit: EQUnit?
    private var ringReader: SharedRingReader?

    private let audioWorld: AudioWorld
    private var driverDeviceListenerQueue: DispatchQueue { audioWorld.queue }

    private(set) var processingState: ProcessingState = .suspended(.routeUnavailable)
    /// オーディオ世界のキュー上で発火する (呼び出し元は必要に応じてメインキューへ戻すこと)。
    /// 第2引数は稼働状態が稼働中でなければ nil。
    var processingStateDidChange: (@Sendable (ProcessingState, ActiveOutputDeviceInfo?) -> Void)?
    /// オーディオ世界のキュー上で発火する。
    var outputDeviceDidConfirm: (@Sendable (String) -> Void)?
    /// オーディオ世界のキュー上で発火する。引数は適用済みレート。
    var appliedSampleRateDidChange: (@Sendable (Double) -> Void)?
    /// テスト用の観測点 (計測のみ、他の状態に影響しない)。
    private(set) var suspensionHistory: [SuspensionCause] = []
    /// 停止直前のあるべき出力先 UID。停止で intendedOutputDeviceUID が失われた後も残り、assemble() の
    /// 成功時に破棄する。
    private(set) var intendedOutputDeviceUIDAtSuspension: String?

    /// EQ ユニットの生成と初期化。既定は実装本体で、差し替え可能な境界として持つ。
    var makeEQUnit: (UInt32, @escaping AURenderCallback, UnsafeMutableRawPointer, AudioWorldToken) -> EQUnit? = { maxFrames, renderCallback, refCon, _ in
        guard let eq = EQUnit() else { return nil }
        let format = EQStreamFormat(channels: AudioConfig.channels, sampleRate: AudioConfig.appliedSampleRate)
        guard eq.setup(format: format, maxFrames: maxFrames, renderCallback: renderCallback, refCon: refCon) else {
            // 境界の内側で前段の生成物を破棄する。クロージャが nil を返すと、呼び出し側の
            // 解放対象に入らないため。
            eq.dispose()
            return nil
        }
        return eq
    }
    /// 出力ユニットの生成と出力デバイスの適用 (失敗時は生成済みの資源を後始末してから nil を返す)。
    private static func makeOutputUnit(
        for deviceID: AudioDeviceID, metrics: AudioRuntimeMetrics, _ token: AudioWorldToken
    ) -> AudioUnit? {
        guard let unit = makeHALUnit() else { return nil }
        guard applyOutputDevice(deviceID, on: unit, metrics: metrics, token) else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    private let eqInputScratch: UnsafeMutablePointer<Float>

    private var eqPlanarOutputABL: UnsafeMutablePointer<AudioBufferList>?
    private var eqPlanarOutputBufs: [UnsafeMutablePointer<Float>] = []

    let levelMeter: LevelMeter

    /// 可視性の再開は含めない。
    let levelMeterRestartGeneration = AtomicUInt64(0)

    let runtimeMetrics = AudioRuntimeMetrics()
    func evaluateRingStalled(_ token: AudioWorldToken) -> Bool {
        guard let reader = ringReader else { return true }
        return reader.checkWriterStalled()
    }

    func refreshDriverObservations(_ token: AudioWorldToken) {
        ringReader?.refreshDriverObservations()
        runtimeMetrics.recordReaderObserved(ringReader != nil)
    }

    /// HAL への問い合わせを含むため、読み手が居ない間は呼んではならない。
    func refreshOutputDeviceSampleRate(_ token: AudioWorldToken) {
        guard let id = currentOutputDeviceID(token) else {
            runtimeMetrics.recordOutputDeviceSampleRate(0)
            return
        }
        runtimeMetrics.recordOutputDeviceSampleRate(nominalSampleRate(id, token) ?? 0)
    }

    func runtimeMetricsSnapshot(_ token: AudioWorldToken) -> AudioRuntimeMetrics.Snapshot {
        refreshDriverObservations(token)
        return runtimeMetrics.snapshot(
            appliedSampleRate: AudioConfig.appliedSampleRate,
            volumeRoute: outputVolumeBridge.routeObservation(token)
        )
    }

    /// AudioDeviceID はディスプレイスリープ復帰・coreaudiod 再起動で入れ替わる (実機で確認済み)。
    /// 使う直前に UID で検証する。
    private var driverDeviceID: AudioDeviceID?

    /// 実際の出力先は AUHAL 内蔵のフォールバックでアプリの関与なく張り替わりうるため、ID は
    /// キャッシュせず currentOutputDeviceID() で読み返す。
    private(set) var intendedOutputDeviceUID: String?

    /// ドライバのコントロールを未読の間の想定値 (仮の値)。
    private static let initialOutputVolume: Float = 1
    private static let initialOutputMuted = false

    private(set) var outputVolume: Float = AudioEngine.initialOutputVolume
    private(set) var outputMuted: Bool = AudioEngine.initialOutputMuted
    private(set) var outputGain: Float = effectiveOutputGain(
        volume: AudioEngine.initialOutputVolume, muted: AudioEngine.initialOutputMuted
    )
    let outputVolumeBridge: OutputVolumeBridge
    private let volumeDeviceIO: DeviceVolumeIO
    private(set) var preampGain: Float = 1
    private var preampDb: Double = 0
    private var bypassed = false
    private var driverDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// リスナー群を実際に登録したデバイス ID。解除は必ずこの ID に対して行う (driverDeviceID は
    /// 再解決で変わりうるため)。
    private(set) var driverDeviceListenerDeviceID: AudioDeviceID?

    /// HAL への問い合わせを含むため、読み手が居ない間は呼んではならない。書き手停止の判定結果に
    /// 関わらず無条件で呼ぶ (再生継続中の coreaudiod 再起動でも音量追従を復帰させるため)。
    func refreshDriverDeviceIDIfNeeded(_ token: AudioWorldToken) {
        if let id = driverDeviceID, deviceUID(id, token) == DriverConfig.deviceUID { return }
        updateDriverDeviceID(translateUIDToDeviceID(forUID: DriverConfig.deviceUID, token), token)
    }

    func updateDriverDeviceID(_ id: AudioDeviceID?, _ token: AudioWorldToken) {
        driverDeviceID = id
        applyDriverDeviceListenerRebind(token)
    }

    private func activeOutputDeviceInfo(_ token: AudioWorldToken) -> ActiveOutputDeviceInfo? {
        guard processingState == .active, let uid = intendedOutputDeviceUID, let id = currentOutputDeviceID(token) else { return nil }
        return ActiveOutputDeviceInfo(device: ResolvedOutputDevice(uid: uid, deviceID: id), name: deviceName(id, token))
    }

    init(audioWorld: AudioWorld = AudioWorld(), volumeDeviceIO: DeviceVolumeIO = CoreAudioDeviceVolumeIO()) {
        self.audioWorld = audioWorld
        self.volumeDeviceIO = volumeDeviceIO
        outputVolumeBridge = OutputVolumeBridge(audioWorld: audioWorld, deviceIO: volumeDeviceIO)
        eqInputScratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioConfig.maxRenderFrames * Int(AudioConfig.channels))
        levelMeter = LevelMeter(bandFrequencies: EQSpec.FREQS, appliedSampleRate: AudioConfig.appliedSampleRate)
        wireOutputVolumeBridge()
    }

    private func wireOutputVolumeBridge() {
        outputVolumeBridge.appGainDidChange = { [weak self] gain in
            self?.outputGain = gain
        }
        outputVolumeBridge.driverVolumeWriteRequested = { [weak self] volume, token in
            guard let self, let id = self.driverDeviceID, self.volumeDeviceIO.writeVolume(id, volume, token) else { return }
            self.outputVolume = volume
        }
        outputVolumeBridge.driverMuteWriteRequested = { [weak self] muted, token in
            guard let self, let id = self.driverDeviceID, self.volumeDeviceIO.writeMute(id, muted, token) else { return }
            self.outputMuted = muted
        }
        outputVolumeBridge.realDeviceDidNotify = { [weak self] deviceID, token in
            guard let self else { return }
            self.outputVolumeBridge.handleOutputDeviceNotification(
                deviceID: deviceID, driverVolume: self.outputVolume, driverMuted: self.outputMuted, token
            )
        }
    }

    private static func makeHALUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(comp, &unit) == noErr else { return nil }
        return unit
    }

    @discardableResult
    func assemble(outputDevice: ResolvedOutputDevice, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID? = nil, _ token: AudioWorldToken) -> Bool {
        guard processingState != .active else { return false }
        self.ringReader = ringReader
        ringReader.adopt(metrics: runtimeMetrics)
        // ヘッダの申告値が不正なら基準レートへ倒す (安全側)。
        let headerSampleRate = ringReader.driverReportedSampleRate
        applySampleRate(headerSampleRate > 0 ? headerSampleRate : AudioConfig.baseSampleRate, token)
        levelMeter.rebuild(appliedSampleRate: AudioConfig.appliedSampleRate)
        updateDriverDeviceID(driverDeviceID ?? translateUIDToDeviceID(forUID: DriverConfig.deviceUID, token), token)

        guard let outUnit = AudioEngine.makeOutputUnit(for: outputDevice.deviceID, metrics: runtimeMetrics, token) else {
            print("[ERROR] output unit create/apply failed")
            suspend(cause: .routeUnavailable, token)
            return false
        }
        outputUnit = outUnit
        intendedOutputDeviceUID = outputDevice.uid
        let driverAtAssemble = refreshDriverVolumeAndMute(token)
        outputVolumeBridge.rebind(
            outputUID: outputDevice.uid, outputDeviceID: outputDevice.deviceID,
            driverVolume: driverAtAssemble.volume, driverMuted: driverAtAssemble.muted, token
        )

        guard buildEQUnitAndStartOutput(on: outUnit, token) else {
            suspend(cause: .routeUnavailable, token)
            return false
        }
        startDriverDeviceMonitoring(token)

        levelMeterRestartGeneration.add(1)

        intendedOutputDeviceUIDAtSuspension = nil
        processingState = .active
        processingStateDidChange?(processingState, activeOutputDeviceInfo(token))
        appliedSampleRateDidChange?(AudioConfig.appliedSampleRate)
        outputDeviceDidConfirm?(outputDevice.uid)
        return true
    }

    private func buildEQUnitAndStartOutput(on outUnit: AudioUnit, _ token: AudioWorldToken) -> Bool {
        var asbd = AudioConfig.makeASBD()
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxFrames: UInt32 = UInt32(AudioConfig.maxRenderFrames)

        guard let eq = makeEQUnit(maxFrames, eqInputRenderProc, Unmanaged.passUnretained(self).toOpaque(), token) else {
            print("[ERROR] EQ unit create/setup failed")
            return false
        }
        eqUnit = eq
        setupPlanarOutputBuffers(maxFrames: maxFrames)

        // 出力 AUHAL は常に interleaved (EQ 側が非interleaved でも最終段で再interleave)。
        var st = AudioUnitSetProperty(outUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize)
        guard st == noErr else {
            print("[ERROR] set output format: \(st)")
            eqUnit?.dispose(); eqUnit = nil
            return false
        }
        AudioUnitSetProperty(outUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
        // ring を直読みせず、常に EQ 経由で render する。
        var outCb = AURenderCallbackStruct(
            inputProc: outputRenderProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        st = AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard st == noErr else {
            print("[ERROR] set output callback: \(st)")
            eqUnit?.dispose(); eqUnit = nil
            return false
        }
        st = AudioUnitInitialize(outUnit)
        guard st == noErr else {
            print("[ERROR] init output unit: \(st)")
            eqUnit?.dispose(); eqUnit = nil
            return false
        }
        guard AudioOutputUnitStart(outUnit) == noErr else {
            print("[ERROR] start output unit")
            AudioUnitUninitialize(outUnit)
            eqUnit?.dispose(); eqUnit = nil
            return false
        }
        return true
    }

    /// I/O バッファ長は出力デバイスの実サンプルレートから導出する (ドライバの実レートとは別の
    /// クロック領域)。取得に失敗した場合は基準レートで代替する。
    private static func applyOutputDevice(
        _ id: AudioDeviceID, on unit: AudioUnit, metrics: AudioRuntimeMetrics, _ token: AudioWorldToken
    ) -> Bool {
        let queriedSampleRate = nominalSampleRate(id, token)
        let deviceSampleRate = queriedSampleRate ?? AudioConfig.baseSampleRate
        setBufferFrameSize(id, AudioConfig.ioBufferFrames(deviceSampleRate: deviceSampleRate), token)
        var dev = id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
        if st != noErr { print("[ERROR] set output device: \(st)"); return false }
        metrics.recordOutputDeviceSampleRate(queriedSampleRate ?? 0)
        return true
    }

    /// AUHAL は内蔵のフォールバックでアプリの関与なく出力先を張り替えることがあるため、現在の
    /// 出力先は必ずここから読み返す (キャッシュしない)。
    func currentOutputDeviceID(_ token: AudioWorldToken) -> AudioDeviceID? {
        guard let outUnit = outputUnit else { return nil }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioUnitGetProperty(outUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        guard st == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// kAudioOutputUnitProperty_CurrentDevice は AudioUnit 稼働中に変更しても反映が不定になるため、
    /// Stop → プロパティ変更 → Start の手順を踏む。Stop〜Start の間は書き手が止まらずバッファ量が
    /// 押し上がるため、共有メモリ読み手に作り直しを要求し次回の読み取りで作り直させる (失敗して旧デバイスへ
    /// 戻す経路でも同じ要求を行うが、その経路では復旧の Start が要求のあとに来る)。
    @discardableResult
    func switchOutputDevice(to device: ResolvedOutputDevice, _ token: AudioWorldToken) -> Bool {
        guard let outUnit = outputUnit else { return false }
        let previousID = currentOutputDeviceID(token)
        if case .notNeeded = outputSwitchDecision(intendedUID: device.uid, currentUID: previousID.flatMap({ deviceUID($0, token) })) {
            intendedOutputDeviceUID = device.uid
            let driver = refreshDriverVolumeAndMute(token)
            outputVolumeBridge.rebind(
                outputUID: device.uid, outputDeviceID: device.deviceID,
                driverVolume: driver.volume, driverMuted: driver.muted, token
            )
            outputDeviceDidConfirm?(device.uid)
            return true
        }
        AudioOutputUnitStop(outUnit)
        let switched = AudioEngine.applyOutputDevice(device.deviceID, on: outUnit, metrics: runtimeMetrics, token)
        let restarted = AudioOutputUnitStart(outUnit) == noErr
        ringReader?.requestOccupancyReset()
        if switched && restarted {
            intendedOutputDeviceUID = device.uid
            let driver = refreshDriverVolumeAndMute(token)
            outputVolumeBridge.rebind(
                outputUID: device.uid, outputDeviceID: device.deviceID,
                driverVolume: driver.volume, driverMuted: driver.muted, token
            )
            outputDeviceDidConfirm?(device.uid)
            return true
        }
        if let previousID { _ = AudioEngine.applyOutputDevice(previousID, on: outUnit, metrics: runtimeMetrics, token) }
        AudioOutputUnitStart(outUnit)
        return false
    }

    /// サンプル領域は allocate(capacity:) 由来のため deallocate()、AudioBufferList の入れ物は
    /// calloc 由来のため free() で解放する (解放子は揃わない)。
    private func setupPlanarOutputBuffers(maxFrames: UInt32) {
        let channels = Int(AudioConfig.channels)
        let wrapper = AudioBufferList.allocate(maximumBuffers: channels)
        wrapper.count = channels
        for _ in 0..<channels {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
            buf.initialize(repeating: 0, count: Int(maxFrames))
            eqPlanarOutputBufs.append(buf)
        }
        for c in 0..<channels {
            wrapper[c] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: maxFrames * UInt32(MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(eqPlanarOutputBufs[c])
            )
        }
        eqPlanarOutputABL = wrapper.unsafeMutablePointer
    }

    func suspend(cause: SuspensionCause, _ token: AudioWorldToken) {
        let alreadySuspendedAsCause: Bool
        if case .suspended(let current) = processingState, current == cause {
            alreadySuspendedAsCause = true
        } else {
            alreadySuspendedAsCause = false
        }
        releaseAudioResources(token)
        guard !alreadySuspendedAsCause else { return }
        suspensionHistory.append(cause)
        processingState = .suspended(cause)
        processingStateDidChange?(processingState, nil)
    }

    private func releaseAudioResources(_ token: AudioWorldToken) {
        intendedOutputDeviceUIDAtSuspension = intendedOutputDeviceUIDAtSuspensionCapture(
            current: intendedOutputDeviceUID, previouslyCaptured: intendedOutputDeviceUIDAtSuspension
        )
        stopDriverDeviceMonitoring(token)
        outputVolumeBridge.unbind(token)
        if let u = outputUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u); outputUnit = nil }
        intendedOutputDeviceUID = nil
        eqUnit?.dispose()
        eqUnit = nil
        ringReader = nil
        runtimeMetrics.recordOutputDeviceSampleRate(0)
        for buf in eqPlanarOutputBufs { buf.deallocate() }
        eqPlanarOutputBufs.removeAll()
        if let abl = eqPlanarOutputABL { free(UnsafeMutableRawPointer(abl)) }
        eqPlanarOutputABL = nil
    }

    // --- 制御 API (UI/ViewModel から呼ぶ公開面。いずれもオーディオ世界のキュー上でのみ呼べる) ----

    func setGain(band: Int, db: Double, _ token: AudioWorldToken) { eqUnit?.setGain(band: band, db: db) }
    func setAllGains(_ dbs: [Double], _ token: AudioWorldToken) { eqUnit?.setAllGains(dbs) }
    func setBypass(_ bypass: Bool, _ token: AudioWorldToken) {
        bypassed = bypass
        eqUnit?.setBypass(bypass)
        recomputePreampGain()
    }
    func setPreamp(db: Double, _ token: AudioWorldToken) {
        preampDb = db
        recomputePreampGain()
    }
    private func recomputePreampGain() {
        preampGain = effectivePreampGain(preampDb: preampDb, bypassed: bypassed)
    }

    /// 音に関わる資源に触れないため AudioWorldToken を取らない。
    func applyLevelMeterTuning(
        stereoCaptureEnabled: Bool, attackCoef: Double, releaseCoef: Double,
        peakHoldEnabled: Bool, peakHoldSeconds: Double, peakDecayDbPerSec: Double
    ) {
        levelMeter.stereoCaptureEnabled = stereoCaptureEnabled
        levelMeter.attackCoef = attackCoef
        levelMeter.releaseCoef = releaseCoef
        levelMeter.setPeakHoldEnabled(peakHoldEnabled)
        levelMeter.peakHoldSeconds = peakHoldSeconds
        levelMeter.peakDecayDbPerSec = peakDecayDbPerSec
    }

    // --- ドライバデバイスに張るリスナー群の追従 (システム音量・消音・公称サンプルレート) ------

    private static let volumeScalarAddress = outputMasterAddress(kAudioDevicePropertyVolumeScalar)
    private static let muteAddress = outputMasterAddress(kAudioDevicePropertyMute)
    private static let nominalSampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let driverDeviceListenerAddresses: [AudioObjectPropertyAddress] = [
        volumeScalarAddress, muteAddress, nominalSampleRateAddress,
    ]

    /// 実登録状態とは独立の、あるべき状態を表すフラグ。ID が一時的に解決不能で解除された後も、
    /// これが立っている限り回復時に再登録される。
    private var driverDeviceMonitoringDesired = false

    private func startDriverDeviceMonitoring(_ token: AudioWorldToken) {
        driverDeviceMonitoringDesired = true
        applyDriverDeviceListenerRebind(token)
    }

    private func stopDriverDeviceMonitoring(_ token: AudioWorldToken) {
        driverDeviceMonitoringDesired = false
        applyDriverDeviceListenerRebind(token)
    }

    private func applyDriverDeviceListenerRebind(_ token: AudioWorldToken) {
        let actions = driverDeviceListenerRebindActions(
            monitoringDesired: driverDeviceMonitoringDesired,
            registeredID: driverDeviceListenerDeviceID,
            resolvedID: driverDeviceID
        )
        if actions.unregister, let id = driverDeviceListenerDeviceID, let block = driverDeviceListenerBlock {
            for var addr in AudioEngine.driverDeviceListenerAddresses {
                AudioObjectRemovePropertyListenerBlock(id, &addr, driverDeviceListenerQueue, block)
            }
            driverDeviceListenerBlock = nil
            driverDeviceListenerDeviceID = nil
        }
        if actions.register, let id = driverDeviceID {
            bindOutputVolumeRoute(forcingAdoption: true, token)
            // block は登録先の id を直接キャプチャする (self.driverDeviceID の再読みだと登録先と食い違う)。
            // 通知はこのキュー自身から届くため、通行証はオーディオ世界の直列キュー上にいる根拠から得る。
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let t = self.audioWorld.assumingOnQueue()
                self.handleDriverDevicePropertyNotification(deviceID: id, t)
            }
            driverDeviceListenerBlock = block
            driverDeviceListenerDeviceID = id
            for var addr in AudioEngine.driverDeviceListenerAddresses {
                AudioObjectAddPropertyListenerBlock(id, &addr, driverDeviceListenerQueue, block)
            }
        }
    }

    func handleDriverDevicePropertyNotification(deviceID: AudioDeviceID, _ token: AudioWorldToken) {
        let newVolume = volumeDeviceIO.readVolume(deviceID, token) ?? outputVolume
        let newMuted = volumeDeviceIO.readMute(deviceID, token) ?? outputMuted
        applyDriverVolumeAndMute(volume: newVolume, muted: newMuted, token)
        applyDriverSampleRateIfChanged(token)
    }

    func applyDriverVolumeAndMute(volume: Float, muted: Bool, _ token: AudioWorldToken) {
        outputVolume = volume
        outputMuted = muted
        outputVolumeBridge.handleDriverVolumeNotification(volume: volume, muted: muted, token)
    }

    @discardableResult
    func refreshDriverVolumeAndMute(_ token: AudioWorldToken) -> (volume: Float, muted: Bool) {
        guard let id = driverDeviceID else { return (outputVolume, outputMuted) }
        outputVolume = volumeDeviceIO.readVolume(id, token) ?? outputVolume
        outputMuted = volumeDeviceIO.readMute(id, token) ?? outputMuted
        return (outputVolume, outputMuted)
    }

    func reoccupyOutputVolumeRoute(_ token: AudioWorldToken) {
        guard processingState == .active else { return }
        bindOutputVolumeRoute(forcingAdoption: false, token)
    }

    private func bindOutputVolumeRoute(forcingAdoption: Bool, _ token: AudioWorldToken) {
        guard let id = currentOutputDeviceID(token), let uid = deviceUID(id, token) else {
            outputVolumeBridge.unbind(token)
            return
        }
        let driver = refreshDriverVolumeAndMute(token)
        if forcingAdoption {
            outputVolumeBridge.rebindWithAdoption(
                outputUID: uid, outputDeviceID: id,
                driverVolume: driver.volume, driverMuted: driver.muted, token
            )
        } else {
            outputVolumeBridge.rebind(
                outputUID: uid, outputDeviceID: id,
                driverVolume: driver.volume, driverMuted: driver.muted, token
            )
        }
    }

    // --- レート変更の検知・再構築 --------------------------------------------

    func applyDriverSampleRateIfChanged(_ token: AudioWorldToken) {
        guard processingState == .active, let reader = ringReader else { return }
        let headerRate = reader.driverReportedSampleRate
        guard headerRate > 0, headerRate != AudioConfig.appliedSampleRate else { return }
        performRateChange(newSampleRate: headerRate, token)
    }

    /// 呼び出しは出力 AUHAL が停止している間に限る。
    private func applySampleRate(_ rate: Double, _ token: AudioWorldToken) {
        AudioConfig.applySampleRate(rate)
        ringReader?.applySampleRate(rate)
    }

    /// レンダ側 (realtime) が減じる。release/acquire で共有する。
    private let outputFadeFramesRemaining = AtomicUInt64(0)
    /// 0=未完了、1=完了。レンダ側が release store、オーディオ世界のキューが acquire load で観測する。
    private let outputFadeCompleted = AtomicUInt64(0)
    /// オーディオ世界のキューのみが書き込み、レンダ側のみが読む。
    private var outputFadeTotalFrames = 0
    private static let outputFadeWaitMarginSeconds: TimeInterval = 0.02

    private func performRateChange(newSampleRate: Double, _ token: AudioWorldToken) {
        guard let outUnit = outputUnit else { return }
        let oldSampleRate = AudioConfig.appliedSampleRate

        // 出力へごく短い線形フェードアウトをかける (フレーム数は旧レートで換算)。
        beginOutputFadeOut(oldSampleRate: oldSampleRate)
        waitForOutputFadeCompletion()

        AudioOutputUnitStop(outUnit)
        AudioUnitUninitialize(outUnit)
        outputFadeFramesRemaining.store(0)
        eqUnit?.dispose()
        eqUnit = nil
        for buf in eqPlanarOutputBufs { buf.deallocate() }
        eqPlanarOutputBufs.removeAll()
        if let abl = eqPlanarOutputABL { free(UnsafeMutableRawPointer(abl)) }
        eqPlanarOutputABL = nil

        // 新しいレートを適用する。
        applySampleRate(newSampleRate, token)

        levelMeter.rebuild(appliedSampleRate: newSampleRate)
        guard buildEQUnitAndStartOutput(on: outUnit, token) else {
            suspend(cause: .routeUnavailable, token)
            return
        }
        // Stop〜Start の間に積み上がったぶんを作り直す (switchOutputDevice と同じ理由)。
        ringReader?.requestOccupancyReset()

        levelMeterRestartGeneration.add(1)

        // 設定の再適用はこの通知を契機に呼び出し側が行う。
        appliedSampleRateDidChange?(AudioConfig.appliedSampleRate)
    }

    private func beginOutputFadeOut(oldSampleRate: Double) {
        let totalFrames = OccupancyPolicy.seamFadeFrames(sampleRate: oldSampleRate)
        // クリアをフェード長書き込みより前に置く (前回の完了を素通りしないため)。
        outputFadeCompleted.store(0)
        outputFadeTotalFrames = totalFrames
        // release store: レンダ側が outputFadeTotalFrames を読める境界。
        outputFadeFramesRemaining.store(UInt64(totalFrames))
    }

    /// フェードが描き切られるまで待つ。レンダが走らない状況で無期限に待たないよう有界にする。
    private func waitForOutputFadeCompletion() {
        let deadline = Date().addingTimeInterval(OccupancyPolicy.seamFadeSeconds + Self.outputFadeWaitMarginSeconds)
        while outputFadeCompleted.value == 0, Date() < deadline {
            usleep(500)
        }
    }

    // --- realtime コールバック実体 -----------------------------------
    // print/alloc/lock は行わず、事前確保済みバッファ間の値の受け渡しのみを行う。

    // バッファ数は AU が決め、フォーマットから確定できるとは限らない。1本渡しの実機確認まで
    // 両分岐を残す。
    func renderEQInput(_ ioData: UnsafeMutablePointer<AudioBufferList>?, _ frames: UInt32) -> OSStatus {
        guard let ioData = ioData, let ringReader else { return noErr }
        guard case .renderable = renderBufferSizing(frames: frames, capacityFrames: AudioConfig.maxRenderFrames) else {
            return kAudio_ParamError
        }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        guard abl.count > 0 else { return noErr }

        let sampleCount = Int(frames) * Int(AudioConfig.channels)
        let got: Int
        if abl.count == 1 {
            guard let mData = abl[0].mData else { return noErr }
            let dst = mData.assumingMemoryBound(to: Float.self)
            got = ringReader.read(into: dst, frames: Int(frames))
            applyPreampGain(dst, count: sampleCount)
        } else {
            got = ringReader.read(into: eqInputScratch, frames: Int(frames))
            applyPreampGain(eqInputScratch, count: sampleCount)
            let channels = abl.count
            for c in 0..<channels {
                guard let mData = abl[c].mData else { continue }
                let dst = mData.assumingMemoryBound(to: Float.self)
                for f in 0..<Int(frames) { dst[f] = eqInputScratch[f * channels + c] }
            }
        }
        runtimeMetrics.recordRead(requestedFrames: Int(frames), deliveredFrames: got)
        return noErr
    }

    private func applyPreampGain(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        guard preampGain != 1 else { return }
        for i in 0..<count { buf[i] *= preampGain }
    }

    /// レベル解析へ渡す信号も返すピークも、ゲインを掛ける前の振幅。
    func captureLevelsAndApplyOutputGain(
        _ buf: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int, gain: Float
    ) -> Float {
        levelMeter.capture(buf, frameCount: frameCount, channels: channels)

        let count = frameCount * channels
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(buf[i])) }
        guard gain != 1 else { return peak }
        for i in 0..<count { buf[i] *= gain }
        return peak
    }

    // 出力コールバック実体: 常に EQ 経由で render し、結果を ioData (interleaved) へ書く。
    func renderOutput(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ ts: UnsafePointer<AudioTimeStamp>,
        _ frames: UInt32,
        _ ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData = ioData, let eq = eqUnit else { return noErr }
        guard case .renderable(let bytesPerChannel) = renderBufferSizing(
            frames: frames, capacityFrames: AudioConfig.maxRenderFrames
        ) else {
            return kAudio_ParamError
        }

        guard let planarOut = eqPlanarOutputABL else { return noErr }
        restorePlanarBufferByteSize(planarOut, bytesPerChannel: bytesPerChannel)
        let st = eq.render(flags: flags, timestamp: ts, frames: frames, ioData: planarOut)
        if st == noErr { reinterleave(planarOut, into: ioData, frames: Int(frames)) }
        guard st == noErr else { return st }

        guard let mData = UnsafeMutableAudioBufferListPointer(ioData).first?.mData else { return noErr }
        let dst = mData.assumingMemoryBound(to: Float.self)

        let gain = outputGain
        let peakBeforeVolume = captureLevelsAndApplyOutputGain(
            dst, frameCount: Int(frames), channels: Int(AudioConfig.channels), gain: gain
        )

        applyOutputFade(dst, frameCount: Int(frames), channels: Int(AudioConfig.channels))

        recordOutputLevel(
            dst, frameCount: Int(frames), channels: Int(AudioConfig.channels),
            peakBeforeVolume: peakBeforeVolume, effectiveOutputGain: gain, reader: ringReader
        )
        return noErr
    }

    /// 添えるゲインにフェード係数は含まない (フェード末尾で無音判定寄りに振れるが、継続長が
    /// クロスフェード長を超えないため実害はない)。
    func recordOutputLevel(
        _ dst: UnsafePointer<Float>, frameCount: Int, channels: Int,
        peakBeforeVolume: Float, effectiveOutputGain: Float, reader: SharedRingReader?
    ) {
        var peak: Float = 0
        for i in 0..<(frameCount * channels) { peak = max(peak, abs(dst[i])) }
        runtimeMetrics.recordPeak(peak)
        runtimeMetrics.recordPeakBeforeVolume(peakBeforeVolume)
        reader?.observeOutputLevel(peak: peak, effectiveOutputGain: effectiveOutputGain, frames: frameCount)
    }

    private func applyOutputFade(_ dst: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        var remaining = Int(outputFadeFramesRemaining.value)
        guard remaining > 0 else { return }
        let total = max(1, outputFadeTotalFrames)
        for f in 0..<frameCount {
            guard remaining > 0 else { break }
            let gain = Float(remaining) / Float(total)
            let base = f * channels
            for c in 0..<channels { dst[base + c] *= gain }
            remaining -= 1
        }
        outputFadeFramesRemaining.store(UInt64(remaining))
        if remaining == 0 {
            outputFadeCompleted.store(1)
        }
    }

    private func reinterleave(_ planar: UnsafeMutablePointer<AudioBufferList>, into ioData: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let src = UnsafeMutableAudioBufferListPointer(planar)
        guard let dstData = UnsafeMutableAudioBufferListPointer(ioData).first?.mData else { return }
        let dst = dstData.assumingMemoryBound(to: Float.self)
        let channels = src.count
        for c in 0..<channels {
            guard let srcData = src[c].mData else { continue }
            let s = srcData.assumingMemoryBound(to: Float.self)
            for f in 0..<frames { dst[f * channels + c] = s[f] }
        }
    }
}

// C コールバック trampoline (Swift メソッドは AURenderCallback の C 関数ポインタ要件を
// 直接満たせないため、free function 経由で Unmanaged self へ橋渡しする)

private func eqInputRenderProc(_ refCon: UnsafeMutableRawPointer,
                               _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               _ ts: UnsafePointer<AudioTimeStamp>,
                               _ bus: UInt32, _ frames: UInt32,
                               _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.renderEQInput(ioData, frames)
}

private func outputRenderProc(_ refCon: UnsafeMutableRawPointer,
                              _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ ts: UnsafePointer<AudioTimeStamp>,
                              _ bus: UInt32, _ frames: UInt32,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.renderOutput(flags, ts, frames, ioData)
}
