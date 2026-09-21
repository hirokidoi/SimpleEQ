import AppKit
import Foundation

/// 連続クリックを 1 つの列として扱うための規則。
enum ClickSequencePolicy {
    static func startsNewSequence(
        now: Date, location: CGPoint, lastPressAt: Date?, lastPressLocation: CGPoint?,
        interval: TimeInterval = NSEvent.doubleClickInterval,
        maxDrift: CGFloat = EQLayout.clickSequenceMaxDrift
    ) -> Bool {
        guard let lastPressAt, let lastPressLocation else { return true }
        guard now.timeIntervalSince(lastPressAt) <= interval else { return true }
        return hypot(location.x - lastPressLocation.x, location.y - lastPressLocation.y) > maxDrift
    }
}
