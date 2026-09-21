import XCTest

enum RepositoryFiles {
    static var license: URL { root.appendingPathComponent("LICENSE") }

    static var driverLicense: URL { driverDirectory.appendingPathComponent("LICENSE") }

    static var appProjectDefinition: URL { root.appendingPathComponent("project.yml") }

    static var appInfoPlist: URL { root.appendingPathComponent("Info.plist") }

    static var makefile: URL { root.appendingPathComponent("Makefile") }

    static var driverProjectFile: URL {
        driverDirectory.appendingPathComponent("SimpleEQAudio.xcodeproj/project.pbxproj")
    }

    static var driverSourceFile: URL {
        driverDirectory.appendingPathComponent("SimpleEQAudio/SimpleEQAudio.c")
    }

    static var appSourceDirectory: URL { root.appendingPathComponent("Sources/SimpleEQ") }

    static var driverInstallScript: URL { root.appendingPathComponent("Driver/install-driver.sh") }

    static var driverUninstallScript: URL { root.appendingPathComponent("Driver/uninstall-driver.sh") }

    private static var driverDirectory: URL { root.appendingPathComponent("Driver/SimpleEQAudio") }

    static func swiftSourceFiles() throws -> [URL] {
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: appSourceDirectory, includingPropertiesForKeys: nil),
            "ソースを列挙できない: \(appSourceDirectory.path)"
        )
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try XCTUnwrap(files.isEmpty ? nil : files, "ソースが見つからない: \(appSourceDirectory.path)")
    }

    private static var root: URL {
        let marker = "Package.swift"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else {
                fatalError("\(marker) が見つからない: \(#filePath) から上へたどれなかった")
            }
            directory = parent
        }
    }
}

enum RepositoryText {
    /// 行内の目印より後ろを値として取り出す。囲みの記号 (引用符・終端のセミコロン) は落とす。
    static func trailingValues(after marker: String, in text: String) -> [String] {
        text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: marker) else { return nil }
                return line[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t;\""))
            }
    }

    /// ドライバのビルド設定が宣言する値をすべて拾う (構成ごとに宣言があるため、そのすべてを見る)。
    static func driverBuildSettingValues(forKey key: String) throws -> [String] {
        trailingValues(
            after: "\(key) = ",
            in: try String(contentsOf: RepositoryFiles.driverProjectFile, encoding: .utf8)
        )
    }
}
