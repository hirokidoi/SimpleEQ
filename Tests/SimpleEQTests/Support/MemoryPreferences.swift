import Foundation
@testable import SimpleEQ

/// メモリ上の設定の入れ物。UserDefaults の suite は cfprefsd に再起動まで残り続けるので、検証では使わない。
final class MemoryPreferences: PreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? {
        lock.withLock { values[defaultName] } as? Data
    }

    /// UserDefaults は property list でない値で例外になるので、検証でも同じ値を止める。
    func set(_ value: Any?, forKey defaultName: String) {
        precondition(
            value.map { PropertyListSerialization.propertyList($0, isValidFor: .binary) } ?? true,
            "property list でない値を \(defaultName) に保存しようとした"
        )
        lock.withLock { values[defaultName] = value }
    }
}
