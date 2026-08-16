import XCTest
@testable import SimpleEQ

/// パス解決とクォート処理のラウンドトリップのみを検証する。管理者権限昇格・ドライバの実際の
/// インストール/削除は自動テスト対象外 (実機検証で担保する)。
final class DriverInstallerTests: XCTestCase {
    func testResolveScriptPathDerivesPathFromResourcesURL() {
        let resourcesURL = URL(fileURLWithPath: "/foo/SimpleEQ.app/Contents/Resources")

        XCTAssertEqual(
            DriverInstaller.resolveScriptPath(named: DriverInstaller.installScriptName, resourcesURL: resourcesURL),
            "/foo/SimpleEQ.app/Contents/Resources/Driver/install-driver.sh"
        )
        XCTAssertEqual(
            DriverInstaller.resolveScriptPath(named: DriverInstaller.uninstallScriptName, resourcesURL: resourcesURL),
            "/foo/SimpleEQ.app/Contents/Resources/Driver/uninstall-driver.sh"
        )
    }

    private func unquoteShell(_ quoted: String) -> String {
        var result = ""
        var rest = quoted.dropFirst().dropLast()  // 前後の ' を剥がす
        while let range = rest.range(of: "'\\''") {
            result += rest[rest.startIndex..<range.lowerBound]
            result += "'"
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }

    private func unquoteAppleScript(_ quoted: String) -> String {
        var result = ""
        var iterator = quoted.makeIterator()
        while let c = iterator.next() {
            if c == "\\", let next = iterator.next() {
                result.append(next)
            } else {
                result.append(c)
            }
        }
        return result
    }

    func testShellQuotedRoundTripsThroughPosixSingleQuoteUnescaping() {
        for original in ["/a/b/c", "/a'b/c", "/a''b", "'"] {
            XCTAssertEqual(unquoteShell(DriverInstaller.shellQuoted(original)), original)
        }
    }

    func testAppleScriptQuotedRoundTripsThroughUnescaping() {
        for original in ["/a/b/c", #"/a"b\c"#, #"\\"#, "\""] {
            XCTAssertEqual(unquoteAppleScript(DriverInstaller.appleScriptQuoted(original)), original)
        }
    }

    func testComposedEscapingRoundTripsToOriginalPath() {
        for original in ["/a/b/c", #"/a'b"c\d"#] {
            let composed = DriverInstaller.appleScriptQuoted(DriverInstaller.shellQuoted(original))
            XCTAssertEqual(unquoteShell(unquoteAppleScript(composed)), original)
        }
    }
}
