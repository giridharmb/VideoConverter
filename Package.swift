// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoConverter",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ConverterCore", targets: ["ConverterCore"]), .executable(name: "ConverterStress", targets: ["ConverterStress"])],
    targets: [
        .target(name: "ConverterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ConverterStress", dependencies: ["ConverterCore"]),
        .testTarget(name: "ConverterCoreTests", dependencies: ["ConverterCore"])
    ]
)
