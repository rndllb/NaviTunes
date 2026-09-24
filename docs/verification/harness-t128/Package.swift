// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "t128", platforms: [.macOS(.v13)],
  targets: [.executableTarget(name: "t128", path: "Sources/t128",
            swiftSettings: [.swiftLanguageMode(.v5)])])
