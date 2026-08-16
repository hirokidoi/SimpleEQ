// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleEQRingC",
    products: [
        .library(name: "SimpleEQRingC", targets: ["SimpleEQRingC"])
    ],
    targets: [
        .target(
            name: "SimpleEQRingC",
            cSettings: [
                .headerSearchPath("CanonicalShared")
            ]
        )
    ]
)
