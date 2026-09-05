enum ProcessingState: Equatable {
    case active
    case suspended(SuspensionCause)
}

/// 停止の種別を表す識別子。
/// 文言・再開手順などの意味的データは持たず、種別ごとの扱いの違いはすべて対応表へ切り出す。
enum SuspensionCause: Equatable, CaseIterable {
    /// 共有メモリまたは安全な出力先のいずれかが揃わず、音声経路を構成できない。
    case routeUnavailable
    /// ドライバのインストール/更新/アンインストールに伴う停止。
    case driverOperation
    /// アプリ終了に伴う停止。
    case applicationTermination
}

/// 停止種別ごとの扱いの対応表。識別子と意味的データを分離するための集約先。
enum SuspensionPolicy {
    static func allowsSelectionResume(_ cause: SuspensionCause) -> Bool {
        switch cause {
        case .routeUnavailable: return true
        case .driverOperation, .applicationTermination: return false
        }
    }

    /// 自動再開を許す種別は必ず選び直しでの再開を許す種別に含まれる (逆は成り立たなくてよい)。
    static func allowsAutomaticResume(_ cause: SuspensionCause) -> Bool {
        switch cause {
        case .routeUnavailable: return true
        case .driverOperation, .applicationTermination: return false
        }
    }

    /// 停止中に維持しない種別 (再起動を前提とする停止) で維持すると、
    /// 誰も消費しないデバイスを一覧に残したまま戻す手段が無くなる。
    static func maintainsDriverVisibility(_ state: ProcessingState) -> Bool {
        switch state {
        case .active: return true
        case .suspended(let cause): return maintainsDriverVisibility(cause)
        }
    }

    private static func maintainsDriverVisibility(_ cause: SuspensionCause) -> Bool {
        switch cause {
        case .routeUnavailable: return true
        case .driverOperation, .applicationTermination: return false
        }
    }
}
