/// About が出す条項の名前と著作権表示。許諾の本文は含めない (本文はバンドル同梱の条項ファイルが持つ)。
/// 値はリポジトリの条項の先頭と同じものであることを検証が担保する。
enum AppLicense {
    static let nameAndCopyright = """
        MIT License
        Copyright © 2026 Hiroki Doi
        """
}

/// About が出す、ドライバの土台への帰属表示。著作権表示はドライバの条項と同じ値であることを検証が担保する。
enum DriverCredit {
    static let origin = "The audio driver is based on Apple's NullAudio sample (MIT)."

    static let copyright = "Copyright © 2024 Apple Inc."
}
