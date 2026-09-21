import XCTest
@testable import SimpleEQ

final class MixerPushPolicyTests: XCTestCase {
    private let renewInterval = DriverConfig.mixerControlLeaseSeconds / 3

    private func roster(_ entries: [(clientID: UInt32, pid: UInt32, bundleID: String, active: Bool)]) -> [MixerRosterEntry] {
        entries.map {
            MixerRosterEntry(clientID: $0.clientID, processID: $0.pid, bundleID: $0.bundleID, active: $0.active)
        }
    }

    // MARK: - 突き合わせキーの集合

    private func keys(
        remembered: [String: Set<String>] = [:],
        _ entries: [(clientID: UInt32, pid: UInt32, bundleID: String, active: Bool)],
        channelKey: String?
    ) -> (table: [String: Set<String>], remembered: [String: Set<String>]) {
        MixerPushPolicy.matchKeys(
            remembered: remembered, roster: roster(entries), channelKeyForProcess: { _ in channelKey }
        )
    }

    /// 1 チャンネルが複数の突き合わせキーを持つ (本体 + ヘルパー)。
    func testEveryClientOfAChannelGetsItsOwnKey() {
        let channelKey = MixerSpec.bundleKey("com.example.app")
        let result = keys([(1, 501, "com.example.app", true), (2, 502, "com.example.app.helper", false)], channelKey: channelKey)
        XCTAssertEqual(result.table[channelKey]?.count, 2, "席を取っただけのクライアントにもゲインを届ける")
        XCTAssertEqual(result.table[channelKey], result.remembered[channelKey], "バンドル由来の鍵は覚える")
    }

    /// アプリを起動し直しても鍵が同じなので、席を取った瞬間からゲインが当たる。
    func testBundleKeysStayAfterTheClientIsGone() throws {
        let channelKey = MixerSpec.bundleKey("com.example.app")
        let seen = keys([(1, 501, "com.example.app.helper", true)], channelKey: channelKey).remembered
        let remembered = try XCTUnwrap(seen[channelKey], "バンドル由来の鍵を覚えていない")
        XCTAssertFalse(remembered.isEmpty)

        let afterQuit = keys(remembered: seen, [], channelKey: channelKey)
        XCTAssertEqual(afterQuit.table[channelKey], remembered, "名簿から消えても表には載り続ける")
    }

    /// 共有フレームワークの鍵を覚えると、そのアプリを終了したあとも別のアプリに当たり続ける。
    func testKeysOutsideTheChannelNamespaceAreNotRemembered() {
        let channelKey = MixerSpec.bundleKey("com.apple.Safari")
        let result = keys([(1, 501, "com.apple.WebKit.GPU", true)], channelKey: channelKey)
        XCTAssertFalse(result.table[channelKey]?.isEmpty ?? true, "動いている間は当てる")
        XCTAssertNil(result.remembered[channelKey], "名前空間の外なので覚えない")
    }

    func testNamespaceOwnershipFollowsTheBundleIDHierarchy() {
        let channelKey = MixerSpec.bundleKey("com.google.Chrome")
        XCTAssertTrue(MixerPushPolicy.isOwned(bundleID: "com.google.Chrome", byChannelKey: channelKey))
        XCTAssertTrue(MixerPushPolicy.isOwned(bundleID: "com.google.Chrome.helper", byChannelKey: channelKey))
        XCTAssertFalse(
            MixerPushPolicy.isOwned(bundleID: "com.google.ChromeCanary", byChannelKey: channelKey),
            "前方一致だけでは別のアプリを取り込む"
        )
        XCTAssertFalse(MixerPushPolicy.isOwned(bundleID: "com.apple.WebKit.GPU", byChannelKey: channelKey))
        XCTAssertFalse(
            MixerPushPolicy.isOwned(bundleID: "com.google.Chrome", byChannelKey: MixerSpec.processKey("afplay")),
            "バンドルを持たない行は名前空間を持たない"
        )
    }

    /// どちらのゲインとも言えない鍵は落とす。片方の設定がもう片方の音に当たらない。
    func testKeyOwnedByTwoChannelsIsLeftOutOfTheTable() {
        let safari = MixerSpec.bundleKey("com.apple.Safari")
        let other = MixerSpec.bundleKey("com.example.viewer")
        let shared = MixerSpec.matchKey(bundleID: "com.apple.WebKit.GPU", processID: 501)!
        let ownSafari = MixerSpec.matchKey(bundleID: "com.apple.Safari", processID: 502)!

        let table = MixerPushPolicy.gainTable(
            matchKeysByChannelKey: [safari: [shared, ownSafari], other: [shared]],
            gainByChannelKey: [safari: 0, other: MixerGainScale.unityGain]
        )
        XCTAssertNil(table[shared], "2 つのアプリが持つ鍵は載せない")
        XCTAssertEqual(table[ownSafari], 0, "そのアプリだけが持つ鍵は載せる")
    }

    /// 行にしていないアプリも数える。行の有無で鍵の当たり先が変わるわけではない。
    func testKeySharedWithAnAppThatHasNoChannelIsAlsoLeftOut() {
        let safari = MixerSpec.bundleKey("com.apple.Safari")
        let candidate = MixerSpec.bundleKey("com.example.viewer")
        let shared = MixerSpec.matchKey(bundleID: "com.apple.WebKit.GPU", processID: 501)!

        let table = MixerPushPolicy.gainTable(
            matchKeysByChannelKey: [safari: [shared], candidate: [shared]],
            gainByChannelKey: [safari: 0]
        )
        XCTAssertTrue(table.isEmpty, "行が無い側も 1 つとして数える")
    }

    /// pid はアプリを起動し直すと変わるので、覚えても当たらない。
    func testPIDKeysAreNotRemembered() {
        let channelKey = MixerSpec.processKey("afplay")
        let result = keys([(1, 777, "", true)], channelKey: channelKey)
        XCTAssertEqual(result.table[channelKey], [MixerSpec.matchKey(bundleID: "", processID: 777)!])
        XCTAssertNil(result.remembered[channelKey])
    }

    func testUnmatchedClientsProduceNoKey() {
        XCTAssertTrue(keys([(1, 501, "com.example.other", true)], channelKey: nil).table.isEmpty)
    }

    // MARK: - ゲイン表の組み立て

    func testTableUsesTheSharedMatchKeyBuilder() {
        let channelKey = MixerSpec.bundleKey("com.example.app")
        let matchKey = MixerSpec.matchKey(bundleID: "com.example.helper", processID: 501)!
        let table = MixerPushPolicy.gainTable(
            matchKeysByChannelKey: [channelKey: [matchKey]], gainByChannelKey: [channelKey: 0.5]
        )
        XCTAssertEqual(table, [matchKey: 0.5])
    }

    /// 中立の要素を載せないことで「中立の間は押し込みが起きない」が表の同値判定だけで決まる。
    func testNeutralChannelsAreLeftOutOfTheTable() {
        let channelKey = MixerSpec.bundleKey("com.example.app")
        XCTAssertTrue(MixerPushPolicy.gainTable(
            matchKeysByChannelKey: [channelKey: ["bundle:com.example.app"]],
            gainByChannelKey: [channelKey: MixerGainScale.unityGain]
        ).isEmpty)

        XCTAssertTrue(MixerPushPolicy.gainTable(
            matchKeysByChannelKey: [channelKey: ["bundle:com.example.app"]], gainByChannelKey: [:]
        ).isEmpty, "行が無いキーは載せない")
    }

    // MARK: - 押し込みの要否

    func testNeutralTableIsNeverPushedWhileNothingHasBeenPushedYet() {
        XCTAssertFalse(MixerPushPolicy.shouldPush(
            table: [:], lastPushed: nil, lastPushAt: nil, now: 0, renewInterval: renewInterval
        ))
    }

    func testChangedTableIsPushed() {
        XCTAssertTrue(MixerPushPolicy.shouldPush(
            table: ["bundle:a": 0.5], lastPushed: nil, lastPushAt: nil, now: 0, renewInterval: renewInterval
        ))
        XCTAssertTrue(MixerPushPolicy.shouldPush(
            table: ["bundle:a": 0.25], lastPushed: ["bundle:a": 0.5], lastPushAt: 0, now: 0.1,
            renewInterval: renewInterval
        ))
    }

    /// 最後の 1 つが中立へ戻った回は 1 度だけ押し込む (これでリースが解除される)。
    func testReturningToNeutralIsPushedExactlyOnce() {
        XCTAssertTrue(MixerPushPolicy.shouldPush(
            table: [:], lastPushed: ["bundle:a": 0.5], lastPushAt: 0, now: 0.1, renewInterval: renewInterval
        ))
        XCTAssertFalse(MixerPushPolicy.shouldPush(
            table: [:], lastPushed: [:], lastPushAt: 0.1, now: 999, renewInterval: renewInterval
        ), "中立が続く間は周期が回っても押し込まない")
    }

    func testNonNeutralTableIsPushedAgainOnceTheRenewalDeadlinePasses() {
        let table = ["bundle:a": 0.5]
        XCTAssertFalse(MixerPushPolicy.shouldPush(
            table: table, lastPushed: table, lastPushAt: 0, now: renewInterval - 0.01,
            renewInterval: renewInterval
        ))
        XCTAssertTrue(MixerPushPolicy.shouldPush(
            table: table, lastPushed: table, lastPushAt: 0, now: renewInterval, renewInterval: renewInterval
        ), "同じ内容でも更新期限が来たら押し込む")
    }

    /// 更新間隔はリース長から導く。両者が一致していなければならない値なので直値を書かない。
    func testRenewalIntervalLeavesRoomInsideTheLease() {
        XCTAssertLessThan(
            MixerCoordinator.passInterval * 2, DriverConfig.mixerControlLeaseSeconds,
            "1 回取りこぼしてもリースが切れない"
        )
    }
}
