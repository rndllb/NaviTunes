import LyraMusicKit
import SwiftUI

/// iOS (and optional macOS) host with a real bundle identifier. Open
/// `LyraMusicHost.xcodeproj` and run this scheme on a simulator or device.
@main
struct LyraMusicHostApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}
