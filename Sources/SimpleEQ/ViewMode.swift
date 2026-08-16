/// EQ ウィンドウの中身の見せ方。
enum ViewMode: String, Codable, CaseIterable {
    case normal
    case compact

    /// 利用者へ出す呼称。
    var title: String {
        switch self {
        case .normal: "ノーマル"
        case .compact: "コンパクト"
        }
    }

    /// このビューへ切り替える操作の文言。
    var switchActionTitle: String { "\(title)ビューに切り替え" }

    var toggled: ViewMode {
        self == .normal ? .compact : .normal
    }
}
