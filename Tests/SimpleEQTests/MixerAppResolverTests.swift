import XCTest
@testable import SimpleEQ

final class MixerAppResolverTests: XCTestCase {
    private static let appPath = "/Applications/Player.app/Contents/MacOS/Player"
    private static let appURL = URL(fileURLWithPath: "/Applications/Player.app")

    /// 観測値をすべて注入する。シンボル解決自体も注入点にし、シンボルが無い環境の挙動を実機に
    /// 依存せず確かめる。
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
}
