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
                    appModel.syncHomeScreenIconIfNeeded()
                }
                .onOpenURL { url in
                    appModel.handleWidgetDeepLink(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    // `.inactive` fires when pressing Home on a physical device; `.background` alone is unreliable.
                    switch phase {
                    case .inactive, .background:
                        appModel.syncHomeScreenIconIfNeeded()
                        appModel.persistPlaybackQueue()
                        // Stop the library-membership network poll while
                        // backgrounded so it can't keep waking the radio during
                        // background audio. Resumed in handleAppBecameActive().
                        appModel.stopLibraryMembershipAutoSync()
                    case .active:
                        appModel.handleAppBecameActive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
