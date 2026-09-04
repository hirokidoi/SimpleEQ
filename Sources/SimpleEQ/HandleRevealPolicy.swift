/// ハンドル表示 (ゲインカーブの編集) へ入る操作。
enum HandleRevealGesture: String, Codable, CaseIterable {
    case longPress
    case click

    static let `default`: HandleRevealGesture = .longPress

    /// 利用者へ出す呼称。
    var title: String {
        switch self {
        case .longPress: "長押し"
        case .click: "クリック"
        }
    }
}

/// ハンドル表示を出すか、出したままにするかの判定。
enum HandleRevealPolicy {
    static func revealsOnPress(_ gesture: HandleRevealGesture) -> Bool {
        gesture == .click
    }

    static func staysRevealed(pointerButtonDown: Bool, pointerInsideCanvas: Bool) -> Bool {
        pointerButtonDown || pointerInsideCanvas
    }
}
