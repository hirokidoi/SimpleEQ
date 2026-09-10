import AppKit
import Combine
import CoreGraphics

/// 画面が利用者から見えているかを答える。判定は毎回 OS の実状態を読み、通知は読み直す契機としてのみ使う。
///
/// 外部ディスプレイのバックライトを DDC で落とす経路は OS を通らないため、ここでは検知できない。
@MainActor
final class ScreenVisibility {
    /// console を持たない側は遠隔から見られており、物理ディスプレイは見えているかを表さない。
    /// 代わりに音声経路を持つかで決める (見るに値する絵はそちらだけ)。
    static func isVisible(locked: Bool, mainDisplayAsleep: Bool, onConsole: Bool, ownsAudioPath: Bool) -> Bool {
        guard !locked else { return false }
        return onConsole ? !mainDisplayAsleep : ownsAudioPath
    }

    private(set) var locked: Bool
    private(set) var mainDisplayAsleep: Bool
    private(set) var onConsole: Bool
    private(set) var ownsAudioPath = false
    var screenIsVisible: Bool {
        Self.isVisible(locked: locked, mainDisplayAsleep: mainDisplayAsleep, onConsole: onConsole, ownsAudioPath: ownsAudioPath)
    }

    func updateOwnsAudioPath(_ value: Bool) {
        guard ownsAudioPath != value else { return }
        ownsAudioPath = value
        notify()
    }

    /// OS の購読と読み直しは 1 組で足りるので、届け先の数だけ増やさない。
    func addObserver(_ handler: @escaping () -> Void) { observers.append(handler) }

    private var observers: [() -> Void] = []
    private func notify() { for observer in observers { observer() } }
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        let state = Self.readActualState()
        locked = state.locked
        mainDisplayAsleep = state.mainDisplayAsleep
        onConsole = state.onConsole

        let workspace = NSWorkspace.shared.notificationCenter
        let triggers: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            // 復帰の通知より実状態の方が遅れることがあり、その回は止まったままになる。これがその出口。
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in triggers {
            center.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                .store(in: &subscriptions)
        }
    }

    /// 変化検出は構成要素ごとに行う (合成値だけでは見落とす組み合わせがある)。
    private func refresh() {
        let updated = Self.readActualState()
        guard updated.locked != locked || updated.mainDisplayAsleep != mainDisplayAsleep || updated.onConsole != onConsole else { return }
        locked = updated.locked
        mainDisplayAsleep = updated.mainDisplayAsleep
        onConsole = updated.onConsole
        notify()
    }

    /// 画面のロック・ディスプレイ休止は読めない値を見えている側へ倒す。誤って見えていないと判定すると絵が止まったままになる。
    /// console 判定が読めない値は console である側へ倒す。
    private static func readActualState() -> (locked: Bool, mainDisplayAsleep: Bool, onConsole: Bool) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (
            locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            mainDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool ?? true
        )
    }
}
