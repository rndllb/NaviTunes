import RandllMusicKit
import SwiftUI

/// iOS (and optional macOS) host with a real bundle identifier. Open
/// `RandllMusicHost.xcodeproj` and run this scheme on a simulator or device.
@main
struct RandllMusicHostApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}
