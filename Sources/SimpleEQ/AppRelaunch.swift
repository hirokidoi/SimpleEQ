import AppKit
import Foundation

/// アプリを起動し直す。自分は通常の終了経路を通り、開き直しは切り離した別プロセスへ任せる
/// (自分が居なくなった後に開く必要があるため)。
enum AppRelaunch {

    @MainActor
    static func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            relaunchScript(
                bundlePath: Bundle.main.bundleURL.path,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                waitTimeout: waitTimeout(terminationWaitTimeout: AppDelegate.terminationWaitTimeout)
            ),
        ]
        do {
            try waiter.run()
        } catch {
            // 開き直す者が居ないまま終わらないよう、留まる。
            print("[warn] could not spawn the relaunch waiter: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    static func waitTimeout(terminationWaitTimeout: TimeInterval) -> TimeInterval {
        terminationWaitTimeout * waitTimeoutFactor
    }

    private static let waitTimeoutFactor: Double = 2
    private static let pollInterval: TimeInterval = 0.2

    /// 上限に達した場合も最後に open は行う (自分がまだ生きていれば前面に出るだけで二重起動しない)。
    static func relaunchScript(
        bundlePath: String, processIdentifier: Int32, waitTimeout: TimeInterval
    ) -> String {
        let attempts = max(1, Int((waitTimeout / pollInterval).rounded()))
        return """
        attempt=0
        while [ $attempt -lt \(attempts) ] && kill -0 \(processIdentifier) 2>/dev/null; do
          sleep \(pollInterval)
          attempt=$((attempt + 1))
        done
        /usr/bin/open \(shellQuoted(bundlePath))
        """
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
