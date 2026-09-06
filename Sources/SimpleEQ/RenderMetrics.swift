import Foundation

/// 描画クロック (ビジュアライザと Mixer メーター) の観測量の保持先。
/// 表示値ではないため @Published を通さない。
@MainActor
final class RenderMetrics {
    /// 頻度を確定させる観測窓の長さ (秒)。
    nonisolated static let windowSeconds: Double = 0.5

    /// 格納するのは Sendable な値だけ (書き出しの経路で非メインのクロージャへ渡る)。
    /// 頻度はいずれも、駆動していない間と窓が満ちるまでの間は nil。
    struct Snapshot: Equatable {
        let visualizerSettingFps: Double
        let visualizer: Visualizer
        let mixerEffectiveFps: Double
        let mixer: Mixer

        struct Visualizer: Equatable {
            let running: Bool
            /// idle へ落ちた先を含む、適用中の刻み。
            let scheduledFps: Double?
            let firedFps: Double?
            let appliedFps: Double?
        }

        struct Mixer: Equatable {
            let running: Bool
            let firedFps: Double?
        }
    }

    private var visualizer = ClockState()
    private var mixer = ClockState()
    private let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { uptimeSeconds() }) {
        self.now = now
    }

    // MARK: - 記録

    func visualizerDidStart(scheduledFps: Double) {
        visualizer.start(scheduledFps: scheduledFps, at: now())
    }

    func visualizerDidFire(applied: Bool) {
        visualizer.fire(applied: applied, at: now())
    }

    func visualizerDidStop() {
        visualizer.stop()
    }

    func mixerDidStart() {
        mixer.start(scheduledFps: nil, at: now())
    }

    func mixerDidFire() {
        mixer.fire(applied: true, at: now())
    }

    func mixerDidStop() {
        mixer.stop()
    }

    // MARK: - 読み出し

    func snapshot(visualizerFps: Double) -> Snapshot {
        Snapshot(
            visualizerSettingFps: visualizerFps,
            visualizer: visualizer.visualizerSnapshot(),
            mixerEffectiveFps: MixerRenderClock.fps(visualizerFps: visualizerFps),
            mixer: mixer.mixerSnapshot()
        )
    }

    /// 窓は時刻で区切る。起点を窓の最初の発火時刻に取ると、発火が 1 つ多く数えられて 1/窓長 ぶん過大になる。
    private struct ClockState {
        private var running = false
        private var scheduledFps: Double?
        private var windowStart: TimeInterval?
        private var firedCount = 0
        private var appliedCount = 0
        private var firedFps: Double?
        private var appliedFps: Double?

        mutating func start(scheduledFps: Double?, at now: TimeInterval) {
            self = ClockState()
            running = true
            self.scheduledFps = scheduledFps
            openWindow(at: now)
        }

        mutating func fire(applied: Bool, at now: TimeInterval) {
            guard let windowStart else { return }
            firedCount += 1
            if applied { appliedCount += 1 }
            let elapsed = now - windowStart
            guard elapsed >= RenderMetrics.windowSeconds else { return }
            firedFps = Double(firedCount) / elapsed
            appliedFps = Double(appliedCount) / elapsed
            openWindow(at: now)
        }

        mutating func stop() {
            self = ClockState()
        }

        func visualizerSnapshot() -> Snapshot.Visualizer {
            Snapshot.Visualizer(
                running: running, scheduledFps: scheduledFps,
                firedFps: firedFps, appliedFps: appliedFps
            )
        }

        func mixerSnapshot() -> Snapshot.Mixer {
            Snapshot.Mixer(running: running, firedFps: firedFps)
        }

        private mutating func openWindow(at now: TimeInterval) {
            windowStart = now
            firedCount = 0
            appliedCount = 0
        }
    }
}
