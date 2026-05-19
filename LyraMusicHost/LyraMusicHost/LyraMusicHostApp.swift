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
                    // One system alert when leaving the app after changing accent, not on every tap in Settings.
                    if phase == .background {
                        appModel.syncHomeScreenIconForAccentIfNeeded()
                    }
                }
        }
    }
}
