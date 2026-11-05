// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoConverter",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ConverterCore", targets: ["ConverterCore"])],
    targets: [
        .target(name: "ConverterCore"),
        .testTarget(name: "ConverterCoreTests", dependencies: ["ConverterCore"])
    ]
)
