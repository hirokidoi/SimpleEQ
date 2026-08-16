import ServiceManagement

/// ログイン時自動起動の登録状態を SMAppService.mainApp 経由で管理する。
/// SMAppService は `.app` バンドルとして安定パスに配置されていることを前提とする。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 失敗時は false を返すのみで例外は投げない。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            print("[warn] LoginItem.setEnabled(\(enabled)) failed: \(error)")
            return false
        }
    }
}
