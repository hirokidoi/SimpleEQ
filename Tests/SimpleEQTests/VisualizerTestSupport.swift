import AppKit
import Foundation
@testable import SimpleEQ

let silentStereoSnapshot = LevelMeter.Snapshot.Stereo(
    leftDb: LevelMeter.silentLevelDb, rightDb: LevelMeter.silentLevelDb,
    leftPeakDb: LevelMeter.silentLevelDb, rightPeakDb: LevelMeter.silentLevelDb
)

/// 条件が満たされるまで実時間で RunLoop を回す (満たされなければ時間切れまで回す)。
func pumpRunLoopUntil(_ satisfied: () -> Bool, timeout: TimeInterval = 2.0) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, !satisfied() {
        RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.02), deadline))
    }
}

/// 解析を経ずに表示値を注入し、アプリと同じ pull 経路で ViewModel へ取り込ませる。
@MainActor
func pushMeterSnapshotForTesting(_ snapshot: LevelMeter.Snapshot, vm: EQViewModel, engine: AudioEngine) {
    engine.levelMeter.setSnapshotForTesting(snapshot)
    vm.tick(now: Date(timeIntervalSinceReferenceDate: 0))
}

extension VisualizerHostView {
    /// テストの実行中は実際のマウス位置に左右されないよう、ポインタの状態を固定する。
    func pinPointer(toScreenPoint point: NSPoint, buttonDown: Bool = false) {
        pointerState = { (point, buttonDown) }
    }

    /// ウィンドウが決まる前でも使えるよう、描画領域の中央を毎回求め直す。
    func pinPointerInsideVisualizeArea() {
        pointerState = { [weak self] in
            guard let self, let window = self.window else { return (.zero, false) }
            let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            return (window.convertPoint(toScreen: self.convert(center, to: nil)), false)
        }
    }
}
