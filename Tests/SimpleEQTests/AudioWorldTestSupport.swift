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

/// 投入した work の完了を待つ。直列キューへ空の work を同期投入すると、それより前に投入された
/// work がすべて終わるまで戻らない性質を使う。`DispatchQueue.main.async` への委譲分は RunLoop を短く回して処理させる。
///
/// 用途は「変化しないことの見届け」に限る。値が動くのを待つ場合は条件が成立するまで見張る
/// waitForAudioWorld を使うこと (固定時間では、着地前に先の検証へ進みうる)。
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
