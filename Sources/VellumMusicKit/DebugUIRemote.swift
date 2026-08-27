#if DEBUG
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
        logLaunchMarker()
        // DEBUG builds only (whole file is #if DEBUG): always-on main-thread stall log so
        // device runs record hangs without needing the simulator-only notify trigger.
        startHangWatch()
        // Companion to the above: the hang watcher gives the duration, this gives the phase.
        startTurnWatch()
        observe("com.vellum.debug.openPlaylist")
        observe("com.vellum.debug.addToPlaylist")
        observe("com.vellum.debug.toast")
        observe("com.vellum.debug.deleteUITestPlaylists")
        observe("com.vellum.debug.pop")
        observe("com.vellum.debug.playFirst")
        observe("com.vellum.debug.playQueue")
        observe("com.vellum.debug.seedHistory")
        observe("com.vellum.debug.playHistoryQuery")
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
        case "com.vellum.debug.playQueue":
            // Like `playFirst`, but with a *full album* behind the needle, so the
            // queue list has more rows than fit on screen — the state the history
            // swipe has to work in.
            Task {
                let albums = app.libraryAlbums
                let wanted = ProcessInfo.processInfo.environment["VELLUM_DEBUG_ALBUM_QUERY"] ?? ""
                guard let album = albums.first(where: {
                          !wanted.isEmpty && $0.title.localizedCaseInsensitiveContains(wanted)
                      }) ?? albums.first(where: { ($0.trackCount ?? 0) >= 8 }) ?? albums.first,
                      let tracks = try? await app.activeLibrary?.tracks(forAlbumId: album.id),
                      !tracks.isEmpty else { return }
                try? await app.player.playAlbum(library: app.activeLibrary, tracks: tracks, startIndex: 0)
            }
        case "com.vellum.debug.seedHistory":
            // Fills the Now Playing → Queue → History list without waiting out the scrobble
            // threshold. `VELLUM_DEBUG_HISTORY_QUERY` picks the track (default: the demo
            // server's "lemmings in love", one of the few there that has server lyrics).
            Task {
                let query = ProcessInfo.processInfo.environment["VELLUM_DEBUG_HISTORY_QUERY"]
                    ?? "lemmings in love"
                guard let results = try? await app.activeLibrary?.searchCatalog(query: query, limit: 5)
                else { return }
                for track in results.songs.prefix(3).reversed() {
                    app.recordRecentTrackPlay(track)
                }
            }
        case "com.vellum.debug.playHistoryQuery":
            // The baseline for `seedHistory`: play that same track the ordinary way.
            Task {
                let query = ProcessInfo.processInfo.environment["VELLUM_DEBUG_HISTORY_QUERY"]
                    ?? "lemmings in love"
                guard let results = try? await app.activeLibrary?.searchCatalog(query: query, limit: 5),
                      let track = results.songs.first else { return }
                try? await app.player.playAlbum(library: app.activeLibrary, tracks: [track], startIndex: 0)
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

    /// Names the runloop phase a long main-thread turn was spent in.
    ///
    /// The hang watcher says *that* the main thread stalled and for how long. It cannot say
    /// what it was doing, which is why the ~300ms swipe-down stall has stayed anonymous: it
    /// falls in a window where nothing else logs. A runloop observer fires on every phase
    /// boundary, so the gap between two consecutive boundaries is one attributable span —
    /// and the phase names say which kind of work it was:
    ///
    ///   - `beforeSources → beforeWaiting` is app + UIKit work for this turn, and a
    ///     `CATransaction` commit (layout, display, SwiftUI render) lands at its end.
    ///   - `afterWaiting → beforeSources` is source0/source1 delivery — a callback.
    ///   - anything `→ afterWaiting` is the thread having been idle, not stalled.
    ///
    /// Threshold is well above a dropped frame so ordinary rendering stays silent.
    private static var turnObserver: CFRunLoopObserver?
    private static var lastTurnAt: CFAbsoluteTime = 0
    private static var lastTurnPhase = "start"

    private static func startTurnWatch() {
        guard turnObserver == nil else { return }
        lastTurnAt = CFAbsoluteTimeGetCurrent()
        let activities: CFRunLoopActivity = [
            .entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit,
        ]
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0,
        ) { _, activity in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastTurnAt
                let phase: String
                switch activity {
                case .entry: phase = "entry"
                case .beforeTimers: phase = "beforeTimers"
                case .beforeSources: phase = "beforeSources"
                case .beforeWaiting: phase = "beforeWaiting"
                case .afterWaiting: phase = "afterWaiting"
                case .exit: phase = "exit"
                default: phase = "other"
                }
                // `→ afterWaiting` means the thread was parked, which is not a stall.
                if elapsed > 0.06, phase != "afterWaiting" {
                    log(String(format: "SLOWTURN %@→%@ %.0fms", lastTurnPhase, phase, elapsed * 1000))
                }
                lastTurnAt = now
                lastTurnPhase = phase
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        turnObserver = observer
    }

    /// Times a block and logs it only when it is slow enough to matter.
    ///
    /// Investigation instrumentation for the swipe-down stall (T054). The hang watcher says
    /// *that* the main thread stalled and for how long; this says *which* span it was in.
    /// Threshold-gated because ``log(_:)`` opens, seeks, writes and closes the file on the
    /// calling thread — logging every span unconditionally would add its own cost to the very
    /// path being measured.
    @discardableResult
    static func span<T>(_ label: String, minMs: Double = 8, _ body: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if ms >= minMs { log(String(format: "NP-PERF %@=%.0fms", label, ms)) }
        return result
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

    /// The one thing this log was missing.
    ///
    /// It is append-only across installs, so a build's lines sit directly after the previous
    /// build's with nothing between them. Whole rounds of wrong conclusions have come from
    /// reading a region that belonged to two builds earlier and calling it a measurement.
    ///
    ///     grep -n "===== LAUNCH" hw.log | tail -1
    ///
    /// gives the first line of the current run; read only past it. The binary's modification
    /// date distinguishes a fresh build from a relaunch of the same one.
    private static func logLaunchMarker() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        var built = "unknown"
        if let executable = Bundle.main.executableURL,
           let modified = try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            built = formatter.string(from: modified)
        }
        log("===== LAUNCH \(formatter.string(from: Date())) build=\(built) "
            + "os=\(ProcessInfo.processInfo.operatingSystemVersionString) =====")
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
        // Timers don't fire while the app is suspended, so backgrounding also shows up as
        // a huge "hang". Record the app state rather than filtering by duration — a long
        // gap while `.active` is a genuine stall and must not be hidden.
        let state: String
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        #else
        state = "n/a"
        #endif
        log(String(format: "HANG gap=%.0fms state=%@ (ended now, started %.3f)", gap * 1000, state, now - gap))
    }
}
#endif
