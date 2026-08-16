import XCTest
@testable import SimpleEQ

/// 同梱物の相対配置は project.yml が書き込み、DriverInstaller と両スクリプトが読む。
/// swift test は .app を組み立てないため、食い違いは実機インストールまで表面化しない。
final class DriverPayloadLayoutTests: XCTestCase {
    func testProjectDefinitionCopiesPayloadWhereDriverInstallerReadsIt() throws {
        let lines = try String(contentsOf: RepositoryFiles.appProjectDefinition, encoding: .utf8)
            .components(separatedBy: .newlines)
        let payload = DriverInstaller.payloadDirectoryName
        let shared = "\(payload)/\(DriverInstaller.sharedSubdirectoryName)"

        for anchor in [
            "- path: Driver/\(DriverInstaller.installScriptName)",
            "- path: Driver/\(DriverInstaller.uninstallScriptName)",
            "- target: SimpleEQAudio/SimpleEQAudio",
        ] {
            XCTAssertEqual(try copyTarget(following: anchor, in: lines).subpath, payload, anchor)
        }
        XCTAssertEqual(
            try copyTarget(
                following: "- path: Driver/\(DriverInstaller.sharedSubdirectoryName)/SimpleEQRingLayout.h",
                in: lines
            ).subpath,
            shared
        )
    }

    /// DriverInstaller は Bundle.main の Resources を起点に解決する。落とし先が変わると届かなくなる。
    func testProjectDefinitionDropsPayloadIntoResources() throws {
        let lines = try String(contentsOf: RepositoryFiles.appProjectDefinition, encoding: .utf8)
            .components(separatedBy: .newlines)

        for anchor in [
            "- path: Driver/\(DriverInstaller.installScriptName)",
            "- path: Driver/\(DriverInstaller.uninstallScriptName)",
            "- path: Driver/\(DriverInstaller.sharedSubdirectoryName)/SimpleEQRingLayout.h",
            "- target: SimpleEQAudio/SimpleEQAudio",
        ] {
            XCTAssertEqual(try copyTarget(following: anchor, in: lines).destination, "resources", anchor)
        }
    }

    func testScriptsResolvePayloadRelativeToTheirOwnLocation() throws {
        let install = try String(contentsOf: RepositoryFiles.driverInstallScript, encoding: .utf8)
        let uninstall = try String(contentsOf: RepositoryFiles.driverUninstallScript, encoding: .utf8)

        XCTAssertTrue(
            install.contains("$SCRIPT_DIR/\(try driverBundleName())"),
            "同梱配置ではドライバ本体がスクリプトと同じ場所に並ぶ"
        )

        let headerReference = "$SCRIPT_DIR/\(DriverInstaller.sharedSubdirectoryName)/SimpleEQRingLayout.h"
        XCTAssertTrue(install.contains(headerReference))
        XCTAssertTrue(uninstall.contains(headerReference))
    }

    /// 走査は当該ブロック内で閉じる。またぐと、指定が消えた回に隣のブロックの値を拾って通ってしまう。
    private func copyTarget(following anchor: String, in lines: [String]) throws -> (destination: String, subpath: String) {
        let start = try XCTUnwrap(
            lines.firstIndex { $0.contains(anchor) },
            "project.yml に \(anchor) が見つからない"
        )
        let anchorIndent = indentWidth(of: lines[start])
        var destination: String?
        var subpath: String?

        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if indentWidth(of: line) <= anchorIndent { break }
            destination = value(after: "destination:", in: line) ?? destination
            subpath = value(after: "subpath:", in: line) ?? subpath
        }

        return (
            try XCTUnwrap(destination, "\(anchor) に落とし先の指定が無い"),
            try XCTUnwrap(subpath, "\(anchor) に落とし先の位置の指定が無い")
        )
    }

    private func indentWidth(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private func driverBundleName() throws -> String {
        let names = try RepositoryText.driverBuildSettingValues(forKey: "PRODUCT_NAME")
        let extensions = try RepositoryText.driverBuildSettingValues(forKey: "WRAPPER_EXTENSION")

        XCTAssertEqual(Set(names).count, 1, "構成ごとの PRODUCT_NAME が揃っていない")
        XCTAssertEqual(Set(extensions).count, 1, "構成ごとの WRAPPER_EXTENSION が揃っていない")
        return "\(try XCTUnwrap(names.first)).\(try XCTUnwrap(extensions.first))"
    }
}
