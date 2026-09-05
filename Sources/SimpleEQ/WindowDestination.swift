import AppKit

/// EQ ウィンドウから開ける独立ウィンドウ。導線が真偽値ではなく開く面そのものを渡すことで、
/// 呼び出し 1 回で意図が読める。
enum WindowDestination {
    case settings
    case diagnostics
}

/// 診断への隠し導線。
/// 現れる条件をここ 1 箇所で決め、
/// 押下時点で読む導線 (プリセットレールの Settings ボタン) とメニューを開く時点で読む導線 (メニューバー) が同じ修飾キーに従うようにする。
enum DiagnosticsEntry {
    static var isRevealed: Bool { NSEvent.modifierFlags.contains(.option) }
}
