import SwiftUI

/// 取り込み口 (専用ドライバ) の行。選択の余地が無いため Picker ではなく、製品としての名前+
/// ドライバ検出状態の表示専用行にする。インストール/更新/アンインストールは viewModel 経由で
/// アプリ内から直接実行する (管理者権限は都度 osascript のダイアログで昇格する)。音声エンジン
/// 自体はここでライブ再初期化されないため、EQ 処理の再開にはアプリの再起動を要する。
struct DriverStatusRow: View {
    @ObservedObject var viewModel: EQViewModel
    @State private var driverActionState: DriverActionState = .idle
    @State private var showingInstallOrUpdateConfirmation = false
    @State private var showingUninstallConfirmation = false
    @State private var showingRestartPrompt = false
    /// 実行を始める前に控える。成功すると可用性が変わり、ボタンの名前が次にできる操作を指す。
    @State private var completedOperationTitle = ""

    private var isDriverActionBusy: Bool { driverActionState == .running }
    /// ドライバ可用性が確認中の間は両ボタンを無効化する。
    private var isDriverAvailabilityPending: Bool { viewModel.driverAvailability == .checking }
    /// オーディオ世界が応答していない間は両ボタンを無効化する。押しても完了の通知が届かず、
    /// スピナーが回り続けたまま以後の操作も受け付けなくなるため。
    private var isAudioWorldUnresponsive: Bool { viewModel.audioWorldUnresponsive }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text(viewModel.driverDeviceName)
                    .font(.system(size: 13))
                Text(driverStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(driverStatusColor)
            }
            if let driverVersionText {
                Text(driverVersionText)
                    .font(.system(size: 11.5))
                    .foregroundColor(EQLayout.Palette.faint)
            }
            HStack(spacing: 8) {
                driverActionButton(
                    title: driverPrimaryActionTitle, enabled: !isDriverActionBusy && !isDriverAvailabilityPending && !isAudioWorldUnresponsive,
                    action: { showingInstallOrUpdateConfirmation = true }
                )
                // 削除対象が存在しない状態でのアンインストール実行を防ぐため、
                // 主操作ボタンと同じ可用性に活性状態を連動させる。
                driverActionButton(
                    title: "アンインストール",
                    enabled: !isDriverActionBusy && !isDriverAvailabilityPending && !isAudioWorldUnresponsive && viewModel.driverAvailability != .notFound,
                    action: { showingUninstallConfirmation = true }
                )
                if driverActionState == .running {
                    ProgressView().controlSize(.small)
                }
            }
            if let driverActionResultText {
                Text(driverActionResultText)
                    .font(.system(size: 11.5))
                    .foregroundColor(EQLayout.Palette.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // インストール/更新/アンインストールはいずれも、ガード通過が確定した時点で専用ドライバに
        // 対する音声エンジンの接続を解放し、EQ を停止させる。そのため両操作とも実行前にアプリ側の
        // 確認アラートを挟み、誤操作による意図しない EQ 停止を防ぐ。
        .destructiveConfirmationAlert(
            "専用ドライバを\(driverPrimaryActionTitle)しますか？", isPresented: $showingInstallOrUpdateConfirmation,
            confirmTitle: driverPrimaryActionTitle, onConfirm: runInstallOrUpdate
        )
        .destructiveConfirmationAlert(
            "専用ドライバをアンインストールしますか？", isPresented: $showingUninstallConfirmation,
            confirmTitle: "アンインストール", onConfirm: runUninstall
        )
        .confirmationAlert(
            DriverOperationPrompt.restartHeadline(operationTitle: completedOperationTitle),
            message: DriverOperationPrompt.restartMessage, isPresented: $showingRestartPrompt,
            confirmTitle: DriverOperationPrompt.restartConfirmTitle, onConfirm: AppRelaunch.relaunch
        )
    }

    private var driverStatusText: String {
        switch viewModel.driverAvailability {
        case .checking: return "確認中"
        case .ok: return "検出済み"
        case .notFound: return "未検出"
        case .versionMismatch: return "更新が必要"
        }
    }

    /// ドライババージョンと、ドライバが共有ヘッダへ書いたレイアウトバージョン。どちらも読めない
    /// 場合は行そのものを出さない。
    private var driverVersionText: String? {
        let probe = viewModel.driverProbe
        guard probe.hasReadableVersions else { return nil }
        let version = probe.driverVersion?.text ?? unreadableValue
        let layout = probe.layoutVersion.map { "\($0)" } ?? unreadableValue
        return "Version: \(version) / Layout: \(layout)"
    }



    private var driverStatusColor: Color {
        switch viewModel.driverAvailability {
        case .checking, .ok: return EQLayout.Palette.faint
        case .notFound, .versionMismatch: return EQLayout.Palette.danger
        }
    }

    private var driverPrimaryActionTitle: String {
        DriverOperationPrompt.actionTitle(for: viewModel.driverAvailability)
    }

    private var driverActionResultText: String? {
        switch driverActionState {
        case .idle, .running: return nil
        case .succeeded: return "完了しました。アプリの再起動が必要です。"
        case .failedNeedsRestart: return "EQ は停止しています。アプリの再起動が必要です。"
        case .failedNoChange: return "失敗しました。"
        }
    }

    private func runInstallOrUpdate() {
        driverActionState = .running
        let operationTitle = driverPrimaryActionTitle
        viewModel.installOrUpdateDriver { applyDriverActionResult($0, restartOffer: operationTitle) }
    }

    private func runUninstall() {
        driverActionState = .running
        viewModel.uninstallDriver { applyDriverActionResult($0, restartOffer: nil) }
    }

    /// completion は必ずメインキュー上で呼ばれる契約のため、ここでは追加のディスパッチを
    /// 行わずそのまま @State を更新する。restartOffer は、成功したときに再起動を尋ねる操作の名前
    /// (尋ねない操作では nil)。
    private func applyDriverActionResult(
        _ result: Result<Void, DriverInstallCoordinator.ActionError>, restartOffer operationTitle: String?
    ) {
        switch result {
        case .success:
            driverActionState = .succeeded
            if let operationTitle {
                completedOperationTitle = operationTitle
                showingRestartPrompt = true
            }
        case .failure(.outputDeviceSwitchFailed):
            driverActionState = .failedNoChange
        case .failure(.executionFailed):
            driverActionState = .failedNeedsRestart
        }
    }

    private func driverActionButton(title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(EQLayout.Palette.faint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(EQLayout.Palette.buttonLine, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// ドライバ行 (DriverStatusRow) の実行状態。running 中は主操作/アンインストール両ボタンを disabled
/// にして ProgressView を隣に添え、succeeded/failedNeedsRestart/failedNoChange は完了メッセージの
/// 表示のみに使う (次の操作で idle へ戻る)。
private enum DriverActionState: Equatable {
    case idle
    case running
    case succeeded
    case failedNeedsRestart
    case failedNoChange
}
