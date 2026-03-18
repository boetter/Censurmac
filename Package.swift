// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Censurmac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Censurmac",
            path: "Sources/Censurmac"
        )
    ]
)
