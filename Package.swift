// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VellumMusic",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.1"),
        // Host `swift build` compiles for macOS; without this, the deployment target is too low for SwiftUI.
        .macOS(.v15),
    ],
    products: [
        .library(name: "VellumMusicKit", targets: ["VellumMusicKit"]),
        .executable(name: "VellumMusic", targets: ["VellumMusic"]),
    ],
    targets: [
        .target(
            name: "VellumMusicKit",
            path: "Sources/VellumMusicKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VellumMusic",
            dependencies: ["VellumMusicKit"],
            path: "Sources/VellumMusic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
