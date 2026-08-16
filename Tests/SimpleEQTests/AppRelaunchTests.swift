import XCTest
@testable import SimpleEQ

/// 起動し直しの決め事だけを、実プロセスの起動から切り離して確かめる。
final class AppRelaunchTests: XCTestCase {

    func testWaitTimeoutOutlastsTheTerminationWaitTimeout() {
        let terminationWaitTimeout: TimeInterval = 5
        XCTAssertGreaterThan(
            AppRelaunch.waitTimeout(terminationWaitTimeout: terminationWaitTimeout), terminationWaitTimeout,
            "待ちの上限が終了の待ちの上限を超えていない"
        )
    }

    func testWaitTimeoutFollowsTheTerminationWaitTimeout() {
        XCTAssertGreaterThan(
            AppRelaunch.waitTimeout(terminationWaitTimeout: 10),
            AppRelaunch.waitTimeout(terminationWaitTimeout: 5)
        )
    }

    func testScriptWaitsForThisProcessToDisappearBeforeOpening() {
        let script = AppRelaunch.relaunchScript(
            bundlePath: "/Applications/SimpleEQ.app", processIdentifier: 4321, waitTimeout: 10
        )
        let waitIndex = script.range(of: "kill -0 4321")?.lowerBound
        let openIndex = script.range(of: "/usr/bin/open")?.lowerBound

        XCTAssertNotNil(waitIndex, "このプロセスの生存を見ていない")
        XCTAssertNotNil(openIndex, "開き直しが含まれていない")
        if let waitIndex, let openIndex {
            XCTAssertLessThan(waitIndex, openIndex, "生存を待つ前に開いている")
        }
    }

    func testScriptOpensTheGivenBundleWithoutForcingANewInstance() {
        let script = AppRelaunch.relaunchScript(
            bundlePath: "/Applications/SimpleEQ.app", processIdentifier: 1, waitTimeout: 10
        )
        XCTAssertTrue(script.contains("/usr/bin/open '/Applications/SimpleEQ.app'"))
        XCTAssertFalse(script.contains(" -n"), "新しいインスタンスを強制する指定が入っている")
    }

    func testScriptQuotesABundlePathThatContainsSpaces() {
        let script = AppRelaunch.relaunchScript(
            bundlePath: "/Volumes/My Disk/SimpleEQ.app", processIdentifier: 1, waitTimeout: 10
        )
        XCTAssertTrue(script.contains("'/Volumes/My Disk/SimpleEQ.app'"), "空白を含むパスが囲まれていない")
    }

    func testScriptBoundsTheWaitAndOpensEvenWhenItIsNotSatisfied() throws {
        let shortWait = AppRelaunch.relaunchScript(bundlePath: "/x.app", processIdentifier: 1, waitTimeout: 1)
        let longWait = AppRelaunch.relaunchScript(bundlePath: "/x.app", processIdentifier: 1, waitTimeout: 10)

        // 回数そのものではなく上限との関係を見る。
        let shortAttempts = try XCTUnwrap(Self.attemptCount(in: shortWait), "待ちの回数が読み取れない")
        let longAttempts = try XCTUnwrap(Self.attemptCount(in: longWait), "待ちの回数が読み取れない")
        XCTAssertGreaterThan(shortAttempts, 0, "一度も待たずに開いている")
        XCTAssertEqual(longAttempts, shortAttempts * 10, "待ちの回数が上限に比例していない")

        XCTAssertTrue(shortWait.hasSuffix("/usr/bin/open '/x.app'"), "上限に達した後に開いていない")
    }

    private static func attemptCount(in script: String) -> Int? {
        guard let range = script.range(of: "attempt -lt ") else { return nil }
        return Int(script[range.upperBound...].prefix { $0.isNumber })
    }
}
