// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SimpleEQ",
    // 対応 OS の下限はアプリ本体のビルド設定と揃える。ここだけ低いと、製品では使える API が
    // 検証でだけ可用性エラーになる。
    platforms: [
        .macOS(.v26)
    ],
    // Driver/RingShim (ローカルパッケージ SimpleEQRingC) は、専用ドライバとの共有メモリ
    // レイアウト定義 (Driver/Shared/SimpleEQRingLayout.h) を直接 #include する薄い C シム。
    // 構造体オフセットを Swift 側 (SharedRingReader) で手書きしないための唯一の窓口。
    // AtomicShim (ローカルパッケージ SimpleEQAtomicC) は同じ考え方で、単一値に対する
    // acquire/release アトミック操作を提供する薄い C シム。SPSC リングのカウンタのほか、
    // 内部観測量・共有リング読み手・出力フェードの受け渡しがこれを使う。
    dependencies: [
        .package(path: "Driver/RingShim"),
        .package(path: "AtomicShim")
    ],
    targets: [
        .executableTarget(
            name: "SimpleEQ",
            dependencies: [
                // .package(path:) のパッケージ識別子はディレクトリ名 (RingShim) になる
                // (Driver/RingShim/Package.swift 内の name: "SimpleEQRingC" はプロダクト名の方)。
                .product(name: "SimpleEQRingC", package: "RingShim"),
                .product(name: "SimpleEQAtomicC", package: "AtomicShim")
            ],
            path: "Sources/SimpleEQ"
        ),
        .testTarget(
            name: "SimpleEQTests",
            dependencies: ["SimpleEQ"],
            path: "Tests/SimpleEQTests"
        )
    ],
    // 明示しないと tools-version の既定に委ねる形になり、Xcode プロジェクト側 (project.yml の
    // SWIFT_VERSION) と揃っているかを読み比べられない。
    swiftLanguageModes: [.v6]
)
