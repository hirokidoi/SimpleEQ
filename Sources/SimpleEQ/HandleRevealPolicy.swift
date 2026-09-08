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

    /// ポインタの居場所が表示を保つか。押下の起点はこれだけを見る。
    static func staysRevealedAt(pointerInsideCanvas: Bool, pointerOverPresetRail: Bool) -> Bool {
        pointerInsideCanvas || pointerOverPresetRail
    }

    static func staysRevealed(
        pointerButtonDown: Bool, pointerInsideCanvas: Bool, pointerOverPresetRail: Bool
    ) -> Bool {
        pointerButtonDown
            || staysRevealedAt(
                pointerInsideCanvas: pointerInsideCanvas, pointerOverPresetRail: pointerOverPresetRail
            )
    }

    /// ポインタを 1 回読み直したときの行方。
    static func advanced(
        holdRemaining: Double, dt: Double, holdSeconds: Double,
        staysRevealed: Bool, windowIsKey: Bool
    ) -> (holdRemaining: Double, revealed: Bool) {
        // 前面から外れた窓に編集モードを残しても操作へは繋がらないため、猶予を挟まない。
        guard windowIsKey else { return (0, false) }
        guard !staysRevealed else { return (holdSeconds, true) }
        let remaining = max(0, holdRemaining - dt)
        return (remaining, remaining > 0)
    }
}
