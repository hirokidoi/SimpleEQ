import XCTest
import CoreAudio
import Foundation
import SimpleEQRingC
@testable import SimpleEQ

private func setWriteCounter(_ url: URL, _ value: UInt64) {
    let handle = try! FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    handle.seek(toFileOffset: 40)
    handle.write(withUnsafeBytes(of: value) { Data($0) })
}

/// 有効な共有メモリヘッダのみを持つ最小のフィクスチャファイルを作る。呼び出し元がテスト終了時に削除すること。
private func makeMinimalSharedRingReaderFixture(
    ringFrames: UInt32 = 64, channels: UInt32 = 1, writeCounter: UInt64 = 0,
    sampleRate: Double = AudioConfig.baseSampleRate, ringValues: [Float] = [],
    // 既定 0 (非稼働) は経過時間に関わらず停止と判定されない。稼働 (1) にすると停止判定を発火させられる。
    writerIOIsRunning: UInt32 = 0,
    // 既定 0 は所有者不在。自分の pid を入れると自分が所有者になる。
    ownerProcessID: UInt32 = 0
) -> URL {
    let headerBytes = UInt32(simpleeq_ring_header_size())
    let ringDataOffset = Int(headerBytes)
    let totalSize = ringDataOffset + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size
    var data = Data(count: totalSize)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        raw.storeBytes(of: simpleeq_ring_expected_magic(), toByteOffset: 0, as: UInt32.self)
        raw.storeBytes(of: simpleeq_ring_expected_layout_version(), toByteOffset: 4, as: UInt32.self)
        raw.storeBytes(of: headerBytes, toByteOffset: 12, as: UInt32.self)
        raw.storeBytes(of: ringFrames, toByteOffset: 16, as: UInt32.self)
        raw.storeBytes(of: channels, toByteOffset: 20, as: UInt32.self)
        // 0 のままだと初回接続の適用時に FFT サイズの導出等が破綻するため、既定は基準レートにする。
        raw.storeBytes(of: sampleRate, toByteOffset: 24, as: Double.self)
        raw.storeBytes(of: writeCounter, toByteOffset: 40, as: UInt64.self)
        raw.storeBytes(of: writerIOIsRunning, toByteOffset: 52, as: UInt32.self)
        raw.storeBytes(of: ownerProcessID, toByteOffset: ownershipOwnerProcessIDOffset, as: UInt32.self)
        for (i, v) in ringValues.enumerated() {
            raw.storeBytes(of: v, toByteOffset: ringDataOffset + i * MemoryLayout<Float>.size, as: Float.self)
        }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioEngineTests-\(UUID().uuidString).shm")
    try! data.write(to: url)
    return url
}

/// テスト実行環境で駆動に使える出力デバイス (ID + UID) を選ぶ。
/// 実 AudioUnit を組み立てるには有効な AudioDeviceID が要るため、実行環境に存在するデバイスを都度読んで使う。
/// 自ドライバとそれを内包する Aggregate は選ばない (書き手の IO を揺らして再生中の音に触れるため)。
/// どれも使えない場合は nil。
private func usableOutputDevice() -> (deviceID: AudioDeviceID, uid: String)? {
    func isUsable(_ id: AudioDeviceID, _ uid: String) -> Bool {
        let containsDriver = containsDriverDevice(id, driverDeviceUID: DriverConfig.deviceUID, testToken)
        return !isExcludedFromOutputPicker(
            uid: uid, driverDeviceUID: DriverConfig.deviceUID,
            containsDriver: containsDriver, isAirPlay: isAirPlayDevice(id, testToken)
        )
    }

    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var defaultID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID) == noErr,
       let uid = deviceUID(defaultID, testToken), isUsable(defaultID, uid) {
        return (defaultID, uid)
    }

    for id in allDeviceIDs(testToken) {
        guard deviceHasStreams(id, needsOutput: true, testToken),
              let uid = deviceUID(id, testToken),
              isUsable(id, uid)
        else { continue }
        return (id, uid)
    }
    return nil
}

private final class PresentationDelayStub {
    private(set) var calls: [(deviceID: AudioDeviceID, sampleRate: Double)] = []
    private var nextValues: [Int?]

    init(_ nextValues: [Int?]) { self.nextValues = nextValues }

    func next(_ deviceID: AudioDeviceID, _ sampleRate: Double, _ token: AudioWorldToken) -> Int? {
        calls.append((deviceID, sampleRate))
        return nextValues.isEmpty ? 0 : nextValues.removeFirst()
    }
}

@MainActor
final class AudioEngineTests: XCTestCase {
    nonisolated private let tempURLs = Recorded<[URL]>([])

    override func tearDown() {
        for url in tempURLs.value { try? FileManager.default.removeItem(at: url) }
        tempURLs.update { $0.removeAll() }
        super.tearDown()
    }

    // MARK: - isExcludedFromOutputPicker

    // MARK: - isRingStalled (「音声を取得できていません」判定)

    func testRingStalledOnlyWhenRunningAndElapsedExceedsThreshold() {
        // 稼働中なのに直近の書き込みからの経過が閾値を超えた場合のみ異常と判定する。
        XCTAssertTrue(isRingStalled(writerIOIsRunning: true, elapsedSinceLastWrite: 1.0, threshold: 0.5))
        XCTAssertFalse(isRingStalled(writerIOIsRunning: false, elapsedSinceLastWrite: 1.0, threshold: 0.5), "非稼働中は経過時間に関わらず停止とみなさない")
        XCTAssertFalse(isRingStalled(writerIOIsRunning: true, elapsedSinceLastWrite: 0.3, threshold: 0.5), "経過が閾値以下なら停止とみなさない")
        XCTAssertFalse(isRingStalled(writerIOIsRunning: false, elapsedSinceLastWrite: 0.3, threshold: 0.5))
    }

    // MARK: - isAudioWorldUnresponsive (「音声システムが応答していません」判定)

    // ハートビートが返ってきた時点からの経過だけで判定する。閾値ちょうどでは応答なしとしない。
    func testAudioWorldUnresponsiveOnlyWhenElapsedExceedsThreshold() {
        XCTAssertTrue(isAudioWorldUnresponsive(
            now: 15.1, lastResponse: 10, waitingSince: 0, threshold: 5
        ))
        XCTAssertFalse(isAudioWorldUnresponsive(
            now: 15, lastResponse: 10, waitingSince: 0, threshold: 5
        ), "閾値ちょうどでは応答なしとしない")
        XCTAssertFalse(isAudioWorldUnresponsive(
            now: 11, lastResponse: 10, waitingSince: 0, threshold: 5
        ))
    }

    // 一度も返っていない間は、投げ始めた時点を起点にする。
    func testAudioWorldUnresponsiveFallsBackToWaitingSinceBeforeFirstResponse() {
        XCTAssertTrue(isAudioWorldUnresponsive(
            now: 5.1, lastResponse: nil, waitingSince: 0, threshold: 5
        ), "一度も返らないまま閾値を超えたら応答なし")
        XCTAssertFalse(isAudioWorldUnresponsive(
            now: 1, lastResponse: nil, waitingSince: 0, threshold: 5
        ), "投げ始めた直後は応答なしとしない")
    }

    // 起点は「最後に返ってきた時点」と「待ち始めた時点」の遅いほう。
    func testAudioWorldUnresponsiveTakesTheLaterOfLastResponseAndWaitingSince() {
        XCTAssertFalse(isAudioWorldUnresponsive(
            now: 101, lastResponse: 10, waitingSince: 100, threshold: 5
        ), "引き直した待ち始めが応答より新しければ、そちらが起点になる")
        XCTAssertTrue(isAudioWorldUnresponsive(
            now: 106, lastResponse: 10, waitingSince: 100, threshold: 5
        ), "引き直した時点からも閾値を超えたら応答なし")
        XCTAssertFalse(isAudioWorldUnresponsive(
            now: 101, lastResponse: 100, waitingSince: 10, threshold: 5
        ), "応答が待ち始めより新しければ、応答が起点になる")
    }

    // MARK: - audioWorldHeartbeatTickIsContinuous (ハートビートの tick が飛んだ区間の除外)

    // 許容倍率までは連続とみなす。
    func testHeartbeatTickContinuityUsesIntervalAndTolerance() {
        XCTAssertTrue(audioWorldHeartbeatTickIsContinuous(
            now: 10, lastTick: nil, interval: 1, tolerance: 3
        ), "初回は比較対象が無いので連続とみなす")
        XCTAssertTrue(audioWorldHeartbeatTickIsContinuous(
            now: 13, lastTick: 10, interval: 1, tolerance: 3
        ), "許容倍率ちょうどまでは連続")
        XCTAssertFalse(audioWorldHeartbeatTickIsContinuous(
            now: 13.1, lastTick: 10, interval: 1, tolerance: 3
        ), "許容倍率を超えたら飛んだとみなす")
    }


    // MARK: - driverDeviceListenerRebindActions (音量・消音・レート変更リスナーの解除/登録判定)

    func testDriverDeviceListenerRebindCoversAllStatePatterns() {
        typealias Actions = (unregister: Bool, register: Bool)
        func assertActions(_ actual: Actions, _ expected: Actions, _ message: String) {
            XCTAssertEqual(actual.unregister, expected.unregister, "\(message) (unregister)")
            XCTAssertEqual(actual.register, expected.register, "\(message) (register)")
        }

        // 監視終了時: 登録が残っていれば解除のみ。
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: false, registeredID: 5, resolvedID: 5), (true, false), "監視終了で解除")
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: false, registeredID: nil, resolvedID: 5), (false, false), "監視終了かつ未登録なら何もしない")

        // 監視中: 登録先と解決済み ID が一致していれば何もしない (両方 nil も含む)。
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: true, registeredID: 5, resolvedID: 5), (false, false), "一致なら維持")
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: true, registeredID: nil, resolvedID: nil), (false, false), "未登録かつ未解決なら待機")

        // 監視中: 未登録で ID が解決できたら登録 (nil 経由からの回復を含む)。
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: true, registeredID: nil, resolvedID: 7), (false, true), "回復時に再登録")

        // 監視中: ID が解決不能になったら解除のみ (あるべき状態は維持し回復を待つ)。
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: true, registeredID: 5, resolvedID: nil), (true, false), "失効時は解除して回復待ち")

        // 監視中: 別 ID へ変わったら張り替え。
        assertActions(driverDeviceListenerRebindActions(monitoringDesired: true, registeredID: 5, resolvedID: 7), (true, true), "ID 変化で張り替え")
    }

    // MARK: - effectiveOutputGain (システム音量の出力段適用)

    func testEffectiveOutputGainClampsVolumeAndPrioritizesMute() {
        XCTAssertEqual(effectiveOutputGain(volume: 0, muted: false), 0, "スライダー最下段は完全な無音")
        XCTAssertEqual(effectiveOutputGain(volume: 1.0, muted: false), 1.0, "スライダー最大は dB=0 → 振幅1")
        XCTAssertEqual(effectiveOutputGain(volume: 1.5, muted: false), 1.0, "範囲外の音量は 0...1 に丸める")
        XCTAssertEqual(effectiveOutputGain(volume: -0.5, muted: false), 0)
        XCTAssertEqual(effectiveOutputGain(volume: 0.5, muted: true), 0, "ミュートは音量に優先する")

        // 中間値は dB カーブを経由するため単純な線形乗算にはならない。
        XCTAssertEqual(effectiveOutputGain(volume: 0.5, muted: false), 0.02512, accuracy: 0.0001)
    }

    // MARK: - preampLinearGain (プリアンプの dB → 振幅変換)

    func testPreampLinearGainAtZeroDbIsUnityAndClampsToEQRange() {
        XCTAssertEqual(preampLinearGain(db: 0), 1.0, accuracy: 0.0001, "0dB は振幅1 (無変化)")
        XCTAssertEqual(preampLinearGain(db: 100), preampLinearGain(db: EQSpec.DB_MAX), accuracy: 0.0001)
        XCTAssertEqual(preampLinearGain(db: -100), preampLinearGain(db: EQSpec.DB_MIN), accuracy: 0.0001)

        XCTAssertEqual(preampLinearGain(db: -12), 0.25119, accuracy: 0.0001)
        XCTAssertEqual(preampLinearGain(db: 12), 3.98107, accuracy: 0.0001)
    }

    // MARK: - effectivePreampGain (EQ-OFF 中はプリアンプ段をユニティにする合成)

    func testEffectivePreampGainIsUnityWhenBypassed() {
        // バイパス中はプリアンプ設定値によらず実効ゲインがユニティ (無変化) になる。
        XCTAssertEqual(effectivePreampGain(preampDb: -6, bypassed: true), 1.0, accuracy: 0.0001)
        XCTAssertEqual(effectivePreampGain(preampDb: 9, bypassed: true), 1.0, accuracy: 0.0001)
    }

    func testEffectivePreampGainRestoresConfiguredValueWhenNotBypassed() {
        // バイパスを解除すると、設定してあったプリアンプ値由来のゲインが復帰する。
        XCTAssertEqual(effectivePreampGain(preampDb: -6, bypassed: false), preampLinearGain(db: -6), accuracy: 0.0001)
    }

    // MARK: - AudioEngine.setBypass/setPreamp (実効プリアンプゲインの再計算経路)

    // バイパス設定とプリアンプ設定の適用順序を入れ替えても、最終的な実効ゲインが一致する。
    func testPreampGainRecomputeIsOrderIndependentOfSetterCallOrder() {
        let engineBypassLast = AudioEngine()
        engineBypassLast.setPreamp(db: -6, testToken)
        engineBypassLast.setBypass(true, testToken)
        engineBypassLast.setBypass(false, testToken)

        let enginePreampLast = AudioEngine()
        enginePreampLast.setBypass(true, testToken)
        enginePreampLast.setBypass(false, testToken)
        enginePreampLast.setPreamp(db: -6, testToken)

        XCTAssertEqual(engineBypassLast.preampGain, preampLinearGain(db: -6), accuracy: 0.0001)
        XCTAssertEqual(enginePreampLast.preampGain, preampLinearGain(db: -6), accuracy: 0.0001)
    }

    // MARK: - outputDeviceResolutionPolicy (自動/手動フォールバック)

    func testOutputDeviceResolutionPolicyIsAutoWhenNoConfiguredUID() {
        XCTAssertEqual(
            outputDeviceResolutionPolicy(configuredUID: nil, configuredUIDResolvable: false),
            .auto
        )
    }

    func testOutputDeviceResolutionPolicyIsConfiguredWhenResolvable() {
        XCTAssertEqual(
            outputDeviceResolutionPolicy(configuredUID: "vg280k-uid", configuredUIDResolvable: true),
            .configured(uid: "vg280k-uid")
        )
    }

    func testOutputDeviceResolutionPolicyFallsBackToAutoWhenUnresolvable() {
        // 手動固定デバイスが現在解決できない (取り外し等) 場合は自動選択へフォールバックする。
        XCTAssertEqual(
            outputDeviceResolutionPolicy(configuredUID: "vg280k-uid", configuredUIDResolvable: false),
            .auto
        )
    }

    // MARK: - renderBufferSizing (レンダ要求の上限ガードとバイト数の算出)

    func testRenderBufferSizingReturnsBytesForRequestedFramesNotCapacity() {
        let requestedFrames: UInt32 = 256
        XCTAssertEqual(
            renderBufferSizing(frames: requestedFrames, capacityFrames: AudioConfig.maxRenderFrames),
            .renderable(bytesPerChannel: requestedFrames * UInt32(MemoryLayout<Float>.size)),
            "バイト数は事前確保容量ぶんではなく今回の要求フレーム数ぶん"
        )
    }

    func testRenderBufferSizingAcceptsRequestEqualToCapacity() {
        let capacityFrames = AudioConfig.maxRenderFrames
        XCTAssertEqual(
            renderBufferSizing(frames: UInt32(capacityFrames), capacityFrames: capacityFrames),
            .renderable(bytesPerChannel: UInt32(capacityFrames) * UInt32(MemoryLayout<Float>.size)),
            "容量ちょうどの要求はレンダ可能"
        )
    }

    func testRenderBufferSizingReportsExceedsCapacityBeyondPreallocatedFrames() {
        // 事前確保容量を超える要求でレンダを続けると realtime バッファを踏み越える。
        let capacityFrames = AudioConfig.maxRenderFrames
        XCTAssertEqual(
            renderBufferSizing(frames: UInt32(capacityFrames + 1), capacityFrames: capacityFrames),
            .exceedsCapacity
        )
    }

    // MARK: - restorePlanarBufferByteSize (AudioUnitRender による書き下げからの復元)

    func testPlanarBufferByteSizeIsRestoredForEveryRequestAfterRenderWritesItDown() {
        let channels = Int(AudioConfig.channels)
        let capacityFrames = 512
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size)
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        var buffers: [UnsafeMutablePointer<Float>] = []
        for c in 0..<channels {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            buf.initialize(repeating: 0, count: capacityFrames)
            buffers.append(buf)
            abl[c] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(capacityFrames) * bytesPerFrame,
                mData: UnsafeMutableRawPointer(buf)
            )
        }
        defer {
            for buf in buffers { buf.deinitialize(count: capacityFrames); buf.deallocate() }
            free(abl.unsafeMutablePointer)
        }

        // 「減ってから増える」系列だけが復元漏れを検出できる。
        for requestedFrames: UInt32 in [256, 128, 384] {
            guard case .renderable(let bytesPerChannel) = renderBufferSizing(
                frames: requestedFrames, capacityFrames: capacityFrames
            ) else {
                return XCTFail("容量内の要求がレンダ不可と判定された (frames=\(requestedFrames))")
            }
            restorePlanarBufferByteSize(abl.unsafeMutablePointer, bytesPerChannel: bytesPerChannel)
            for c in 0..<channels {
                XCTAssertEqual(
                    abl[c].mDataByteSize, requestedFrames * bytesPerFrame,
                    "レンダ直前に今回の要求ぶんへ復元される (frames=\(requestedFrames), ch=\(c))"
                )
            }
            // AudioUnitRender の書き下げを手で再現する (実生成ぶんまで下げられた状態を作る)。
            for c in 0..<channels { abl[c].mDataByteSize = requestedFrames * bytesPerFrame / 2 }
        }
    }

    // MARK: - outputSwitchDecision (出力先の切替要否は ID ではなく UID で判定する)

    func testOutputSwitchNotNeededWhenCurrentUIDMatchesIntent() {
        // AudioDeviceID が総入れ替えになっても、UID があるべき状態と同じなら切替は不要。
        XCTAssertEqual(outputSwitchDecision(intendedUID: "spk-uid", currentUID: "spk-uid"), .notNeeded)
    }

    func testOutputSwitchNeededWhenAnotherDeviceTookTheSameDeviceID() {
        // 別のデバイスが以前の ID を取った場合、ID 比較では検出できないが UID 判定では切替要になる。
        XCTAssertEqual(outputSwitchDecision(intendedUID: "spk-uid", currentUID: "hdmi-uid"), .needed)
    }

    func testOutputSwitchNeededWhenCurrentUIDUnavailable() {
        // 現在の UID を取得できない場合はあるべき状態と一致している確証が無いため切替要へ倒す。
        XCTAssertEqual(outputSwitchDecision(intendedUID: "spk-uid", currentUID: nil), .needed)
    }

    // MARK: - SuspensionPolicy (状態モデルの対応表)

    func testAllowsSelectionResumeOnlyForRouteUnavailable() {
        XCTAssertTrue(SuspensionPolicy.allowsSelectionResume(.routeUnavailable))
        XCTAssertFalse(SuspensionPolicy.allowsSelectionResume(.driverOperation))
        XCTAssertFalse(SuspensionPolicy.allowsSelectionResume(.applicationTermination))
        XCTAssertFalse(SuspensionPolicy.allowsSelectionResume(.ownershipUnavailable))
    }

    func testAllowsAutomaticResumeOnlyForRouteUnavailable() {
        XCTAssertTrue(SuspensionPolicy.allowsAutomaticResume(.routeUnavailable))
        XCTAssertFalse(SuspensionPolicy.allowsAutomaticResume(.driverOperation))
        XCTAssertFalse(SuspensionPolicy.allowsAutomaticResume(.applicationTermination))
        XCTAssertFalse(SuspensionPolicy.allowsAutomaticResume(.ownershipUnavailable))
    }

    func testAllowsResumeOnOwnershipAcquiredOnlyForOwnershipUnavailable() {
        XCTAssertTrue(SuspensionPolicy.allowsResumeOnOwnershipAcquired(.ownershipUnavailable))
        XCTAssertFalse(SuspensionPolicy.allowsResumeOnOwnershipAcquired(.routeUnavailable))
        XCTAssertFalse(SuspensionPolicy.allowsResumeOnOwnershipAcquired(.driverOperation))
        XCTAssertFalse(SuspensionPolicy.allowsResumeOnOwnershipAcquired(.applicationTermination))
    }

    // 可視性の維持とは条件が違う。ドライバ操作中・終了中は自分が経路を担ったままなので固定名へ戻す。
    // 同じ述語を流用すると、その 2 種別で名前が戻らなくなる。
    func testWritesDriverDeviceNameClosesOnlyForLackOfOwnership() {
        XCTAssertTrue(SuspensionPolicy.writesDriverDeviceName(.active))
        XCTAssertTrue(SuspensionPolicy.writesDriverDeviceName(.suspended(.routeUnavailable)))
        XCTAssertTrue(SuspensionPolicy.writesDriverDeviceName(.suspended(.driverOperation)))
        XCTAssertTrue(SuspensionPolicy.writesDriverDeviceName(.suspended(.applicationTermination)))
        XCTAssertFalse(SuspensionPolicy.writesDriverDeviceName(.suspended(.ownershipUnavailable)))
    }

    func testMaintainsDriverVisibilityForActiveAndRouteUnavailableSuspensionOnly() {
        XCTAssertTrue(SuspensionPolicy.maintainsDriverVisibility(.active))
        XCTAssertTrue(SuspensionPolicy.maintainsDriverVisibility(.suspended(.routeUnavailable)))
        XCTAssertFalse(SuspensionPolicy.maintainsDriverVisibility(.suspended(.driverOperation)))
        XCTAssertFalse(SuspensionPolicy.maintainsDriverVisibility(.suspended(.applicationTermination)))
        XCTAssertFalse(SuspensionPolicy.maintainsDriverVisibility(.suspended(.ownershipUnavailable)))
    }

    // 自動再開を許す種別は必ず選び直しでの再開を許す種別に含まれる (逆は成り立たなくてよい)。
    func testAutomaticResumeCausesAreSubsetOfSelectionResumeCauses() {
        for cause in SuspensionCause.allCases where SuspensionPolicy.allowsAutomaticResume(cause) {
            XCTAssertTrue(SuspensionPolicy.allowsSelectionResume(cause), "\(cause)")
        }
    }

    // 可視性の維持を伴う停止種別は、必ず選び直しでの再開を許す種別に含まれる。
    func testVisibilityMaintainingSuspensionCausesAreSubsetOfSelectionResumeCauses() {
        for cause in SuspensionCause.allCases where SuspensionPolicy.maintainsDriverVisibility(.suspended(cause)) {
            XCTAssertTrue(SuspensionPolicy.allowsSelectionResume(cause), "\(cause)")
        }
    }

    // MARK: - intendedOutputDeviceUIDAtSuspensionCapture (停止をまたいで保持するあるべき出力先の UID)

    func testIntendedOutputDeviceUIDAtSuspensionCaptureUsesCurrentIntentWhenPresent() {
        XCTAssertEqual(intendedOutputDeviceUIDAtSuspensionCapture(current: "x", previouslyCaptured: nil), "x")
        XCTAssertEqual(intendedOutputDeviceUIDAtSuspensionCapture(current: "y", previouslyCaptured: "x"), "y", "新しいあるべき出力先があれば最新値へ更新される")
    }

    func testIntendedOutputDeviceUIDAtSuspensionCapturePreservesPreviousValueWhenNoCurrentIntent() {
        XCTAssertEqual(intendedOutputDeviceUIDAtSuspensionCapture(current: nil, previouslyCaptured: "x"), "x", "既に停止している間の再度の suspend で上書きされない")
        XCTAssertNil(intendedOutputDeviceUIDAtSuspensionCapture(current: nil, previouslyCaptured: nil))
    }

    // MARK: - AudioEngine.processingState / suspend (状態遷移)

    func testInitialProcessingStateIsSuspendedRouteUnavailable() {
        XCTAssertEqual(AudioEngine().processingState, .suspended(.routeUnavailable))
    }

    func testSuspendIsIdempotentForSameCauseAndNotifiesOnlyOnRealTransition() {
        let engine = AudioEngine()
        let notified = Recorded<[ProcessingState]>([])
        engine.processingStateDidChange = { state, _ in notified.update { $0.append(state) } }

        // 初期状態と同じ種別 → 冪等 (履歴も通知も増えない)。
        engine.suspend(cause: .routeUnavailable, testToken)
        XCTAssertTrue(engine.suspensionHistory.isEmpty)
        XCTAssertTrue(notified.value.isEmpty)

        // 実際の遷移。
        engine.suspend(cause: .driverOperation, testToken)
        XCTAssertEqual(engine.suspensionHistory, [.driverOperation])
        XCTAssertEqual(notified.value, [.suspended(.driverOperation)])

        // 同じ種別の再呼び出し → 再び冪等。
        engine.suspend(cause: .driverOperation, testToken)
        XCTAssertEqual(engine.suspensionHistory, [.driverOperation])
        XCTAssertEqual(notified.value, [.suspended(.driverOperation)])
    }

    // MARK: - AudioEngine.assemble (途中失敗時の資源解放)

    func testAssembleSuspendsAndReleasesResourcesWhenEQUnitCreationFails() {
        let engine = AudioEngine(driverPresentationLatencyIO: MockDriverPresentationLatencyIO())
        // 初期状態からの失敗は状態遷移しない (冪等) ため、まず別の種別へ遷移させておく。
        engine.suspend(cause: .driverOperation, testToken)
        engine.makeEQUnit = { _, _, _, _ in nil }
        let notified = Recorded<[ProcessingState]>([])
        engine.processingStateDidChange = { state, _ in notified.update { $0.append(state) } }

        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try! SharedRingReader.open(path: url.path).get()

        let ok = engine.assemble(outputDevice: ResolvedOutputDevice(uid: "out-uid", deviceID: 1), ringReader: ringReader, testToken)

        XCTAssertFalse(ok)
        XCTAssertEqual(engine.processingState, .suspended(.routeUnavailable))
        XCTAssertNil(engine.intendedOutputDeviceUID, "組み立て失敗時にあるべき出力先の UID を保持したままにしない")
        XCTAssertTrue(engine.evaluateRingStalled(testToken), "共有メモリの読み手を保持したままにしない")
        XCTAssertEqual(engine.suspensionHistory, [.driverOperation, .routeUnavailable])
        XCTAssertEqual(notified.value, [.suspended(.routeUnavailable)])
    }

    func testSilencedEngineHoldsZeroOutputGainAcrossOutputDeviceRebinds() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        XCTAssertEqual(engine.outputGain, 0)

        // 初回 bind では音量 0 だけでもゲインが 0 になるため、
        // 採用がユニティへ戻る 2 回目の bind まで見ないとミュートが効いているかを判別できない。
        let otherUIDDevice = ResolvedOutputDevice(uid: "another-uid-for-silence-test", deviceID: device.deviceID)
        XCTAssertTrue(engine.switchOutputDevice(to: otherUIDDevice, testToken), "前提: 別 UID への張り替えが成立すること")

        XCTAssertEqual(engine.outputGain, 0)

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - 所有権によるレンダー経路の無音化

    /// リングに内容がある状態でレンダー経路を回し、非ゼロが一度でも出たかを返す。
    /// 出力段が実際に回るため、書き手の位置を毎回進めて涸れないようにする。
    private func renderProducesNonZero(ownerProcessID: UInt32) throws -> Bool {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let frames = 256
        let sampleCount = frames * Int(AudioConfig.channels)
        let ringFrames = UInt32(frames * 32)
        let url = makeMinimalSharedRingReaderFixture(
            ringFrames: ringFrames, channels: AudioConfig.channels, writeCounter: UInt64(frames),
            ringValues: [Float](repeating: 0.5, count: Int(ringFrames) * Int(AudioConfig.channels)),
            ownerProcessID: ownerProcessID
        )
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(
            path: url.path, primingEnabled: false, initialWriterBlockFrames: frames
        ).get()
        let engine = makeSilencedEngine()
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        defer { engine.suspend(cause: .applicationTermination, testToken) }

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { buffer.deallocate() }
        let byteSize = UInt32(sampleCount * MemoryLayout<Float>.size)

        for step in 1...64 {
            setWriteCounter(url, UInt64(frames * (step + 1) * 4))
            buffer.update(repeating: 0, count: sampleCount)
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: AudioConfig.channels, mDataByteSize: byteSize,
                    mData: UnsafeMutableRawPointer(buffer)
                )
            )
            _ = engine.renderEQInput(&abl, UInt32(frames))
            if (0..<sampleCount).contains(where: { buffer[$0] != 0 }) { return true }
        }
        return false
    }

    /// 所有していない間は、リングに内容があってもレンダー経路が無音を出すこと。
    /// 制御経路が詰まってリースが落ちたときに二重再生を防ぐ唯一の安全弁にあたる。
    /// 空席と他者の席を対で見る。空席だけでは「席が空でなければ流す」実装でも通り、二重再生を捕まえられない。
    func testRenderOutputsSilenceWhileThisSessionDoesNotOwnTheAudioPath() throws {
        for ownerProcessID: UInt32 in [0, SharedRingReader.selfProcessID &+ 1] {
            let sawAudio = try renderProducesNonZero(ownerProcessID: ownerProcessID)
            XCTAssertFalse(sawAudio, "所有していない間にリングの内容が出力へ出た (owner=\(ownerProcessID))")
        }
    }

    /// 対で見ないと「常に無音」でも通ってしまう。
    func testRenderPassesRingContentThroughWhileThisSessionOwnsTheAudioPath() throws {
        let sawAudio = try renderProducesNonZero(ownerProcessID: UInt32(bitPattern: getpid()))
        XCTAssertTrue(sawAudio, "所有している間にリングの内容が出力へ出なかった")
    }

    // MARK: - 実体の差し替え

    // 差し替えを見た周で止めないと、レンダー経路は削除済みの実体を読み続ける。
    // 旧実体の所有者は自分のままなので無音化の安全弁も働かず、復旧はアプリの再起動だけになる。
    @MainActor
    func testAPassThatFindsTheRingReplacedStopsTheOutputStage() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let ringURL = makeMinimalSharedRingReaderFixture(
            channels: AudioConfig.channels, ownerProcessID: SharedRingReader.selfProcessID
        )
        tempURLs.update { $0.append(ringURL) }
        let engine = makeSilencedEngine()
        let reader = try SharedRingReader.open(path: ringURL.path).get()
        XCTAssertTrue(
            engine.assemble(
                outputDevice: ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID),
                ringReader: reader, testToken
            ),
            "前提: 実デバイスへの組み立てが成立すること"
        )
        defer { engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertEqual(engine.processingState, .active, "前提: 稼働中")

        let suiteName = TestDefaults.makeName("OwnershipRingReplacement")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaults.remove(name: suiteName, defaults: defaults) }
        let directory = MockAudioDeviceDirectory()
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: DriverConfig.deviceUID)
        let outputController = OutputDeviceController(
            directory: directory, settings: SettingsStore(defaults: defaults), targetDeviceUID: DriverConfig.deviceUID
        )
        let audioWorld = AudioWorld()
        let coordinator = OwnershipCoordinator(
            audioWorld: audioWorld, engine: engine,
            activationCoordinator: AudioActivationCoordinator(
                engine: engine, driverLifecycle: lifecycle, outputController: outputController
            ),
            driverLifecycle: lifecycle, outputController: outputController, directory: directory,
            sharedMemoryPath: ringURL.path, isOnConsole: { true }
        )

        runPassAndWait(coordinator, audioWorld) // inode の基準を作る周。
        XCTAssertEqual(engine.processingState, .active, "前提: 差し替えの無い周では止めない")

        let replacement = makeMinimalSharedRingReaderFixture(
            channels: AudioConfig.channels, ownerProcessID: SharedRingReader.selfProcessID
        )
        tempURLs.update { $0.append(replacement) }
        try FileManager.default.removeItem(at: ringURL)
        try FileManager.default.copyItem(at: replacement, to: ringURL)

        // 観測だけを取り出す入口が挟まっても、差し替えの立ち上がりは次の周まで残る。
        coordinator.requestOwnership()

        runPassAndWait(coordinator, audioWorld)
        XCTAssertEqual(engine.processingState, .suspended(.ownershipUnavailable), "差し替えを見た周で出力段を止める")
    }

    @MainActor
    private func runPassAndWait(_ coordinator: OwnershipCoordinator, _ audioWorld: AudioWorld) {
        let pushed = XCTestExpectation(description: "所有権の押し出し")
        coordinator.didUpdate = { _ in pushed.fulfill() }
        coordinator.runPass()
        wait(for: [pushed], timeout: 2.0)
        _ = audioWorld.submitUncoalescedAndWait(timeout: 2.0) { _ in true }
    }

    func testAssembleAdvancesLevelMeterRestartGeneration() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let generationBeforeAssemble = engine.levelMeterRestartGeneration.value
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        XCTAssertNotEqual(
            engine.levelMeterRestartGeneration.value, generationBeforeAssemble,
            "音声処理の再開 (assemble 成功) が作り直しの申告を進めること"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - AudioEngine.runtimeMetrics (停止・再開をまたいだ内部観測量の生存)

    func testRuntimeMetricsPersistsAcrossAssembleWithANewRingReaderInstance() {
        let engine = AudioEngine(driverPresentationLatencyIO: MockDriverPresentationLatencyIO())
        engine.makeEQUnit = { _, _, _, _ in nil }

        // 接続直後の大きな積み上がりを発火させ、最初の読み手で観測を 1 件作る。
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let backlog = maxOccupancy + target
        let firstURL = makeMinimalSharedRingReaderFixture(
            ringFrames: UInt32(backlog + target), writeCounter: UInt64(backlog),
            ringValues: (0..<backlog).map { Float($0) }
        )
        tempURLs.update { $0.append(firstURL) }
        let firstReader = try! SharedRingReader.open(path: firstURL.path, initialWriterBlockFrames: writerBlockFrames).get()

        _ = engine.assemble(outputDevice: ResolvedOutputDevice(uid: "out-uid", deviceID: 1), ringReader: firstReader, testToken)

        var dst = [Float](repeating: -1, count: clientRequestFrames)
        _ = dst.withUnsafeMutableBufferPointer { firstReader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertEqual(engine.runtimeMetrics.occupancyResetDueToInitialSyncCount, 1, "接続直後の大きな積み上がりは初回同期として即時同期される")
        XCTAssertTrue(
            firstReader.metrics === engine.runtimeMetrics,
            "組み立てで読み手はエンジンの観測量を受け取る (停止・再開をまたいで積み上がりを保つため)"
        )

        // 「停止・再開」を模して、真新しい (使い捨ての既定観測量を持つ) 読み手を渡す。
        let secondURL = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(secondURL) }
        let secondReader = try! SharedRingReader.open(path: secondURL.path).get()

        _ = engine.assemble(outputDevice: ResolvedOutputDevice(uid: "out-uid", deviceID: 1), ringReader: secondReader, testToken)

        XCTAssertEqual(
            secondReader.metrics.occupancyResetDueToInitialSyncCount, 1,
            "作り直された読み手 (既定では 0 から始まる使い捨て観測量を持つ) でも、adopt(metrics:) により"
                + "エンジン保持の永続インスタンスへ差し替わるため直前までの累計を引き継ぐ"
        )
        XCTAssertEqual(engine.runtimeMetrics.occupancyResetDueToInitialSyncCount, 1, "エンジン側の永続インスタンスは停止・再開をまたいで値を保つ")
    }

    // MARK: - 診断の観測状態 (読み手を持っているか)

    // 読み手を持っている間は「今の状態」として見せてよいことを記録し、手放したら記録を落とす。
    func testReaderObservedFollowsWhetherTheEngineHoldsAReader() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        engine.refreshDriverObservations(testToken)
        XCTAssertFalse(engine.runtimeMetrics.readerObserved, "前提: 組み立て前は読み手が居ない")

        XCTAssertTrue(engine.assemble(
            outputDevice: ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID),
            ringReader: ringReader, testToken
        ))
        engine.refreshDriverObservations(testToken)
        XCTAssertTrue(engine.runtimeMetrics.readerObserved, "読み手を持っている間は今の状態として見せてよい")

        engine.suspend(cause: .routeUnavailable, testToken)
        engine.refreshDriverObservations(testToken)
        XCTAssertFalse(engine.runtimeMetrics.readerObserved, "手放したら記録を落とす")
    }

    // MARK: - AudioEngine.suspend/assemble (停止をまたぐあるべき出力先の UID の保持と破棄)

    func testSuspendCapturesIntendedUIDBeforeReleaseAndAssembleDiscardsItOnSuccess() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let firstURL = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(firstURL) }
        let firstRingReader = try SharedRingReader.open(path: firstURL.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: firstRingReader, testToken))
        XCTAssertEqual(engine.intendedOutputDeviceUID, device.uid)
        XCTAssertNil(engine.intendedOutputDeviceUIDAtSuspension, "稼働中は保持しない")

        engine.suspend(cause: .routeUnavailable, testToken)
        XCTAssertEqual(engine.intendedOutputDeviceUIDAtSuspension, device.uid, "停止直前のあるべき出力先の UID が停止をまたいで残る")
        XCTAssertNil(engine.intendedOutputDeviceUID, "稼働中のあるべき出力先自体は停止で失われる")

        let secondURL = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(secondURL) }
        let secondRingReader = try SharedRingReader.open(path: secondURL.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: secondRingReader, testToken))
        XCTAssertNil(engine.intendedOutputDeviceUIDAtSuspension, "再開成功時に破棄される")

        engine.suspend(cause: .applicationTermination, testToken) // 実資源 (AudioUnit) の後始末
    }

    // MARK: - AudioEngine.assemble の組み立て入口の保護

    func testAssembleReturnsFalseWithoutRebuildingWhenAlreadyActive() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let firstURL = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(firstURL) }
        let firstRingReader = try SharedRingReader.open(path: firstURL.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: firstRingReader, testToken))
        XCTAssertEqual(engine.processingState, .active)

        let notified = Recorded<[ProcessingState]>([])
        engine.processingStateDidChange = { state, _ in notified.update { $0.append(state) } }

        let secondURL = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(secondURL) }
        let secondRingReader = try SharedRingReader.open(path: secondURL.path).get()
        let rebuilt = engine.assemble(outputDevice: outputDevice, ringReader: secondRingReader, testToken)

        XCTAssertFalse(rebuilt, "稼働中の呼び出しは組み立てを行わない")
        XCTAssertEqual(engine.processingState, .active, "稼働状態は変化しない")
        XCTAssertEqual(engine.intendedOutputDeviceUID, device.uid, "あるべき出力先の UID は上書きされない")
        XCTAssertTrue(notified.value.isEmpty, "状態変化通知も発火しない")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - 自ドライバ ID の再検証

    // 保持している ID の UID が自ドライバのものと一致しなければ解決し直し、リスナーを新しい ID へ張り替える。
    // 移動先は環境によって変わるため、移動したこと自体を見る。
    func testRefreshDriverDeviceIDRebindsListenerWhenCachedIDIsNotTheDriver() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture(writerIOIsRunning: 0)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        // device.deviceID を「解決済みの自ドライバ ID」として渡し、リスナー登録を起こす。
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: reader, driverDeviceID: device.deviceID, testToken))
        XCTAssertEqual(engine.driverDeviceListenerDeviceID, device.deviceID, "前提: 渡した ID でリスナーが登録されている")

        engine.refreshDriverDeviceIDIfNeeded(testToken)
        XCTAssertNotEqual(
            engine.driverDeviceListenerDeviceID, device.deviceID,
            "UID 不一致による再検証が走り、登録先が渡した ID から離れる"
        )
        engine.suspend(cause: .applicationTermination, testToken) // 実資源 (AudioUnit) の後始末
    }

    // MARK: - AudioEngine.outputSilenceObservation

    func testOutputSilenceObservationIsNilWhileNotActive() {
        let engine = makeSilencedEngine()
        XCTAssertNil(engine.outputSilenceObservation(testToken))
    }

    func testOutputSilenceObservationReadsTheLiveHeaderWhileOwnedAndActive() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture(
            writerIOIsRunning: 1, ownerProcessID: UInt32(bitPattern: getpid())
        )
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: reader, testToken))
        defer { engine.suspend(cause: .applicationTermination, testToken) }

        let observation = try XCTUnwrap(engine.outputSilenceObservation(testToken))
        XCTAssertTrue(observation.writerIOIsRunning, "転記値ではなくヘッダの稼働フラグを読む")
        XCTAssertEqual(observation.primingSilenceCount, engine.runtimeMetrics.primingSilenceCountSinceLaunch)
    }

    func testOutputSilenceObservationIsNilWhileAnotherProcessOwnsTheRing() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture(
            writerIOIsRunning: 1, ownerProcessID: UInt32(bitPattern: getpid()) &+ 1
        )
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: reader, testToken))
        defer { engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(engine.processingState, .active, "前提: 稼働中")
        XCTAssertNil(engine.outputSilenceObservation(testToken))
    }

    // MARK: - AudioEngine.outputDeviceDidConfirm × OutputDeviceController (復帰先の実出力先追従)

    // 出力先の確定で記録した復帰先は、エンジンの停止をまたいで消えない (別の store であるため)。
    func testRestoreTargetSurvivesEngineSuspendAfterOutputConfirmed() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let suiteName = TestDefaults.makeName("AudioEngineTests")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaults.remove(name: suiteName, defaults: defaults) }
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "startup-default-uid"
        settings.switchPending = true
        let directory = MockAudioDeviceDirectory()
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: "driver-uid-not-used-here")

        let engine = makeSilencedEngine()
        engine.outputDeviceDidConfirm = { uid in outputController.noteOutputDeviceDidConfirm(uid: uid) }

        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(outputController.restoreTargetUID, device.uid, "出力先の確定で復帰先が実出力先へ追従する")

        engine.suspend(cause: .routeUnavailable, testToken)

        XCTAssertEqual(outputController.restoreTargetUID, device.uid, "エンジンの停止では復帰先は消えない")
    }

    func testOutputDeviceDidConfirmWiredAfterFirstAssembleLosesStartupConfirmation() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let suiteName = TestDefaults.makeName("AudioEngineTests")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaults.remove(name: suiteName, defaults: defaults) }
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "startup-default-uid"
        settings.switchPending = true
        let directory = MockAudioDeviceDirectory()
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: "driver-uid-not-used-here")

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        engine.outputDeviceDidConfirm = { uid in outputController.noteOutputDeviceDidConfirm(uid: uid) }

        XCTAssertEqual(
            outputController.restoreTargetUID, "startup-default-uid",
            "結線前に確定した最初の出力先は outputDeviceDidConfirm が nil のため反映されない。"
                + "AppDelegate はこの順序 (先に assemble、後で結線) を採ってはならない"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - AudioEngine.switchOutputDevice の通知発火 (実クラス経由)

    func testSwitchOutputDeviceFiresConfirmationOnNotNeededBranch() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        let confirmedUIDs = Recorded<[String]>([])
        engine.outputDeviceDidConfirm = { uid in confirmedUIDs.update { $0.append(uid) } }

        // 既にあるべき出力先へ出力中のため、Stop/Start を伴わない分岐を通る。
        XCTAssertTrue(engine.switchOutputDevice(to: outputDevice, testToken))
        XCTAssertEqual(confirmedUIDs.value, [outputDevice.uid], ".notNeeded 分岐でも出力先確定の通知が発火する")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // 分岐 (Stop → デバイス再適用 → Start) でも発火する。
    func testSwitchOutputDeviceFiresConfirmationOnSwitchedAndRestartedBranch() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        let confirmedUIDs = Recorded<[String]>([])
        engine.outputDeviceDidConfirm = { uid in confirmedUIDs.update { $0.append(uid) } }

        let forcedSwitchDevice = ResolvedOutputDevice(uid: "forced-different-uid-for-branch-coverage", deviceID: device.deviceID)
        XCTAssertTrue(engine.switchOutputDevice(to: forcedSwitchDevice, testToken))
        XCTAssertEqual(confirmedUIDs.value, [forcedSwitchDevice.uid], "switched && restarted 分岐でも出力先確定の通知が発火する")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - AudioEngine.switchOutputDevice × SharedRingReader (バッファ量の作り直しの要求)

    // 出力ユニットが稼働中はテストから直接呼ばず、実レンダコールバックの消費を Thread.sleep で待つ。

    /// フィクスチャの sampleRate だけを書き換える (「ドライバのレートが変わった」を模す)。
    private func setHeaderSampleRate(_ url: URL, _ rate: Double) {
        let handle = try! FileHandle(forWritingTo: url)
        defer { try! handle.close() }
        handle.seek(toFileOffset: 24)
        handle.write(withUnsafeBytes(of: rate) { Data($0) })
    }

    func testSwitchOutputDeviceDoesNotRequestOccupancyResetOnNotNeededBranch() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 0,
            "前提: 出力 AUHAL を止めていない間はリセットが発火しない"
        )

        XCTAssertTrue(engine.switchOutputDevice(to: outputDevice, testToken), ".notNeeded 分岐は true を返す")

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 0,
            ".notNeeded 分岐は出力ユニットを止めないためリセットを要求しない"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    func testSwitchOutputDeviceRequestsOccupancyResetWhenActuallyStoppedAndRestarted() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 0,
            "前提: 出力 AUHAL を止めていない間はリセットが発火しない"
        )

        let forcedSwitchDevice = ResolvedOutputDevice(uid: "forced-different-uid-for-reset-test", deviceID: device.deviceID)
        XCTAssertTrue(engine.switchOutputDevice(to: forcedSwitchDevice, testToken), "実デバイス ID なので切替は成功する")

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 1,
            "実際に停止・再開する分岐 (成功) では次回 read がバッファ量を作り直す"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    func testSwitchOutputDeviceRequestsOccupancyResetEvenWhenSwitchFailsAndRevertsToPreviousDevice() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 0,
            "前提: 出力 AUHAL を止めていない間はリセットが発火しない"
        )

        // 存在しないデバイス ID を渡し、「切替に失敗して元のデバイスへ戻す」経路を強制する。
        let invalidDevice = ResolvedOutputDevice(uid: "invalid-device-for-revert-test", deviceID: 999_999)
        XCTAssertFalse(engine.switchOutputDevice(to: invalidDevice, testToken), "無効なデバイス ID への切替は失敗し、元のデバイスへ戻る")

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 1,
            "切替に失敗して元のデバイスへ戻す経路でも、出力ユニットは実際に停止・再開されているため同じ IO 空白が"
                + "生じる。成否によらずリセットを要求する (AudioEngine.switchOutputDevice の why コメント参照)"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - 遅延線の作り直し (assemble / switchOutputDevice / performRateChange、実クラス経由)

    func testAssembleInstallsTheDelayTheStubDeclaresAndSuspendReleasesIt() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let stub = PresentationDelayStub([4321])
        engine.readDeclaredPresentationLatencyFrames = stub.next
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 4321, "遅延は申告値")
        XCTAssertEqual(stub.calls.map(\.deviceID), [device.deviceID])
        XCTAssertEqual(stub.calls.map(\.sampleRate), [AudioConfig.appliedSampleRate])

        engine.suspend(cause: .applicationTermination, testToken)
        XCTAssertNil(engine.presentationDelay, "停止で手放す")
    }

    func testAssembleInstallsAZeroDelayLineWhenTheStubDeclaresZero() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        engine.readDeclaredPresentationLatencyFrames = PresentationDelayStub([0]).next
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 0)

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - 遅延線の作り直しの要否 (出力先の UID)

    private func assembledEngine(
        declared: Int?, device: (deviceID: AudioDeviceID, uid: String)
    ) throws -> (engine: AudioEngine, ringReader: SharedRingReader) {
        let engine = makeSilencedEngine()
        engine.readDeclaredPresentationLatencyFrames = PresentationDelayStub([declared, declared, declared]).next
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(
            outputDevice: ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID), ringReader: ringReader, testToken
        ))
        return (engine, ringReader)
    }

    func testNotNeededSwitchKeepsTheDelayWhenItsOutputUIDMatches() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let (engine, _) = try assembledEngine(declared: 20000, device: device)
        defer { engine.suspend(cause: .applicationTermination, testToken) }
        let before = try XCTUnwrap(engine.presentationDelay)

        XCTAssertTrue(engine.switchOutputDevice(to: ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID), testToken))

        XCTAssertTrue(engine.presentationDelay === before, "出力先の UID が一致するなら作り直さない")
    }

    func testTheSnapshotCarriesTheDeclaredAndAppliedDelayWhileRunningAndNilWhenStopped() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let (engine, _) = try assembledEngine(declared: 4000, device: device)

        XCTAssertEqual(
            engine.runtimeMetricsSnapshot(testToken).presentationDelay,
            PresentationDelayObservation(declaredFrames: 4000, appliedFrames: 4000)
        )

        engine.suspend(cause: .applicationTermination, testToken)
        XCTAssertNil(engine.runtimeMetricsSnapshot(testToken).presentationDelay)
    }

    func testTheSnapshotLeavesDeclaredNilWhenTheStubCannotRead() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let (engine, _) = try assembledEngine(declared: nil, device: device)
        defer { engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(
            engine.runtimeMetricsSnapshot(testToken).presentationDelay,
            PresentationDelayObservation(declaredFrames: nil, appliedFrames: 0),
            "読めない申告値は 0 として遅延計算に使い、観測では nil のまま"
        )
    }

    func testSwitchOutputDeviceRebuildsTheDelayForTheNewDeviceOnSuccess() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let stub = PresentationDelayStub([100, 200])
        engine.readDeclaredPresentationLatencyFrames = stub.next
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 100)

        // UID だけ変えて .notNeeded を避け、実際の切替経路 (switched && restarted) を通す。
        let forcedSwitchDevice = ResolvedOutputDevice(uid: "forced-different-uid-for-delay-rebuild", deviceID: device.deviceID)
        XCTAssertTrue(engine.switchOutputDevice(to: forcedSwitchDevice, testToken))

        XCTAssertEqual(engine.presentationDelay?.delayFrames, 200, "切替成功で新しい値へ作り直される")
        XCTAssertEqual(stub.calls.map(\.deviceID), [device.deviceID, device.deviceID], "同じ device ID で作り直しが呼ばれる")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    func testSwitchOutputDeviceKeepsThePreviousDelayWhenTheSwitchFails() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let stub = PresentationDelayStub([100])
        engine.readDeclaredPresentationLatencyFrames = stub.next
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 100)

        // 存在しないデバイス ID を渡し、「切替に失敗して元のデバイスへ戻す」経路を強制する。
        let invalidDevice = ResolvedOutputDevice(uid: "invalid-device-for-delay-revert-test", deviceID: 999_999)
        XCTAssertFalse(engine.switchOutputDevice(to: invalidDevice, testToken))

        XCTAssertEqual(engine.presentationDelay?.delayFrames, 100, "新デバイスへの適用が失敗した回は遅延線を作り直していないため元の値のまま")
        XCTAssertEqual(stub.calls.count, 1, "適用が失敗した回では作り直しを呼ばない")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    func testPerformRateChangeRebuildsTheDelayForTheNewRate() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        let engine = makeSilencedEngine()
        let stub = PresentationDelayStub([100, 200])
        engine.readDeclaredPresentationLatencyFrames = stub.next
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000)
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 100)
        XCTAssertEqual(stub.calls.map(\.sampleRate), [48000])

        setHeaderSampleRate(url, 44100)
        engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(AudioConfig.appliedSampleRate, 44100, "前提: レート変更が適用されている")
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 200, "レート変更で新しい処理レートに合わせて作り直される")
        XCTAssertEqual(stub.calls.map(\.sampleRate), [48000, 44100], "作り直しに渡る処理レートが新しいレートに変わる")
        XCTAssertEqual(stub.calls.map(\.deviceID), [device.deviceID, device.deviceID], "現在の出力デバイスで作り直す")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // MARK: - 出力段の水準の受け渡し (ピークの観測と、無音判定の材料)

    func testCaptureLevelsAndApplyOutputGainReturnsThePeakMeasuredBeforeTheGain() {
        let engine = AudioEngine()
        let channels = Int(AudioConfig.channels)

        var attenuated: [Float] = [1.5, -0.5]
        let attenuatedPeak = attenuated.withUnsafeMutableBufferPointer {
            engine.captureLevelsAndApplyOutputGain($0.baseAddress!, frameCount: 1, channels: channels, gain: 0.5)
        }
        XCTAssertEqual(attenuatedPeak, 1.5, "返るピークは音量を掛ける前の振幅")
        XCTAssertEqual(attenuated, [0.75, -0.25], "バッファには音量が適用される")

        var muted: [Float] = [1.5, -1.5]
        let mutedPeak = muted.withUnsafeMutableBufferPointer {
            engine.captureLevelsAndApplyOutputGain($0.baseAddress!, frameCount: 1, channels: channels, gain: 0)
        }
        XCTAssertEqual(mutedPeak, 1.5, "消音中も掛ける前の振幅を返す")
        XCTAssertEqual(muted, [0, 0])

        var unity: [Float] = [0.25, -0.75]
        let unityPeak = unity.withUnsafeMutableBufferPointer {
            engine.captureLevelsAndApplyOutputGain($0.baseAddress!, frameCount: 1, channels: channels, gain: 1)
        }
        XCTAssertEqual(unityPeak, 0.75)
        XCTAssertEqual(unity, [0.25, -0.75], "ユニティではバッファを書き換えない")
    }

    func testCaptureLevelsAndApplyOutputGainFeedsTheAnalyzerBeforeTheGain() {
        let engine = AudioEngine()
        let channels = Int(AudioConfig.channels)
        let fftSize = LevelMeter.deriveFFTSize(sampleRate: engine.levelMeter.appliedSampleRate)
        let frameCount = LevelMeter.deriveHopSize(fftSize: fftSize)

        var buffer = [Float](repeating: 1.5, count: frameCount * channels)
        _ = buffer.withUnsafeMutableBufferPointer {
            engine.captureLevelsAndApplyOutputGain(
                $0.baseAddress!, frameCount: frameCount, channels: channels, gain: 0.5
            )
        }

        let clip = engine.levelMeter.analyzeAvailableHops()
        XCTAssertTrue(clip.left, "音量を掛ける前の振幅で超過を判定する")
        XCTAssertTrue(clip.right)
    }

    // 出力コールバックの末尾で 1 回だけ走る受け渡しを直接駆動して結線を固定する。
    func testRecordOutputLevelPassesThePostVolumePeakWithTheEffectiveOutputGain() throws {
        let engine = AudioEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()

        let frameCount = 128
        let channels = Int(AudioConfig.channels)
        let threshold = OccupancyPolicy.silenceLevelThresholdAmplitude
        // 素の閾値だけを見れば無音と判定される水準。
        let quietPeak = threshold * 0.5
        func record(_ value: Float, gain: Float, beforeVolume: Float) {
            let buffer = [Float](repeating: value, count: frameCount * channels)
            buffer.withUnsafeBufferPointer {
                engine.recordOutputLevel(
                    $0.baseAddress!, frameCount: frameCount, channels: channels,
                    peakBeforeVolume: beforeVolume, effectiveOutputGain: gain, reader: reader
                )
            }
        }

        // 閾値は実効出力ゲインを掛けて比べる。
        record(quietPeak, gain: 0.25, beforeVolume: quietPeak * 4)
        XCTAssertEqual(reader.silentOutputFrameCount, 0, "音量を絞っただけの通常再生は無音にしない")

        // 渡すピークは音量適用後のバッファそのもの (適用前の値へ戻して渡さない)。
        XCTAssertEqual(engine.runtimeMetrics.peak, quietPeak, accuracy: 1e-9, "ピークは音量適用後の実出力")

        // 同じバッファでも、音量を絞っていない回は閾値を下回り静けさとして積まれる。
        record(quietPeak, gain: 1, beforeVolume: quietPeak)
        XCTAssertEqual(reader.silentOutputFrameCount, frameCount)

        // 消音 (ゲイン 0) でも受け渡しは行われ、静けさの継続が伸びる (消音中に捨てるのは望ましい)。
        record(0, gain: 0, beforeVolume: threshold * 10)
        XCTAssertEqual(reader.silentOutputFrameCount, frameCount * 2, "消音中も静けさとして数える")

        // 静かでない回は数え直す。
        record(threshold * 10, gain: 1, beforeVolume: threshold * 10)
        XCTAssertEqual(reader.silentOutputFrameCount, 0, "静かでない回は継続を 0 へ戻す")
    }

    func testRecordOutputLevelRecordsTheTwoPeaksSeparately() {
        let engine = AudioEngine()
        let frameCount = 128
        let channels = Int(AudioConfig.channels)
        let exceedingPeak: Float = 1.5

        let buffer = [Float](repeating: 0, count: frameCount * channels)
        buffer.withUnsafeBufferPointer {
            engine.recordOutputLevel(
                $0.baseAddress!, frameCount: frameCount, channels: channels,
                peakBeforeVolume: exceedingPeak, effectiveOutputGain: 0, reader: nil
            )
        }

        XCTAssertEqual(engine.runtimeMetrics.peak, 0, "音量適用後は渡したバッファそのもの")
        XCTAssertEqual(engine.runtimeMetrics.peakBeforeVolume, exceedingPeak, accuracy: 1e-9)
    }

    // MARK: - レート変更の検知・再構築 (実クラス経由)

    // sampleRate はプロセス全体で共有されるため、レート変更を伴うテストは終了時に基準レートへ戻す。
    private func restoringBaseSampleRateAfterTest() {
        addTeardownBlock { AudioConfig.applySampleRate(AudioConfig.baseSampleRate) }
    }

    func testAssembleRebuildsLevelMeterWithHeaderSampleRate() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let levelMeterAtInit = engine.levelMeter
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 44100)
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        XCTAssertEqual(AudioConfig.appliedSampleRate, 44100, "初回接続はヘッダの実レートを適用する")
        XCTAssertTrue(
            engine.levelMeter === levelMeterAtInit,
            "LevelMeter の参照は差し替えない。内部だけがヘッダの実レートで組み直される"
        )
        XCTAssertEqual(
            engine.levelMeter.appliedSampleRate, 44100,
            "バンドのビン範囲・解析窓の時間長を確定させるレートが実レートと一致する"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // ヘッダの sampleRate が変わったことを検知し、新しいレートで再構築が完了することを検証する。
    func testApplyDriverSampleRateIfChangedRebuildsWhenHeaderRateDiffersFromApplied() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000)
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(AudioConfig.appliedSampleRate, 48000, "初回接続はヘッダの実レートを適用する")

        let levelMeterBeforeRebuild = engine.levelMeter
        let generationBeforeRebuild = engine.levelMeterRestartGeneration.value
        let appliedRatesAtNotification = Recorded<[Double]>([])
        engine.appliedSampleRateDidChange = { rate in appliedRatesAtNotification.update { $0.append(rate) } }

        setHeaderSampleRate(url, 44100)
        engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(AudioConfig.appliedSampleRate, 44100, "レート変更の単一入口がヘッダの新しい値を適用する")
        XCTAssertEqual(appliedRatesAtNotification.value, [44100], "再構築完了の通知が新しいレートで発火する")
        XCTAssertTrue(engine.levelMeter === levelMeterBeforeRebuild, "LevelMeter の参照は差し替えない。内部だけが新しいレートで組み直される")
        XCTAssertEqual(engine.levelMeter.appliedSampleRate, 44100, "組み直し後の内部が新しいレートを反映している")
        XCTAssertNotEqual(
            engine.levelMeterRestartGeneration.value, generationBeforeRebuild,
            "レート変更が作り直しの申告 (世代) を進める"
        )
        XCTAssertEqual(engine.processingState, .active, "再構築成功時は稼働状態を維持する")

        // 再構築は出力 AUHAL の停止をまたいだ再開であり、出力先の切替と同じ規則でバッファ量を作り直す。
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 1,
            "レート変更の再構築でもバッファ量の作り直しを要求する"
        )

        // 同じ値のまま呼んでも空振りする (状態を持たない検査、複数回呼んでも誤判定しない)。
        engine.applyDriverSampleRateIfChanged(testToken)
        XCTAssertEqual(appliedRatesAtNotification.value, [44100], "適用中の値と一致していれば再構築は起きない")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ringReader.metrics.occupancyResetDueToOutputRestartCount, 1,
            "再構築が起きない回は要求も出さない"
        )

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // レート変更を連続して発生させても、それぞれが独立して完了し最終的なレートへ収束する。
    func testConsecutiveRateChangesEachCompleteIndependently() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let outputDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)

        let engine = makeSilencedEngine()
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000)
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(engine.assemble(outputDevice: outputDevice, ringReader: ringReader, testToken))

        let appliedRatesAtNotification = Recorded<[Double]>([])
        engine.appliedSampleRateDidChange = { rate in appliedRatesAtNotification.update { $0.append(rate) } }

        setHeaderSampleRate(url, 44100)
        engine.applyDriverSampleRateIfChanged(testToken)

        // 途中に高レートへの遷移を挟む。
        setHeaderSampleRate(url, 96000)
        engine.applyDriverSampleRateIfChanged(testToken)

        setHeaderSampleRate(url, 48000)
        engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(appliedRatesAtNotification.value, [44100, 96000, 48000], "連続したレート変更のそれぞれが完了として通知される")
        XCTAssertEqual(AudioConfig.appliedSampleRate, 48000)
        XCTAssertEqual(engine.levelMeter.appliedSampleRate, 48000, "最終的なレートへ内部が収束している")
        XCTAssertEqual(engine.processingState, .active, "連続したレート変更後も稼働状態を維持する")

        engine.suspend(cause: .applicationTermination, testToken)
    }

    // 出力先を切り替えてからクリーン終了すると、切り替えた先へ復帰する。
    func testCleanExitRestoresToDeviceSwitchedToDuringSession() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        let startupDevice = ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID)
        // セッション中に選び直した先。
        let switchedDevice = ResolvedOutputDevice(uid: "switched-to-uid", deviceID: device.deviceID)

        let suiteName = TestDefaults.makeName("AudioEngineTests")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaults.remove(name: suiteName, defaults: defaults) }
        let settings = SettingsStore(defaults: defaults)
        settings.savedDefaultOutputUID = "startup-default-uid"
        settings.switchPending = true

        let directory = MockAudioDeviceDirectory()
        // クリーン終了時の切り戻し用: 切替先を実デバイスとして解決できるようにする。
        let restoreDeviceID: AudioDeviceID = 999
        directory.deviceIDsByUID[switchedDevice.uid] = restoreDeviceID
        directory.uidsByDeviceID[restoreDeviceID] = switchedDevice.uid
        // デフォルト出力が自ドライバのデバイスを指したままであることを模す (切り戻しの要否判定用)。
        let driverDeviceID: AudioDeviceID = 111
        directory.currentDefaultOutputID = driverDeviceID
        directory.uidsByDeviceID[driverDeviceID] = "driver-uid"

        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: "driver-uid")
        let engine = makeSilencedEngine()
        engine.outputDeviceDidConfirm = { uid in outputController.noteOutputDeviceDidConfirm(uid: uid) }

        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let ringReader = try SharedRingReader.open(path: url.path).get()

        XCTAssertTrue(engine.assemble(outputDevice: startupDevice, ringReader: ringReader, testToken))
        XCTAssertEqual(outputController.restoreTargetUID, startupDevice.uid, "前提: 起動時に採用した出力先が復帰先として記録されている")

        XCTAssertTrue(engine.switchOutputDevice(to: switchedDevice, testToken))
        XCTAssertEqual(outputController.restoreTargetUID, switchedDevice.uid, "切り替えた先が復帰先として記録されている")

        XCTAssertTrue(outputController.restore(testToken), "自ドライバから離れているので非表示にしてよい")

        XCTAssertEqual(directory.setDefaultOutputCalls, [restoreDeviceID], "切り替えた先 (switchedDevice.uid) へ復帰する")
        XCTAssertFalse(outputController.currentRestoreState(testToken).pending)

        engine.suspend(cause: .applicationTermination, testToken) // 実資源 (AudioUnit) の後始末
    }

    // MARK: - AudioEngine.levelMeter は生成後は差し替えない
    func testLevelMeterReferenceStaysStableAcrossRebuild() {
        let engine = AudioEngine()
        let original = engine.levelMeter

        engine.levelMeter.rebuild(appliedSampleRate: 48000)

        XCTAssertTrue(engine.levelMeter === original, "rebuild は内部を組み直すだけで参照を差し替えない")
        XCTAssertEqual(engine.levelMeter.appliedSampleRate, 48000)
    }

    // MARK: - 取り込み経路 (実クラス経由)

    /// 実デバイスをエンドポイントに見立てた取り込み経路。リングへは誰も書かないので出力は無音のまま。
    private func makeCapturePathFixture() throws -> (engine: AudioEngine, capture: FakeCaptureSource, reader: SharedRingReader, url: URL, device: (deviceID: AudioDeviceID, uid: String)) {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let capture = FakeCaptureSource(endpointUID: device.uid, endpointDeviceID: device.deviceID, sampleRate: 44100)
        return (makeSilencedEngine(), capture, reader, url, device)
    }

    func testTheCapturePathHandsTheLoudnessStageNeutralSettingsWhileKeepingTheHeldOnes() throws {
        let f = try makeCapturePathFixture()
        var settings = SoundLabSettings()
        settings.loudness.enabled = true
        settings.stereoExpander.enabled = true
        f.engine.applySoundLab(settings, testToken)

        XCTAssertTrue(f.engine.assembleAirPlay(capture: f.capture, ringReader: f.reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        XCTAssertEqual(f.engine.soundLabSettingsInEffect.loudness, LoudnessSettings())
        XCTAssertEqual(f.engine.soundLabSettingsInEffect.stereoExpander, settings.stereoExpander, "他の段は保持している操作値のまま")
        XCTAssertEqual(f.engine.airPlayRoute, f.device.uid)
        XCTAssertEqual(f.engine.runtimeMetrics.audioInput, .airPlay)

        f.engine.suspend(cause: .routeUnavailable, testToken)
        XCTAssertEqual(f.engine.runtimeMetrics.audioInput, .none)
        XCTAssertTrue(f.engine.assemble(outputDevice: ResolvedOutputDevice(uid: f.device.uid, deviceID: f.device.deviceID), ringReader: f.reader, testToken))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(f.engine.soundLabSettingsInEffect.loudness, settings.loudness, "戻れば保持していた値で効く")
        XCTAssertNil(f.engine.airPlayRoute)
        XCTAssertEqual(f.engine.runtimeMetrics.audioInput, .dedicatedDriver)
    }

    func testTheCapturePathStillTranscribesTheDriverObservationsIntoTheEngineMetrics() throws {
        let f = try makeCapturePathFixture()
        XCTAssertTrue(f.engine.assembleAirPlay(capture: f.capture, ringReader: f.reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertNotEqual(f.reader.driverReportedLayoutVersion, 0, "前提: ヘッダに版が書かれていること")

        f.engine.refreshDriverObservations(testToken)

        XCTAssertEqual(f.engine.runtimeMetrics.driverLayoutVersion, f.reader.driverReportedLayoutVersion)
    }

    func testTheCapturePathInstallsTheDelayTheEndpointDeclares() throws {
        let f = try makeCapturePathFixture()
        let delayFrames = 1234
        f.engine.readDeclaredPresentationLatencyFrames = { _, _, _ in delayFrames }
        f.engine.applyAVSyncOffsets([f.device.uid: 200], testToken)

        XCTAssertTrue(f.engine.assembleAirPlay(capture: f.capture, ringReader: f.reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        XCTAssertEqual(f.engine.presentationDelay?.delayFrames, delayFrames, "遅延線は申告値だけで決まる")

        f.engine.applyAVSyncOffsets([f.device.uid: -200], testToken)
        XCTAssertEqual(f.engine.presentationDelay?.delayFrames, delayFrames, "実行中に届いた表も使わない")

        f.engine.suspend(cause: .routeUnavailable, testToken)
        XCTAssertNil(f.engine.presentationDelay, "停止で手放す")
    }

    func testTheAnalyzerSeesTheDelayedSignalWhileTheReturnedPeakIsNotDelayed() {
        let engine = AudioEngine()
        let channels = Int(AudioConfig.channels)
        let fftSize = LevelMeter.deriveFFTSize(sampleRate: engine.levelMeter.appliedSampleRate)
        let frameCount = LevelMeter.deriveHopSize(fftSize: fftSize)
        let delay = PresentationDelayLine(delayFrames: frameCount, channels: channels)

        var loud = [Float](repeating: 1.5, count: frameCount * channels)
        let peak = loud.withUnsafeMutableBufferPointer {
            engine.captureLevelsAndApplyOutputGain($0.baseAddress!, frameCount: frameCount, channels: channels, gain: 1, presentationDelay: delay)
        }
        XCTAssertEqual(peak, 1.5, "返すピークは遅らせない")
        XCTAssertFalse(engine.levelMeter.analyzeAvailableHops().left, "解析へはまだ届いていない")

        var quiet = [Float](repeating: 0, count: frameCount * channels)
        _ = quiet.withUnsafeMutableBufferPointer {
            engine.captureLevelsAndApplyOutputGain($0.baseAddress!, frameCount: frameCount, channels: channels, gain: 1, presentationDelay: delay)
        }
        XCTAssertTrue(engine.levelMeter.analyzeAvailableHops().left, "遅延ぶん後に解析へ届く")
    }

    // ドライバのレートで取り込み経路を組み直すと、エンドポイントのレートと食い違う。
    func testADriverRateChangeDoesNotRebuildTheCapturePath() throws {
        let f = try makeCapturePathFixture()
        XCTAssertTrue(f.engine.assembleAirPlay(capture: f.capture, ringReader: f.reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertEqual(AudioConfig.appliedSampleRate, f.capture.sampleRate, "前提: 取り込み経路のレートを適用している")
        let notifiedRates = Recorded<[Double]>([])
        f.engine.appliedSampleRateDidChange = { rate in notifiedRates.update { $0.append(rate) } }

        setHeaderSampleRate(f.url, 96000)
        f.engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(AudioConfig.appliedSampleRate, f.capture.sampleRate)
        XCTAssertTrue(notifiedRates.value.isEmpty)
    }

    // 出力段が止まっている間にだけ入口の資源を手放す。
    func testStoppingTheCapturePathDestroysItOnlyAfterTheOutputUnitIsGone() throws {
        let f = try makeCapturePathFixture()
        let outputUnitGoneAtDestroy = Recorded<Bool?>(nil)
        f.capture.onDestroy = { [engine = f.engine] in
            outputUnitGoneAtDestroy.update { $0 = engine.currentOutputDeviceID(testToken) == nil }
        }
        XCTAssertTrue(f.engine.assembleAirPlay(capture: f.capture, ringReader: f.reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        XCTAssertEqual(f.capture.startCount, 1)
        XCTAssertNotNil(f.engine.currentOutputDeviceID(testToken), "前提: 出力段が動いている")

        f.engine.suspend(cause: .routeUnavailable, testToken)

        XCTAssertEqual(f.capture.destroyCount, 1)
        XCTAssertEqual(outputUnitGoneAtDestroy.value, true)
    }

    func testACapturePathThatCannotStartIsDestroyedAndStopsTheEngine() throws {
        let f = try makeCapturePathFixture()
        f.capture.startShouldSucceed = false

        XCTAssertFalse(f.engine.assembleAirPlay(capture: f.capture, ringReader: f.reader, testToken))

        XCTAssertEqual(f.capture.destroyCount, 1)
        XCTAssertEqual(f.engine.processingState, .suspended(.routeUnavailable))
        XCTAssertNil(f.engine.airPlayRoute)
    }

    func testTheCapturePathIsHealthyOnlyWhileTheRingIsFedAtTheAppliedRateToTheEndpoint() throws {
        let f = try makeCapturePathFixture()
        let capture = FakeCaptureSource(
            endpointUID: f.capture.endpointUID, endpointDeviceID: f.capture.endpointDeviceID, sampleRate: 44100, ioBufferFrames: 64
        )
        XCTAssertTrue(f.engine.evaluateAirPlayCaptureStalled(testToken), "取り込み経路が無い間は止まっているとみなす")
        XCTAssertTrue(f.engine.assembleAirPlay(capture: capture, ringReader: f.reader, testToken), "前提: 実デバイスへの組み立てが成立すること")
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let silence = [Float](repeating: 0, count: 64 * Int(AudioConfig.channels))
        let cycleThreshold = SharedRingReader.writerStallThreshold(ioCycleFrames: 64, sampleRate: capture.sampleRate)

        Thread.sleep(forTimeInterval: cycleThreshold * 4)
        XCTAssertFalse(f.engine.evaluateAirPlayCaptureStalled(testToken), "組み立て直後は最初の書き込みまで周期しきい値で読まない")

        silence.withUnsafeBufferPointer { capture.ring.write($0.baseAddress!, frames: 64) }
        XCTAssertFalse(f.engine.evaluateAirPlayCaptureStalled(testToken))
        XCTAssertTrue(f.engine.airPlayRouteHealthy(testToken))

        capture.sampleRateReading = 48000
        XCTAssertFalse(f.engine.airPlayRouteHealthy(testToken), "Aggregate のレートが適用中のレートと違う")
        capture.sampleRateReading = capture.sampleRate

        Thread.sleep(forTimeInterval: SharedRingReader.writerStallThreshold(ioCycleFrames: 64, sampleRate: capture.sampleRate) * 4)
        XCTAssertTrue(f.engine.evaluateAirPlayCaptureStalled(testToken))
        XCTAssertFalse(f.engine.airPlayRouteHealthy(testToken))
    }

    func testSilenceObservationsGoToTheCaptureRingWhileItIsTheInput() throws {
        let engine = AudioEngine()
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let ring = CaptureRing(sampleRate: 44100)
        let frameCount = 128
        let buffer = [Float](repeating: 0, count: frameCount * Int(AudioConfig.channels))

        buffer.withUnsafeBufferPointer {
            engine.recordOutputLevel(
                $0.baseAddress!, frameCount: frameCount, channels: Int(AudioConfig.channels),
                peakBeforeVolume: 0, effectiveOutputGain: 1, reader: reader, captureRing: ring
            )
        }

        XCTAssertEqual(ring.silentOutputFrameCount, frameCount)
        XCTAssertEqual(reader.silentOutputFrameCount, 0)
    }
}

// MARK: - AudioActivationCoordinator (起動・再開の共通手順)

/// この代役へ触れる経路は直列キューが順序を作るため、同時に触れることが無い。
final class MockActivatableAudioEngine: ActivatableAudioEngine, @unchecked Sendable {
    var processingState: ProcessingState = .suspended(.routeUnavailable)
    var assembleShouldSucceed = true
    private(set) var assembleCalls: [(outputDevice: ResolvedOutputDevice, driverDeviceID: AudioDeviceID?)] = []
    private(set) var assembleAirPlayCalls: [(capture: AirPlayCaptureSource, driverDeviceID: AudioDeviceID?)] = []

    @discardableResult
    func assemble(outputDevice: ResolvedOutputDevice, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        assembleCalls.append((outputDevice, driverDeviceID))
        processingState = assembleShouldSucceed ? .active : .suspended(.routeUnavailable)
        return assembleShouldSucceed
    }

    @discardableResult
    func assembleAirPlay(capture: AirPlayCaptureSource, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        assembleAirPlayCalls.append((capture, driverDeviceID))
        processingState = assembleShouldSucceed ? .active : .suspended(.routeUnavailable)
        return assembleShouldSucceed
    }

    func suspend(cause: SuspensionCause, _ token: AudioWorldToken) {
        processingState = .suspended(cause)
    }
}

@MainActor
final class AudioActivationCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    nonisolated private let tempURLs = Recorded<[URL]>([])

    private let driverUID = "driver-device-uid"
    private let driverDeviceID: AudioDeviceID = 40
    private let speakerUID = "speaker-uid"
    private let speakerID: AudioDeviceID = 10

    // 同期版は隔離を持たず、この検証が保持する状態 (メイン隔離) を触れない。
    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("AudioActivationCoordinatorTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        for url in tempURLs.value { try? FileManager.default.removeItem(at: url) }
        tempURLs.update { $0.removeAll() }
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    nonisolated private static func openValidSharedRingReader(
        registeringInto tempURLs: Recorded<[URL]>
    ) -> Result<SharedRingReader, SharedRingReader.OpenFailure> {
        let url = makeMinimalSharedRingReaderFixture()
        tempURLs.update { $0.append(url) }
        return SharedRingReader.open(path: url.path)
    }

    private func makeDirectory() -> MockAudioDeviceDirectory {
        let directory = MockAudioDeviceDirectory()
        directory.hiddenDeviceIDsByUID[driverUID] = driverDeviceID
        directory.uidsByDeviceID[driverDeviceID] = driverUID
        directory.deviceIDsByUID[speakerUID] = speakerID
        directory.uidsByDeviceID[speakerID] = speakerUID
        return directory
    }

    private func makeCoordinator(
        directory: MockAudioDeviceDirectory, engine: MockActivatableAudioEngine,
        openSharedMemory: @escaping @Sendable () -> Result<SharedRingReader, SharedRingReader.OpenFailure>,
        waitBeforeRetry: @escaping @Sendable () -> Void = {}
    ) -> (coordinator: AudioActivationCoordinator, lifecycle: DriverLifecycleController) {
        let settings = SettingsStore(defaults: defaults)
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: driverUID)
        let coordinator = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: openSharedMemory, waitBeforeRetry: waitBeforeRetry
        )
        return (coordinator, lifecycle)
    }

    // 共有メモリを開けない場合、可視化も切替も行わず停止のまま返す。
    func testActivateReturnsUnchangedStateWhenSharedMemoryUnopenable() {
        let directory = makeDirectory()
        let engine = MockActivatableAudioEngine()
        let (coordinator, lifecycle) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { .failure(.fileNotFound) }
        )

        let result = coordinator.activate(resolveOutputDevice: { _ in XCTFail("到達しないはず"); return nil }, attempt: .resume, testToken)

        XCTAssertEqual(result.processingState, .suspended(.routeUnavailable))
        XCTAssertNil(result.activeOutputDevice)
        XCTAssertNil(lifecycle.resolvedDeviceID, "可視化しない")
        XCTAssertTrue(directory.setHiddenCalls.isEmpty)
        XCTAssertTrue(directory.setDefaultOutputCalls.isEmpty, "切替も行わない")
        XCTAssertTrue(engine.assembleCalls.isEmpty)
    }

    // 出力先を解決できない場合、この試行で切替を行っていたら復帰させ、停止のまま返す。
    func testActivateRestoresWhenOutputDeviceUnresolvedAfterSwitching() {
        let directory = makeDirectory()
        // 復帰対象 (退避先): 現在のデフォルト出力を保存する。
        directory.currentDefaultOutputID = speakerID
        let engine = MockActivatableAudioEngine()
        let (coordinator, _) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )

        let result = coordinator.activate(resolveOutputDevice: { _ in nil }, attempt: .resume, testToken)

        XCTAssertEqual(result.processingState, .suspended(.routeUnavailable))
        XCTAssertNil(result.activeOutputDevice)
        XCTAssertEqual(directory.setDefaultOutputCalls, [driverDeviceID, speakerID], "切替に続けて復帰させる")
        XCTAssertTrue(engine.assembleCalls.isEmpty)
    }

    // 起動は所有権の停止のまま所有を確定させてから呼ぶ。出力先を解決できなければ経路の停止へ移し、他の停止種別は変えない。
    func testActivateMovesOwnershipSuspensionToRouteUnavailableWhenOutputDeviceUnresolved() {
        for (initial, expected) in [
            (ProcessingState.suspended(.ownershipUnavailable), ProcessingState.suspended(.routeUnavailable)),
            (.suspended(.driverOperation), .suspended(.driverOperation)),
        ] {
            let directory = makeDirectory()
            let engine = MockActivatableAudioEngine()
            engine.processingState = initial
            let (coordinator, _) = makeCoordinator(
                directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
            )

            let result = coordinator.activate(resolveOutputDevice: { _ in nil }, attempt: .launch, testToken)

            XCTAssertEqual(result.processingState, expected, "\(initial)")
            XCTAssertTrue(result.outputRouteNotEstablished)
        }
    }

    // 占有していない状態からの再開は占有を確立する / 占有済みなら切替を打ち直さない。
    func testActivateSwitchesOnlyWhenNotAlreadyOccupying() {
        let directory = makeDirectory()
        directory.currentDefaultOutputID = speakerID
        let engine = MockActivatableAudioEngine()
        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)
        let (coordinator, _) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )

        let first = coordinator.activate(resolveOutputDevice: { _ in target }, attempt: .resume, testToken)
        XCTAssertEqual(directory.setDefaultOutputCalls, [driverDeviceID], "未占有からの再開は占有を確立する")
        XCTAssertEqual(first.activeOutputDevice, target)

        // 2 回目: 既に占有している (デフォルト出力が自ドライバのデバイス)。
        directory.resetCallRecords()
        coordinator.activate(resolveOutputDevice: { _ in target }, attempt: .resume, testToken)
        XCTAssertTrue(directory.setDefaultOutputCalls.isEmpty, "占有済みなら切替を打ち直さない")
    }

    // 自分で切り替えたのでなくても、稼働を引き受けた側が復帰義務と戻し先を負う。
    // 負わないと、占有された状態がそのまま次の起動へ引き継がれ、誰も既定出力を戻さなくなる。
    func testActivateAssumesTheRestoreObligationWithoutHavingSwitchedItself() {
        let directory = makeDirectory()
        directory.currentDefaultOutputID = driverDeviceID // 既にドライバが既定出力を握っている。
        let settings = SettingsStore(defaults: defaults)
        let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
        let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: driverUID)
        let engine = MockActivatableAudioEngine()
        let coordinator = AudioActivationCoordinator(
            engine: engine, driverLifecycle: lifecycle, outputController: outputController,
            openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        XCTAssertFalse(outputController.currentRestoreState(testToken).pending, "前提: 義務を持たない")

        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)
        coordinator.activate(resolveOutputDevice: { _ in target }, attempt: .resume, testToken)

        XCTAssertTrue(directory.setDefaultOutputCalls.isEmpty, "前提: 自分では切り替えていない")
        let state = outputController.currentRestoreState(testToken)
        XCTAssertTrue(state.pending, "稼働を引き受けたので義務を負う")
        XCTAssertEqual(state.uid, speakerUID, "戻し先は実際に鳴らしている出力先")
    }

    // 掌握済みなら可視化を打ち直さない。
    func testActivateDoesNotReapplyVisibilityWhenAlreadyOwned() {
        let directory = makeDirectory()
        directory.currentDefaultOutputID = speakerID
        let engine = MockActivatableAudioEngine()
        let (coordinator, lifecycle) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        lifecycle.applyVisibility(hidden: false, deviceID: driverDeviceID, testToken)
        directory.resetCallRecords()

        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)
        coordinator.activate(resolveOutputDevice: { _ in target }, attempt: .resume, testToken)

        XCTAssertTrue(directory.setHiddenCalls.isEmpty, "掌握済みなら可視化を打ち直さない")
        XCTAssertTrue(directory.resolveHiddenDeviceIDCalls.isEmpty)
    }

    // MARK: - 取り込み経路の組み立て

    private let airPlayID: AudioDeviceID = 150

    // デフォルト出力が AirPlay でもドライバでも書かず、ドライバを表示せず、戻す義務も引き受けない。
    func testActivatingTheCapturePathLeavesTheDefaultOutputVisibilityAndObligationAlone() {
        for defaultOutput in [airPlayID, driverDeviceID] {
            let directory = makeDirectory()
            directory.uidsByDeviceID[airPlayID] = "airplay-uid"
            directory.airPlayDeviceIDs = [airPlayID]
            directory.currentDefaultOutputID = defaultOutput
            let engine = MockActivatableAudioEngine()
            let settings = SettingsStore(defaults: defaults)
            settings.savedDefaultOutputUID = speakerUID
            let lifecycle = DriverLifecycleController(directory: directory, targetDeviceUID: driverUID)
            let outputController = OutputDeviceController(directory: directory, settings: settings, targetDeviceUID: driverUID)
            let coordinator = AudioActivationCoordinator(
                engine: engine, driverLifecycle: lifecycle, outputController: outputController,
                openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
            )
            let stateBefore = outputController.currentRestoreState(testToken)

            XCTAssertTrue(coordinator.activateAirPlay(capture: FakeCaptureSource(), testToken))

            XCTAssertTrue(directory.setDefaultOutputCalls.isEmpty, "default=\(defaultOutput)")
            XCTAssertTrue(directory.setHiddenCalls.isEmpty, "default=\(defaultOutput)")
            XCTAssertNil(lifecycle.resolvedDeviceID, "可視性の責務を新たに負わない (default=\(defaultOutput))")
            XCTAssertEqual(outputController.currentRestoreState(testToken).pending, stateBefore.pending)
            XCTAssertEqual(outputController.currentRestoreState(testToken).uid, stateBefore.uid)
            XCTAssertEqual(engine.assembleAirPlayCalls.count, 1)
            XCTAssertEqual(engine.assembleAirPlayCalls.first?.driverDeviceID, driverDeviceID, "表示せずに解決した ID を渡す")
        }
    }

    func testActivatingTheCapturePathPrefersTheDriverIDTheSessionAlreadyHolds() {
        let directory = makeDirectory()
        let engine = MockActivatableAudioEngine()
        let (coordinator, lifecycle) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        let heldID: AudioDeviceID = 41
        lifecycle.applyVisibility(hidden: true, deviceID: heldID, testToken)
        directory.resetCallRecords()

        coordinator.activateAirPlay(capture: FakeCaptureSource(), testToken)

        XCTAssertEqual(engine.assembleAirPlayCalls.first?.driverDeviceID, heldID)
        XCTAssertTrue(directory.resolveHiddenDeviceIDCalls.isEmpty)
    }

    func testActivatingTheCapturePathWithoutSharedMemoryAssemblesNothing() {
        let directory = makeDirectory()
        let engine = MockActivatableAudioEngine()
        engine.processingState = .suspended(.routeUnavailable)
        let (coordinator, _) = makeCoordinator(directory: directory, engine: engine, openSharedMemory: { .failure(.fileNotFound) })

        XCTAssertFalse(coordinator.activateAirPlay(capture: FakeCaptureSource(), testToken))

        XCTAssertTrue(engine.assembleAirPlayCalls.isEmpty)
        XCTAssertEqual(engine.processingState, .suspended(.routeUnavailable))
    }

    // 再開が許されない停止種別では、組み立てを一切試みない。
    func testResumeSkipsActivationWhenCauseDoesNotAllowResume() {
        let directory = makeDirectory()
        let engine = MockActivatableAudioEngine()
        engine.processingState = .suspended(.driverOperation)
        let openCallCount = Recorded<Int>(0)
        let (coordinator, _) = makeCoordinator(
            directory: directory, engine: engine,
            openSharedMemory: { openCallCount.update { $0 += 1 }; return .failure(.fileNotFound) }
        )

        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)
        let result = coordinator.resume(outputDevice: target, trigger: .userSelection, testToken)

        XCTAssertEqual(result.processingState, .suspended(.driverOperation))
        XCTAssertNil(result.activeOutputDevice)
        XCTAssertEqual(openCallCount.value, 0, "共有メモリを開く手順にすら到達しない")
        XCTAssertTrue(engine.assembleCalls.isEmpty)
    }

    // 選び直しと自動再開はそれぞれ別の許可列を読む。
    func testResumeAttemptsActivationWhenCauseAllowsResume() {
        for trigger: ResumeTrigger in [.userSelection, .automatic] {
            let directory = makeDirectory()
            directory.currentDefaultOutputID = speakerID
            let engine = MockActivatableAudioEngine()
            engine.processingState = .suspended(.routeUnavailable)
            let (coordinator, _) = makeCoordinator(
                directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
            )
            let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)

            let result = coordinator.resume(outputDevice: target, trigger: trigger, testToken)

            XCTAssertEqual(engine.assembleCalls.count, 1, "\(trigger)")
            XCTAssertEqual(engine.assembleCalls.first?.outputDevice, target, "\(trigger)")
            XCTAssertEqual(result.processingState, .active, "\(trigger)")
        }
    }

    // 所有権取得による再開は、所有権を持たないことによる停止でだけ許される。
    func testOwnershipAcquiredResumesOnlyFromOwnershipUnavailable() {
        let directory = makeDirectory()
        directory.currentDefaultOutputID = speakerID
        let engine = MockActivatableAudioEngine()
        engine.processingState = .suspended(.ownershipUnavailable)
        let (coordinator, _) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)

        let result = coordinator.resume(outputDevice: target, trigger: .ownershipAcquired, testToken)

        XCTAssertEqual(engine.assembleCalls.count, 1)
        XCTAssertEqual(result.processingState, .active)
    }

    // 所有権取得以外の契機での停止では、所有権取得による再開は組み立てを一切試みない。
    func testOwnershipAcquiredSkipsActivationForOtherCauses() {
        for cause: SuspensionCause in [.routeUnavailable, .driverOperation, .applicationTermination] {
            let directory = makeDirectory()
            let engine = MockActivatableAudioEngine()
            engine.processingState = .suspended(cause)
            let openCallCount = Recorded<Int>(0)
            let (coordinator, _) = makeCoordinator(
                directory: directory, engine: engine,
                openSharedMemory: { openCallCount.update { $0 += 1 }; return .failure(.fileNotFound) }
            )
            let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)

            let result = coordinator.resume(outputDevice: target, trigger: .ownershipAcquired, testToken)

            XCTAssertEqual(result.processingState, .suspended(cause), "\(cause)")
            XCTAssertEqual(openCallCount.value, 0, "\(cause)")
        }
    }

    // MARK: - ヘッダ無効の再試行

    // 初回の probe がヘッダ無効以外を返せば即座にその値を採用し、wait は呼ばれない。
    func testOpenRetryingHeaderInvalidReturnsImmediatelyWhenFirstProbeSucceeds() {
        let waitCount = Recorded<Int>(0)
        let result = AudioActivationCoordinator.openRetryingHeaderInvalid(
            maxAttempts: 5, probe: { Self.openValidSharedRingReader(registeringInto: tempURLs) }, wait: { waitCount.update { $0 += 1 } }
        )
        XCTAssertEqual(DriverAvailability(openResult: result), .ok)
        XCTAssertEqual(waitCount.value, 0)
    }

    // ヘッダ無効が続く間は wait を挟んで再試行し、開けた時点で結果を確定する。
    func testOpenRetryingHeaderInvalidRetriesUntilProbeSucceeds() {
        var probeIndex = 0
        let waitCount = Recorded<Int>(0)
        let result = AudioActivationCoordinator.openRetryingHeaderInvalid(
            maxAttempts: 5,
            probe: {
                probeIndex += 1
                return probeIndex < 3 ? .failure(.headerInvalid) : Self.openValidSharedRingReader(registeringInto: tempURLs)
            },
            wait: { waitCount.update { $0 += 1 } }
        )
        XCTAssertEqual(DriverAvailability(openResult: result), .ok)
        XCTAssertEqual(waitCount.value, 2, "ヘッダ無効を 2 回観測した後の 3 回目で成功するため wait は 2 回")
    }

    // ヘッダ無効を返し続ける場合、ちょうど maxAttempts 回だけ wait して打ち切る。
    func testOpenRetryingHeaderInvalidGivesUpAfterMaxAttempts() {
        let waitCount = Recorded<Int>(0)
        let maxAttempts = 5
        let result = AudioActivationCoordinator.openRetryingHeaderInvalid(
            maxAttempts: maxAttempts, probe: { .failure(.headerInvalid) }, wait: { waitCount.update { $0 += 1 } }
        )
        XCTAssertEqual(DriverAvailability(openResult: result), .notFound)
        XCTAssertEqual(waitCount.value, maxAttempts)
    }

    // ファイル不在・レイアウトバージョン不一致は安定した実状態とみなし、再試行しない。
    func testOpenRetryingHeaderInvalidDoesNotRetryOnStableFailures() {
        for failure: SharedRingReader.OpenFailure in [.fileNotFound, .versionMismatch(found: 1, expected: 2)] {
            let waitCount = Recorded<Int>(0)
            let result = AudioActivationCoordinator.openRetryingHeaderInvalid(
                maxAttempts: 5, probe: { .failure(failure) }, wait: { waitCount.update { $0 += 1 } }
            )
            XCTAssertEqual(waitCount.value, 0, "\(failure)")
            guard case .failure(let observed) = result else {
                XCTFail("失敗のまま返るはず: \(failure)")
                continue
            }
            XCTAssertEqual(observed, failure)
        }
    }

    // 起動経路はヘッダ無効を再試行し、開けたら組み立てまで進む。
    func testActivateRetriesHeaderInvalidWhenRequested() {
        let directory = makeDirectory()
        directory.currentDefaultOutputID = speakerID
        let engine = MockActivatableAudioEngine()
        let probeCount = Recorded<Int>(0)
        let waitCount = Recorded<Int>(0)
        let (coordinator, _) = makeCoordinator(
            directory: directory, engine: engine,
            openSharedMemory: { [tempURLs] in
                let attempt = probeCount.update { $0 += 1; return $0 }
                return attempt < 2 ? .failure(.headerInvalid) : Self.openValidSharedRingReader(registeringInto: tempURLs)
            },
            waitBeforeRetry: { waitCount.update { $0 += 1 } }
        )
        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)

        let result = coordinator.activate(resolveOutputDevice: { _ in target }, attempt: .launch, testToken)

        XCTAssertEqual(probeCount.value, 2, "ヘッダ無効を観測したら開き直す")
        XCTAssertEqual(waitCount.value, 1, "開き直す前に 1 度だけ待つ")
        XCTAssertEqual(result.processingState, .active)
    }

    // どのキューに乗せるかが結果を分ける。塞いだキューへ乗せれば届かず、別のキューへ乗せれば届く。
    func testDriverAvailabilityConfirmationArrivesOnlyWhenKeptOffTheBlockedQueue() {
        let audioWorld = AudioWorld(queue: DispatchQueue(label: "AudioActivationCoordinatorTests.blocked"))
        // このキューを占有し続ける仕事を積む (塞がった状態の再現)。
        let releaseBlockedQueue = DispatchSemaphore(value: 0)
        audioWorld.submitUncoalesced { _ in releaseBlockedQueue.wait() }
        defer { releaseBlockedQueue.signal() }

        let blockedConfirm = expectation(description: "塞がったキューでは確定が届かない")
        blockedConfirm.isInverted = true
        AppDelegate.confirmDriverProbeOffAudioWorld(
            probeQueue: audioWorld.queue, probe: { .versionsUnreadable(.versionMismatch) }
        ) { _ in blockedConfirm.fulfill() }
        wait(for: [blockedConfirm], timeout: 0.5)

        let offQueueConfirm = expectation(description: "別のキューなら確定が届く")
        var received: DriverProbe?
        AppDelegate.confirmDriverProbeOffAudioWorld(
            probeQueue: DispatchQueue(label: "AudioActivationCoordinatorTests.probe"),
            probe: { .versionsUnreadable(.versionMismatch) }
        ) { probe in
            received = probe
            offQueueConfirm.fulfill()
        }
        wait(for: [offQueueConfirm], timeout: 2)
        XCTAssertEqual(received?.availability, .versionMismatch)
    }

    // 可用性の確定は組み立てを経由せず、共有メモリを開く結果だけから導かれる。
    func testProbeDriverDerivesFromOpenResultWithoutAssembling() {
        let engine = MockActivatableAudioEngine()
        let (coordinator, lifecycle) = makeCoordinator(
            directory: makeDirectory(), engine: engine, openSharedMemory: { .failure(.fileNotFound) }
        )

        XCTAssertEqual(coordinator.probeDriver().availability, .notFound)
        XCTAssertNil(lifecycle.resolvedDeviceID, "可視化しない")
        XCTAssertTrue(engine.assembleCalls.isEmpty, "組み立てない")
    }

    // 可用性の確定もヘッダ無効を再試行する (ドライバが初期化の間ヘッダの識別値を無効にする窓を跨ぐ)。
    func testProbeDriverRetriesWhileHeaderInvalid() {
        let probeCount = Recorded<Int>(0)
        let waitCount = Recorded<Int>(0)
        let (coordinator, _) = makeCoordinator(
            directory: makeDirectory(), engine: MockActivatableAudioEngine(),
            openSharedMemory: { [tempURLs] in
                let attempt = probeCount.update { $0 += 1; return $0 }
                return attempt < 2 ? .failure(.headerInvalid) : Self.openValidSharedRingReader(registeringInto: tempURLs)
            },
            waitBeforeRetry: { waitCount.update { $0 += 1 } }
        )

        XCTAssertEqual(coordinator.probeDriver().availability, .ok)
        XCTAssertEqual(probeCount.value, 2, "ヘッダ無効を観測したら開き直す")
        XCTAssertEqual(waitCount.value, 1, "開き直す前に 1 度だけ待つ")
    }

    // 再開経路は再試行しない (繰り返し通るため待ち時間が積み上がる)。
    func testResumeDoesNotRetryHeaderInvalid() {
        for trigger: ResumeTrigger in [.userSelection, .automatic] {
            let directory = makeDirectory()
            directory.currentDefaultOutputID = speakerID
            let engine = MockActivatableAudioEngine()
            engine.processingState = .suspended(.routeUnavailable)
            let probeCount = Recorded<Int>(0)
            let (coordinator, _) = makeCoordinator(
                directory: directory, engine: engine,
                openSharedMemory: {
                    probeCount.update { $0 += 1 }
                    return .failure(.headerInvalid)
                }
            )
            let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)

            let result = coordinator.resume(outputDevice: target, trigger: trigger, testToken)

            XCTAssertEqual(probeCount.value, 1, "\(trigger)")
            XCTAssertEqual(result.processingState, .suspended(.routeUnavailable), "\(trigger)")
        }
    }

    // MARK: - ドライバデバイスの音量・消音の取り込み

    /// 渡された値をそのまま反映する。CoreAudio に触れないため直接駆動できる。
    func testApplyDriverVolumeAndMuteReflectsTheGivenValues() {
        let engine = AudioEngine()
        XCTAssertEqual(engine.outputVolume, 1, "前提: 初期値")
        XCTAssertFalse(engine.outputMuted, "前提: 初期値")

        engine.applyDriverVolumeAndMute(volume: 0.25, muted: true, testToken)
        XCTAssertEqual(engine.outputVolume, 0.25)
        XCTAssertTrue(engine.outputMuted)

        // 片方だけ変わる回も反映される。
        engine.applyDriverVolumeAndMute(volume: 0.25, muted: false, testToken)
        XCTAssertEqual(engine.outputVolume, 0.25)
        XCTAssertFalse(engine.outputMuted)
    }

    func testDriverVolumeIsReadBackFromTheDeviceRatherThanTheCache() {
        let deviceIO = MockDeviceVolumeIO()
        let driverDeviceID = AudioDeviceID(91001)
        deviceIO.volumeCapabilities[driverDeviceID] = DevicePropertyCapability(exists: true, settable: true)
        deviceIO.muteCapabilities[driverDeviceID] = DevicePropertyCapability(exists: true, settable: true)
        deviceIO.volumes[driverDeviceID] = 0.25
        deviceIO.mutes[driverDeviceID] = true

        let engine = AudioEngine(volumeDeviceIO: deviceIO)
        engine.updateDriverDeviceID(driverDeviceID, testToken)
        XCTAssertEqual(engine.outputVolume, 1, "前提: 未読の間の想定値")

        let driver = engine.refreshDriverVolumeAndMute(testToken)

        XCTAssertEqual(driver.volume, 0.25)
        XCTAssertTrue(driver.muted)
        XCTAssertEqual(engine.outputVolume, 0.25, "保持値も実値へ揃う")
        XCTAssertTrue(engine.outputMuted)
    }

    func testAdoptionWritesRealDeviceValueBackToTheDriverAfterDriverReset() {
        let deviceIO = MockDeviceVolumeIO()
        let driverDeviceID = AudioDeviceID(93001)
        let outputDeviceID = AudioDeviceID(93002)
        for id in [driverDeviceID, outputDeviceID] {
            deviceIO.volumeCapabilities[id] = DevicePropertyCapability(exists: true, settable: true)
            deviceIO.muteCapabilities[id] = DevicePropertyCapability(exists: true, settable: true)
        }
        deviceIO.volumes[driverDeviceID] = 1
        deviceIO.mutes[driverDeviceID] = false
        deviceIO.volumes[outputDeviceID] = 0.33
        deviceIO.mutes[outputDeviceID] = true

        let engine = AudioEngine(volumeDeviceIO: deviceIO)
        engine.applyDriverVolumeAndMute(volume: 0.33, muted: true, testToken)
        engine.updateDriverDeviceID(driverDeviceID, testToken)
        XCTAssertEqual(engine.outputVolume, 0.33, "前提: 保持値は再起動前の位置")

        let driver = engine.refreshDriverVolumeAndMute(testToken)
        engine.outputVolumeBridge.rebindWithAdoption(
            outputUID: "output-uid", outputDeviceID: outputDeviceID,
            driverVolume: driver.volume, driverMuted: driver.muted, testToken
        )

        XCTAssertEqual(deviceIO.volumes[driverDeviceID], 0.33, "実デバイスの値がドライバへ書き戻される")
        XCTAssertEqual(deviceIO.mutes[driverDeviceID], true)
        XCTAssertEqual(deviceIO.volumes[outputDeviceID], 0.33, "実デバイスは既定値で上書きされない")
        XCTAssertEqual(deviceIO.mutes[outputDeviceID], true)
        XCTAssertEqual(engine.outputVolume, 0.33, "保持値も書き戻した値へ揃う")
        XCTAssertTrue(engine.outputMuted)
    }

    func testDriverVolumeReadKeepsPreviousValueWhenUnreadable() {
        let deviceIO = MockDeviceVolumeIO()
        let engine = AudioEngine(volumeDeviceIO: deviceIO)
        engine.applyDriverVolumeAndMute(volume: 0.4, muted: false, testToken)
        engine.updateDriverDeviceID(AudioDeviceID(91002), testToken)

        let driver = engine.refreshDriverVolumeAndMute(testToken)

        XCTAssertEqual(driver.volume, 0.4, "読めない回は直前の値を保つ")
        XCTAssertFalse(driver.muted)
    }

    func testOutputGainFollowsVolumeAndMuteInAppMode() {
        let deviceIO = MockDeviceVolumeIO()
        let deviceID = AudioDeviceID(90001)
        let engine = AudioEngine(volumeDeviceIO: deviceIO)
        engine.outputVolumeBridge.rebind(outputUID: "app-mode-uid", outputDeviceID: deviceID, driverVolume: 1, driverMuted: false, testToken)
        XCTAssertEqual(engine.outputVolumeBridge.volumeMode, .app, "前提: プロパティ無しのデバイス")

        engine.applyDriverVolumeAndMute(volume: 0.25, muted: false, testToken)
        XCTAssertEqual(engine.outputGain, effectiveOutputGain(volume: 0.25, muted: false))
        XCTAssertNotEqual(engine.outputGain, 1, "前提: 音量を下げた回はユニティから外れること")

        // 消音は音量に優先する。
        engine.applyDriverVolumeAndMute(volume: 0.25, muted: true, testToken)
        XCTAssertEqual(engine.outputGain, 0)

        // 音量を戻せば実効ゲインも戻る (保持したまま取り残されない)。
        engine.applyDriverVolumeAndMute(volume: 1, muted: false, testToken)
        XCTAssertEqual(engine.outputGain, effectiveOutputGain(volume: 1, muted: false))
    }

    func testOutputGainStaysUnityInDeviceModeAndRealDeviceReceivesTheValue() {
        let deviceIO = MockDeviceVolumeIO()
        let deviceID = AudioDeviceID(90002)
        deviceIO.volumeCapabilities[deviceID] = DevicePropertyCapability(exists: true, settable: true)
        deviceIO.volumes[deviceID] = 1
        let engine = AudioEngine(volumeDeviceIO: deviceIO)
        engine.outputVolumeBridge.rebind(outputUID: "device-mode-uid", outputDeviceID: deviceID, driverVolume: 1, driverMuted: false, testToken)
        XCTAssertEqual(engine.outputVolumeBridge.volumeMode, .device, "前提")

        engine.applyDriverVolumeAndMute(volume: 0.25, muted: false, testToken)

        XCTAssertEqual(engine.outputGain, 1)
        XCTAssertEqual(deviceIO.volumes[deviceID], 0.25, "実デバイスへ中継されること")
    }

    /// 通知の入口は、問い合わせに失敗した回に直前の値を保つ。
    func testDriverDevicePropertyNotificationKeepsThePreviousValuesWhenTheQueryFails() {
        let engine = AudioEngine()
        engine.applyDriverVolumeAndMute(volume: 0.5, muted: true, testToken)

        engine.handleDriverDevicePropertyNotification(deviceID: AudioDeviceID(0), testToken)

        XCTAssertEqual(engine.outputVolume, 0.5, "取得に失敗した回は直前の値を保つ")
        XCTAssertTrue(engine.outputMuted)
    }

    func testExcludedFromOutputPickerWhenUIDMatches() {
        // 自ドライバ自身を出力先に選ぶと、EQ 出力が自分自身の取り込み口へ回り込むため除外される。
        XCTAssertTrue(isExcludedFromOutputPicker(uid: "driver-uid", driverDeviceUID: "driver-uid", containsDriver: false, isAirPlay: false))
    }

    func testExcludedFromOutputPickerWhenContainsDriver() {
        // 専用ドライバを含む Aggregate/Multi-Output デバイスも同じリスクを持つため除外される。
        XCTAssertTrue(isExcludedFromOutputPicker(uid: "multi-output-uid", driverDeviceUID: "driver-uid", containsDriver: true, isAirPlay: false))
    }

    // MARK: - outputExceedsFullScale

    func testOutputExceedsFullScaleComparesAgainstFullScale() {
        XCTAssertFalse(outputExceedsFullScale(peakAmplitude: 0.99))
        XCTAssertFalse(outputExceedsFullScale(peakAmplitude: 1), "ちょうどフルスケールは超過ではない")
        XCTAssertTrue(outputExceedsFullScale(peakAmplitude: 1.2))
    }

    func testExcludedFromOutputPickerWhenAirPlay() {
        // AirPlay は出力先に選ぶとデバイス自体が消え、あるべき出力先を保持できないため除外される。
        XCTAssertTrue(isExcludedFromOutputPicker(uid: "airplay-uid", driverDeviceUID: "driver-uid", containsDriver: false, isAirPlay: true))
    }

    func testNotExcludedFromOutputPickerWhenUIDDiffersAndNotContainsDriver() {
        XCTAssertFalse(isExcludedFromOutputPicker(uid: "vg280k-uid", driverDeviceUID: "driver-uid", containsDriver: false, isAirPlay: false))
    }

    func testNotExcludedFromOutputPickerWhenNoDriverUIDGiven() {
        XCTAssertFalse(isExcludedFromOutputPicker(uid: "vg280k-uid", driverDeviceUID: nil, containsDriver: false, isAirPlay: false))
    }
}

// MARK: - 音量経路の純粋関数 (AudioEnginePolicy)

final class OutputVolumeRoutingPolicyTests: XCTestCase {
    func testVolumeControlModeFromCapability() {
        XCTAssertEqual(volumeControlModeFromCapability(exists: true, settable: true), .device)
        XCTAssertEqual(volumeControlModeFromCapability(exists: true, settable: false), .app, "存在しても settable でなければアプリ側")
        XCTAssertEqual(volumeControlModeFromCapability(exists: false, settable: false), .app)
    }

    func testWriteReadbackJudgmentBranches() {
        XCTAssertEqual(
            writeReadbackJudgment(writeSucceeded: false, written: Float(0.5), readback: nil), .downgrade,
            "書き込みがエラーを返した"
        )
        XCTAssertEqual(
            writeReadbackJudgment(writeSucceeded: true, written: Float(0.5), readback: nil), .downgrade,
            "書き込みは通ったが読み戻せない"
        )
        XCTAssertEqual(
            writeReadbackJudgment(writeSucceeded: true, written: Float(0.5), readback: 0.5), .normal,
            "読み戻し値が書いた値と一致"
        )
        XCTAssertEqual(
            writeReadbackJudgment(writeSucceeded: true, written: Float(0.5), readback: 0.5625), .rounded(0.5625),
            "グリッドへ吸着した値はそのデバイスの正として受け入れる"
        )
    }

    func testWriteReadbackJudgmentAcceptsValueRoundedBackToItsOriginalPosition() {
        XCTAssertEqual(
            writeReadbackJudgment(writeSucceeded: true, written: Float(0.375), readback: 0.37500003),
            .rounded(0.37500003)
        )
    }

    func testMirrorWriteNeededIsIdempotentCompare() {
        XCTAssertFalse(mirrorWriteNeeded(current: Float(0.5), target: 0.5))
        XCTAssertTrue(mirrorWriteNeeded(current: Float(0.5), target: 0.6))
    }

    func testAppModeVolumeAdoptionPrefersRememberedValue() {
        XCTAssertEqual(appModeVolumeAdoption(remembered: 0.4, isFirstBindOfSession: true, driverCurrentScalar: 0.9), 0.4)
        XCTAssertEqual(appModeVolumeAdoption(remembered: 0.4, isFirstBindOfSession: false, driverCurrentScalar: 0.9), 0.4)
    }

    func testAppModeVolumeAdoptionWithoutRememberedValue() {
        XCTAssertEqual(
            appModeVolumeAdoption(remembered: nil, isFirstBindOfSession: true, driverCurrentScalar: 0.33), 0.33,
            "セッション最初の束ねはドライバの現在スカラを引き継ぐ"
        )
        XCTAssertEqual(
            appModeVolumeAdoption(remembered: nil, isFirstBindOfSession: false, driverCurrentScalar: 0.33), 1,
            "2 台目以降はそのデバイスの素の状態 (ユニティ) から始まる"
        )
    }

    func testOutputDeviceRebindActionsOnFirstBind() {
        let actions = outputDeviceRebindActions(boundUID: nil, listenerDeviceID: nil, resolvedUID: "a", resolvedDeviceID: 100)
        XCTAssertEqual(actions, OutputDeviceRebindActions(unregisterListener: false, registerListener: true, adopt: true))
    }

    func testOutputDeviceRebindActionsWhenUIDUnchangedButListenerIDChanges() {
        // ドライバ再解決でホスト再起動を経ても、実出力デバイスの UID 自体は不変な局面。
        let actions = outputDeviceRebindActions(boundUID: "a", listenerDeviceID: 100, resolvedUID: "a", resolvedDeviceID: 200)
        XCTAssertEqual(
            actions, OutputDeviceRebindActions(unregisterListener: true, registerListener: true, adopt: false),
            "UID が同じなら能力の再判定・採用は行わず、リスナー登録先の張替えだけ"
        )
    }

    func testOutputDeviceRebindActionsWhenUIDUnchangedAndListenerIDUnchanged() {
        let actions = outputDeviceRebindActions(boundUID: "a", listenerDeviceID: 100, resolvedUID: "a", resolvedDeviceID: 100)
        XCTAssertEqual(actions, OutputDeviceRebindActions(unregisterListener: false, registerListener: false, adopt: false))
    }

    func testOutputDeviceRebindActionsWhenUIDChanges() {
        let actions = outputDeviceRebindActions(boundUID: "a", listenerDeviceID: 100, resolvedUID: "b", resolvedDeviceID: 200)
        XCTAssertEqual(actions, OutputDeviceRebindActions(unregisterListener: true, registerListener: true, adopt: true))
    }

    func testOutputDeviceRebindActionsWhenResolvedIsUnavailable() {
        let actions = outputDeviceRebindActions(boundUID: "a", listenerDeviceID: 100, resolvedUID: nil, resolvedDeviceID: nil)
        XCTAssertEqual(actions, OutputDeviceRebindActions(unregisterListener: true, registerListener: false, adopt: false))
    }

    func testBridgeOutputGainTreatsDeviceModeComponentsAsUnity() {
        XCTAssertEqual(bridgeOutputGain(volumeMode: .device, volume: 0.1, muteMode: .device, muted: true), 1, "デバイスが担うなら実デバイスが持つため 1")
        XCTAssertEqual(
            bridgeOutputGain(volumeMode: .app, volume: 0.5, muteMode: .device, muted: true),
            effectiveOutputGain(volume: 0.5, muted: false)
        )
        XCTAssertEqual(
            bridgeOutputGain(volumeMode: .device, volume: 0.5, muteMode: .app, muted: true),
            effectiveOutputGain(volume: 1, muted: true)
        )
    }
}

// MARK: - OutputVolumeBridge

@MainActor
final class OutputVolumeBridgeTests: XCTestCase {
    private let deviceModeUID = "device-mode-uid"
    private let deviceModeDeviceID = AudioDeviceID(70001)

    private func makeDeviceModeIO(volume: Float = 1, muted: Bool = false) -> MockDeviceVolumeIO {
        let io = MockDeviceVolumeIO()
        io.volumeCapabilities[deviceModeDeviceID] = DevicePropertyCapability(exists: true, settable: true)
        io.muteCapabilities[deviceModeDeviceID] = DevicePropertyCapability(exists: true, settable: true)
        io.volumes[deviceModeDeviceID] = volume
        io.mutes[deviceModeDeviceID] = muted
        return io
    }

    // MARK: 採用 (実デバイス → ドライバ)

    func testAdoptOnFirstBindReadsRealDeviceAndWritesDriverWhenDifferent() {
        let deviceIO = makeDeviceModeIO(volume: 0.4)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        let adopted = bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        XCTAssertTrue(adopted)
        XCTAssertEqual(bridge.volumeMode, .device)
        XCTAssertEqual(bridge.appVolume, 1, "デバイスが担うならアプリ側のゲインはユニティ")
        XCTAssertEqual(driverWrites.value, [0.4])
    }

    func testAdoptSkipsDriverWriteWhenAlreadyEqual() {
        let deviceIO = makeDeviceModeIO(volume: 1)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        XCTAssertTrue(driverWrites.value.isEmpty, "冪等比較により一致していれば書かない")
    }

    func testSameUIDRebindSkipsAdoptionAndOnlyRebindsListener() {
        let deviceIO = makeDeviceModeIO(volume: 0.4)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.4, driverMuted: false, testToken)

        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }
        let newListenerID = AudioDeviceID(70099)
        deviceIO.volumeCapabilities[newListenerID] = DevicePropertyCapability(exists: true, settable: true)
        deviceIO.volumes[newListenerID] = 0.9 // 採用が誤って再度走れば検出できるよう、あえて違う値にする。

        let adopted = bridge.rebind(outputUID: deviceModeUID, outputDeviceID: newListenerID, driverVolume: 0.4, driverMuted: false, testToken)

        XCTAssertFalse(adopted, "束ね先の UID が不変なら採用は起きない")
        XCTAssertTrue(driverWrites.value.isEmpty)
        XCTAssertEqual(deviceIO.removedListeners, [deviceModeDeviceID])
        XCTAssertEqual(deviceIO.addedListeners, [deviceModeDeviceID, newListenerID])
        XCTAssertTrue(bridge.established, "リスナー登録先の張替えのみで確立状態は維持される")
    }

    // MARK: ドライバのリスナー登録に伴う再採用 (前方ミラーへ流さない)

    func testRebindWithAdoptionWritesDriverButNeverWritesRealDevice() {
        let deviceIO = makeDeviceModeIO(volume: 0.33)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.33, driverMuted: false, testToken)

        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        // ドライバがプロセス再起動で既定値 1.0 に戻った状態を模す。
        let readopted = bridge.rebindWithAdoption(
            outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken
        )

        XCTAssertTrue(readopted)
        XCTAssertEqual(driverWrites.value, [0.33], "実デバイスの値がドライバへ写ること")
        XCTAssertEqual(deviceIO.volumes[deviceModeDeviceID], 0.33, "実デバイスの値は既定値 1.0 で上書きされないこと")
    }

    func testRebindWithAdoptionUsesFreshlyResolvedDeviceID() {
        let deviceIO = makeDeviceModeIO(volume: 0.33)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.33, driverMuted: false, testToken)

        // 実出力デバイスの ID だけが振り直された状態を模す (UID は不変)。
        let renumberedID = AudioDeviceID(70055)
        deviceIO.volumeCapabilities[renumberedID] = DevicePropertyCapability(exists: true, settable: true)
        deviceIO.muteCapabilities[renumberedID] = DevicePropertyCapability(exists: true, settable: true)
        deviceIO.volumes[renumberedID] = 0.33
        deviceIO.mutes[renumberedID] = false
        deviceIO.volumeCapabilities[deviceModeDeviceID] = DevicePropertyCapability(exists: false, settable: false)
        deviceIO.muteCapabilities[deviceModeDeviceID] = DevicePropertyCapability(exists: false, settable: false)

        bridge.rebindWithAdoption(
            outputUID: deviceModeUID, outputDeviceID: renumberedID, driverVolume: 1, driverMuted: false, testToken
        )

        XCTAssertEqual(bridge.volumeMode, .device, "振り直された ID で採用し直すためデバイスモードのまま")
        XCTAssertEqual(bridge.boundDeviceID, renumberedID)
        XCTAssertEqual(deviceIO.addedListeners, [deviceModeDeviceID, renumberedID], "リスナーも新しい ID へ張り替える")
    }

    // MARK: 前方ミラー (ドライバ → 実デバイス)

    func testForwardMirrorIgnoredBeforeEstablished() {
        let deviceIO = makeDeviceModeIO(volume: 1)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        XCTAssertFalse(bridge.established, "前提: まだ束ねていない")

        bridge.handleDriverVolumeNotification(volume: 0.2, muted: false, testToken)

        XCTAssertEqual(deviceIO.volumes[deviceModeDeviceID], 1, "確立前の通知は実デバイスへ影響しない")
    }

    func testForwardMirrorWritesRealDeviceOnExactReadback() {
        let deviceIO = makeDeviceModeIO(volume: 0.3)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.3, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 0.7, muted: false, testToken)

        XCTAssertEqual(deviceIO.volumes[deviceModeDeviceID], 0.7)
        XCTAssertEqual(bridge.volumeMode, .device)
        XCTAssertEqual(bridge.appVolume, 1)
    }

    func testForwardMirrorSkipsWriteWhenRealDeviceAlreadyAtTargetValue() {
        // 後方ミラーが直後にドライバへ書いた値と同じ通知が戻ってくる往復を想定する。
        let deviceIO = makeDeviceModeIO(volume: 0.7)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.7, driverMuted: false, testToken)
        deviceIO.volumeWriteShouldSucceed = false // 書き込みが起きたら即座に検出できるようにする。

        bridge.handleDriverVolumeNotification(volume: 0.7, muted: false, testToken)

        XCTAssertEqual(deviceIO.volumes[deviceModeDeviceID], 0.7, "冪等比較により往復が止まること")
        XCTAssertEqual(bridge.volumeMode, .device, "書き込みを試みていなければ降格もしない")
    }

    func testForwardMirrorAcceptsRoundingAndMirrorsBackToDriver() {
        let deviceIO = makeDeviceModeIO(volume: 0.3)
        deviceIO.volumeWriteRounding = { _ in 0.6875 } // 粗いグリッドへ吸着するデバイスを模す。
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.3, driverMuted: false, testToken)
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        bridge.handleDriverVolumeNotification(volume: 0.7, muted: false, testToken)

        XCTAssertEqual(driverWrites.value, [0.6875], "丸めた値を読み戻してドライバへ写す")
        XCTAssertEqual(bridge.volumeMode, .device, "丸めは許容であり降格ではない")
    }

    func testForwardMirrorKeepsDeviceModeWhenValueRoundsBackToItsOriginalPosition() {
        let deviceIO = makeDeviceModeIO(volume: 0.3)
        deviceIO.volumeWriteIsNoOp = true // 書いた値が書く前の位置へ吸着するデバイスを模す。
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.3, driverMuted: false, testToken)
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        bridge.handleDriverVolumeNotification(volume: 0.7, muted: false, testToken)

        XCTAssertEqual(bridge.volumeMode, .device)
        XCTAssertFalse(bridge.volumeDowngraded)
        XCTAssertEqual(bridge.appVolume, 1, "デバイスが担当している間はアプリ側で二重に減衰させない")
        XCTAssertEqual(driverWrites.value, [0.3], "デバイスが持つ値をドライバへ写す")
    }

    func testForwardMirrorDowngradesWhenReadbackUnavailable() {
        let deviceIO = makeDeviceModeIO(volume: 0.3)
        deviceIO.volumeWriteClearsReadback = true // 書き込みは通るが以後読み取れないデバイスを模す。
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.3, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 0.7, muted: false, testToken)

        XCTAssertEqual(bridge.volumeMode, .app)
        XCTAssertTrue(bridge.volumeDowngraded)
        XCTAssertEqual(bridge.appVolume, 0.7, "降格後はアプリ側でドライバの通知値をそのまま使う")
    }

    func testForwardMirrorDowngradesWhenWriteErrors() {
        let deviceIO = makeDeviceModeIO(volume: 0.3)
        deviceIO.volumeWriteShouldSucceed = false
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.3, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 0.7, muted: false, testToken)

        XCTAssertEqual(bridge.volumeMode, .app)
        XCTAssertTrue(bridge.volumeDowngraded)
    }

    // MARK: 後方ミラー (実デバイス → ドライバ)

    func testBackwardMirrorWritesDriverWhenRealDeviceChangedExternally() {
        let deviceIO = makeDeviceModeIO(volume: 0.2)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.2, driverMuted: false, testToken)
        deviceIO.volumes[deviceModeDeviceID] = 0.9 // Audio MIDI 設定など外部からの変更を模す。
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        bridge.handleOutputDeviceNotification(deviceID: deviceModeDeviceID, driverVolume: 0.2, driverMuted: false, testToken)

        XCTAssertEqual(driverWrites.value, [0.9])
    }

    func testBackwardMirrorSkipsWriteWhenAlreadyEqual() {
        let deviceIO = makeDeviceModeIO(volume: 0.2)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.2, driverMuted: false, testToken)
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        bridge.handleOutputDeviceNotification(deviceID: deviceModeDeviceID, driverVolume: 0.2, driverMuted: false, testToken)

        XCTAssertTrue(driverWrites.value.isEmpty)
    }

    func testBackwardMirrorIgnoresNotificationFromStaleDeviceID() {
        let deviceIO = makeDeviceModeIO(volume: 0.2)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.2, driverMuted: false, testToken)
        deviceIO.volumes[deviceModeDeviceID] = 0.9
        let driverWrites = Recorded<[Float]>([])
        bridge.driverVolumeWriteRequested = { volume, _ in driverWrites.update { $0.append(volume) } }

        bridge.handleOutputDeviceNotification(deviceID: AudioDeviceID(999999), driverVolume: 0.2, driverMuted: false, testToken)

        XCTAssertTrue(driverWrites.value.isEmpty, "束ね直しで解除済みの旧登録からの遅延通知を無視する")
    }

    // MARK: アプリ側が担うときの音量記憶 (デバイス UID ごと)

    func testAppModeRemembersVolumePerUID() {
        let deviceIO = MockDeviceVolumeIO() // 能力を登録しない = 常にアプリ側が担う。
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)

        bridge.rebind(outputUID: "device-a", outputDeviceID: 1, driverVolume: 0.6, driverMuted: false, testToken)
        XCTAssertEqual(bridge.appVolume, 0.6, "セッション最初の束ねはドライバの現在スカラを引き継ぐ")

        bridge.rebind(outputUID: "device-b", outputDeviceID: 2, driverVolume: 0.6, driverMuted: false, testToken)
        XCTAssertEqual(bridge.appVolume, 1, "2 台目は素の状態 (ユニティ) から始まる")

        bridge.handleDriverVolumeNotification(volume: 0.25, muted: false, testToken)
        XCTAssertEqual(bridge.appVolume, 0.25)

        bridge.rebind(outputUID: "device-a", outputDeviceID: 1, driverVolume: 0.25, driverMuted: false, testToken)
        XCTAssertEqual(bridge.appVolume, 0.6, "device-a へ戻れば記憶していた値を採用する (device-b の操作で汚れない)")

        bridge.rebind(outputUID: "device-b", outputDeviceID: 2, driverVolume: 0.6, driverMuted: false, testToken)
        XCTAssertEqual(bridge.appVolume, 0.25, "device-b の記憶も別に保たれている")
    }

    // MARK: 機器が音量を担う経路

    // エンジンのゲインを直接単位にすると同値判定の記憶が残り、同じ機器へ戻ったときにゲインの押し出しが省かれる。
    func testReleasingForADeviceCarriedRouteGoesNeutralAndTheSameDeviceGetsItsGainBack() {
        let deviceIO = MockDeviceVolumeIO() // 能力を登録しない = アプリのゲイン段が担う。
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        let gains = Recorded<[Float]>([])
        bridge.appGainDidChange = { gain in gains.update { $0.append(gain) } }
        bridge.rebind(outputUID: "device-a", outputDeviceID: 1, driverVolume: 0.5, driverMuted: false, testToken)
        let appGain = effectiveOutputGain(volume: 0.5, muted: false)
        XCTAssertEqual(gains.value, [appGain], "前提: アプリのゲイン段が音量を担っている")

        bridge.releaseForDeviceCarriedRoute(testToken)
        XCTAssertEqual(gains.value.last, effectiveOutputGain(volume: 1, muted: false), "単位ゲインを押し出す")
        XCTAssertNil(bridge.routeObservation(testToken), "束ねは無い")

        bridge.rebind(outputUID: "device-a", outputDeviceID: 1, driverVolume: 0.5, driverMuted: false, testToken)
        XCTAssertEqual(gains.value.last, appGain, "戻ると元のゲインを押し出す")
        XCTAssertEqual(gains.value.count, 3)
    }

    // MARK: 解除

    func testUnbindRemovesListenerAndClearsEstablishedState() {
        let deviceIO = makeDeviceModeIO(volume: 0.4)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.4, driverMuted: false, testToken)

        bridge.unbind(testToken)

        XCTAssertFalse(bridge.established)
        XCTAssertNil(bridge.boundUID)
        XCTAssertEqual(deviceIO.removedListeners, [deviceModeDeviceID])
    }

    func testUnbindClearsRouteObservation() {
        let deviceIO = makeDeviceModeIO(volume: 0.4)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 0.4, driverMuted: false, testToken)
        XCTAssertEqual(bridge.routeObservation(testToken)?.volumeMode, .device, "前提")

        bridge.unbind(testToken)

        XCTAssertNil(bridge.routeObservation(testToken), "束ねが無い間はモードを現在の構成として配らない")
        XCTAssertEqual(bridge.volumeMode, .app)
        XCTAssertFalse(bridge.volumeDowngraded)
    }

    // MARK: 消音

    func testAdoptReadsRealDeviceMuteAndWritesDriverWhenDifferent() {
        let deviceIO = makeDeviceModeIO(muted: true)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        let driverWrites = Recorded<[Bool]>([])
        bridge.driverMuteWriteRequested = { muted, _ in driverWrites.update { $0.append(muted) } }

        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        XCTAssertEqual(bridge.muteMode, .device)
        XCTAssertFalse(bridge.appMuted, "デバイスが担うならアプリ側で消音しない")
        XCTAssertEqual(driverWrites.value, [true])
    }

    func testAdoptFallsBackToAppMuteWhenDeviceHasNoMute() {
        let deviceIO = makeDeviceModeIO()
        deviceIO.muteCapabilities[deviceModeDeviceID] = DevicePropertyCapability(exists: false, settable: false)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)

        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: true, testToken)

        XCTAssertEqual(bridge.muteMode, .app)
        XCTAssertFalse(bridge.muteDowngraded, "能力が無いだけなら降格ではない")
        XCTAssertTrue(bridge.appMuted)
    }

    func testForwardMirrorMuteWritesRealDevice() {
        let deviceIO = makeDeviceModeIO(muted: false)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 1, muted: true, testToken)

        XCTAssertEqual(deviceIO.mutes[deviceModeDeviceID], true)
        XCTAssertEqual(bridge.muteMode, .device)
        XCTAssertFalse(bridge.appMuted)
    }

    func testForwardMirrorMuteDowngradesWhenWriteFails() {
        let deviceIO = makeDeviceModeIO(muted: false)
        deviceIO.muteWriteShouldSucceed = false
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 1, muted: true, testToken)

        XCTAssertEqual(bridge.muteMode, .app)
        XCTAssertTrue(bridge.muteDowngraded)
        XCTAssertTrue(bridge.appMuted, "降格したぶんはアプリ側で消音する")
    }

    func testForwardMirrorMuteDowngradesWhenReadbackUnavailable() {
        let deviceIO = makeDeviceModeIO(muted: false)
        deviceIO.muteWriteClearsReadback = true
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 1, muted: true, testToken)

        XCTAssertEqual(bridge.muteMode, .app)
        XCTAssertTrue(bridge.muteDowngraded)
        XCTAssertTrue(bridge.appMuted)
    }

    func testForwardMirrorMuteDowngradesWhenDeviceDoesNotFollow() {
        let deviceIO = makeDeviceModeIO(muted: false)
        deviceIO.muteWriteIsNoOp = true
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        bridge.handleDriverVolumeNotification(volume: 1, muted: true, testToken)

        XCTAssertEqual(bridge.muteMode, .app)
        XCTAssertTrue(bridge.muteDowngraded)
        XCTAssertTrue(bridge.appMuted)
    }

    func testBackwardMirrorMuteWritesDriver() {
        let deviceIO = makeDeviceModeIO(muted: false)
        let bridge = OutputVolumeBridge(audioWorld: makeTestAudioWorld(), deviceIO: deviceIO)
        bridge.rebind(outputUID: deviceModeUID, outputDeviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        let driverWrites = Recorded<[Bool]>([])
        bridge.driverMuteWriteRequested = { muted, _ in driverWrites.update { $0.append(muted) } }
        deviceIO.mutes[deviceModeDeviceID] = true

        bridge.handleOutputDeviceNotification(deviceID: deviceModeDeviceID, driverVolume: 1, driverMuted: false, testToken)

        XCTAssertEqual(driverWrites.value, [true])
    }
}

// MARK: - ドライバの申告遅延

extension AudioEngineTests {
    private static let latencyDriverID: AudioDeviceID = 424_242
    private static let neutralFrames = DriverConfig.presentationLatencyNeutralFrames

    private struct LatencyFixture {
        let engine: AudioEngine
        let io: MockDriverPresentationLatencyIO
        let reader: SharedRingReader
        let url: URL
        let device: (deviceID: AudioDeviceID, uid: String)
        var outputDevice: ResolvedOutputDevice { ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID) }
    }

    private func expectedDriverLatency(
        outputDeclared: Int?, avSyncOffset: Int = DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault
    ) -> Int {
        DriverPresentationLatencyPolicy.totalFrames(
            outputDeclaredFrames: outputDeclared, avSyncOffsetMilliseconds: avSyncOffset,
            appliedSampleRate: AudioConfig.appliedSampleRate
        )
    }

    private func makeLatencyFixture(
        declared: [Int?] = [4000], ownerIsSelf: Bool = true, initialDriverValue: Int? = DriverConfig.presentationLatencyNeutralFrames,
        sampleRate: Double = AudioConfig.baseSampleRate, assemble: Bool = true
    ) throws -> LatencyFixture {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let io = MockDriverPresentationLatencyIO()
        io.values[Self.latencyDriverID] = initialDriverValue
        let engine = makeSilencedEngine(driverPresentationLatencyIO: io)
        engine.readDeclaredPresentationLatencyFrames = PresentationDelayStub(declared + [Int?](repeating: 0, count: 4)).next
        let owner = ownerIsSelf ? SharedRingReader.selfProcessID : SharedRingReader.selfProcessID &+ 1
        let url = makeMinimalSharedRingReaderFixture(sampleRate: sampleRate, ownerProcessID: owner)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let fixture = LatencyFixture(engine: engine, io: io, reader: reader, url: url, device: device)
        if assemble {
            XCTAssertTrue(engine.assemble(
                outputDevice: fixture.outputDevice, ringReader: reader, driverDeviceID: Self.latencyDriverID, testToken
            ), "前提: 実デバイスへの組み立てが成立すること")
        }
        return fixture
    }

    func testAssemblingWritesTheDeclarationBuiltFromItsPartsToTheDriverOnce() throws {
        let f = try makeLatencyFixture(declared: [4000])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let expected = expectedDriverLatency(outputDeclared: 4000)

        XCTAssertEqual(f.io.writtenFrames, [expected])
        XCTAssertEqual(f.io.writes.map(\.id), [Self.latencyDriverID])
        XCTAssertEqual(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames, expected, "診断には読み直した値が出る")
    }

    func testAnUnreadableOutputDeclarationIsDeclaredAsZeroForThatTerm() throws {
        let f = try makeLatencyFixture(declared: [nil])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(f.io.writtenFrames, [expectedDriverLatency(outputDeclared: nil)])
    }

    func testNothingIsWrittenWhenTheDriverAlreadyHoldsTheIntendedValue() throws {
        let preset = try makeLatencyFixture(declared: [4000], assemble: false)
        let expected = expectedDriverLatency(outputDeclared: 4000)
        preset.io.values[Self.latencyDriverID] = expected

        XCTAssertTrue(preset.engine.assemble(
            outputDevice: preset.outputDevice, ringReader: preset.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { preset.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertTrue(preset.io.writes.isEmpty, "一致なら書かない")
        XCTAssertEqual(preset.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames, expected)
    }

    func testNothingIsWrittenWhenTheDriverValueCannotBeRead() throws {
        let f = try makeLatencyFixture(declared: [4000], assemble: false)
        f.io.readable = false

        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertTrue(f.io.writes.isEmpty, "読めない (旧ドライバ) なら書かない")
        XCTAssertNil(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames)
    }

    func testAFailedWriteLeavesTheDiagnosticsOnTheValueTheDriverStillHolds() throws {
        let f = try makeLatencyFixture(declared: [4000], assemble: false)
        f.io.writeShouldSucceed = false

        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(f.io.writtenFrames, [expectedDriverLatency(outputDeclared: 4000)], "前提: 書き込みを試みたこと")
        XCTAssertEqual(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames, Self.neutralFrames,
                       "書けなければ、診断はドライバが持ち続けている値を出す")
    }

    func testSwitchingTheOutputDeviceWritesTheNewDeclarationButTheSameUIDEarlyReturnDoesNot() throws {
        let f = try makeLatencyFixture(declared: [100, 200])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let first = expectedDriverLatency(outputDeclared: 100)
        let second = expectedDriverLatency(outputDeclared: 200)
        XCTAssertNotEqual(first, second, "前提: 値が変わる組")

        XCTAssertTrue(f.engine.switchOutputDevice(to: f.outputDevice, testToken))
        XCTAssertEqual(f.io.writtenFrames, [first], "遅延線を作り直さない早期 return では書かない")

        let other = ResolvedOutputDevice(uid: "forced-different-uid-for-driver-latency", deviceID: f.device.deviceID)
        XCTAssertTrue(f.engine.switchOutputDevice(to: other, testToken))
        XCTAssertEqual(f.io.writtenFrames, [first, second])
    }

    func testARateChangeWritesTheDeclarationAtTheNewRate() throws {
        let f = try makeLatencyFixture(declared: [100, 100], sampleRate: 48000)
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let initial = expectedDriverLatency(outputDeclared: 100)
        XCTAssertEqual(f.io.writtenFrames, [initial])

        setHeaderSampleRate(f.url, 44100)
        f.engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(AudioConfig.appliedSampleRate, 44100, "前提: レート変更が適用されている")
        XCTAssertEqual(f.io.writes.count, 2)
        XCTAssertEqual(f.io.writtenFrames.last, expectedDriverLatency(outputDeclared: 100))
        XCTAssertNotEqual(f.io.writtenFrames.last, initial, "出力先の申告値が同じでもレートだけで値が変わる")
    }

    func testSuspendingARunningOwnerReturnsTheDriverToNeutralExceptForLosingOwnership() throws {
        for cause in SuspensionCause.allCases {
            let f = try makeLatencyFixture(declared: [4000])
            let writesBefore = f.io.writes.count
            XCTAssertNotEqual(f.io.values[Self.latencyDriverID], Self.neutralFrames, "前提: 申告中")

            f.engine.suspend(cause: cause, testToken)

            if cause == .ownershipUnavailable {
                XCTAssertEqual(f.io.writes.count, writesBefore, "\(cause): 新しい所有者の申告を消さない")
                XCTAssertNotEqual(f.io.values[Self.latencyDriverID], Self.neutralFrames)
            } else {
                XCTAssertEqual(f.io.writtenFrames.last, Self.neutralFrames, "\(cause)")
                XCTAssertEqual(f.io.values[Self.latencyDriverID], Self.neutralFrames, "\(cause)")
            }
            XCTAssertNil(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames, "\(cause): 停止後は観測値を捨てる")
        }
    }

    func testSuspendingAnEngineThatNeverRanWritesNothing() {
        let io = MockDriverPresentationLatencyIO()
        io.values[Self.latencyDriverID] = 777
        let engine = makeSilencedEngine(driverPresentationLatencyIO: io)

        engine.suspend(cause: .applicationTermination, testToken)

        XCTAssertTrue(io.writes.isEmpty)
        XCTAssertEqual(io.values[Self.latencyDriverID], 777)
    }

    func testTheCapturePathWritesNeutralInsteadOfACalculatedValue() throws {
        let io = MockDriverPresentationLatencyIO()
        io.values[Self.latencyDriverID] = 5000
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let engine = makeSilencedEngine(driverPresentationLatencyIO: io)
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000, ownerProcessID: SharedRingReader.selfProcessID)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let capture = FakeCaptureSource(endpointUID: device.uid, endpointDeviceID: device.deviceID, sampleRate: 44100)

        XCTAssertTrue(engine.assembleAirPlay(capture: capture, ringReader: reader, driverDeviceID: Self.latencyDriverID, testToken))
        defer { engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(io.writtenFrames, [Self.neutralFrames], "計算値は書かず、前の値を中立へ戻す")

        io.values[Self.latencyDriverID] = 9
        engine.reassertDriverPresentationLatency(testToken)
        XCTAssertEqual(io.values[Self.latencyDriverID], 9, "取り込み経路では点検しない")
    }

    // MARK: 映像との同期補正 (ドライバの申告値)

    func testOffsetsAppliedBeforeAssembleAreDeclaredToTheDriverButNotAddedToTheDelay() throws {
        let f = try makeLatencyFixture(declared: [4000], assemble: false)
        f.engine.applyAVSyncOffsets([f.device.uid: 120], testToken)
        XCTAssertTrue(f.io.writes.isEmpty, "前提: 停止中は書かない")

        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(f.io.writtenFrames, [expectedDriverLatency(outputDeclared: 4000, avSyncOffset: 120)])
        XCTAssertEqual(f.engine.presentationDelay?.delayFrames, 4000, "遅延線は申告値のまま")
    }

    func testApplyingOffsetsWhileRunningRewritesOnlyTheDriverDeclaration() throws {
        let f = try makeLatencyFixture(declared: [4000])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let line = try XCTUnwrap(f.engine.presentationDelay)
        let base = expectedDriverLatency(outputDeclared: 4000)
        let plus = expectedDriverLatency(outputDeclared: 4000, avSyncOffset: 120)
        let minus = expectedDriverLatency(outputDeclared: 4000, avSyncOffset: -50)
        XCTAssertEqual(Set([base, plus, minus]).count, 3, "前提: 値が変わる組")
        XCTAssertEqual(f.io.writtenFrames, [base])

        f.engine.applyAVSyncOffsets([f.device.uid: 120], testToken)
        XCTAssertEqual(f.io.writtenFrames, [base, plus])
        f.engine.applyAVSyncOffsets([f.device.uid: -50], testToken)
        XCTAssertEqual(f.io.writtenFrames, [base, plus, minus])
        f.engine.applyAVSyncOffsets([:], testToken)
        XCTAssertEqual(f.io.writtenFrames, [base, plus, minus, base], "表が空なら補正なしの合計に戻る")

        XCTAssertTrue(f.engine.presentationDelay === line, "遅延線は作り直さない")
        XCTAssertEqual(line.delayFrames, 4000, "遅延線は申告値のまま")
    }

    func testAnUnchangedDeclarationDoesNotWriteAgain() throws {
        let f = try makeLatencyFixture(declared: [4000])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        f.engine.applyAVSyncOffsets([f.device.uid: 120], testToken)
        let writes = f.io.writes.count

        f.engine.applyAVSyncOffsets([f.device.uid: 120], testToken)
        XCTAssertEqual(f.io.writes.count, writes, "同じ表をもう一度送っても書かない")

        f.engine.applyAVSyncOffsets([f.device.uid: 120, "some-other-device": 200], testToken)
        XCTAssertEqual(f.io.writes.count, writes, "別の出力先の補正だけの変更は書かない")
    }

    func testChangingOffsetsWithoutTheSeatDoesNotWriteAndTheReassertWritesTheNewTotal() throws {
        let f = try makeLatencyFixture(declared: [4000], ownerIsSelf: false, initialDriverValue: 777)
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        f.engine.applyAVSyncOffsets([f.device.uid: 120], testToken)
        XCTAssertTrue(f.io.writes.isEmpty)
        XCTAssertEqual(f.io.values[Self.latencyDriverID], 777)

        let handle = try FileHandle(forWritingTo: f.url)
        try handle.seek(toOffset: UInt64(ownershipOwnerProcessIDOffset))
        try handle.write(contentsOf: withUnsafeBytes(of: SharedRingReader.selfProcessID) { Data($0) })
        try handle.close()
        XCTAssertTrue(f.reader.isSelfOwner, "前提: 席を取り戻した")

        f.engine.reassertDriverPresentationLatency(testToken)
        XCTAssertEqual(f.io.writtenFrames, [expectedDriverLatency(outputDeclared: 4000, avSyncOffset: 120)])
    }

    func testOffsetsChangedWhileStoppedTakeEffectAtTheNextAssembly() throws {
        let f = try makeLatencyFixture(declared: [4000, 4000])
        f.engine.suspend(cause: .routeUnavailable, testToken)
        let writes = f.io.writes.count

        f.engine.applyAVSyncOffsets([f.device.uid: 90], testToken)
        XCTAssertEqual(f.io.writes.count, writes, "停止中は書かない")

        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }

        XCTAssertEqual(f.io.writtenFrames.last, expectedDriverLatency(outputDeclared: 4000, avSyncOffset: 90), "停止をまたいで表が残り、再組み立てで効く")
        XCTAssertEqual(f.engine.presentationDelay?.delayFrames, 4000)
    }

    func testSwitchingToAnotherUIDDeclaresThatUIDsOffset() throws {
        let f = try makeLatencyFixture(declared: [20000, 20000], assemble: false)
        let otherUID = "forced-different-uid-for-offset-switch"
        f.engine.applyAVSyncOffsets([f.device.uid: 100, otherUID: -100], testToken)
        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let first = expectedDriverLatency(outputDeclared: 20000, avSyncOffset: 100)
        let second = expectedDriverLatency(outputDeclared: 20000, avSyncOffset: -100)
        XCTAssertEqual(f.io.writtenFrames, [first])

        XCTAssertTrue(f.engine.switchOutputDevice(to: ResolvedOutputDevice(uid: otherUID, deviceID: f.device.deviceID), testToken))

        XCTAssertEqual(f.io.writtenFrames, [first, second], "切替先の UID の補正で申告される")
        XCTAssertEqual(f.engine.presentationDelay?.delayFrames, 20000)
    }

    func testNotNeededSwitchRebuildsWhenItsOutputUIDDiffersAndDeclaresTheActualUIDsOffset() throws {
        let f = try makeLatencyFixture(declared: [20000, 20000, 20000], assemble: false)
        let otherUID = "forced-different-uid-for-notneeded-rebuild"
        f.engine.applyAVSyncOffsets([f.device.uid: 100, otherUID: -100], testToken)
        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        // 遅延線の出力先だけ別 UID にした状態を作る (実デバイスは同じまま)。
        XCTAssertTrue(f.engine.switchOutputDevice(to: ResolvedOutputDevice(uid: otherUID, deviceID: f.device.deviceID), testToken))
        let before = try XCTUnwrap(f.engine.presentationDelay)
        XCTAssertEqual(f.io.writtenFrames.last, expectedDriverLatency(outputDeclared: 20000, avSyncOffset: -100), "前提: 別 UID の補正")
        Thread.sleep(forTimeInterval: 0.2)
        let resetsBefore = f.reader.metrics.occupancyResetDueToOutputRestartCount

        XCTAssertTrue(f.engine.switchOutputDevice(to: f.outputDevice, testToken))

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(f.engine.presentationDelay === before, "出力先の UID が違うので作り直される")
        XCTAssertEqual(f.io.writtenFrames.last, expectedDriverLatency(outputDeclared: 20000, avSyncOffset: 100), "実際の出力先の UID の補正で書き直される")
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToOutputRestartCount, resetsBefore + 1)
    }

    func testARateChangeDeclaresTheOffsetConvertedAtTheNewRate() throws {
        let f = try makeLatencyFixture(declared: [100, 100], sampleRate: 48000, assemble: false)
        f.engine.applyAVSyncOffsets([f.device.uid: 70], testToken)
        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let initial = expectedDriverLatency(outputDeclared: 100, avSyncOffset: 70)
        XCTAssertEqual(f.io.writtenFrames, [initial])

        setHeaderSampleRate(f.url, 44100)
        f.engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(AudioConfig.appliedSampleRate, 44100, "前提: レート変更が適用されている")
        XCTAssertEqual(f.io.writtenFrames.last, expectedDriverLatency(outputDeclared: 100, avSyncOffset: 70), "新しいレートに換算した補正が入る")
        XCTAssertNotEqual(f.io.writtenFrames.last, initial)
    }

    func testTheCapturePathKeepsWritingNeutralEvenWhenTheEndpointUIDHasAnOffset() throws {
        let io = MockDriverPresentationLatencyIO()
        io.values[Self.latencyDriverID] = 5000
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let engine = makeSilencedEngine(driverPresentationLatencyIO: io)
        engine.readDeclaredPresentationLatencyFrames = { _, _, _ in 1234 }
        engine.applyAVSyncOffsets([device.uid: 200], testToken)
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000, ownerProcessID: SharedRingReader.selfProcessID)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let capture = FakeCaptureSource(endpointUID: device.uid, endpointDeviceID: device.deviceID, sampleRate: 44100)

        XCTAssertTrue(engine.assembleAirPlay(capture: capture, ringReader: reader, driverDeviceID: Self.latencyDriverID, testToken))
        defer { engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertEqual(io.writtenFrames, [Self.neutralFrames], "前提: 取り込み経路は中立を書く")
        XCTAssertEqual(engine.presentationDelay?.delayFrames, 1234, "遅延線は申告値")

        io.values[Self.latencyDriverID] = 9
        engine.applyAVSyncOffsets([device.uid: -200], testToken)

        XCTAssertEqual(io.writtenFrames, [Self.neutralFrames], "実行中に表が届いても書かない")
        XCTAssertEqual(io.values[Self.latencyDriverID], 9)
    }

    func testReassertingWritesBackTheRecordedTotalOnlyWhenTheDriverValueDiffers() throws {
        let f = try makeLatencyFixture(declared: [4000])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let expected = expectedDriverLatency(outputDeclared: 4000)
        XCTAssertEqual(f.io.writes.count, 1)

        f.engine.reassertDriverPresentationLatency(testToken)
        XCTAssertEqual(f.io.writes.count, 1, "一致なら書かない")

        f.io.values[Self.latencyDriverID] = Self.neutralFrames
        f.engine.reassertDriverPresentationLatency(testToken)
        XCTAssertEqual(f.io.writtenFrames, [expected, expected], "coreaudiod 再起動で中立へ戻った分を書き直す")
        XCTAssertEqual(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames, expected)
    }

    func testReassertingWhileSuspendedDoesNothing() throws {
        let f = try makeLatencyFixture(declared: [4000])
        f.engine.suspend(cause: .routeUnavailable, testToken)
        let writes = f.io.writes.count
        f.io.values[Self.latencyDriverID] = 31

        f.engine.reassertDriverPresentationLatency(testToken)

        XCTAssertEqual(f.io.writes.count, writes)
        XCTAssertEqual(f.io.values[Self.latencyDriverID], 31)
    }

    func testAnEngineThatIsNotTheOwnerNeverWritesWhetherBuildingReassertingOrSuspending() throws {
        let f = try makeLatencyFixture(declared: [4000], ownerIsSelf: false, initialDriverValue: 777)
        XCTAssertEqual(f.engine.processingState, .active, "前提: 組み立て自体は所有を確かめず稼働中になる")
        XCTAssertTrue(f.io.writes.isEmpty, "組み立て")

        f.engine.reassertDriverPresentationLatency(testToken)
        XCTAssertTrue(f.io.writes.isEmpty, "点検")

        f.engine.suspend(cause: .routeUnavailable, testToken)
        XCTAssertTrue(f.io.writes.isEmpty, "停止の中立化")
        XCTAssertEqual(f.io.values[Self.latencyDriverID], 777, "新しい所有者の値が残る")
    }

    func testAnAssemblyThatFailsAfterDeclaringReturnsTheDriverToNeutral() throws {
        let f = try makeLatencyFixture(declared: [4000], assemble: false)
        f.engine.makeEQUnit = { _, _, _, _ in nil }

        XCTAssertFalse(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ), "前提: EQ ユニットが作れず組み立てが失敗する")
        XCTAssertEqual(f.io.writtenFrames, [
            expectedDriverLatency(outputDeclared: 4000),
            DriverConfig.presentationLatencyNeutralFrames,
        ])
    }

    func testLosingTheSeatWhileActiveDropsTheObservedValueInsteadOfKeepingTheLastOne() throws {
        let f = try makeLatencyFixture(declared: [4000])
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertNotNil(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames, "前提: 所有中は観測値がある")

        let handle = try FileHandle(forWritingTo: f.url)
        try handle.seek(toOffset: UInt64(ownershipOwnerProcessIDOffset))
        try handle.write(contentsOf: withUnsafeBytes(of: SharedRingReader.selfProcessID &+ 1) { Data($0) })
        try handle.close()
        XCTAssertFalse(f.reader.isSelfOwner, "前提: 席が他者へ移った")

        f.engine.reassertDriverPresentationLatency(testToken)
        XCTAssertNil(f.engine.runtimeMetricsSnapshot(testToken).driverPresentationLatencyFrames)
    }

    func testTheOwnershipCheckForNeutralizingIsTakenBeforeTheReaderIsDropped() throws {
        let f = try makeLatencyFixture(declared: [4000])

        f.engine.suspend(cause: .routeUnavailable, testToken)

        XCTAssertEqual(f.io.values[Self.latencyDriverID], Self.neutralFrames, "所有者の停止は中立へ戻す")
    }

    func testReturnsDriverPresentationLatencyToNeutralIsFalseOnlyForOwnershipUnavailable() {
        for cause in SuspensionCause.allCases {
            XCTAssertEqual(
                SuspensionPolicy.returnsDriverPresentationLatencyToNeutral(cause), cause != .ownershipUnavailable, "\(cause)"
            )
        }
    }
}

// MARK: - ドライバのレート

extension AudioEngineTests {
    private struct SampleRateFixture {
        let engine: AudioEngine
        let rateIO: MockDeviceSampleRateIO
        let latencyIO: MockDriverPresentationLatencyIO
        let reader: SharedRingReader
        let url: URL
        let device: (deviceID: AudioDeviceID, uid: String)
        var outputDevice: ResolvedOutputDevice { ResolvedOutputDevice(uid: device.uid, deviceID: device.deviceID) }
        func otherDevice(_ tag: String) -> ResolvedOutputDevice {
            ResolvedOutputDevice(uid: "forced-different-uid-for-driver-rate-\(tag)", deviceID: device.deviceID)
        }
    }

    private static let outputDeclaredFramesForRateTests = 4000

    private func makeSampleRateFixture(
        headerRate: Double = 48000, outputRate: Double? = 44100, ownerIsSelf: Bool = true, assemble: Bool = true
    ) throws -> SampleRateFixture {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let rateIO = MockDeviceSampleRateIO()
        rateIO.rates[device.deviceID] = outputRate
        rateIO.available[Self.latencyDriverID] = TestSampleRates.all.map { $0...$0 }
        XCTAssertTrue(
            Set<Double>([44100, 48000, 88200, 96000]).isSubset(of: TestSampleRates.all),
            "前提: この extension が使うレートはドライバの一覧に入る"
        )
        let latencyIO = MockDriverPresentationLatencyIO()
        latencyIO.values[Self.latencyDriverID] = Self.neutralFrames
        let engine = makeSilencedEngine(driverPresentationLatencyIO: latencyIO, deviceSampleRateIO: rateIO)
        engine.readDeclaredPresentationLatencyFrames = { _, _, _ in Self.outputDeclaredFramesForRateTests }
        let owner = ownerIsSelf ? SharedRingReader.selfProcessID : SharedRingReader.selfProcessID &+ 1
        let url = makeMinimalSharedRingReaderFixture(sampleRate: headerRate, ownerProcessID: owner)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let fixture = SampleRateFixture(engine: engine, rateIO: rateIO, latencyIO: latencyIO, reader: reader, url: url, device: device)
        if assemble {
            XCTAssertTrue(engine.assemble(
                outputDevice: fixture.outputDevice, ringReader: reader, driverDeviceID: Self.latencyDriverID, testToken
            ), "前提: 実デバイスへの組み立てが成立すること")
        }
        return fixture
    }

    private func expectedLatencyAtAppliedRate() -> Int {
        expectedDriverLatency(outputDeclared: Self.outputDeclaredFramesForRateTests)
    }

    private func expectedLatency(
        at rate: Double, declared: Int = outputDeclaredFramesForRateTests,
        avSyncOffset: Int = DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsDefault
    ) -> Int {
        DriverPresentationLatencyPolicy.totalFrames(
            outputDeclaredFrames: declared, avSyncOffsetMilliseconds: avSyncOffset, appliedSampleRate: rate
        )
    }

    private func takeTheSeatBack(_ f: SampleRateFixture) throws {
        let handle = try FileHandle(forWritingTo: f.url)
        try handle.seek(toOffset: UInt64(ownershipOwnerProcessIDOffset))
        try handle.write(contentsOf: withUnsafeBytes(of: SharedRingReader.selfProcessID) { Data($0) })
        try handle.close()
        XCTAssertTrue(f.reader.isSelfOwner, "前提: 席を取り戻した")
    }

    private func runPeriodicPass(_ f: SampleRateFixture) {
        f.engine.reassertDriverPresentationLatency(testToken)
        f.engine.refreshOutputDeviceSampleRate(testToken)
    }

    /// ヘッダが出力先のレートになり、作り直しが済んだ状態にする。
    private func converge(_ f: SampleRateFixture) {
        guard let outputRate = f.rateIO.rates[f.device.deviceID] else { return XCTFail("前提: 出力先のレートがある") }
        setHeaderSampleRate(f.url, outputRate)
        f.engine.applyDriverSampleRateIfChanged(testToken)
        XCTAssertEqual(f.engine.processingState, .active, "前提: レート変更の作り直しで出力段が再開した")
        XCTAssertEqual(AudioConfig.appliedSampleRate, outputRate, "前提: 出力先のレートが適用された")
    }

    func testAssemblingDeclaresAheadAndTheReflectionSettlesTheRequest() throws {
        let latencyWritesAtRateWrite = Recorded<[Int]>([])
        let f = try makeSampleRateFixture(assemble: false)
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        f.rateIO.willWrite = { [latencyIO = f.latencyIO] in latencyWritesAtRateWrite.update { $0.append(latencyIO.writes.count) } }
        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ), "前提: 実デバイスへの組み立てが成立すること")
        let notified = Recorded<[Double]>([])
        f.engine.appliedSampleRateDidChange = { rate in notified.update { $0.append(rate) } }
        let atTargetRate = expectedLatency(at: 44100)
        XCTAssertNotEqual(atTargetRate, expectedLatencyAtAppliedRate(), "前提: 行き先のレートと適用中のレートで値が違う")

        XCTAssertEqual(f.rateIO.writtenRates, [44100], "組み立てが出力先のレートを決める")
        XCTAssertEqual(f.rateIO.writes.map(\.id), [Self.latencyDriverID], "レートの書き込み先はドライバ")
        XCTAssertEqual(f.latencyIO.writtenFrames, [atTargetRate], "出力先の申告を行き先のレートで読み直して書く")
        XCTAssertEqual(latencyWritesAtRateWrite.value, [1], "レートの書き込み時点で申告は書き終えている")

        converge(f)

        XCTAssertEqual(notified.value, [44100], "反映の通知は 1 回")
        XCTAssertEqual(f.rateIO.writtenRates, [44100], "反映では書き直さない")
        XCTAssertEqual(f.latencyIO.writtenFrames, [atTargetRate], "反映後は申告も書き増えない")

        setHeaderSampleRate(f.url, 88200)
        f.engine.applyDriverSampleRateIfChanged(testToken)

        XCTAssertEqual(AudioConfig.appliedSampleRate, 88200, "前提: 外部の変更に追従して作り直した")
        XCTAssertEqual(f.rateIO.writtenRates, [44100], "作り直しは出力先のレートを決めない")
        XCTAssertEqual(f.latencyIO.writtenFrames, [atTargetRate, expectedLatency(at: 88200)], "反映で依頼が決着し、作り直しの申告が書かれる")

        let step = DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsStep
        f.engine.applyAVSyncOffsets([f.device.uid: step], testToken)

        XCTAssertEqual(
            f.latencyIO.writtenFrames, [atTargetRate, expectedLatency(at: 88200), expectedLatency(at: 88200, avSyncOffset: step)],
            "決着の後の同期補正は書かれる"
        )
    }

    func testARequestThatNeverLandsHoldsTheDeclarationsAndReleasesThemOnTheSecondPass() throws {
        let f = try makeSampleRateFixture()
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        let atTargetRate = expectedLatency(at: 44100)
        let step = DriverPresentationLatencyPolicy.avSyncOffsetMillisecondsStep
        XCTAssertNotEqual(AudioConfig.appliedSampleRate, 44100, "前提: 反映されていない")

        f.engine.applyAVSyncOffsets([f.device.uid: step], testToken)
        XCTAssertEqual(f.latencyIO.writtenFrames, [atTargetRate], "依頼中の同期補正は書かない")

        runPeriodicPass(f)
        XCTAssertEqual(f.latencyIO.writtenFrames, [atTargetRate], "依頼を出した周の再申告は書かない")

        runPeriodicPass(f)
        f.engine.reassertDriverPresentationLatency(testToken)

        XCTAssertEqual(
            f.latencyIO.writtenFrames, [atTargetRate, expectedLatency(at: AudioConfig.appliedSampleRate, avSyncOffset: step)],
            "手放した後の再申告で、適用中のレートでの同期補正込みの値を書く"
        )
        XCTAssertEqual(f.rateIO.writtenRates, [44100], "再依頼しない")
    }

    func testTheDecisionPointsAreAssemblingAndSwitchingAndStoppingForgetsTheRequest() throws {
        let f = try makeSampleRateFixture(headerRate: 48000, outputRate: 48000)
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertTrue(f.rateIO.writes.isEmpty, "前提: 一致している間は書かない")

        f.rateIO.rates[f.device.deviceID] = 96000
        XCTAssertTrue(f.engine.switchOutputDevice(to: f.outputDevice, testToken))
        XCTAssertTrue(f.rateIO.writes.isEmpty, "遅延線を作り直さない早期 return では決めない")

        XCTAssertTrue(f.engine.switchOutputDevice(to: f.otherDevice("switch"), testToken))
        XCTAssertEqual(f.rateIO.writtenRates, [96000], "切替の成功で決める")

        f.rateIO.rates[f.device.deviceID] = 88200
        XCTAssertTrue(f.engine.switchOutputDevice(to: f.outputDevice, testToken))
        XCTAssertEqual(f.rateIO.writtenRates, [96000, 88200], "遅延線を作り直す切替で決める")

        f.engine.suspend(cause: .routeUnavailable, testToken)
        f.rateIO.rates[f.device.deviceID] = 96000
        f.engine.refreshOutputDeviceSampleRate(testToken)
        XCTAssertEqual(f.rateIO.writtenRates, [96000, 88200], "停止中の周期パスは何もしない")

        f.rateIO.rates[f.device.deviceID] = 88200
        XCTAssertTrue(f.engine.assemble(
            outputDevice: f.outputDevice, ringReader: f.reader, driverDeviceID: Self.latencyDriverID, testToken
        ))
        XCTAssertEqual(f.rateIO.writtenRates, [96000, 88200, 88200], "停止で依頼中を忘れているので組み立て直しで決め直す")
    }

    func testTheGateKeepsTheDriverUntouchedAndThePeriodicPassFollows() throws {
        let f = try makeSampleRateFixture(ownerIsSelf: false)
        defer { f.engine.suspend(cause: .applicationTermination, testToken) }
        XCTAssertTrue(f.rateIO.writes.isEmpty, "席が無い間は書かない")
        XCTAssertTrue(f.latencyIO.writes.isEmpty, "席が無い間は申告も書かない")
        XCTAssertEqual(f.rateIO.availableReadCount, 0, "席が無い間は一覧も読まない")

        try takeTheSeatBack(f)
        f.engine.updateDriverDeviceID(nil, testToken)
        f.engine.refreshOutputDeviceSampleRate(testToken)
        XCTAssertTrue(f.rateIO.writes.isEmpty, "ドライバが無ければ書かない")
        XCTAssertEqual(f.rateIO.availableReadCount, 0, "ドライバが無ければ一覧も読まない")

        f.engine.updateDriverDeviceID(Self.latencyDriverID, testToken)
        f.rateIO.writeShouldSucceed = false
        f.engine.refreshOutputDeviceSampleRate(testToken)

        XCTAssertEqual(f.rateIO.writtenRates, [44100], "周期パスが出力先のレートへ追従する")
        XCTAssertEqual(
            f.latencyIO.writtenFrames, [expectedLatency(at: 44100), expectedLatencyAtAppliedRate()],
            "行き先のレートの値を先に書き、拒否されたので決定地点で保持した適用中のレートの値へ戻す"
        )
    }

    func testTheCapturePathNeverAsksTheDriverForARate() throws {
        guard let device = usableOutputDevice() else {
            throw XCTSkip("この環境で駆動に使える出力デバイスが無いため、実クラスの assemble を駆動できない")
        }
        restoringBaseSampleRateAfterTest()
        let rateIO = MockDeviceSampleRateIO()
        rateIO.rates[device.deviceID] = 44100
        rateIO.available[Self.latencyDriverID] = TestSampleRates.all.map { $0...$0 }
        let engine = makeSilencedEngine(deviceSampleRateIO: rateIO)
        let url = makeMinimalSharedRingReaderFixture(sampleRate: 48000, ownerProcessID: SharedRingReader.selfProcessID)
        tempURLs.update { $0.append(url) }
        let reader = try SharedRingReader.open(path: url.path).get()
        let capture = FakeCaptureSource(endpointUID: device.uid, endpointDeviceID: device.deviceID, sampleRate: 44100)

        XCTAssertTrue(engine.assembleAirPlay(capture: capture, ringReader: reader, driverDeviceID: Self.latencyDriverID, testToken))
        defer { engine.suspend(cause: .applicationTermination, testToken) }
        engine.refreshOutputDeviceSampleRate(testToken)

        XCTAssertTrue(rateIO.writes.isEmpty)
        XCTAssertEqual(rateIO.availableReadCount, 0, "取り込み経路では一覧も読まない")
    }
}
