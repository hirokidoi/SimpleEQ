import Foundation

/// 専用ドライバのインストール・更新・削除実行を担う。
enum DriverInstaller {
    static let payloadDirectoryName = "Driver"
    static let sharedSubdirectoryName = "Shared"

    static let installScriptName = "install-driver.sh"
    static let uninstallScriptName = "uninstall-driver.sh"

    /// 解決元を引数で受ける形は崩さない。内側で Bundle.main を読むと呼び出し側が起点を選べなくなる。
    static func resolveScriptPath(named name: String, resourcesURL: URL) -> String {
        resourcesURL
            .appendingPathComponent(payloadDirectoryName)
            .appendingPathComponent(name)
            .path
    }

    enum ActionError: Error {
        case payloadMissing
        case scriptFailed(exitCode: Int32)
        case cancelled
    }

    static func installOrUpdate(completion: @escaping @MainActor (Result<Void, ActionError>) -> Void) {
        runElevated(scriptNamed: installScriptName, completion: completion)
    }

    static func uninstall(completion: @escaping @MainActor (Result<Void, ActionError>) -> Void) {
        runElevated(scriptNamed: uninstallScriptName, completion: completion)
    }

    /// osascript へ渡す文字列は、アプリバンドル内の位置とスクリプト名の結合のみで構成し、
    /// ユーザ入力・アプリ外部由来の値を混入させない。
    private static func runElevated(scriptNamed name: String, completion: @escaping @MainActor (Result<Void, ActionError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let resourcesURL = Bundle.main.resourceURL else {
                complete(.failure(.payloadMissing), completion)
                return
            }
            let scriptPath = resolveScriptPath(named: name, resourcesURL: resourcesURL)
            // 管理者権限昇格はこのパスを直接実行するため、実行権の有無まで見る。
            guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
                complete(.failure(.payloadMissing), completion)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // do shell script へ渡すシェル文字列として (shellQuoted)、続けて -e の AppleScript
            // ソース文字列リテラルとして (appleScriptQuoted) の 2 段階でエスケープする。
            let shellSafe = shellQuoted(scriptPath)
            let source = "do shell script \"\(appleScriptQuoted(shellSafe))\" with administrator privileges"
            process.arguments = ["-e", source]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                complete(.failure(.scriptFailed(exitCode: -1)), completion)
                return
            }
            process.waitUntilExit()

            let status = process.terminationStatus
            if status == 0 {
                complete(.success(()), completion)
                return
            }

            // キャンセル時の終了コードへの写像は環境依存のため、終了コードと stderr の両方を見る。
            let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if status == -128 || stderrText.contains("-128") {
                complete(.failure(.cancelled), completion)
            } else {
                complete(.failure(.scriptFailed(exitCode: status)), completion)
            }
        }
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// completion は必ずメインキュー上で呼ぶ契約にする (installOrUpdate/uninstall はバックグラウンド
    /// キューで実行されるため)。
    private static func complete(_ result: Result<Void, ActionError>, _ completion: @escaping @MainActor (Result<Void, ActionError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}
