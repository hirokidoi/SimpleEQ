import ServiceManagement

/// ログイン時自動起動の登録状態を SMAppService.mainApp 経由で管理する。
/// SMAppService は `.app` バンドルとして安定パスに配置されていることを前提とする。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            print("[warn] LoginItem.setEnabled(\(enabled)) failed: \(error)")
        }
        if enabled && service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
