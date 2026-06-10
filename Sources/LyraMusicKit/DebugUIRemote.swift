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
        observe("com.lyra.debug.ping")
        observe("com.lyra.debug.hangwatch")
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
        case "com.lyra.debug.hangwatch":
            startHangWatch()
        case "com.lyra.debug.ping":
            // Main-thread responsiveness probe: handle() already hops to the
            // main actor, so the pong's latency ≈ how long the main thread was
            // busy. Pair with `notifyutil -1 com.lyra.debug.pong` host-side.
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.lyra.debug.pong" as CFString),
                nil, nil, true
            )
        default:
            break
        }
    }

    // MARK: - Main-thread hang watcher

    private static var hangTimer: Timer?
    private static var lastBeat: CFAbsoluteTime = 0

    /// 30ms heartbeat on the main run loop; any gap > 120ms is a main-thread
    /// stall and gets appended to Documents/lyra-hangwatch.log, readable from
    /// the host via the app's data container.
    private static func startHangWatch() {
        guard hangTimer == nil else { return }
        lastBeat = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hangTimer = timer
    }

    private static func beat() {
        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - lastBeat
        lastBeat = now
        guard gap > 0.12 else { return }
        let line = String(format: "%.3f gap=%.0fms\n", now, gap * 1000)
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("lyra-hangwatch.log") else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif
