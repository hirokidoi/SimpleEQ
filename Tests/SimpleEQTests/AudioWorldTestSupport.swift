import CoreAudio
import Foundation
import Synchronization
import XCTest
@testable import SimpleEQ

/// オーディオ世界のキュー上で走る依頼が積んだ値を、検証側が受け取るための容れ物。読み書きの両方をロックの内側で行う。
final class Recorded<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ initialValue: Value) {
        storage = Mutex(initialValue)
    }

    var value: Value { storage.withLock { $0 } }

    @discardableResult
    func update<Result>(_ body: @Sendable (inout Value) -> Result) -> Result {
        storage.withLock { body(&$0) }
    }
}

/// オーディオ世界の直列キュー上でのみ得られる通行証を、テストが同期的に呼び出すために用意する。
/// 値そのものは状態を持たないため、テストターゲット全体で使い回してよい。
let testToken: AudioWorldToken = {
    let queue = DispatchQueue(label: "AudioWorldTestSupport.token")
    let world = AudioWorld(queue: queue)
    return queue.sync { world.assumingOnQueue() }
}()

func makeTestAudioWorld() -> AudioWorld {
    AudioWorld(queue: DispatchQueue(label: "AudioWorldTestSupport.world.\(UUID().uuidString)"))
}

/// 投入した work の完了を待つ。
/// 直列キューへ空の work を同期投入すると、それより前に投入された work がすべて終わるまで戻らない性質を使う。
/// `DispatchQueue.main.async` への委譲分は RunLoop を短く回して処理させる。
///
/// 用途は「変化しないことの見届け」に限る。
/// 値が動くのを待つ場合は条件が成立するまで見張る waitForAudioWorld を使うこと (固定時間では、着地前に先の検証へ進みうる)。
func drainAudioWorld(_ audioWorld: AudioWorld, settlingMainQueueFor seconds: TimeInterval = 0.05) {
    audioWorld.queue.sync {}
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 期限切れを後続の検証の失敗として現すと、着地しなかったのか別の値になったのかを切り分けられなくなる。
func waitUntilSettled(
    timeout: TimeInterval = 2, pollingInterval: TimeInterval = 0.01,
    file: StaticString = #filePath, line: UInt = #line, _ isSettled: () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !isSettled(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(pollingInterval))
    }
    if !isSettled() {
        XCTFail("待ちが期限 (\(timeout) 秒) までに成立しなかった", file: file, line: line)
    }
}

func waitForAudioWorld(
    _ audioWorld: AudioWorld, timeout: TimeInterval = 2, pollingInterval: TimeInterval = 0.01,
    file: StaticString = #filePath, line: UInt = #line, until isSettled: () -> Bool
) {
    audioWorld.queue.sync {}
    waitUntilSettled(timeout: timeout, pollingInterval: pollingInterval, file: file, line: line, isSettled)
}

@MainActor
func makeSilencedEngine() -> AudioEngine {
    let engine = AudioEngine(volumeDeviceIO: MockDeviceVolumeIO())
    engine.applyDriverVolumeAndMute(volume: 0, muted: true, testToken)
    return engine
}

/// 実デバイスの状態を ID ごとに保持する代役。CoreAudio に触れないため直接駆動できる。
final class MockDeviceVolumeIO: DeviceVolumeIO, @unchecked Sendable {
    var volumeCapabilities: [AudioDeviceID: DevicePropertyCapability] = [:]
    var muteCapabilities: [AudioDeviceID: DevicePropertyCapability] = [:]
    var volumes: [AudioDeviceID: Float] = [:]
    var mutes: [AudioDeviceID: Bool] = [:]
    var volumeWriteShouldSucceed = true
    var muteWriteShouldSucceed = true
    var volumeWriteRounding: ((Float) -> Float)?
    var volumeWriteIsNoOp = false
    var muteWriteIsNoOp = false
    var volumeWriteClearsReadback = false
    var muteWriteClearsReadback = false

    private(set) var addedListeners: [AudioDeviceID] = []
    private(set) var removedListeners: [AudioDeviceID] = []

    func volumeCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability {
        volumeCapabilities[id] ?? DevicePropertyCapability(exists: false, settable: false)
    }

    func muteCapability(_ id: AudioDeviceID, _ token: AudioWorldToken) -> DevicePropertyCapability {
        muteCapabilities[id] ?? DevicePropertyCapability(exists: false, settable: false)
    }

    func readVolume(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Float? { volumes[id] }

    @discardableResult
    func writeVolume(_ id: AudioDeviceID, _ value: Float, _ token: AudioWorldToken) -> Bool {
        guard volumeWriteShouldSucceed else { return false }
        guard !volumeWriteClearsReadback else { volumes[id] = nil; return true }
        guard !volumeWriteIsNoOp else { return true }
        volumes[id] = volumeWriteRounding?(value) ?? value
        return true
    }

    func readMute(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool? { mutes[id] }

    @discardableResult
    func writeMute(_ id: AudioDeviceID, _ value: Bool, _ token: AudioWorldToken) -> Bool {
        guard muteWriteShouldSucceed else { return false }
        guard !muteWriteClearsReadback else { mutes[id] = nil; return true }
        guard !muteWriteIsNoOp else { return true }
        mutes[id] = value
        return true
    }

    func addVolumeMuteListener(_ id: AudioDeviceID, queue: DispatchQueue, _ block: @escaping AudioObjectPropertyListenerBlock) {
        addedListeners.append(id)
    }

    func removeVolumeMuteListener(_ id: AudioDeviceID, queue: DispatchQueue, _ block: @escaping AudioObjectPropertyListenerBlock) {
        removedListeners.append(id)
    }
}
