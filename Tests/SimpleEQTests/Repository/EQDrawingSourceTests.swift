import XCTest

@testable import SimpleEQ

/// EQ 本体の描画は CALayer に閉じる。SwiftUI Canvas は使わない (計測済みの却下判断)。
final class EQDrawingSourceTests: XCTestCase {
    func testAppSourcesDoNotUseSwiftUICanvas() throws {
        let files = try RepositoryFiles.swiftSourceFiles()

        var offenders: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//")[0]
                guard code.contains("Canvas(") || code.contains("Canvas {") else { continue }
                offenders.append("\(url.lastPathComponent):\(offset + 1)")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "EQ の描画はレイヤで行う。Canvas を置くと、操作中だけ毎フレームのラスタライズが戻る"
        )
    }
}
