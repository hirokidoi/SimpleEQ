import CoreAudio
import Foundation

protocol ActivatableAudioEngine: AnyObject, Sendable {
    var processingState: ProcessingState { get }
    @discardableResult
    func assemble(outputDevice: ResolvedOutputDevice, ringReader: SharedRingReader, driverDeviceID: AudioDeviceID?, _ token: AudioWorldToken) -> Bool
}

extension AudioEngine: ActivatableAudioEngine {}
extension AudioEngine: MixerAudioBridge {}

struct AudioActivationOutcome: Equatable {
    let processingState: ProcessingState
    /// この試行で実際に採用された出力デバイス (組み立てまで成功した場合のみ非 nil)。
    let activeOutputDevice: ResolvedOutputDevice?
    /// 共有メモリは開けたが、出力の経路を確立できずに終わったか。稼働状態からは判別できない
    /// (共有メモリを開けずに早入りで終わった場合と同じ値になるため)。
    let outputRouteNotEstablished: Bool
}

enum ResumeTrigger {
    case userSelection
    case automatic
}

enum ActivationAttempt: Equatable {
    case launch
    case resume
}

/// 起動と再開が共有する手順。手順だけを持ち状態は持たない (状態は別に持つ)。
final class AudioActivationCoordinator: Sendable {
    /// 技術的な待ち時間の暫定値。実機検証で調整すること。
    private static let headerInvalidRetryMaxAttempts = 5
    private static let headerInvalidRetryInterval: TimeInterval = 0.4

    private let engine: ActivatableAudioEngine
    private let driverLifecycle: DriverLifecycleController
    private let outputController: OutputDeviceController
    private let openSharedMemory: @Sendable () -> Result<SharedRingReader, SharedRingReader.OpenFailure>
    /// 再試行の合間の待機。テストが実時間を消費せずに再試行の配線を検証するための注入口。
    private let waitBeforeRetry: @Sendable () -> Void

    init(
        engine: ActivatableAudioEngine,
        driverLifecycle: DriverLifecycleController,
        outputController: OutputDeviceController,
        openSharedMemory: @escaping @Sendable () -> Result<SharedRingReader, SharedRingReader.OpenFailure> = {
            SharedRingReader.open(path: DriverConfig.sharedMemoryPath)
        },
        waitBeforeRetry: @escaping @Sendable () -> Void = {
            Thread.sleep(forTimeInterval: AudioActivationCoordinator.headerInvalidRetryInterval)
        }
    ) {
        self.engine = engine
        self.driverLifecycle = driverLifecycle
        self.outputController = outputController
        self.openSharedMemory = openSharedMemory
        self.waitBeforeRetry = waitBeforeRetry
    }

    /// 共有メモリを開く → 未掌握なら可視化 → 未占有ならデフォルト出力を切替 → 出力先を解決 → エンジンを組み立てる。
    /// 解決・組み立てに失敗した場合、この試行で切替を行っていればのみ復帰させる。
    /// attempt が .launch のときだけヘッダ無効を再試行する (.resume は繰り返し通るため待たない)。
    @discardableResult
    func activate(
        resolveOutputDevice: (AudioWorldToken) -> ResolvedOutputDevice?,
        attempt: ActivationAttempt,
        _ token: AudioWorldToken
    ) -> AudioActivationOutcome {
        let openResult = attempt == .launch
            ? Self.openRetryingHeaderInvalid(
                maxAttempts: Self.headerInvalidRetryMaxAttempts,
                probe: openSharedMemory,
                wait: waitBeforeRetry
            )
            : openSharedMemory()
        guard let ringReader = try? openResult.get() else {
            return outcome(activeOutputDevice: nil)
        }

        let driverDeviceID = driverLifecycle.resolvedDeviceID ?? driverLifecycle.resolveAndMakeVisible(token)

        let switchedOutput = outputController.occupiesDefaultOutput(token)
            ? false
            : outputController.occupyDefaultOutputForDriver(driverDeviceID: driverDeviceID, token)

        guard let outputDevice = resolveOutputDevice(token) else {
            if switchedOutput { outputController.restore(token) }
            return outcome(activeOutputDevice: nil, outputRouteNotEstablished: true)
        }

        guard engine.assemble(outputDevice: outputDevice, ringReader: ringReader, driverDeviceID: driverDeviceID, token) else {
            if switchedOutput { outputController.restore(token) }
            return outcome(activeOutputDevice: nil, outputRouteNotEstablished: true)
        }

        return outcome(activeOutputDevice: outputDevice)
    }

    /// ドライバ可用性とバージョンを確定する。
    /// 共有メモリを開く結果だけから導かれ CoreAudio を呼ばないため、
    /// 音に関わる資源を持つ直列キューの上で呼ばないこと (呼ぶと確定が coreaudiod の応答待ちに巻き込まれる)。
    /// 待ちを含むのでメインスレッドでも呼ばないこと。
    func probeDriver() -> DriverProbe {
        DriverProbe(openResult: Self.openRetryingHeaderInvalid(
            maxAttempts: Self.headerInvalidRetryMaxAttempts,
            probe: openSharedMemory,
            wait: waitBeforeRetry
        ))
    }

    /// 現在の停止種別が再開を許す場合にのみ activate を試みる。
    @discardableResult
    func resume(outputDevice: ResolvedOutputDevice, trigger: ResumeTrigger, _ token: AudioWorldToken) -> AudioActivationOutcome {
        guard case .suspended(let cause) = engine.processingState else {
            return AudioActivationOutcome(
                processingState: engine.processingState, activeOutputDevice: nil, outputRouteNotEstablished: false
            )
        }
        let allowed: Bool
        switch trigger {
        case .userSelection: allowed = SuspensionPolicy.allowsSelectionResume(cause)
        case .automatic: allowed = SuspensionPolicy.allowsAutomaticResume(cause)
        }
        guard allowed else {
            return AudioActivationOutcome(
                processingState: engine.processingState, activeOutputDevice: nil, outputRouteNotEstablished: false
            )
        }
        return activate(resolveOutputDevice: { _ in outputDevice }, attempt: .resume, token)
    }

    /// probe がヘッダ無効を返す限り、最大 maxAttempts 回まで wait を挟んで再試行する。
    /// 成功・ファイル不在・レイアウトバージョン不一致はいずれも安定した実状態とみなし、それ以上は再試行しない
    /// (ファイル不在はドライバが導入されていないことを意味し、待っても変わらない)。
    /// probe/wait をクロージャ注入にすることで実時間を使わず単体テストできる。
    static func openRetryingHeaderInvalid(
        maxAttempts: Int,
        probe: () -> Result<SharedRingReader, SharedRingReader.OpenFailure>,
        wait: () -> Void
    ) -> Result<SharedRingReader, SharedRingReader.OpenFailure> {
        var latest = probe()
        var attempt = 0
        while case .failure(.headerInvalid) = latest, attempt < maxAttempts {
            wait()
            latest = probe()
            attempt += 1
        }
        return latest
    }

    private func outcome(
        activeOutputDevice: ResolvedOutputDevice?, outputRouteNotEstablished: Bool = false
    ) -> AudioActivationOutcome {
        AudioActivationOutcome(
            processingState: engine.processingState, activeOutputDevice: activeOutputDevice,
            outputRouteNotEstablished: outputRouteNotEstablished
        )
    }
}
