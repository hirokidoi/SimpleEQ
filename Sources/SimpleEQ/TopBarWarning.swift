/// 上部バーの警告の識別子。識別子だけを表し、文言・誘導先は持たない。表示内容は
/// 対応表として別に持つ。
enum TopBarWarningIdentifier: Equatable {
    /// 音に関わる資源を持つ直列キューが応答していない。
    case audioWorldUnresponsive
    /// 専用ドライバが見つからない。
    case driverNotFound
    /// 専用ドライバのレイアウトバージョンが一致しない。
    case driverVersionMismatch
    /// 音声経路を構成できずに停止しており、出力先の選び直しで再開できる。
    case outputRouteSelectionRequired
    /// 再起動を前提とする停止 (ドライバ操作・アプリ終了) 中である。
    case restartRequired
    /// ドライバは見つかっているが、音が届いていない。共有メモリへの書き込みが直近で停止している場合と、
    /// システムのデフォルト出力から自ドライバへ音が届かない場合の両方を表す。
    case audioUnavailable
}

/// 上部バーの警告の誘導先。
enum TopBarWarningDestination: Equatable {
    /// 誘導先を持たない (是正手段が上部バー自身にある)。
    case none
    /// Settings 画面を開く。
    case settings
}

/// 上部バーの警告チップの表示内容 (文言 + 誘導先)。View から定数を直参照させないための型。
struct TopBarWarningContent: Equatable {
    let message: String
    let destination: TopBarWarningDestination
}

/// 上部バーの警告優先順位の判定本体 (CoreAudio に触れない純粋関数、ユニットテスト対象)。
/// 応答なしを最優先に置くのは、他の判定がいずれも値の更新が続いていることを前提にするため。
/// 音声取得失敗 (共有メモリへの書き込み停止 / 出力デバイス制御の到達判定の否定) は経路が違っても同じ識別子で表す。
func topBarWarningIdentifier(
    driverAvailability: DriverAvailability, processingState: ProcessingState, ringStalled: Bool,
    defaultOutputReachesDriver: Bool, audioWorldUnresponsive: Bool, startupActivationSettled: Bool
) -> TopBarWarningIdentifier? {
    if audioWorldUnresponsive { return .audioWorldUnresponsive }
    switch driverAvailability {
    // 確認中は表示がまだ確定していないため警告を出さない。
    case .checking: return nil
    case .notFound: return .driverNotFound
    case .versionMismatch: return .driverVersionMismatch
    case .ok: break
    }
    if case .suspended(let cause) = processingState {
        switch cause {
        case .routeUnavailable:
            // 起動の最初の組み立てを終えるまでは、まだ何も試していない状態を異常として伝えない。
            return startupActivationSettled ? .outputRouteSelectionRequired : nil
        case .driverOperation, .applicationTermination: return .restartRequired
        }
    }
    return (ringStalled || !defaultOutputReachesDriver) ? .audioUnavailable : nil
}

/// 識別子から表示内容 (文言・誘導先) を引く対応表。
enum TopBarWarningPolicy {
    static func content(for identifier: TopBarWarningIdentifier) -> TopBarWarningContent {
        switch identifier {
        case .audioWorldUnresponsive:
            // 是正手段がアプリの中に無い (相手は音声系の常駐)。誘導先を持たせても行き先が無いため
            // 状態を伝えるに留める。
            return TopBarWarningContent(message: "音声システムが応答していません", destination: .none)
        case .driverNotFound:
            return TopBarWarningContent(message: "ドライバが見つかりません", destination: .settings)
        case .driverVersionMismatch:
            return TopBarWarningContent(message: "ドライバの更新が必要です", destination: .settings)
        case .outputRouteSelectionRequired:
            // Settings の出力デバイス選択は次回起動の既定値だけを変えるため、そこへは送らない。
            return TopBarWarningContent(message: "出力先を選び直してください", destination: .none)
        case .restartRequired:
            return TopBarWarningContent(message: "再起動が必要です", destination: .settings)
        case .audioUnavailable:
            return TopBarWarningContent(message: "音声を取得できません", destination: .none)
        }
    }
}
