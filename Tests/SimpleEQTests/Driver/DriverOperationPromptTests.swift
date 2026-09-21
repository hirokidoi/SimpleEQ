import XCTest
@testable import SimpleEQ

final class DriverOperationPromptTests: XCTestCase {

    /// 失敗表示はインストール/更新/再インストール/アンインストールで共有されるため、
    /// 呼び名を固定で書くと、実際に押した操作と食い違ったまま表示される。
    func testOutputDeviceSwitchFailureMessageNamesTheOperationItWasGiven() {
        let titles = [
            DriverOperationPrompt.actionTitle(for: .notFound),
            DriverOperationPrompt.actionTitle(for: .versionMismatch),
            DriverOperationPrompt.actionTitle(for: .ok),
            DriverOperationPrompt.uninstallTitle,
        ]
        let messages = titles.map { DriverOperationPrompt.outputDeviceSwitchFailureMessage(operationTitle: $0) }

        for (title, message) in zip(titles, messages) {
            XCTAssertTrue(message.contains(title), "「\(title)」を実行した結果に「\(message)」が出る")
        }
        XCTAssertEqual(Set(messages).count, titles.count, "呼び名ごとに異なる文面になる")
    }
}
