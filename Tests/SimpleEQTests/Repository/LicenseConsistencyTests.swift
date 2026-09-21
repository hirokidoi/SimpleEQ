import XCTest
@testable import SimpleEQ

/// 画面へ出す条項の綴りがリポジトリの条項と一致していることと、条項がバンドルへ入ることを固定する。
final class LicenseConsistencyTests: XCTestCase {

    func testDisplayedLicenseMatchesTheRepositoryLicense() throws {
        XCTAssertEqual(AppLicense.nameAndCopyright, try Self.nameAndCopyrightOfRepositoryLicense())
    }

    func testDisplayedLicenseCarriesNoPermissionBody() {
        XCTAssertFalse(
            AppLicense.nameAndCopyright.contains("Permission is hereby granted"),
            "画面へ出す綴りへ許諾の本文が混ざっている"
        )
    }

    func testDisplayedDriverCreditMatchesTheDriverLicense() throws {
        let contents = try String(contentsOf: RepositoryFiles.driverLicense, encoding: .utf8)
        XCTAssertTrue(
            contents.contains(DriverCredit.copyright),
            "画面へ出す帰属表示の著作権行がドライバの条項に見当たらない。両方を同時に動かすこと"
        )
    }

    /// ライセンスファイルがビルド設定でリソースとして取り込まれていることを確認する。
    func testAppBuildSettingsBundleTheLicense() throws {
        let definition = try String(contentsOf: RepositoryFiles.appProjectDefinition, encoding: .utf8)
        XCTAssertTrue(
            definition.contains("- path: \(Self.licenseFileName)"),
            "アプリのビルド設定が \(Self.licenseFileName) を取り込んでいない"
        )
        XCTAssertTrue(
            definition.contains("- path: \(Self.licenseFileName)\n        buildPhase: resources"),
            "アプリのビルド設定が \(Self.licenseFileName) をリソースの段へ入れていない"
        )
    }

    /// 参照の宣言だけの状態と区別し、リソース段に実際に載っていることを見る。
    func testDriverBuildSettingsBundleTheLicense() throws {
        let project = try String(contentsOf: RepositoryFiles.driverProjectFile, encoding: .utf8)
        XCTAssertTrue(
            project.contains("/* \(Self.licenseFileName) in Resources */,"),
            "ドライバのビルド設定が \(Self.licenseFileName) をリソースの段へ入れていない"
        )
    }

    /// LICENSE は名前・著作権表示・許諾本文の順に空行区切りで並ぶ前提で読む。
    private static func nameAndCopyrightOfRepositoryLicense() throws -> String {
        let contents = try String(contentsOf: RepositoryFiles.license, encoding: .utf8)
        let paragraphs = contents
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        XCTAssertGreaterThanOrEqual(
            paragraphs.count, 2, "条項が名前と著作権表示を空行で分けて並べていない"
        )
        return paragraphs.prefix(2).joined(separator: "\n")
    }

    /// リポジトリでもバンドルの中でも同じ名前を持つ。
    private static let licenseFileName = "LICENSE"
}
