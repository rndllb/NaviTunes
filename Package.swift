// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LyraMusic",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        // Host `swift build` compiles for macOS; without this, the deployment target is too low for SwiftUI.
        .macOS(.v15),
    ],
    products: [
        .library(name: "LyraMusicKit", targets: ["LyraMusicKit"]),
        .executable(name: "LyraMusic", targets: ["LyraMusic"]),
    ],
    targets: [
        .target(
            name: "LyraMusicKit",
            path: "Sources/LyraMusicKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LyraMusic",
            dependencies: ["LyraMusicKit"],
            path: "Sources/LyraMusic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
