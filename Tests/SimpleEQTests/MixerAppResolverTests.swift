import XCTest
@testable import SimpleEQ

final class MixerAppResolverTests: XCTestCase {
    private static let appPath = "/Applications/Player.app/Contents/MacOS/Player"
    private static let appURL = URL(fileURLWithPath: "/Applications/Player.app")

    /// 観測値をすべて注入する。
    /// シンボル解決自体も注入点にし、シンボルが無い環境の挙動を実機に依存せず確かめる。
    private func makeResolver(
        responsibleForPID: (@Sendable (pid_t) -> pid_t)? = nil,
        parents: [pid_t: pid_t] = [:],
        paths: [pid_t: String] = [:],
        bundles: [String: MixerAppResolver.BundleInfo] = [:]
    ) -> MixerAppResolver {
        MixerAppResolver(environment: MixerAppResolver.Environment(
            responsibleForPID: responsibleForPID,
            parentPID: { parents[$0] },
            executablePath: { paths[$0] },
            bundleInfo: { bundles[$0.path] }
        ))
    }

    private var appBundles: [String: MixerAppResolver.BundleInfo] {
        [Self.appURL.path: MixerAppResolver.BundleInfo(bundleID: "com.example.player", displayName: "Player")]
    }

    // MARK: - 退避の 4 段

    func testPrivateAPIResolvesToTheResponsibleApp() {
        let resolver = makeResolver(
            responsibleForPID: { $0 == 500 ? 400 : 0 },
            parents: [500: 9],
            paths: [400: Self.appPath],
            bundles: appBundles
        )
        let resolution = resolver.resolve(pid: 500)
        XCTAssertEqual(resolution.kind, .privateAPI)
        XCTAssertEqual(resolution.channelKey, MixerSpec.bundleKey("com.example.player"))
        XCTAssertEqual(resolution.identity?.displayName, "Player")
        XCTAssertEqual(resolution.identity?.iconFilePath, Self.appURL.path)
    }

    func testFallsBackToTheParentWhenThePrivateAPIIsUnavailable() {
        let resolver = makeResolver(
            responsibleForPID: nil,
            parents: [500: 400],
            paths: [400: Self.appPath],
            bundles: appBundles
        )
        XCTAssertFalse(resolver.privateAPIAvailable)
        XCTAssertEqual(resolver.resolve(pid: 500).kind, .parentFallback)
    }

    func testFallsBackToTheParentWhenThePrivateAPIAnswersWithTheProcessItself() {
        let resolver = makeResolver(
            responsibleForPID: { $0 },
            parents: [500: 400],
            paths: [400: Self.appPath],
            bundles: appBundles
        )
        XCTAssertEqual(resolver.resolve(pid: 500).kind, .parentFallback)
    }

    /// 親が launchd なら退避しない。退避すると全 XPC が launchd に潰れる。
    func testDoesNotEscapeToLaunchd() {
        let resolver = makeResolver(
            responsibleForPID: { _ in 0 },
            parents: [500: 1],
            paths: [500: Self.appPath],
            bundles: appBundles
        )
        XCTAssertEqual(resolver.resolve(pid: 500).kind, .processItself)
    }

    func testFallsBackToTheProcessItselfWhenNoParentIsReadable() {
        let resolver = makeResolver(paths: [500: Self.appPath], bundles: appBundles)
        XCTAssertEqual(resolver.resolve(pid: 500).kind, .processItself)
    }

    // MARK: - キーの落とし先

    func testExecutableWithoutABundleFallsBackToTheProcessKey() {
        let resolver = makeResolver(paths: [500: "/usr/bin/afplay"])
        let resolution = resolver.resolve(pid: 500)
        XCTAssertEqual(resolution.channelKey, MixerSpec.processKey("afplay"))
        XCTAssertEqual(resolution.identity?.displayName, "afplay")
        XCTAssertNil(resolution.identity?.iconFilePath, "汎用アイコンへ落とす")
    }

    /// 永続化キーが立たない行を作ると、次回起動時に復元できない行が残る。
    func testUnresolvableProcessProducesNoKey() {
        let resolver = makeResolver()
        let resolution = resolver.resolve(pid: 500)
        XCTAssertEqual(resolution.kind, .unresolved)
        XCTAssertNil(resolution.channelKey)
        XCTAssertNil(resolution.identity)
    }

    func testBundleWithoutAnIdentifierFallsBackToTheProcessKey() {
        let resolver = makeResolver(
            paths: [500: Self.appPath],
            bundles: [Self.appURL.path: MixerAppResolver.BundleInfo(bundleID: nil, displayName: "Player")]
        )
        XCTAssertEqual(resolver.resolve(pid: 500).channelKey, MixerSpec.processKey("Player"))
    }

    // MARK: - バンドルから読む表示名

    // 鳴っている行と鳴っていない行が同じ口から名前を読む。読む順が食い違うと、
    // 両方のキーを持つアプリの行が「鳴っているか」で名前を変える。
    func testBundleDisplayNameWinsOverTheShortName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEQTests-\(UUID().uuidString)")
        let bundleURL = root.appendingPathComponent("Player.app")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.player",
            "CFBundleDisplayName": "Player Deluxe",
            "CFBundleName": "Player",
        ]
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))

        let read = try XCTUnwrap(MixerAppResolver.BundleInfo.read(from: bundleURL))
        XCTAssertEqual(read.bundleID, "com.example.player")
        XCTAssertEqual(read.displayName, "Player Deluxe", "利用者が Finder で見ている名前を採る")
    }

    // MARK: - バンドルへの遡り

    func testEnclosingBundleURLWalksUpToTheNearestBundle() {
        XCTAssertEqual(
            MixerAppResolver.enclosingBundleURL(executablePath: Self.appPath),
            Self.appURL
        )
        XCTAssertEqual(
            MixerAppResolver.enclosingBundleURL(
                executablePath: "/Applications/Browser.app/Contents/XPCServices/Media.xpc/Contents/MacOS/Media"
            ),
            URL(fileURLWithPath: "/Applications/Browser.app/Contents/XPCServices/Media.xpc"),
            "最も内側のバンドルで止まる"
        )
        XCTAssertNil(MixerAppResolver.enclosingBundleURL(executablePath: "/usr/bin/afplay"))
    }

    // 走行中コードの署名を安定させるための複製は `<名前>.app.bundle` を名乗る。
    // 拾えないと、その複製から走っているアプリはバンドル ID へ遡れず、保存済みの行にマッチしなくなる。
    func testEnclosingBundleURLWalksUpToASigningClone() {
        let clonePath =
            "/private/var/folders/ab/X/com.example.player.code_sign_clone/code_sign_clone.aB1cD2"
            + "/Player.app.bundle/Contents/MacOS/Player"
        XCTAssertEqual(
            MixerAppResolver.enclosingBundleURL(executablePath: clonePath),
            URL(fileURLWithPath:
                "/private/var/folders/ab/X/com.example.player.code_sign_clone/code_sign_clone.aB1cD2/Player.app.bundle"
            )
        )
    }

    // 拡張子だけで受けると、アプリの内側のプラグインで止まって別のバンドル ID へ落ちる。
    func testEnclosingBundleURLWalksPastAPluginBundleToTheApp() {
        XCTAssertEqual(
            MixerAppResolver.enclosingBundleURL(
                executablePath: "/Applications/Browser.app/Contents/PlugIns/Codec.bundle/Contents/MacOS/Codec"
            ),
            URL(fileURLWithPath: "/Applications/Browser.app"),
            "プラグインでは止まらない"
        )
    }

    // 複製から走っていても、名乗るバンドル ID は同じなので保存済みの行と同じ鍵へ落ちる。
    func testAnAppRunningFromASigningCloneKeepsItsBundleKey() {
        let cloneURL = URL(fileURLWithPath: "/private/var/folders/ab/X/clone/Player.app.bundle")
        let clonePath = cloneURL.appendingPathComponent("Contents/MacOS/Player").path
        let resolver = makeResolver(
            paths: [500: clonePath],
            bundles: [cloneURL.path: MixerAppResolver.BundleInfo(bundleID: "com.example.player", displayName: "Player")]
        )
        let resolution = resolver.resolve(pid: 500)

        XCTAssertEqual(resolution.channelKey, MixerSpec.bundleKey("com.example.player"))
        XCTAssertNil(resolution.identity?.subtitle, "バンドルへ遡れているので副題は出さない")
    }
}
