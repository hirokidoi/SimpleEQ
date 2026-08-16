import XCTest

@testable import SimpleEQ

/// EQ 本体の描画は CALayer に閉じる。SwiftUI Canvas は使わない (計測済みの却下判断)。
final class EQDrawingSourceTests: XCTestCase {
    func testAppSourcesDoNotUseSwiftUICanvas() {
        let files = Self.swiftSourceFiles()
        XCTAssertFalse(files.isEmpty, "前提: ソースを 1 件以上辿れていること")

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

    private static func swiftSourceFiles() -> [URL] {
        let root = RepositoryFiles.appSourceDirectory
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
