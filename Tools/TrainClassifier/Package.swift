// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrainClassifier",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TrainClassifier",
            path: "Sources"
        )
    ]
)
