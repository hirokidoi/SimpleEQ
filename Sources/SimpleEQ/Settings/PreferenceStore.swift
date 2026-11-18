import Foundation

/// 設定の保存先。検証はメモリ上の入れ物に差し替える。
protocol PreferenceStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}
