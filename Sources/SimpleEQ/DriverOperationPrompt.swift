import Foundation

/// ドライバ操作の呼び名と、操作の後に再起動を尋ねる問い。再起動を尋ねるのはドライバを
/// 置き換えられた場合だけ (アンインストール後は再起動しても EQ は復帰しない)。
enum DriverOperationPrompt {

    static func actionTitle(for availability: DriverAvailability) -> String {
        switch availability {
        case .checking: return "確認中"
        case .notFound: return "インストール"
        case .versionMismatch: return "更新"
        case .ok: return "再インストール"
        }
    }

    static func restartHeadline(operationTitle: String) -> String {
        "\(operationTitle)が完了しました"
    }

    static let restartMessage = "EQ処理を再開するにはアプリの再起動が必要です。今すぐ再起動しますか？"
    static let restartConfirmTitle = "再起動"
}
