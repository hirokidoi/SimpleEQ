import XCTest
import SimpleEQRingC

/// 突き合わせキーの組み立てを、C シム経由でドライバと同じ実装のまま叩いて検証する。
/// アプリ側で組み立て直すとドライバとの規則がずれ、壊れ方が「ゲインが黙って効かない」になる。
final class MixerMatchKeyTests: XCTestCase {
    private static let capacity = Int(simpleeq_mixer_match_key_max_bytes())
    private static let bundlePrefix = String(cString: simpleeq_mixer_match_key_bundle_prefix())
    private static let pidPrefix = String(cString: simpleeq_mixer_match_key_pid_prefix())

    /// 末尾に番兵を置いた領域へ書かせ、鍵の範囲を越えて書いていないことも同時に見る。
    private struct BuildOutcome {
        var succeeded: Bool
        var key: String
        var sentinelIntact: Bool
    }

    private func build(bundleID: String?, processID: UInt32, capacity: Int = capacity) -> BuildOutcome {
        let sentinelCount = 8
        var storage = [CChar](repeating: 0x7F, count: capacity + sentinelCount)
        let succeeded = storage.withUnsafeMutableBufferPointer { buffer -> Bool in
            if let bundleID {
                return bundleID.withCString { simpleeq_mixer_build_match_key(buffer.baseAddress!, capacity, $0, processID) }
            }
            return simpleeq_mixer_build_match_key(buffer.baseAddress!, capacity, nil, processID)
        }
        let sentinelIntact = storage[capacity...].allSatisfy { $0 == 0x7F }
        let key = storage[..<capacity].withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return BuildOutcome(succeeded: succeeded, key: key, sentinelIntact: sentinelIntact)
    }

    // MARK: - 前置き

    func testBundleIDProducesTheBundlePrefixedKey() {
        let outcome = build(bundleID: "com.example.player", processID: 4321)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.key, "\(Self.bundlePrefix)com.example.player")
        XCTAssertTrue(outcome.sentinelIntact, "鍵の領域を越えて書かないこと")
    }

    func testMissingBundleIDFallsBackToThePIDKey() {
        for bundleID in [nil, ""] as [String?] {
            let outcome = build(bundleID: bundleID, processID: 4321)
            XCTAssertTrue(outcome.succeeded)
            XCTAssertEqual(outcome.key, "\(Self.pidPrefix)4321", "bundleID=\(String(describing: bundleID))")
            XCTAssertTrue(outcome.sentinelIntact)
        }
    }

    // MARK: - 切り詰めない

    /// 切り詰めた鍵は別アプリと衝突しうるので、収まらないバンドル ID は pid へ落とす。
    func testOversizedBundleIDFallsBackToThePIDKeyInsteadOfBeingTruncated() {
        let maxBundleBytes = Int(simpleeq_mixer_bundle_id_max_bytes())
        let oversized = String(repeating: "a", count: maxBundleBytes)

        let outcome = build(bundleID: oversized, processID: 99)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.key, "\(Self.pidPrefix)99")
        XCTAssertTrue(outcome.sentinelIntact)
    }

    func testLongestBundleIDThatFitsIsStillBuiltAsABundleKey() {
        let maxBundleBytes = Int(simpleeq_mixer_bundle_id_max_bytes())
        let longest = String(repeating: "a", count: maxBundleBytes - 1)

        let outcome = build(bundleID: longest, processID: 99)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.key, "\(Self.bundlePrefix)\(longest)")
        XCTAssertTrue(outcome.sentinelIntact)
    }

    // MARK: - 容量

    func testInsufficientCapacityFailsWithoutWritingPastTheBuffer() {
        let outcome = build(bundleID: "com.example.player", processID: 4321, capacity: Self.bundlePrefix.count + 4)
        XCTAssertFalse(outcome.succeeded, "収まらないなら鍵を作らない")
        XCTAssertEqual(outcome.key, "", "失敗時は空文字にする")
        XCTAssertTrue(outcome.sentinelIntact, "容量を越えて書かないこと")
    }

    func testZeroCapacityIsRefused() {
        var storage = [CChar](repeating: 0x7F, count: 8)
        let succeeded = storage.withUnsafeMutableBufferPointer { buffer in
            "com.example.player".withCString { simpleeq_mixer_build_match_key(buffer.baseAddress!, 0, $0, 1) }
        }
        XCTAssertFalse(succeeded)
        XCTAssertTrue(storage.allSatisfy { $0 == 0x7F }, "1 バイトも書かないこと")
    }

    // MARK: - 上限の導出

    /// 前置きとバンドル ID の上限のどちらかを動かしたときに、鍵の上限だけ取り残されないようにする。
    func testMatchKeyCapacityIsDerivedFromThePrefixAndTheBundleIDLimit() {
        XCTAssertEqual(
            Int(simpleeq_mixer_match_key_max_bytes()),
            Self.bundlePrefix.utf8.count + Int(simpleeq_mixer_bundle_id_max_bytes())
        )
    }
}
