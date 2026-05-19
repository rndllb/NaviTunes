import LyraMusicKit
import SwiftUI

/// iOS (and optional macOS) host with a real bundle identifier. Open
/// `LyraMusicHost.xcodeproj` and run this scheme on a simulator or device.
@main
struct LyraMusicHostApp: App {
    @StateObject private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .onAppear {
                    appModel.syncHomeScreenIconForAccentIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    // `.inactive` fires when pressing Home on a physical device; `.background` alone is unreliable.
                    switch phase {
                    case .inactive, .background:
                        appModel.syncHomeScreenIconForAccentIfNeeded()
                        appModel.persistPlaybackQueue()
                    default:
                        break
                    }
                }
        }
    }
}
