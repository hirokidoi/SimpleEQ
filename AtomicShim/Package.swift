// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleEQAtomicC",
    products: [
        .library(name: "SimpleEQAtomicC", targets: ["SimpleEQAtomicC"])
    ],
    targets: [
        .target(name: "SimpleEQAtomicC")
    ]
)
