// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "mb3", platforms: [.macOS(.v13)],
  targets: [.executableTarget(name: "mb3", path: "Sources/mb3",
            swiftSettings: [.swiftLanguageMode(.v5)])])
