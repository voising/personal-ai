// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PersonalAI",
            path: "Sources/PersonalAI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
