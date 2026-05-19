// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RandllMusic",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        // Host `swift build` compiles for macOS; without this, the deployment target is too low for SwiftUI.
        .macOS(.v15),
    ],
    products: [
        .library(name: "RandllMusicKit", targets: ["RandllMusicKit"]),
        .executable(name: "RandllMusic", targets: ["RandllMusic"]),
    ],
    targets: [
        .target(
            name: "RandllMusicKit",
            path: "Sources/RandllMusicKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RandllMusic",
            dependencies: ["RandllMusicKit"],
            path: "Sources/RandllMusic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
