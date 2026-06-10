#if DEBUG
import SwiftUI

/// Simulator-only remote control for UI verification — the project has no UI
/// test target, so transitions and open/close performance are exercised from
/// the command line via Darwin notifications:
///
///     xcrun simctl spawn booted notifyutil -p com.lyra.debug.openPlaylist
///     xcrun simctl spawn booted notifyutil -p com.lyra.debug.pop
///
/// `openPlaylist` pushes the playlist whose name contains the
/// `LYRA_DEBUG_PLAYLIST` launch environment value (first user playlist when
/// unset) through the same ``NowPlayingDeepLink`` path a real navigation
/// takes; `pop` pops the active tab's stack. Compiled out of Release builds.
@MainActor
enum DebugUIRemote {
    private static weak var app: AppModel?
    private static var installed = false

    static func install(app model: AppModel) {
        app = model
        guard !installed else { return }
        installed = true
        observe("com.lyra.debug.openPlaylist")
        observe("com.lyra.debug.pop")
        observe("com.lyra.debug.libraryTab")
    }

    private static func observe(_ name: String) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, name, _, _ in
                guard let raw = name?.rawValue as String? else { return }
                Task { @MainActor in
                    DebugUIRemote.handle(raw)
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private static func handle(_ name: String) {
        guard let app else { return }
        switch name {
        case "com.lyra.debug.openPlaylist":
            let wanted = ProcessInfo.processInfo.environment["LYRA_DEBUG_PLAYLIST"] ?? ""
            let playlist = app.libraryPlaylists.first {
                wanted.isEmpty || $0.name.localizedCaseInsensitiveContains(wanted)
            }
            guard let playlist else { return }
            app.deepLinkTab = app.selectedTab
            app.presentedDeepLink = .playlist(playlist)
        case "com.lyra.debug.pop":
            app.debugPopRequests += 1
        case "com.lyra.debug.libraryTab":
            app.selectedTab = .library
        default:
            break
        }
    }
}
#endif
