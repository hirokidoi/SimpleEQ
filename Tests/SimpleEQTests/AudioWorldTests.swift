import XCTest
@testable import SimpleEQ

/// 直列キューへ依頼を投入する口の畳み込み規則を検証する。CoreAudio には一切触れない。
@MainActor
final class AudioWorldTests: XCTestCase {

    // 同じ key を持つ未処理の依頼は、まだ実行が始まっていない限り最新の 1 件へ畳まれる。
    // キューを suspend() で止めた状態で 2 件投入し、resume() 後に何が実行されたかを見る。
    func testSubmitCoalescesPendingWorkWithSameKey() {
        let queue = DispatchQueue(label: "AudioWorldTests.coalesce")
        queue.suspend()
        let world = AudioWorld(queue: queue)
        let executed = Recorded<[String]>([])

        world.submit(coalescingKey: "reconcile") { _ in executed.update { $0.append("first") } }
        world.submit(coalescingKey: "reconcile") { _ in executed.update { $0.append("second") } }

        queue.resume()
        queue.sync {}

        XCTAssertEqual(executed.value, ["second"], "未処理の同種の依頼は最新の1件だけが実行される")
    }

    // 同じ key への再投入は、キュー上の実行位置も最新の投入位置 (末尾) へ動く。
    // 先に別の key で確保されていた位置を追い越して古い値のまま実行されてはならない。
    func testSubmitCoalescingMovesQueuePositionSoLaterKeyDoesNotOvertakeEarlierOne() {
        let queue = DispatchQueue(label: "AudioWorldTests.reorder")
        queue.suspend()
        let world = AudioWorld(queue: queue)
        let executed = Recorded<[String]>([])

        // 投入順: A(1回目) → B → A(2回目、再投入=畳み込み)。
        world.submit(coalescingKey: "A") { _ in executed.update { $0.append("A-first") } }
        world.submit(coalescingKey: "B") { _ in executed.update { $0.append("B") } }
        world.submit(coalescingKey: "A") { _ in executed.update { $0.append("A-second") } }

        queue.resume()
        queue.sync {}

        XCTAssertEqual(executed.value, ["B", "A-second"], "A への再投入は実行位置も末尾へ動き、B を追い越さない")
    }

    // 異なる key を持つ依頼は互いに畳まれず、両方とも実行される。
    func testSubmitDoesNotCoalesceDifferentKeys() {
        let queue = DispatchQueue(label: "AudioWorldTests.distinctKeys")
        queue.suspend()
        let world = AudioWorld(queue: queue)
        let executed = Recorded<Set<String>>([])

        world.submit(coalescingKey: "reconcile") { _ in executed.update { _ = $0.insert("reconcile") } }
        world.submit(coalescingKey: "eq") { _ in executed.update { _ = $0.insert("eq") } }

        queue.resume()
        queue.sync {}

        XCTAssertEqual(executed.value, ["reconcile", "eq"])
    }

    // 先に投入した依頼が実行を終えたあとの投入は「未処理」ではないため畳まれず、改めて実行される。
    func testSubmitRunsAgainAfterPreviousSameKeyWorkCompleted() {
        let world = AudioWorld()
        let firstDone = expectation(description: "first")
        let secondDone = expectation(description: "second")
        let executed = Recorded<[String]>([])

        world.submit(coalescingKey: "reconcile") { _ in
            executed.update { $0.append("first") }
            firstDone.fulfill()
        }
        wait(for: [firstDone], timeout: 1.0)

        world.submit(coalescingKey: "reconcile") { _ in
            executed.update { $0.append("second") }
            secondDone.fulfill()
        }
        wait(for: [secondDone], timeout: 1.0)

        XCTAssertEqual(executed.value, ["first", "second"])
    }

    // 取りこぼしてはならない依頼は、同時に複数投入しても畳まれずすべて個別に実行される。
    func testSubmitUncoalescedNeverCoalesces() {
        let queue = DispatchQueue(label: "AudioWorldTests.uncoalesced")
        queue.suspend()
        let world = AudioWorld(queue: queue)
        let executed = Recorded<[String]>([])

        world.submitUncoalesced { _ in executed.update { $0.append("install") } }
        world.submitUncoalesced { _ in executed.update { $0.append("uninstall") } }

        queue.resume()
        queue.sync {}

        XCTAssertEqual(executed.value, ["install", "uninstall"], "ドライバ操作はいずれも畳まれず両方実行される")
    }

    // 投入した依頼は単一の直列キュー上で、投入順を保って実行される。
    func testWorkRunsSeriallyInSubmissionOrder() {
        let world = AudioWorld()
        let done = expectation(description: "serial")
        let order = Recorded<[Int]>([])
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            world.submitUncoalesced { _ in
                order.update { $0.append(i) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done.fulfill() }
        wait(for: [done], timeout: 2.0)
        XCTAssertEqual(order.value, Array(0..<20))
    }

    // MARK: - submitUncoalescedAndWait (終了シーケンス専用の同期待ち)

    // 終了シーケンスがオーディオ世界の完了を実際に待ってから戻ることを固定する。
    // work の完了より前に制御が戻ると、既定出力の復帰とドライバの非表示化がプロセスの終了に間に合わない。
    func testSubmitUncoalescedAndWaitBlocksUntilWorkCompletes() {
        let world = AudioWorld()
        let completedInsideWork = Recorded<Bool>(false)

        let produced = world.submitUncoalescedAndWait(timeout: 1.0) { _ -> String in
            Thread.sleep(forTimeInterval: 0.05)
            completedInsideWork.update { $0 = true }
            return "確定値"
        }

        XCTAssertEqual(produced, "確定値", "上限内に完了すれば work の戻り値がそのまま返る")
        XCTAssertTrue(completedInsideWork.value, "呼び出しから戻った時点で work は完了している (待たずに戻らない)")
    }

    // 待ちには上限を持つ。work が上限を超えて完了しない場合は、待ちを諦めて値を返さない。
    func testSubmitUncoalescedAndWaitGivesUpAfterTimeout() {
        let world = AudioWorld()
        let workStarted = expectation(description: "work started")
        let workMayFinish = DispatchSemaphore(value: 0)

        let produced = world.submitUncoalescedAndWait(timeout: 0.1) { _ -> String in
            workStarted.fulfill()
            // 呼び出し元の待ちの上限 (0.1s) より十分長く work 自体を引き延ばし、上限超過を確実に踏む。
            _ = workMayFinish.wait(timeout: .now() + 2.0)
            return "確定値"
        }

        XCTAssertNil(produced, "上限を超えて完了しなければ待ちを諦め、値を持ち帰らない")
        wait(for: [workStarted], timeout: 1.0)
        workMayFinish.signal() // work 自体はキュー上で走り続けているため、後始末として完了させる。
    }
}
