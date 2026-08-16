import XCTest
import SimpleEQRingC
@testable import SimpleEQ

/// ドライバのビルド設定が名乗る値と、ドライバのソースが宣言する値の一致を担保する。ビルド設定は
/// ソース側の宣言から導出できず同じ値が 2 箇所に置かれるため、一致を人手の規律に委ねない。
final class DriverSourceConsistencyTests: XCTestCase {

    func testDriverBundleVersionMatchesTheSharedHeaderConstants() throws {
        let expected = "\(simpleeq_driver_version_major()).\(simpleeq_driver_version_minor())"
        let declared = try RepositoryText.driverBuildSettingValues(forKey: "MARKETING_VERSION")

        XCTAssertFalse(declared.isEmpty, "ドライバのビルド設定にバージョンの宣言が見当たらない")
        for value in declared {
            XCTAssertEqual(
                value, expected,
                "ドライババンドルが名乗るバージョンと共有ヘッダの定数が食い違っている。両方を同時に動かすこと"
            )
        }
    }

    func testDriverBundleIdentifierMatchesTheSourceConstant() throws {
        let expected = try Self.driverSourceDefineValue(named: "kPlugIn_BundleID")
        let declared = try RepositoryText.driverBuildSettingValues(forKey: "PRODUCT_BUNDLE_IDENTIFIER")

        XCTAssertFalse(declared.isEmpty, "ドライバのビルド設定にバンドル識別子の宣言が見当たらない")
        for value in declared {
            XCTAssertEqual(
                value, expected,
                "ドライババンドルが名乗る識別子とソースの定数が食い違っている。両方を同時に動かすこと"
            )
        }
    }

    /// アイコンのファイル名は複数箇所にある。食い違うとアイコンを返す経路だけが静かに失敗する。
    func testDriverIconFileNameIsTheSameEverywhere() throws {
        let expected = try Self.driverSourceDefineValue(named: "kPlugIn_Icon")

        let project = try String(contentsOf: RepositoryFiles.driverProjectFile, encoding: .utf8)
        XCTAssertTrue(
            project.contains("path = \(expected);"),
            "ドライバのビルド設定が \(expected) をバンドルへ入れていない"
        )

        let generated = try RepositoryText.trailingValues(
            after: "DRIVER_ICON := ", in: String(contentsOf: RepositoryFiles.makefile, encoding: .utf8)
        )
        XCTAssertEqual(generated.count, 1, "アイコンの生成先の宣言が 1 つではない")
        XCTAssertEqual(
            generated.first.map { URL(fileURLWithPath: $0).lastPathComponent }, expected,
            "アイコンの生成先の名前とソースの定数が食い違っている"
        )
    }

    /// 「持っている」と答えたセレクタには「変更できるか」も答える。片方だけに足すと、同じセレクタに
    /// 対して持っていると知らないを同時に答える状態になる。
    func testEveryDeclaredPropertyAlsoAnswersWhetherItIsSettable() throws {
        for objectKind in ["PlugIn", "Box", "Device", "Stream", "Control"] {
            let declared = try Self.driverSourceCaseLabels(inFunction: "Has\(objectKind)Property")
            let settable = try Self.driverSourceCaseLabels(inFunction: "Is\(objectKind)PropertySettable")

            XCTAssertFalse(declared.isEmpty, "\(objectKind) の宣言しているセレクタを読み取れていない")
            XCTAssertEqual(
                declared, settable,
                "\(objectKind) で、持っているかと変更できるかの答えるセレクタが揃っていない"
            )
        }
    }

    /// 検証側はレート依存の導出を確かめるためにドライバの申告レート表の写しを持つ。写しが古いと、
    /// 新しいレートを取りこぼしたまま何も失敗せずに通る。
    func testDeclaredSampleRatesMatchTheVerificationCopy() throws {
        let declared = try Self.driverSourceDoubleArrayValues(named: "kDevice_SampleRates")

        XCTAssertEqual(
            declared, TestSampleRates.all,
            "ドライバが申告するレートと検証側の写しが食い違っている。両方を同時に動かすこと"
        )
    }

    /// 解釈できない要素を捨てると、マクロや式で足された要素が黙って落ちて写しと一致してしまう。
    private static func driverSourceDoubleArrayValues(named name: String) throws -> [Double] {
        let source = try String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)
        let declarations = source
            .split(separator: "\n")
            .filter { $0.contains("\(name)[]") && $0.contains("=") }
        XCTAssertEqual(declarations.count, 1, "ドライバのソースにある \(name) の宣言が 1 つではない")

        let declaration = try XCTUnwrap(declarations.first)
        let open = try XCTUnwrap(declaration.range(of: "{"), "\(name) の初期化子が波括弧で始まっていない")
        let close = try XCTUnwrap(
            declaration.range(of: "};", range: open.upperBound..<declaration.endIndex),
            "\(name) の初期化子が同じ行で閉じていない"
        )

        return try declaration[open.upperBound..<close.lowerBound]
            .split(separator: ",")
            .map { element in
                let token = element.trimmingCharacters(in: .whitespaces)
                return try XCTUnwrap(Double(token), "\(name) の要素 \(token) を数値として読めない")
            }
    }

    /// ドライバのソースが宣言するマクロの値を取り出す。宣言が 1 つであることも併せて確かめる。
    private static func driverSourceDefineValue(named name: String) throws -> String {
        let found = try RepositoryText.trailingValues(
            after: "#define \(name) ", in: String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)
        )
        XCTAssertEqual(found.count, 1, "ドライバのソースにある \(name) の宣言が 1 つではない")
        return try XCTUnwrap(found.first)
    }

    /// ある関数が並べている case のラベルを集める。前方宣言側を拾わないよう定義側だけを掴む。
    private static func driverSourceCaseLabels(inFunction name: String) throws -> Set<String> {
        let source = try String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)
        let definition = try XCTUnwrap(
            source.range(
                of: "\\nstatic \\w+ SimpleEQAudio_\(name)\\([^;]*?\\)\\s*\\n\\{",
                options: [.regularExpression]
            ),
            "\(name) の定義が見当たらない"
        )
        let end = source.range(of: "\n}\n", range: definition.upperBound..<source.endIndex)
        let body = source[definition.upperBound..<(end?.lowerBound ?? source.endIndex)]

        var labels: Set<String> = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case k"), trimmed.hasSuffix(":") else { continue }
            labels.insert(String(trimmed.dropFirst("case ".count).dropLast()))
        }
        return labels
    }

}
