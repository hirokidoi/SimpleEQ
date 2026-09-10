import Darwin
import Foundation

/// アプリの特定がどの段で落ちたか。
enum MixerResolutionKind: Equatable, Sendable {
    case privateAPI
    case parentFallback
    case processItself
    case unresolved
}

struct MixerAppIdentity: Equatable, Sendable {
    static let noBundleSubtitle = "バンドルがありません"

    let displayName: String
    let subtitle: String?
    /// アイコンを引く先。バンドルへ遡れなかったときは nil。
    let iconFilePath: String?

    init(displayName: String, subtitle: String? = nil, iconFilePath: String? = nil) {
        self.displayName = displayName
        self.subtitle = subtitle
        self.iconFilePath = iconFilePath
    }
}

struct MixerAppResolution: Equatable, Sendable {
    /// nil は特定できなかったことを表す。
    let channelKey: String?
    let identity: MixerAppIdentity?
    let kind: MixerResolutionKind

    static let unresolved = MixerAppResolution(channelKey: nil, identity: nil, kind: .unresolved)
}

/// クライアントがどのアプリのものかの特定。非公開 API → 親プロセス → 自プロセス → 特定不能、の 4 段で落ちる。
struct MixerAppResolver: Sendable {

    struct BundleInfo: Equatable, Sendable {
        let bundleID: String?
        let displayName: String?

        /// 鳴っている行と鳴っていない行で名前が変わらないよう、バンドルから読む口はここだけにする。
        /// DisplayName を先に見るのは、利用者が Finder で見ている名前と揃えるため。
        static func read(from url: URL) -> Self? {
            guard let bundle = Bundle(url: url) else { return nil }
            let displayName = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            return Self(bundleID: bundle.bundleIdentifier, displayName: displayName)
        }
    }

    struct Environment: Sendable {
        /// nil は「シンボルを引けなかった」。
        /// 宣言を書いて直接呼ぶ形にすると、シンボルが無い OS で起動不能になる。
        var responsibleForPID: (@Sendable (pid_t) -> pid_t)?
        var parentPID: @Sendable (pid_t) -> pid_t?
        var executablePath: @Sendable (pid_t) -> String?
        var bundleInfo: @Sendable (URL) -> BundleInfo?
    }

    let environment: Environment

    var privateAPIAvailable: Bool { environment.responsibleForPID != nil }

    func resolve(pid: pid_t) -> MixerAppResolution {
        let owner = responsibleOwner(of: pid)
        guard let path = environment.executablePath(owner.pid), !path.isEmpty else {
            return .unresolved
        }
        if let url = Self.enclosingBundleURL(executablePath: path),
           let info = environment.bundleInfo(url),
           let bundleID = info.bundleID, !bundleID.isEmpty {
            let name = info.displayName ?? url.deletingPathExtension().lastPathComponent
            return MixerAppResolution(
                channelKey: MixerSpec.bundleKey(bundleID),
                identity: MixerAppIdentity(displayName: name, iconFilePath: url.path),
                kind: owner.kind
            )
        }
        let executableName = (path as NSString).lastPathComponent
        guard !executableName.isEmpty else { return .unresolved }
        return MixerAppResolution(
            channelKey: MixerSpec.processKey(executableName),
            identity: MixerAppIdentity(displayName: executableName, subtitle: MixerAppIdentity.noBundleSubtitle),
            kind: owner.kind
        )
    }

    private func responsibleOwner(of pid: pid_t) -> (pid: pid_t, kind: MixerResolutionKind) {
        if let responsibleForPID = environment.responsibleForPID {
            let responsible = responsibleForPID(pid)
            if responsible > 0, responsible != pid { return (responsible, .privateAPI) }
        }
        // 親が 1 (launchd) なら退避しない。退避すると全 XPC が launchd に潰れる。
        if let parent = environment.parentPID(pid), parent > 1, parent != pid {
            return (parent, .parentFallback)
        }
        return (pid, .processItself)
    }

    private static let bundlePathExtensions = ["app", "appex", "xpc"]

    /// 走行中コードの署名を安定させるために OS が作る複製は `<名前>.app.bundle` を名乗る。
    /// 拡張子 bundle だけを受けると、アプリの内側のプラグインで止まって別のバンドル ID へ落ちる。
    private static func isBundleDirectory(_ url: URL) -> Bool {
        if bundlePathExtensions.contains(url.pathExtension) { return true }
        return url.pathExtension == "bundle" && url.deletingPathExtension().pathExtension == "app"
    }

    static func enclosingBundleURL(executablePath: String) -> URL? {
        var url = URL(fileURLWithPath: executablePath)
        while url.pathComponents.count > 1 {
            // 遡ると末尾に区切りが付くため、比較にも表示にも使える形へ揃え直す。
            if isBundleDirectory(url) { return URL(fileURLWithPath: url.path) }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

extension MixerAppResolver.Environment {
    static let responsibilitySymbolName = "responsibility_get_pid_responsible_for_pid"

    static func live() -> Self {
        MixerAppResolver.Environment(
            responsibleForPID: makeResponsibleForPID(),
            parentPID: { pid in
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) > 0 else { return nil }
                return pid_t(info.pbi_ppid)
            },
            executablePath: { pid in
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
                return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            },
            bundleInfo: { url in MixerAppResolver.BundleInfo.read(from: url) }
        )
    }

    private static func makeResponsibleForPID() -> (@Sendable (pid_t) -> pid_t)? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), responsibilitySymbolName) else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> Int32).self)
        return { pid in pid_t(function(pid)) }
    }
}
