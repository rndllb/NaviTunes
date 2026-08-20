#if DEBUG
import SwiftUI

/// Simulator-only remote control for UI verification — the project has no UI
/// test target, so transitions and open/close performance are exercised from
/// the command line via Darwin notifications:
///
///     xcrun simctl spawn booted notifyutil -p com.vellum.debug.openPlaylist
///     xcrun simctl spawn booted notifyutil -p com.vellum.debug.pop
///
/// `openPlaylist` pushes the playlist whose name contains the
/// `VELLUM_DEBUG_PLAYLIST` launch environment value (first user playlist when
/// unset) through the same ``NowPlayingDeepLink`` path a real navigation
/// takes; `pop` pops the active tab's stack. Compiled out of Release builds.
@MainActor
enum DebugUIRemote {
    private static weak var app: AppModel?
    private static var installed = false

    /// Timeline markers the UI tests may post — the Darwin notify center has
    /// no wildcard observation (nil name is unsupported), so every observable
    /// name must be registered up front.
    private static let markLabels = [
        "tap-pin", "edge-swipe-begin", "edge-swipe-end",
        "scroll-1", "scroll-2", "scroll-done", "test-end",
        "variant-1", "variant-2", "variant-3", "variant-4", "variant-5",
        "variant-found", "variant-none",
    ]

    static func install(app model: AppModel) {
        app = model
        guard !installed else { return }
        installed = true
        // DEBUG builds only (whole file is #if DEBUG): always-on main-thread stall log so
        // device runs record hangs without needing the simulator-only notify trigger.
        startHangWatch()
        observe("com.vellum.debug.openPlaylist")
        observe("com.vellum.debug.addToPlaylist")
        observe("com.vellum.debug.toast")
        observe("com.vellum.debug.deleteUITestPlaylists")
        observe("com.vellum.debug.pop")
        observe("com.vellum.debug.playFirst")
        observe("com.vellum.debug.openPlayer")
        observe("com.vellum.debug.libraryTab")
        observe("com.vellum.debug.ping")
        observe("com.vellum.debug.hangwatch")
        for label in markLabels {
            observe("com.vellum.debug.mark." + label)
        }
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
        case "com.vellum.debug.openPlaylist":
            let wanted = ProcessInfo.processInfo.environment["VELLUM_DEBUG_PLAYLIST"] ?? ""
            let playlist = app.libraryPlaylists.first {
                wanted.isEmpty || $0.name.localizedCaseInsensitiveContains(wanted)
            }
            guard let playlist else { return }
            app.deepLinkTab = app.selectedTab
            app.presentedDeepLink = .playlist(playlist)
        case "com.vellum.debug.addToPlaylist":
            // Opens the add-to-playlist sheet with any resolvable track so its
            // layout can be screenshot-verified without scripted taps.
            let track = app.recentlyPlayedTracks.first
                ?? app.libraryPlaylists.lazy
                    .compactMap { app.cachedPlaylistRows(playlistId: $0.id)?.first?.track }
                    .first
            if let track { app.presentAddToPlaylist(tracks: [track]) }
        case "com.vellum.debug.toast":
            // Renders the rich confirmation toast for screenshot verification.
            app.showTransientToast(TransientToastContent(
                title: "1 song added",
                subtitle: "vellum toast check",
                artworkURL: app.libraryPlaylists.first?.artworkURL
            ))
        case "com.vellum.debug.deleteUITestPlaylists":
            // Cleanup hook for scratch playlists created by the UI tests.
            Task {
                for playlist in app.libraryPlaylists where playlist.name.hasPrefix("vellum ui test") {
                    try? await app.deletePlaylist(playlistId: playlist.id)
                }
                await app.refreshLibraryPlaylists()
            }
        case "com.vellum.debug.pop":
            app.debugPopRequests += 1
        case "com.vellum.debug.playFirst":
            // Starts playback of any resolvable track so the Now Playing main
            // view can be screenshot-verified (paused is fine — chrome is the
            // subject, not audio).
            let track = app.recentlyPlayedTracks.first
                ?? app.libraryPlaylists.lazy
                    .compactMap { app.cachedPlaylistRows(playlistId: $0.id)?.first?.track }
                    .first
            if let track {
                Task { try? await app.player.playAlbum(library: app.activeLibrary, tracks: [track], startIndex: 0) }
            }
        case "com.vellum.debug.openPlayer":
            app.debugOpenPlayerRequests += 1
        case "com.vellum.debug.libraryTab":
            app.selectedTab = .library
        case "com.vellum.debug.hangwatch":
            startHangWatch()
        case "com.vellum.debug.ping":
            // Main-thread responsiveness probe: handle() already hops to the
            // main actor, so the pong's latency ≈ how long the main thread was
            // busy. Pair with `notifyutil -1 com.vellum.debug.pong` host-side.
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.vellum.debug.pong" as CFString),
                nil, nil, true
            )
        default:
            if name.hasPrefix("com.vellum.debug.mark.") {
                log("MARK " + name.dropFirst("com.vellum.debug.mark.".count))
            }
        }
    }

    /// Appends a timestamped line to the shared verification log — same file
    /// the hang watcher writes, so external markers, app events, and stalls
    /// form one timeline.
    static func log(_ message: String) {
        let line = String(format: "%.3f %@\n", CFAbsoluteTimeGetCurrent(), message)
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("vellum-hangwatch.log") else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Main-thread hang watcher

    private static var hangTimer: Timer?
    private static var lastBeat: CFAbsoluteTime = 0

    /// 30ms heartbeat on the main run loop; any gap > 120ms is a main-thread
    /// stall and gets appended to Documents/vellum-hangwatch.log, readable from
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
        log(String(format: "HANG gap=%.0fms (ended now, started %.3f)", gap * 1000, now - gap))
    }
}
#endif
