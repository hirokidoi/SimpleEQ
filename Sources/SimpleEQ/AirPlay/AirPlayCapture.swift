import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - CaptureRing

/// 取り込み経路の SPSC リング。書き手は取り込みの IOProc、読み手は出力のレンダ経路。
final class CaptureRing: @unchecked Sendable {
    /// 構築ごとに新しいリングを作るため、書き手の再起動を表す世代は進まない。
    private static let epoch: UInt32 = 0

    let capacityFrames: Int
    private let channels: Int
    private let payload: UnsafeMutablePointer<Float>
    private let writeCounter = AtomicUInt64(0)
    private let lastWriteHostTimeStorage = AtomicUInt64(0)
    private let writerStartHostTimeStorage = AtomicUInt64(0)
    private let cursor: OccupancyCursor

    static func capacityFrames(sampleRate: Double) -> Int {
        let blockFrames = AudioConfig.maxRenderFrames
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: blockFrames, clientRequestFrames: blockFrames, sampleRate: sampleRate
        )
        return OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: blockFrames, sampleRate: sampleRate
        ) + blockFrames
    }

    init(
        sampleRate: Double, channels: Int = Int(AudioConfig.channels), primingEnabled: Bool = true,
        initialWriterBlockFrames: Int = OccupancyPolicy.bootstrapWriterBlockFrames,
        metrics: AudioRuntimeMetrics = AudioRuntimeMetrics()
    ) {
        capacityFrames = Self.capacityFrames(sampleRate: sampleRate)
        self.channels = channels
        payload = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * channels)
        payload.initialize(repeating: 0, count: capacityFrames * channels)
        cursor = OccupancyCursor(
            ringFrames: capacityFrames, channels: channels, primingEnabled: primingEnabled,
            initialWriterBlockFrames: initialWriterBlockFrames, appliedSampleRate: sampleRate, metrics: metrics
        )
    }

    deinit {
        payload.deallocate()
    }

    // --- 書き手 (取り込みの IOProc) -------------------------------------------------------
    // ロック・メモリ確保・ログは行わない。書くかどうかを判断せず常に書く。

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        let start = writeCounter.value
        var written = 0
        while written < frames {
            let ringIndex = Int((start + UInt64(written)) % UInt64(capacityFrames))
            let run = min(frames - written, capacityFrames - ringIndex)
            (payload + ringIndex * channels).update(from: source + written * channels, count: run * channels)
            written += run
        }
        writeCounter.store(start + UInt64(frames))
        lastWriteHostTimeStorage.store(mach_absolute_time())
    }

    // --- 読み手 (出力のレンダ経路) --------------------------------------------------------

    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        cursor.read(
            into: dst, frames: frames,
            writeCounter: writeCounter.value, epoch: Self.epoch, payload: UnsafePointer(payload)
        )
    }

    func observeOutputLevel(peak: Float, effectiveOutputGain: Float, frames: Int) {
        cursor.observeOutputLevel(peak: peak, effectiveOutputGain: effectiveOutputGain, frames: frames)
    }

    /// 読む側も同じ realtime 経路に限る (非アトミック)。
    var silentOutputFrameCount: Int { cursor.silentOutputFrameCount }

    // --- 経路外 -------------------------------------------------------------------------

    var metrics: AudioRuntimeMetrics { cursor.metrics }

    /// 呼び出しは realtime コールバック開始前に限る。
    func adopt(metrics: AudioRuntimeMetrics) {
        cursor.adopt(metrics: metrics)
    }

    /// 呼び出しは出力 AUHAL 停止中の 1 回に限る。
    func applySampleRate(_ rate: Double) {
        cursor.applySampleRate(rate)
    }

    var lastWriteHostTime: UInt64 { lastWriteHostTimeStorage.value }

    /// 開始の印から最後の書き込み時刻が動いたか。時刻は 1 回の保存で入れ替わるので、書き手の途中を読まない。
    var hasReceivedWriteSinceStart: Bool { lastWriteHostTimeStorage.value != writerStartHostTimeStorage.value }

    /// 書き手の開始より前に呼ぶ。最初の書き込みまでを書き手の停止と読まないため。
    func markWriterStarting() {
        let now = mach_absolute_time()
        writerStartHostTimeStorage.store(now)
        lastWriteHostTimeStorage.store(now)
    }
}

// MARK: - 1 周期の取り込み

enum CaptureInputLayout: Equatable, Sendable {
    case interleaved
    case nonInterleaved
}

/// IOProc の 1 周期ぶんの本体。出力は常に 0 で埋め、Tap のバッファが無い周期は同じフレーム数の無音を書く。
/// scratch は scratchFrames × channels の事前確保の作業域。
func writeCaptureCycle(
    input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>?,
    layout: CaptureInputLayout, channels: Int,
    scratch: UnsafeMutablePointer<Float>, scratchFrames: Int, fallbackCycleFrames: Int,
    into ring: CaptureRing
) {
    let sampleBytes = MemoryLayout<Float>.size
    var outputFrames: Int?
    if let output {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            if outputFrames == nil, buffer.mNumberChannels > 0 {
                outputFrames = Int(buffer.mDataByteSize) / (sampleBytes * Int(buffer.mNumberChannels))
            }
        }
    }

    // サブデバイスの入力が先、Tap が後ろに並ぶ。
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    switch layout {
    case .interleaved:
        if inputs.count >= 1 {
            let tap = inputs[inputs.count - 1]
            if let data = tap.mData, Int(tap.mNumberChannels) == channels {
                let frames = Int(tap.mDataByteSize) / (sampleBytes * channels)
                if frames > 0 {
                    ring.write(UnsafePointer(data.assumingMemoryBound(to: Float.self)), frames: frames)
                    return
                }
            }
        }
    case .nonInterleaved:
        if inputs.count >= channels {
            let firstTapBuffer = inputs.count - channels
            var frames = Int.max
            var complete = true
            for c in 0..<channels {
                let buffer = inputs[firstTapBuffer + c]
                guard buffer.mData != nil else { complete = false; break }
                frames = min(frames, Int(buffer.mDataByteSize) / sampleBytes)
            }
            if complete, frames > 0 {
                var written = 0
                while written < frames {
                    let chunk = min(frames - written, scratchFrames)
                    for c in 0..<channels {
                        let source = inputs[firstTapBuffer + c].mData!.assumingMemoryBound(to: Float.self) + written
                        for f in 0..<chunk { scratch[f * channels + c] = source[f] }
                    }
                    ring.write(UnsafePointer(scratch), frames: chunk)
                    written += chunk
                }
                return
            }
        }
    }

    let silentFrames = outputFrames ?? fallbackCycleFrames
    var written = 0
    while written < silentFrames {
        let chunk = min(silentFrames - written, scratchFrames)
        scratch.update(repeating: 0, count: chunk * channels)
        ring.write(UnsafePointer(scratch), frames: chunk)
        written += chunk
    }
}

/// IOProc が参照する、構築時に決めた値と事前確保の作業域。
final class CaptureIOContext: @unchecked Sendable {
    let ring: CaptureRing
    let layout: CaptureInputLayout
    let channels: Int
    let scratchFrames: Int
    let fallbackCycleFrames: Int
    let scratch: UnsafeMutablePointer<Float>

    init(ring: CaptureRing, layout: CaptureInputLayout, channels: Int, fallbackCycleFrames: Int) {
        self.ring = ring
        self.layout = layout
        self.channels = channels
        scratchFrames = AudioConfig.maxRenderFrames
        self.fallbackCycleFrames = fallbackCycleFrames
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * channels)
        scratch.initialize(repeating: 0, count: scratchFrames * channels)
    }

    deinit {
        scratch.deallocate()
    }
}

private func captureIOProc(
    _ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>, _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>, _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>, _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = Unmanaged<CaptureIOContext>.fromOpaque(clientData).takeUnretainedValue()
    writeCaptureCycle(
        input: inputData, output: outputData, layout: context.layout, channels: context.channels,
        scratch: context.scratch, scratchFrames: context.scratchFrames,
        fallbackCycleFrames: context.fallbackCycleFrames, into: context.ring
    )
    return noErr
}

// MARK: - 取り込み経路の資源

/// エンジンが持つ取り込み経路。開始・破棄はオーディオ世界だけが行う。
protocol AirPlayCaptureSource: AnyObject, Sendable {
    var ring: CaptureRing { get }
    var sampleRate: Double { get }
    var endpointUID: String { get }
    var endpointDeviceID: AudioDeviceID { get }
    var ioBufferFrames: Int { get }
    func currentSampleRate(_ token: AudioWorldToken) -> Double?
    @discardableResult
    func start(_ token: AudioWorldToken) -> Bool
    /// 冪等。
    func destroy(_ token: AudioWorldToken)
}

final class AirPlayCapture: AirPlayCaptureSource, @unchecked Sendable {
    private static let aggregateName = "SimpleEQ AirPlay Capture"

    let ring: CaptureRing
    let sampleRate: Double
    let endpointUID: String
    let endpointDeviceID: AudioDeviceID
    let ioBufferFrames: Int
    private let context: CaptureIOContext
    private var tapID: AudioObjectID
    private var aggregateID: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    private init(
        request: CaptureBuildRequest, sampleRate: Double, ioBufferFrames: Int, context: CaptureIOContext,
        tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID
    ) {
        ring = context.ring
        self.sampleRate = sampleRate
        endpointUID = request.endpointUID
        endpointDeviceID = request.endpointDeviceID
        self.ioBufferFrames = ioBufferFrames
        self.context = context
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
    }

    func currentSampleRate(_ token: AudioWorldToken) -> Double? {
        nominalSampleRate(aggregateID, token)
    }

    @discardableResult
    func start(_ token: AudioWorldToken) -> Bool {
        guard let procID else { return false }
        return AudioDeviceStart(aggregateID, procID) == noErr
    }

    func destroy(_ token: AudioWorldToken) {
        Self.teardown(tapID: &tapID, aggregateID: &aggregateID, procID: &procID)
    }

    private static func teardown(
        tapID: inout AudioObjectID, aggregateID: inout AudioObjectID, procID: inout AudioDeviceIOProcID?
    ) {
        if aggregateID != kAudioObjectUnknown, let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// 構築キューで呼ぶ。途中で失敗したら、まだ誰にも渡していない資源をここで破棄する。
    static func make(request: CaptureBuildRequest, selfProcessObjectID: AudioObjectID) -> AirPlayCaptureSource? {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        func fail() -> AirPlayCaptureSource? {
            teardown(tapID: &tapID, aggregateID: &aggregateID, procID: &procID)
            return nil
        }

        let description = CATapDescription(
            __excludingProcesses: [NSNumber(value: selfProcessObjectID)],
            andDeviceUID: request.endpointUID, withStream: 0
        )
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return fail() }

        guard let format = readProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              let layout = captureInputLayout(format) else { return fail() }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: request.endpointUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: request.endpointUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return fail() }
        guard let sampleRate = readProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0)), sampleRate > 0,
              let bufferFrames = readProperty(aggregateID, kAudioDevicePropertyBufferFrameSize, UInt32(0)), bufferFrames > 0
        else { return fail() }

        let context = CaptureIOContext(
            ring: CaptureRing(sampleRate: sampleRate), layout: layout,
            channels: Int(AudioConfig.channels), fallbackCycleFrames: Int(bufferFrames)
        )
        guard AudioDeviceCreateIOProcID(
            aggregateID, captureIOProc, Unmanaged.passUnretained(context).toOpaque(), &procID
        ) == noErr, let createdProcID = procID else { return fail() }

        return AirPlayCapture(
            request: request, sampleRate: sampleRate, ioBufferFrames: Int(bufferFrames), context: context,
            tapID: tapID, aggregateID: aggregateID, procID: createdProcID
        )
    }

    /// 経路の段が前提にする形式 (Float PCM・経路のチャンネル数) でなければ nil。
    static func captureInputLayout(_ format: AudioStreamBasicDescription) -> CaptureInputLayout? {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == UInt32(MemoryLayout<Float>.size * 8),
              format.mChannelsPerFrame == AudioConfig.channels else { return nil }
        return format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? .nonInterleaved : .interleaved
    }

    private static func readProperty<Value: BitwiseCopyable>(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: Value
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

// MARK: - 収録の許可

struct CaptureAuthorizationProbe: Sendable {
    typealias Preflight = @Sendable () -> Int32
    typealias Request = @Sendable (_ completion: @escaping @Sendable (Bool) -> Void) -> Void

    let preflight: Preflight?
    let request: Request?

    private static let frameworkPath = "/System/Library/PrivateFrameworks/TCC.framework/TCC"
    private static let service = "kTCCServiceAudioCapture"

    static let system = resolveSystemSymbols()

    // 宣言して直接呼ぶと、シンボルが無い環境で起動できない。
    private static func resolveSystemSymbols() -> CaptureAuthorizationProbe {
        typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
        typealias RequestFunction = @convention(c) (CFString, CFDictionary?, AnyObject) -> Void
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return CaptureAuthorizationProbe(preflight: nil, request: nil)
        }
        var preflight: Preflight?
        if let symbol = dlsym(handle, "TCCAccessPreflight") {
            let function = unsafeBitCast(symbol, to: PreflightFunction.self)
            preflight = { function(service as CFString, nil) }
        }
        var request: Request?
        if let symbol = dlsym(handle, "TCCAccessRequest") {
            let function = unsafeBitCast(symbol, to: RequestFunction.self)
            request = { (completion: @escaping @Sendable (Bool) -> Void) in
                // TCC がブロックを保持して後で呼ぶので、非エスケープで渡すとランタイムが停止させる。
                let callback: @convention(block) @Sendable (Bool) -> Void = { granted in completion(granted) }
                function(service as CFString, nil, callback as AnyObject)
            }
        }
        return CaptureAuthorizationProbe(preflight: preflight, request: request)
    }
}

/// Tap を張る前に許可状態を確定させる門。構築キューの上だけで読み書きする。
final class CaptureAuthorizationGate: @unchecked Sendable {
    enum RequestProgress: Equatable {
        case notRequested
        case awaitingResult
        case resulted(granted: Bool)
    }

    enum Decision: Equatable {
        case build(CaptureAuthorization)
        case request
        case awaitResult
    }

    enum Admission: Equatable {
        case build(CaptureAuthorization)
        case awaitingResult
    }

    private enum PreflightValue {
        static let granted: Int32 = 0
        static let denied: Int32 = 1
        static let undetermined: Int32 = 2
    }

    private let probe: CaptureAuthorizationProbe
    private let queue: DispatchQueue
    private let resultDidArrive: @Sendable () -> Void
    private(set) var progress: RequestProgress = .notRequested

    init(probe: CaptureAuthorizationProbe, queue: DispatchQueue, resultDidArrive: @escaping @Sendable () -> Void) {
        self.probe = probe
        self.queue = queue
        self.resultDidArrive = resultDidArrive
    }

    static func decision(preflight: Int32?, requestProgress: RequestProgress, canRequest: Bool) -> Decision {
        switch preflight {
        case PreflightValue.granted:
            return .build(.granted)
        case PreflightValue.denied:
            return .build(.denied)
        case PreflightValue.undetermined:
            switch requestProgress {
            case .awaitingResult:
                return .awaitResult
            case .resulted(let granted):
                // 求めた結果が事前の値に反映されない場合に、求め直しを繰り返さない。
                return .build(granted ? .granted : .denied)
            case .notRequested:
                return canRequest ? .request : .build(.unreadable)
            }
        default:
            return .build(.unreadable)
        }
    }

    /// 事前の値は呼ぶたびに読み直す。
    func admit() -> Admission {
        switch Self.decision(
            preflight: probe.preflight?(), requestProgress: progress, canRequest: probe.request != nil
        ) {
        case .build(let authorization):
            return .build(authorization)
        case .awaitResult:
            return .awaitingResult
        case .request:
            progress = .awaitingResult
            probe.request? { [self] granted in
                queue.async { [self] in
                    progress = .resulted(granted: granted)
                    // 同じ直列キューから出すので、結果待ちの結果は必ずこの知らせより先にオーディオ世界へ届く。
                    resultDidArrive()
                }
            }
            return .awaitingResult
        }
    }
}

// MARK: - 構築

struct CaptureBuildRequest: Equatable, Sendable {
    let endpointUID: String
    let endpointDeviceID: AudioDeviceID
    let selfProcessObjectID: AudioObjectID?
    let generation: UInt64
}

enum CaptureBuildOutcome: Sendable {
    case built(AirPlayCaptureSource, CaptureAuthorization)
    case failed
    case awaitingAuthorization
}

/// Tap の構築は許可のダイアログの応答まで戻らないことがあるため、オーディオ世界の外の専用キューで作る。
final class AirPlayCaptureBuilder: @unchecked Sendable {
    typealias MakeCapture = @Sendable (_ request: CaptureBuildRequest, _ selfProcessObjectID: AudioObjectID) -> AirPlayCaptureSource?

    private let queue: DispatchQueue
    private let gate: CaptureAuthorizationGate
    private let makeCapture: MakeCapture
    private let didFinish: @Sendable (CaptureBuildOutcome, _ generation: UInt64) -> Void

    init(
        probe: CaptureAuthorizationProbe = .system,
        queue: DispatchQueue = DispatchQueue(label: "com.simpleeq.airplay-capture"),
        makeCapture: @escaping MakeCapture = { AirPlayCapture.make(request: $0, selfProcessObjectID: $1) },
        didFinish: @escaping @Sendable (CaptureBuildOutcome, _ generation: UInt64) -> Void,
        authorizationResultDidArrive: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.makeCapture = makeCapture
        self.didFinish = didFinish
        gate = CaptureAuthorizationGate(probe: probe, queue: queue, resultDidArrive: authorizationResultDidArrive)
    }

    func build(_ request: CaptureBuildRequest) {
        queue.async { [self] in
            didFinish(outcome(for: request), request.generation)
        }
    }

    private func outcome(for request: CaptureBuildRequest) -> CaptureBuildOutcome {
        // 除外しないと出し直した音まで自分の Tap でミュートされる。
        guard let selfProcessObjectID = request.selfProcessObjectID else { return .failed }
        switch gate.admit() {
        case .awaitingResult:
            return .awaitingAuthorization
        case .build(let authorization):
            guard let capture = makeCapture(request, selfProcessObjectID) else { return .failed }
            return .built(capture, authorization)
        }
    }
}
