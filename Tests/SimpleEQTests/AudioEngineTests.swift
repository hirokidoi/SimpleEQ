import XCTest
import CoreAudio
import Foundation
import SimpleEQRingC
@testable import SimpleEQ

/// 有効な共有メモリヘッダのみを持つ最小のフィクスチャファイルを作る。呼び出し元がテスト終了時に削除すること。
private func makeMinimalSharedRingReaderFixture(
    ringFrames: UInt32 = 64, channels: UInt32 = 1, writeCounter: UInt64 = 0,
    sampleRate: Double = AudioConfig.baseSampleRate, ringValues: [Float] = [],
    // 既定 0 (非稼働) は経過時間に関わらず停止と判定されない。稼働 (1) にすると停止判定を発火させられる。
    writerIOIsRunning: UInt32 = 0
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
        for (i, v) in ringValues.enumerated() {
            raw.storeBytes(of: v, toByteOffset: ringDataOffset + i * MemoryLayout<Float>.size, as: Float.self)
        }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioEngineTests-\(UUID().uuidString).shm")
    try! data.write(to: url)
    return url
}

/// テスト実行環境で駆動に使える出力デバイス (ID + UID) を選ぶ。実 AudioUnit を組み立てるには有効な
/// AudioDeviceID が要るため、実行環境に存在するデバイスを都度読んで使う。自ドライバとそれを内包する
/// Aggregate は選ばない (書き手の IO を揺らして再生中の音に触れるため)。どれも使えない場合は nil。
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
    }

    func testAllowsAutomaticResumeOnlyForRouteUnavailable() {
        XCTAssertTrue(SuspensionPolicy.allowsAutomaticResume(.routeUnavailable))
        XCTAssertFalse(SuspensionPolicy.allowsAutomaticResume(.driverOperation))
        XCTAssertFalse(SuspensionPolicy.allowsAutomaticResume(.applicationTermination))
    }

    func testMaintainsDriverVisibilityForActiveAndRouteUnavailableSuspensionOnly() {
        XCTAssertTrue(SuspensionPolicy.maintainsDriverVisibility(.active))
        XCTAssertTrue(SuspensionPolicy.maintainsDriverVisibility(.suspended(.routeUnavailable)))
        XCTAssertFalse(SuspensionPolicy.maintainsDriverVisibility(.suspended(.driverOperation)))
        XCTAssertFalse(SuspensionPolicy.maintainsDriverVisibility(.suspended(.applicationTermination)))
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
        let engine = AudioEngine()
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

        // 初回 bind では音量 0 だけでもゲインが 0 になるため、採用がユニティへ戻る 2 回目の
        // bind まで見ないとミュートが効いているかを判別できない。
        let otherUIDDevice = ResolvedOutputDevice(uid: "another-uid-for-silence-test", deviceID: device.deviceID)
        XCTAssertTrue(engine.switchOutputDevice(to: otherUIDDevice, testToken), "前提: 別 UID への張り替えが成立すること")

        XCTAssertEqual(engine.outputGain, 0)

        engine.suspend(cause: .applicationTermination, testToken)
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
        let engine = AudioEngine()
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
}

// MARK: - AudioActivationCoordinator (起動・再開の共通手順)

/// この代役へ触れる経路は直列キューが順序を作るため、同時に触れることが無い。
final class MockActivatableAudioEngine: ActivatableAudioEngine, @unchecked Sendable {
    var processingState: ProcessingState = .suspended(.routeUnavailable)
    var assembleShouldSucceed = true
    private(set) var assembleCalls: [(outputDevice: ResolvedOutputDevice, driverDeviceID: AudioDeviceID?)] = []

    @discardableResult
    func assemble(outputDevice: ResolvedOutputDevice, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool {
        assembleCalls.append((outputDevice, driverDeviceID))
        processingState = assembleShouldSucceed ? .active : .suspended(.routeUnavailable)
        return assembleShouldSucceed
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

    // 掌握済みなら可視化を打ち直さない。
    func testActivateDoesNotReapplyVisibilityWhenAlreadyOwned() {
        let directory = makeDirectory()
        directory.currentDefaultOutputID = speakerID
        let engine = MockActivatableAudioEngine()
        let (coordinator, lifecycle) = makeCoordinator(
            directory: directory, engine: engine, openSharedMemory: { [tempURLs] in Self.openValidSharedRingReader(registeringInto: tempURLs) }
        )
        lifecycle.reapplyVisibility(deviceID: driverDeviceID, testToken)
        directory.resetCallRecords()

        let target = ResolvedOutputDevice(uid: speakerUID, deviceID: speakerID)
        coordinator.activate(resolveOutputDevice: { _ in target }, attempt: .resume, testToken)

        XCTAssertTrue(directory.setHiddenCalls.isEmpty, "掌握済みなら可視化を打ち直さない")
        XCTAssertTrue(directory.resolveHiddenDeviceIDCalls.isEmpty)
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
