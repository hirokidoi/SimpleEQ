import Foundation

/// アプリバージョン。バンドルの情報から読む口をここ 1 つに閉じる。
enum AppVersion {
    static let unavailableText = unreadableValue

    static var text: String {
        text(infoDictionary: Bundle.main.infoDictionary)
    }

    static func text(infoDictionary: [String: Any]?) -> String {
        infoDictionary?[shortVersionKey] as? String ?? unavailableText
    }

    private static let shortVersionKey = "CFBundleShortVersionString"
}
