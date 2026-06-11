// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ls-isinvoice",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ls-isinvoice")
    ]
)
