import AppKit
import Combine
import CoreGraphics

/// 画面が利用者から見えているかを答える。判定は毎回 OS の実状態を読み、通知は読み直す契機としてのみ使う。
///
/// 外部ディスプレイのバックライトを DDC で落とす経路は OS を通らないため、ここでは検知できない。
@MainActor
final class ScreenVisibility {
    /// 3 つは同時には動かず、先後も一定しない。
    static func isVisible(locked: Bool, mainDisplayAsleep: Bool, onConsole: Bool) -> Bool {
        !locked && !mainDisplayAsleep && onConsole
    }

    private(set) var screenIsVisible: Bool
    private let onChange: () -> Void
    private var subscriptions: Set<AnyCancellable> = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        screenIsVisible = Self.readActualState()

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

    private func refresh() {
        let updated = Self.readActualState()
        guard updated != screenIsVisible else { return }
        screenIsVisible = updated
        onChange()
    }

    /// 読めない値は見えている側へ倒す。誤って見えていないと判定すると絵が止まったままになる。
    private static func readActualState() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return isVisible(
            locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            mainDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool ?? true
        )
    }
}
