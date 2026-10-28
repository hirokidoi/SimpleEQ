import XCTest
import SimpleEQRingC
@testable import SimpleEQ

/// ドライバのビルド設定が名乗る値と、ドライバのソースが宣言する値の一致を担保する。
/// ビルド設定はソース側の宣言から導出できず同じ値が 2 箇所に置かれるため、一致を人手の規律に委ねない。
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

    /// 「持っている」と答えたセレクタには「変更できるか」も答える。
    /// 片方だけに足すと、同じセレクタに対して持っていると知らないを同時に答える状態になる。
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

    /// カスタムプロパティの宣言一覧に載せたセレクタは、応答関数のすべてに現れる。
    /// 1 つでも落とすと、載せたのに答えない状態になる。
    func testEveryCustomPropertyInTheDeviceListIsAnsweredByAllHandlers() throws {
        let source = try String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)
        let listStart = try XCTUnwrap(source.range(of: "kDevice_CustomPropertyList[] = {"), "宣言一覧が見当たらない")
        let listEnd = try XCTUnwrap(source.range(of: "};", range: listStart.upperBound..<source.endIndex))
        let selectors = source[listStart.upperBound..<listEnd.lowerBound]
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("{ k") else { return nil }
                return trimmed.dropFirst(2).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
            }
        XCTAssertFalse(selectors.isEmpty, "宣言一覧のセレクタを読み取れていない")

        for handler in [
            "HasDeviceProperty", "IsDevicePropertySettable", "GetDevicePropertyDataSize",
            "GetDevicePropertyData", "SetDevicePropertyData",
        ] {
            let labels = try Self.driverSourceCaseLabels(inFunction: handler)
            for selector in selectors {
                XCTAssertTrue(labels.contains(selector), "\(handler) が \(selector) に答えていない")
            }
        }
    }

    /// 申告遅延の応答がリテラルを返すと渡された値が HAL へ届かない。Set の時点で応答の変数を書き換えると、構成変更の外で値が変わる。
    func testTheDeviceLatencyIsSwappedInOnlyInsideAConfigurationChange() throws {
        let source = try String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)
        let action = "ChangeAction_SetPresentationLatency"
        let latencyBody = try Self.driverSourceCaseBody(
            inFunction: "GetDevicePropertyData", label: "kAudioDevicePropertyLatency"
        )
        let pattern = try NSRegularExpression(pattern: "\\*\\(\\(UInt32\\*\\)outData\\) = ([A-Za-z_]\\w*);")
        let match = try XCTUnwrap(
            pattern.firstMatch(in: latencyBody, range: NSRange(latencyBody.startIndex..., in: latencyBody)),
            "Latency の応答が変数を返す形になっていない"
        )
        let variable = String(latencyBody[try XCTUnwrap(Range(match.range(at: 1), in: latencyBody))])

        let performBody = try Self.driverSourceCaseBody(inFunction: "PerformDeviceConfigurationChange", label: action)
        XCTAssertTrue(performBody.contains("\(variable) = "), "構成変更の中で \(variable) へ入れ替えていない")

        let setterBody = try Self.driverSourceCaseBody(
            inFunction: "SetDevicePropertyData", label: "kSimpleEQPresentationLatencySelector"
        )
        let applier = "SimpleEQAudio_ApplyPresentationLatency"
        XCTAssertTrue(setterBody.contains("\(applier)("), "Set の case が保存と依頼の関数を呼んでいない")

        let definition = try XCTUnwrap(source.range(of: "\nstatic void \(applier)("), "保存と依頼の関数の定義が見当たらない")
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: definition.upperBound..<source.endIndex))
        let applierBody = source[definition.upperBound..<end.lowerBound]
        XCTAssertTrue(applierBody.contains("RequestDeviceConfigurationChange("), "Set が呼ぶ関数が構成変更を依頼していない")
        XCTAssertTrue(applierBody.contains(action), "依頼が遅延の入れ替え用の種別になっていない")
        XCTAssertFalse(applierBody.contains("\(variable) = "), "Set の時点で \(variable) を書き換えると、構成変更の外で値が変わる")

        let abortBody = try Self.driverSourceCaseBody(inFunction: "AbortDeviceConfigurationChange", label: action)
        XCTAssertTrue(
            abortBody.contains("gDevice_RequestedPresentationLatencyFrames = \(variable)"),
            "取り下げで要求値を \(variable) へ戻していない"
        )
    }

    func testVolumeControlWritesAreJudgedWithTheActualSeatAcrossEverySelector() throws {
        let source = try String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)

        let refuser = "SimpleEQAudio_RefusesVolumeControlWrite"
        let definition = try XCTUnwrap(source.range(of: "\nstatic bool \(refuser)("), "拒否判定の関数の定義が見当たらない")
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: definition.upperBound..<source.endIndex))
        let refuserBody = String(source[definition.upperBound..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: "SimpleEQVolumeControlRefusesWrite\\(([A-Za-z_]\\w*), ([A-Za-z_]\\w*)\\)")
        let match = try XCTUnwrap(
            pattern.firstMatch(in: refuserBody, range: NSRange(refuserBody.startIndex..., in: refuserBody)),
            "共有ヘッダの判定へ書き込み元と席の値を変数で渡していない"
        )
        let writer = String(refuserBody[try XCTUnwrap(Range(match.range(at: 1), in: refuserBody))])
        let seat = String(refuserBody[try XCTUnwrap(Range(match.range(at: 2), in: refuserBody))])
        XCTAssertTrue(refuserBody.contains("\(writer) = SimpleEQAudio_ClientIsAudioService("), "判定へ渡す \(writer) が書き込み元の識別結果ではない")
        XCTAssertTrue(refuserBody.contains("\(seat) = SimpleEQOwnership_SeatIsHeld("), "判定へ渡す \(seat) が席の判定結果ではない")

        let setter = try XCTUnwrap(
            source.range(of: "\nstatic OSStatus SimpleEQAudio_SetControlPropertyData(", options: .backwards), "コントロールの Set の定義が見当たらない"
        )
        let dispatch = try XCTUnwrap(source.range(of: "switch(inObjectID)", range: setter.upperBound..<source.endIndex))
        let entry = source[setter.upperBound..<dispatch.lowerBound]
        XCTAssertTrue(entry.contains("\(refuser)(inClientProcessID)"), "Set の入口で拒否判定を呼んでいない")
        for selector in ["kAudioLevelControlPropertyScalarValue", "kAudioLevelControlPropertyDecibelValue", "kAudioBooleanControlPropertyValue"] {
            XCTAssertTrue(entry.contains(selector), "\(selector) が拒否の対象に入っていない")
        }
    }

    /// case ラベルから次の case ラベルの手前までの本体。
    private static func driverSourceCaseBody(inFunction name: String, label: String) throws -> String {
        let source = try String(contentsOf: RepositoryFiles.driverSourceFile, encoding: .utf8)
        let definition = try XCTUnwrap(
            source.range(
                of: "\\nstatic \\w+ SimpleEQAudio_\(name)\\([^;]*?\\)\\s*\\n\\{",
                options: [.regularExpression]
            ),
            "\(name) の定義が見当たらない"
        )
        let functionEnd = source.range(of: "\n}\n", range: definition.upperBound..<source.endIndex)
        let body = source[definition.upperBound..<(functionEnd?.lowerBound ?? source.endIndex)]
        let start = try XCTUnwrap(body.range(of: "        case \(label):\n"), "\(name) に \(label) の case が見当たらない")
        let next = body.range(of: "\n        case ", range: start.upperBound..<body.endIndex)
        let defaultCase = body.range(of: "\n        default:", range: start.upperBound..<body.endIndex)
        let end = [next?.lowerBound, defaultCase?.lowerBound].compactMap { $0 }.min() ?? body.endIndex
        return String(body[start.upperBound..<end])
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
            guard trimmed.hasPrefix("case k"), let colon = trimmed.firstIndex(of: ":") else { continue }
            labels.insert(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "case ".count)..<colon]))
        }
        return labels
    }

}
