import Foundation

/// 専用ドライバのインストール/更新/アンインストールフロー。安全性ガード・実行・
/// 成功時の再検出リトライを一元化する。
final class DriverInstallCoordinator: Sendable {
    enum ActionError: Error {
        /// 自ドライバのデバイスがデフォルト出力のままで安全な実デバイスへ切り替えられなかった。
        /// 実行本体はまだ呼んでいない。
        case outputDeviceSwitchFailed
        case executionFailed(DriverInstaller.ActionError)
    }

    private let outputController: OutputDeviceController
    private let audioWorld: AudioWorld

    /// 技術的なタイミング吸収のための暫定値。実機検証で調整すること。
    private static let reprobeMaxAttempts = 5
    private static let reprobeRetryInterval: TimeInterval = 0.4

    init(outputController: OutputDeviceController, audioWorld: AudioWorld) {
        self.outputController = outputController
        self.audioWorld = audioWorld
    }

    /// 実行前に安全性ガードを通し、安全が確認できた場合のみ beforeExecuting を呼んでから実行する。
    /// afterReprobe は再検出と同じキュー entry の中で呼ばれる。成功時は再検出結果を completion に
    /// 渡す (音声エンジン自体はライブ再初期化しない。EQ 処理の再開には再起動を要する)。
    /// completion は必ずメインキュー上で呼ぶ。
    func installOrUpdate(
        beforeExecuting: @escaping @Sendable (AudioWorldToken) -> Void = { _ in },
        afterReprobe: @escaping @Sendable (AudioWorldToken) -> Void = { _ in },
        completion: @escaping @MainActor (Result<DriverProbe, ActionError>) -> Void
    ) {
        audioWorld.submitUncoalesced { [weak self] token in
            guard let self else { return }
            guard self.outputController.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: DriverConfig.deviceUID, token) else {
                DispatchQueue.main.async { completion(.failure(.outputDeviceSwitchFailed)) }
                return
            }
            beforeExecuting(token)
            DriverInstaller.installOrUpdate { result in
                switch result {
                case .success:
                    self.audioWorld.submitUncoalesced { reprobeToken in
                        let probe = Self.refreshDriverProbeAfterInstall()
                        afterReprobe(reprobeToken)
                        DispatchQueue.main.async { completion(.success(probe)) }
                    }
                case .failure(let error):
                    DispatchQueue.main.async { completion(.failure(.executionFailed(error))) }
                }
            }
        }
    }

    /// 成功時は再プローブせず未検出へ確定させて completion に渡す
    /// (アンインストールの成功はドライバの不在を意味する結果が1通りしかない)。
    func uninstall(
        beforeExecuting: @escaping @Sendable (AudioWorldToken) -> Void = { _ in },
        afterReprobe: @escaping @Sendable (AudioWorldToken) -> Void = { _ in },
        completion: @escaping @MainActor (Result<DriverProbe, ActionError>) -> Void
    ) {
        audioWorld.submitUncoalesced { [weak self] token in
            guard let self else { return }
            guard self.outputController.ensureDefaultOutputIsSafeToMutateDriver(driverDeviceUID: DriverConfig.deviceUID, token) else {
                DispatchQueue.main.async { completion(.failure(.outputDeviceSwitchFailed)) }
                return
            }
            beforeExecuting(token)
            DriverInstaller.uninstall { result in
                switch result {
                case .success:
                    self.audioWorld.submitUncoalesced { reprobeToken in
                        afterReprobe(reprobeToken)
                        DispatchQueue.main.async { completion(.success(.versionsUnreadable(.notFound))) }
                    }
                case .failure(let error):
                    DispatchQueue.main.async { completion(.failure(.executionFailed(error))) }
                }
            }
        }
    }

    private static func refreshDriverProbeAfterInstall() -> DriverProbe {
        resolveDriverProbeWithRetry(
            maxAttempts: reprobeMaxAttempts,
            probe: { DriverProbe(openResult: SharedRingReader.open(path: DriverConfig.sharedMemoryPath)) },
            wait: { Thread.sleep(forTimeInterval: reprobeRetryInterval) }
        )
    }

    /// probe が可用と答えるまで、最大 maxAttempts 回まで wait を挟んで再試行する。
    /// ドライバを入れ替えた直後は、新しいドライバが共有領域を作り直すまでの間だけ版ずれが観測されうる
    /// (この経路は今観測した値がひとりでに変わることが期待できる唯一の場所)。
    static func resolveDriverProbeWithRetry(
        maxAttempts: Int, probe: () -> DriverProbe, wait: () -> Void
    ) -> DriverProbe {
        var latest = probe()
        var attempt = 0
        while latest.availability != .ok && attempt < maxAttempts {
            wait()
            latest = probe()
            attempt += 1
        }
        return latest
    }
}
