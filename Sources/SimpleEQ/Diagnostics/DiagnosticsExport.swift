import Foundation

/// 診断の書き出し先の組み立てとファイルへの書き込み。パスを組み立てる口をここ 1 つに閉じ、
/// 置き場を差し替えられる形にしておく。
enum DiagnosticsExport {

    /// 置き場の既定値。ログの標準的な置き場の下へアプリ専用のディレクトリを作る。
    static func defaultDirectory(
        libraryDirectory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    ) -> URL {
        let library = libraryDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs").appendingPathComponent(directoryName)
    }

    /// 書き出し 1 件のファイル名。日時を含めることで、続けて撃った証跡が並んで残る。
    static func fileName(at date: Date, sequence: Int = 0) -> String {
        let stamp = timestampFormatter.string(from: date)
        let suffix = sequence > 0 ? "-\(sequence + 1)" : ""
        return "\(fileNamePrefix)-\(stamp)\(suffix).\(fileNameExtension)"
    }

    /// 同じ秒に何回まで連番で避けるか。これを超えたら最後の候補をそのまま返す
    /// (探し続けて以後の書き出しが詰まるより、1 件を上書きする方が被害が小さい)。
    private static let maxSequencePerSecond = 100

    /// 同じ名前が既にあれば連番を付けて避ける。
    static func availableURL(in directory: URL, at date: Date, exists: (URL) -> Bool) -> URL {
        var candidate = directory.appendingPathComponent(fileName(at: date))
        for sequence in 1..<maxSequencePerSecond {
            if !exists(candidate) { return candidate }
            candidate = directory.appendingPathComponent(fileName(at: date, sequence: sequence))
        }
        return candidate
    }

    /// 置き場を用意する。書き込みと、置き場を開く操作のどちらもここを通す。
    @discardableResult
    static func ensureDirectory(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// 置き場を用意してから書き込む。失敗は握り潰さず、伝えられる形で返す。
    static func write(
        _ text: String, into directory: URL, at date: Date, fileManager: FileManager = .default
    ) -> DiagnosticsModel.ExportOutcome {
        guard ensureDirectory(directory, fileManager: fileManager) else {
            return .failed(reason: "置き場を作成できない")
        }
        let url = availableURL(in: directory, at: date) { fileManager.fileExists(atPath: $0.path) }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failed(reason: "書き込めない")
        }
        return .written(fileName: url.lastPathComponent)
    }

    // MARK: - 名前の部品

    private static let directoryName = "SimpleEQ"
    private static let fileNamePrefix = "SimpleEQ-diagnostics"
    private static let fileNameExtension = "txt"

    /// ファイル名に使う日時。並べたときに書き出した順に並ぶ形にする。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
