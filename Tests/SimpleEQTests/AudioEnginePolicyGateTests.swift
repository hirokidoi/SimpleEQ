import XCTest
@testable import SimpleEQ

/// 定期検算の門 (HAL への問い合わせを含む手順を実施してよいか) の判定。
final class AudioEnginePolicyGateTests: XCTestCase {
    // 稼働中だけ実施する。停止中に実施すると、問い合わせる相手が居ないまま自ドライバ ID や
    // 出力デバイスのレートを HAL へ問い合わせに行く。
    func testRunsPeriodicDeviceQueriesOnlyWhileActive() {
        XCTAssertTrue(runsPeriodicDeviceQueries(processingState: .active))
        for cause in SuspensionCause.allCases {
            XCTAssertFalse(runsPeriodicDeviceQueries(processingState: .suspended(cause)), "停止中 (\(cause)) は実施しない")
        }
    }
}
