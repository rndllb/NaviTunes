// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "mb2", platforms: [.macOS(.v13)],
  targets: [.executableTarget(name: "mb2", path: "Sources/mb2",
            swiftSettings: [.swiftLanguageMode(.v5)])])
