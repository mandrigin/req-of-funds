// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TestCHFExtraction",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TestCHFExtraction")
    ]
)
