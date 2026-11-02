// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NaviTunes",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.1"),
        // Host `swift build` compiles for macOS; without this, the deployment target is too low for SwiftUI.
        .macOS(.v15),
    ],
    products: [
        .library(name: "NaviTunesKit", targets: ["NaviTunesKit"]),
        .executable(name: "NaviTunes", targets: ["NaviTunes"]),
    ],
    targets: [
        .target(
            name: "NaviTunesKit",
            path: "Sources/NaviTunesKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NaviTunes",
            dependencies: ["NaviTunesKit"],
            path: "Sources/NaviTunes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NaviTunesKitTests",
            dependencies: ["NaviTunesKit"],
            path: "Tests/NaviTunesKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
