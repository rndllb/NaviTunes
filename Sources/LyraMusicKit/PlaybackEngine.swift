import AVFoundation
import CoreGraphics
import MediaPlayer
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private enum PlaybackEngineError: LocalizedError {
    case missingLibrary
    case missingTrack

    var errorDescription: String? {
        switch self {
        case .missingLibrary: return "No music library connection."
        case .missingTrack: return "Nothing to play."
        }
    }
}

enum ShuffleMode { case off, on }
enum RepeatMode { case off, all, one }

/// Where the current playback queue came from, so the Now Playing UI can offer
/// "Go to Playlist" / "Go to Album" navigation. `nil` = ad-hoc queue with no origin.
enum PlaybackSource: Equatable {
    case playlist(PlaylistSummary)
}

/// The playback clock, isolated from ``PlaybackEngine``'s `objectWillChange`.
/// `currentTime` ticks every ~0.35s during playback; publishing it through the
/// engine re-evaluated every observing view per tick — including the full Now
/// Playing body (whose queue page scales with queue length) and the mini player.
/// Only views that *display* time (scrubber, lyrics sync) observe this object.
@MainActor
final class PlaybackTimeModel: ObservableObject {
    @Published fileprivate(set) var currentTime: TimeInterval = 0
}

@MainActor
final class PlaybackEngine: NSObject, ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int = 0
    /// IDs of tracks that were inserted into the queue via "Play Next" / "Add to Queue"
    /// (vs. items that came from the active source like an album or playlist). Drives the
    /// Now Playing → Queue → "Queue" vs "Continue Playing" split.
    @Published private(set) var userQueuedTrackIds: Set<String> = []
    @Published private(set) var isPlaying: Bool = false
    /// True while the player intends to play but audio is not progressing —
    /// loading a new item or stalled waiting for the network to buffer. Drives
    /// the transport spinner so controls never claim "playing" during a stall.
    @Published private(set) var isBuffering: Bool = false
    /// UI-throttled playhead — published via ``time`` (see ``PlaybackTimeModel``),
    /// not this object, so per-tick updates don't re-render every player view.
    let time = PlaybackTimeModel()
    private(set) var currentTime: TimeInterval {
        get { time.currentTime }
        set { time.currentTime = newValue }
    }
    /// Live playhead updated every periodic observer tick. Prefer over ``currentTime`` for synced lyrics — ``currentTime`` is UI-throttled.
    var livePlaybackTime: TimeInterval { playbackHead }
    @Published private(set) var duration: TimeInterval = 0
    /// Delivered audio format for the Now Playing badge ("FLAC", "MP3 320").
    /// Reflects the candidate that actually loaded — a transcoded stream
    /// reports the transcode target, not the file's source codec.
    @Published private(set) var nowPlayingFormatLabel: String?
    @Published private(set) var lyrics: [LyricLine] = []
    @Published var shuffleMode: ShuffleMode = .off
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var playbackSource: PlaybackSource?
    /// User preference mirrored from ``AppModel`` — drives optional Now Playing chrome.
    var showSkipIntervalButtons = false
    var showSleepTimerButton = false
    var skipBackwardInterval: TimeInterval = 15
    var skipForwardInterval: TimeInterval = 30
    var remoteControlMode: RemoteControlMode = .skipTrack
    @Published var playbackRate: Float = 1.0
    @Published private(set) var sleepTimerEndDate: Date?
    /// Proactive album metadata refresh before loading a stream (``AppModel``).
    var refreshTrackBeforePlay: ((Track) async -> Track)?
    /// Reactive stale-id recovery when every stream candidate fails (``AppModel``).
    var recoverStaleTrackOnFailure: ((Track) async -> StaleSongRecoveryResult?)?
    /// Drives the tab-bar mini player pill — false after a cold restore until the user starts playback.
    @Published private(set) var showsMiniPlayerChrome = false
    /// Stores the pre-shuffle queue order for restoring when shuffle is toggled off.
    private var unshuffledQueue: [Track]?
    /// Natural ordered track list from the most recently loaded source — used to detect
    /// manual queue reordering and to restore order when shuffle is disabled.
    private var sourceQueueOrder: [Track]?

    private var lastEmittedUIProgress: TimeInterval = -10_000
    private var lastNowPlayingInfoRefresh: TimeInterval = -10_000
    private var playbackHead: TimeInterval = 0
    /// Seek target carried from a persisted queue restore — applied on the first play tap when the AVPlayer is still nil.
    private var pendingRestoreSeconds: TimeInterval = 0
    private var isSeeking = false
    /// Ignores stale periodic time samples until after a scrub seek settles.
    private var seekSettleDeadline: ContinuousClock.Instant?
    private var seekGeneration = 0
    /// Probed length of the current local file — avoids bad `AVPlayerItem.duration` flicker on downloads.
    private var localFileDuration: TimeInterval = 0
    private var probingLocalFileURL: URL?
    /// Coalesces overlapping skip/end/advance requests so only one load cycle runs at a time.
    private var advanceWork: Task<Void, Never>?
    /// Re-kicks AVPlayer when `playImmediately` doesn't stick (common after track handoff).
    private var autoplayVerifyTask: Task<Void, Never>?
    /// Captured at skip/jump/end before the async ``advance()`` task runs — avoids losing play intent.
    private var shouldAutoPlayAfterAdvance = false
    /// When a track is inserted via Play Next / Add to Queue from a playlist detail view, remember
    /// which playlist it came from so Now Playing → Go to Playlist navigates correctly.
    private var trackOriginPlaylistIds: [String: String] = [:]
    /// True while ``advance()`` is loading the next item — ignores stale `.paused` KVO during handoff.
    private var isAdvancingToNextItem = false

    private var player: AVPlayer?
    /// Same instance as ``player`` (an `AVQueuePlayer`), typed for queue ops. The
    /// engine keeps the *next* track enqueued so iOS performs the end-of-track
    /// transition in its media daemon — gaplessly and, crucially, reliably while
    /// backgrounded (an app-driven teardown/rebuild at a track boundary can't
    /// complete in the background and silently stops playback).
    private var queuePlayer: AVQueuePlayer? { player as? AVQueuePlayer }
    /// The pre-enqueued next item and the queue index/track it represents, so
    /// ``handleEnded`` can promote bookkeeping in place after the OS auto-advances.
    private var enqueuedNextItem: AVPlayerItem?
    private var enqueuedNextIndex: Int?
    private var enqueuedNextTrack: Track?
    /// HanSJin-style ``AVAudioUnitEQ`` path — local files only (downloads + stream cache).
    private var equalizedPlayer: EqualizedAudioEnginePlayer?
    private var equalizedPlaybackURL: URL?
    private var equalizedPlaybackAsset: AVURLAsset?
    private var equalizedPlaybackHeaders: [String: String] = [:]
    private var equalizedEndEpoch: UInt = 0
    /// Swaps AVPlayer → EQ engine once a stream finishes caching mid-playback.
    private var eqCacheHandoffTask: Task<Void, Never>?

    var equalizerEnabled = false
    var equalizerBypass = false
    var equalizerBandGains: [Float] = EqualizerBand.flatGains

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    /// A single pre-warmed `AVURLAsset` for the track that will play next, keyed by
    /// its stream URL. Created (and its `.isPlayable` key loaded) while the current
    /// track is playing so a skip reuses a warm asset instead of doing the DNS /
    /// TLS / HTTP-header handshake cold on tap. ``makePlaybackAsset`` consumes it.
    private var prewarmedAssets: [String: AVURLAsset] = [:]
    /// On-disk stream cache for instant replays of fully cached tracks. Off by
    /// default. Live streams always use plain http(s) URLs — AVFoundation probes
    /// custom-scheme asset URLs with URLSession and breaks playback.
    private var streamingDiskCacheEnabled: Bool {
        UserDefaults.standard.bool(forKey: "streamingDiskCacheEnabled")
    }
    /// KVO on `AVPlayer.timeControlStatus` — the system-set property reflecting
    /// what playback is actually doing. Catches every external pause cause
    /// (headphone unplug, Control Center, network stall, audio session steal)
    /// in one place so ``isPlaying`` never goes stale.
    private var timeControlStatusObservation: NSKeyValueObservation?
    /// Armed while the player sits in `.waitingToPlayAtSpecifiedRate`; if the stall
    /// outlives its budget the engine reloads the current item at the playhead
    /// instead of waiting forever on a dead connection.
    private var stallRecoveryTask: Task<Void, Never>?
    /// Bumped whenever a new load/play cycle begins so in-flight `startCurrentItem` work
    /// from an earlier tap cannot attach or start another `AVPlayer`.
    private var playbackEpoch: UInt = 0
    /// Prevents stacked `startFromPendingRestore` tasks when play is tapped repeatedly.
    private var isStartingPlayback = false

    private var library: MusicLibraryProviding?
    private weak var offline: OfflineDownloadManager?
    private var scrobbledForCurrentTrack = false
    private var resolveArtwork: ((Track) -> URL?)?

    /// Fires once per track when scrobble threshold is reached (~50% / 30s). `AppModel`
    /// uses this to stamp the played playlist (or album, for ad-hoc queues) into the
    /// Recently Played shelf on the Home tab.
    var onTrackScrobbled: ((Track, PlaybackSource?) -> Void)?

    /// Fires the moment a track becomes the active item at position 0 — whether the
    /// user tapped it, jumped to it, or auto-advanced. Drives the per-track Now Playing
    /// → Queue → History list, which records on start (not on scrobble threshold).
    var onTrackStarted: ((Track) -> Void)?
    var onAudioRouteChanged: (() -> Void)?

    /// Fires the moment the user explicitly skips forward (`skipNext`). NOT fired by
    /// natural end-of-track advances or by `skipPrevious`. Drives Kill Mode's
    /// "mark for removal" path — `AppModel` inspects the source + queue to decide
    /// whether to mark the outgoing track.
    var onTrackSkipped: ((Track, PlaybackSource?) -> Void)?

    private var didConfigureRemoteCommands = false
    private var sleepTimerTask: Task<Void, Never>?
    private var nextTrackRemoteTarget: Any?
    private var previousTrackRemoteTarget: Any?
    private var skipForwardRemoteTarget: Any?
    private var skipBackwardRemoteTarget: Any?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkTrackId: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    #if os(iOS)
    private var audioSessionInterruptionObserver: NSObjectProtocol?
    private var audioSessionRouteObserver: NSObjectProtocol?
    private var didInstallAudioSessionObservers = false
    /// Captures `isPlaying` when an interruption begins so we can decide on
    /// `.ended` whether to resume — `isPlaying` itself is flipped to `false`
    /// on `.began` to keep the transport button in sync with the system pause.
    private var wasPlayingBeforeInterruption = false
    #endif

    func bind(offline: OfflineDownloadManager? = nil, resolveArtwork: ((Track) -> URL?)? = nil) {
        self.offline = offline
        self.resolveArtwork = resolveArtwork
        #if os(iOS)
        installAudioSessionObserversIfNeeded()
        #endif
        activateAudioSession()
    }

    #if os(iOS)
    private func installAudioSessionObserversIfNeeded() {
        guard !didInstallAudioSessionObservers else { return }
        didInstallAudioSessionObservers = true
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        audioSessionInterruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main,
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioSessionInterruption(note) }
        }
        audioSessionRouteObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main,
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioSessionRouteChange(note) }
        }
    }
    #endif

    func reconcilePlaybackSessionAfterUIMilestone() {
        activateAudioSession()
        if let equalizedPlayer {
            if isPlaying, !equalizedPlayer.isPlaying {
                equalizedPlayer.play(rate: playbackRate)
            } else {
                refreshNowPlaying()
            }
            return
        }
        guard let player else { return }
        player.isMuted = false
        if player.volume < 0.001 { player.volume = 1.0 }
        if isPlaying, player.rate < 0.01 { beginPlayback(on: player) }
        else { refreshNowPlaying() }
    }

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .default,
            options: [.allowBluetoothA2DP, .allowAirPlay],
        )
        try? session.setActive(true, options: [])
        #endif
    }

    #if os(iOS)
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            // iOS has already paused AVPlayer (phone call, Siri, another app
            // taking the audio session). Mirror that into ``isPlaying`` so the
            // transport button stops showing the pause glyph while playback
            // is silently halted.
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            refreshNowPlaying()
        case .ended:
            let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            let shouldResume = wasPlayingBeforeInterruption && opts.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }
            activateAudioSession()
            if let player { beginPlayback(on: player) }
            isPlaying = true
        @unknown default:
            break
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        // Don't auto-resume — when the user unplugs headphones the system
        // pauses us on purpose (HIG: respect that intent), and the
        // `timeControlStatus` KVO will sync ``isPlaying`` to match. Any other
        // route change (new device available, override, etc.) likewise
        // shouldn't force playback to keep going if the system paused us.
        _ = notification
        onAudioRouteChanged?()
    }
    #endif

    var activeTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Playlist the given queue item was queued from (Play Next / Add to Queue), if any.
    func originPlaylistId(forTrackId trackId: String) -> String? {
        trackOriginPlaylistIds[trackId]
    }

    private func recordTrackOriginPlaylist(_ trackIds: some Sequence<String>, playlistId: String?) {
        guard let playlistId else { return }
        for id in trackIds {
            trackOriginPlaylistIds[id] = playlistId
        }
    }

    private func clearTrackOriginPlaylists(_ trackIds: some Sequence<String>) {
        for id in trackIds {
            trackOriginPlaylistIds.removeValue(forKey: id)
        }
    }

    private func revealMiniPlayerChrome() {
        guard activeTrack != nil else { return }
        showsMiniPlayerChrome = true
    }

    func reset() {
        cancelPendingAdvanceWork()
        teardownPlayer()
        queue = []
        currentIndex = 0
        lyrics = []
        didConfigureRemoteCommands = false
        currentTime = 0
        playbackHead = 0
        pendingRestoreSeconds = 0
        isPlaying = false
        duration = 0
        playbackSource = nil
        showsMiniPlayerChrome = false
        userQueuedTrackIds.removeAll()
        trackOriginPlaylistIds.removeAll()
        unshuffledQueue = nil
        cancelNowPlayingArtworkLoad()
        updateNowPlaying(nil)
    }

    /// Encodable copy of the current playback queue + playhead, used by `AppModel` to persist across launches.
    /// Returns `nil` when the queue is empty so we don't overwrite a useful saved snapshot with garbage.
    func currentSnapshot() -> PlaybackQueueSnapshot? {
        guard !queue.isEmpty else { return nil }
        let livePosition = player?.currentTime().seconds ?? playbackHead
        let position: TimeInterval = {
            if livePosition.isFinite, livePosition >= 0 { return livePosition }
            return max(0, currentTime)
        }()
        let playlist: PlaylistSummary? = {
            switch playbackSource {
            case .playlist(let p): return p
            case .none: return nil
            }
        }()
        return PlaybackQueueSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            position: position,
            playlistSource: playlist,
            shuffle: shuffleMode == .on,
            repeatMode: Self.encodeRepeatMode(repeatMode),
            savedAt: Date(),
            unshuffledQueue: unshuffledQueue,
            sourceQueueOrder: sourceQueueOrder,
        )
    }

    /// Repopulates the queue + index + transport modes from a saved snapshot **without** starting playback.
    /// The first play tap (mini player / lock screen) resumes from `pendingRestoreSeconds`.
    func restore(library: MusicLibraryProviding?, snapshot: PlaybackQueueSnapshot) {
        guard !snapshot.queue.isEmpty else { return }
        cancelPendingAdvanceWork()
        teardownPlayer()
        if let library { self.library = library }
        queue = snapshot.queue
        let clampedIndex = min(max(0, snapshot.currentIndex), max(snapshot.queue.count - 1, 0))
        currentIndex = clampedIndex
        playbackSource = snapshot.playlistSource.map(PlaybackSource.playlist)
        shuffleMode = snapshot.shuffle ? .on : .off
        repeatMode = Self.decodeRepeatMode(snapshot.repeatMode)
        let pending = max(0, snapshot.position)
        pendingRestoreSeconds = pending
        playbackHead = pending
        currentTime = pending
        lastEmittedUIProgress = pending
        lyrics = []
        scrobbledForCurrentTrack = false
        isPlaying = false
        unshuffledQueue = snapshot.unshuffledQueue
        sourceQueueOrder = snapshot.sourceQueueOrder
        duration = activeTrack?.duration ?? 0
        // A restored snapshot represents real playback the user wants to resume — surface
        // the mini player so the saved track + playhead are visible on launch. Only the
        // never-played cold-launch path leaves this `false`.
        showsMiniPlayerChrome = activeTrack != nil
        configureRemoteCommandsIfNeeded()
        updateNowPlaying(nil)
    }

    private static func encodeRepeatMode(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return "off"
        case .all: return "all"
        case .one: return "one"
        }
    }

    private static func decodeRepeatMode(_ raw: String) -> RepeatMode {
        switch raw {
        case "all": return .all
        case "one": return .one
        default: return .off
        }
    }

    /// Returns `true` if there's a queue staged from a restore but no AVPlayer yet — caller should
    /// kick off ``startFromPendingRestore()`` instead of toggling the (nil) player.
    private var hasPendingRestore: Bool {
        player == nil && equalizedPlayer == nil && queue.indices.contains(currentIndex)
    }

    private var hasActivePlaybackOutput: Bool {
        player != nil || equalizedPlayer != nil
    }

    private func startFromPendingRestore() async {
        let epoch = beginPlaybackSession()
        let startAt = pendingRestoreSeconds
        pendingRestoreSeconds = 0
        activateAudioSession()
        do {
            try await startCurrentItem(epoch: epoch, startSeconds: startAt, autoPlay: true)
            guard isPlaybackEpochCurrent(epoch), hasActivePlaybackOutput else {
                isPlaying = false
                return
            }
            if let player, player.rate < 0.01 { beginPlayback(on: player) }
            else if let equalizedPlayer { equalizedPlayer.play(rate: playbackRate) }
            isPlaying = true
        } catch {
            // If the restored stream can't be reached (offline, server moved), leave the queue
            // intact and paused — the user can still skip/jump or try again later.
            isPlaying = false
        }
        revealMiniPlayerChrome()
    }

    /// Starts a fresh queue from the given natural-order tracks, randomizing playback order
    /// while remembering the original so the user can disable shuffle later and have the
    /// queue resume in its original chronological order. Sets ``shuffleMode`` to `.on` so
    /// the Now Playing shuffle button reflects the hero shuffle action.
    func playAlbumShuffled(library: MusicLibraryProviding?, tracks: [Track], source: PlaybackSource? = nil) async throws {
        guard !tracks.isEmpty else { return }
        try await playAlbum(library: library, tracks: tracks.shuffled(), startIndex: 0, source: source)
        unshuffledQueue = tracks
        sourceQueueOrder = tracks
        shuffleMode = .on
    }

    func playAlbum(library: MusicLibraryProviding?, tracks: [Track], startIndex: Int = 0, source: PlaybackSource? = nil) async throws {
        if let library { self.library = library }
        let normalized = tracksWithResolvedArtwork(tracks)
        let epoch = beginPlaybackSession()
        cancelPendingAdvanceWork()
        teardownPlayer()
        queue = normalized
        currentIndex = min(max(0, startIndex), max(normalized.count - 1, 0))
        playbackSource = source
        // Fresh source = no user-queued items yet.
        userQueuedTrackIds.removeAll()
        trackOriginPlaylistIds.removeAll()
        unshuffledQueue = nil
        sourceQueueOrder = normalized
        // Caller may flip this back to `.on` (e.g. ``playAlbumShuffled``) after the queue lands.
        shuffleMode = .off
        lastEmittedUIProgress = -10_000
        playbackHead = 0
        scheduleLyricsLoad()
        activateAudioSession()
        try await startCurrentItem(epoch: epoch, autoPlay: true)
        guard isPlaybackEpochCurrent(epoch), hasActivePlaybackOutput else {
            throw PlaybackEngineError.missingTrack
        }
        if let player {
            beginPlayback(on: player)
            ensurePlaybackStarted(on: player, epoch: epoch)
        } else if let equalizedPlayer {
            equalizedPlayer.play(rate: playbackRate)
        }
        isPlaying = true
        scrobbledForCurrentTrack = false
        configureRemoteCommandsIfNeeded()
        revealMiniPlayerChrome()
        schedulePrewarmNextTrack()
        if let started = activeTrack { onTrackStarted?(started) }
    }

    func playNext(library: MusicLibraryProviding?, track: Track, sourcePlaylistId: String? = nil) async throws {
        if let library { self.library = library }
        let normalized = tracksWithResolvedArtwork([track])[0]
        if queue.isEmpty {
            try await playAlbum(library: library, tracks: [normalized], startIndex: 0)
            return
        }
        removeUpcomingOccurrences(of: [normalized.id])
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(normalized, at: insertAt)
        userQueuedTrackIds.insert(normalized.id)
        recordTrackOriginPlaylist([normalized.id], playlistId: sourcePlaylistId)
        refreshEnqueuedNextItem()
    }

    func playTracksNext(library: MusicLibraryProviding?, tracks: [Track], sourcePlaylistId: String? = nil) async throws {
        guard !tracks.isEmpty else { return }
        if let library { self.library = library }
        if queue.isEmpty {
            try await playAlbum(library: library, tracks: tracks, startIndex: 0)
            return
        }
        let normalized = tracksWithResolvedArtwork(tracks)
        removeUpcomingOccurrences(of: Set(normalized.map(\.id)))
        let insertAt = min(currentIndex + 1, queue.count)
        for (i, t) in normalized.enumerated() {
            queue.insert(t, at: insertAt + i)
            userQueuedTrackIds.insert(t.id)
        }
        recordTrackOriginPlaylist(normalized.map(\.id), playlistId: sourcePlaylistId)
        refreshEnqueuedNextItem()
    }

    func addToQueue(library: MusicLibraryProviding?, track: Track, sourcePlaylistId: String? = nil) async throws {
        try await addTracksToQueue(library: library, tracks: [track], sourcePlaylistId: sourcePlaylistId)
    }

    func addTracksToQueue(library: MusicLibraryProviding?, tracks: [Track], sourcePlaylistId: String? = nil) async throws {
        guard !tracks.isEmpty else { return }
        if let library { self.library = library }
        if queue.isEmpty {
            try await playAlbum(library: library, tracks: tracks, startIndex: 0)
            return
        }
        let normalized = tracksWithResolvedArtwork(tracks)
        removeUpcomingOccurrences(of: Set(normalized.map(\.id)))
        queue.append(contentsOf: normalized)
        for t in normalized { userQueuedTrackIds.insert(t.id) }
        recordTrackOriginPlaylist(normalized.map(\.id), playlistId: sourcePlaylistId)
        refreshEnqueuedNextItem()
    }

    private func tracksWithResolvedArtwork(_ tracks: [Track]) -> [Track] {
        tracks.map { track in
            guard let url = resolveArtwork?(track) ?? track.artworkURL else { return track }
            return track.withArtworkURL(url)
        }
    }

    /// Strips later occurrences of `ids` from the up-next portion of `queue` so a
    /// re-insertion (Play Next / Add to Queue) doesn't leave a duplicate in its natural
    /// Continue Playing position. Active and already-played tracks are untouched.
    private func removeUpcomingOccurrences<S: Sequence>(of ids: S) where S.Element == String {
        let idSet = Set(ids)
        guard !idSet.isEmpty, currentIndex + 1 < queue.count else { return }
        let head = queue.prefix(currentIndex + 1)
        let tail = queue.suffix(from: currentIndex + 1).filter { !idSet.contains($0.id) }
        queue = Array(head) + Array(tail)
    }

    /// Removes everything in the user-queued section (Now Playing → Queue → "Clear").
    /// The active track and the source's natural Continue Playing list are preserved.
    func clearUserQueue() {
        guard !userQueuedTrackIds.isEmpty else { return }
        let ids = userQueuedTrackIds
        removeTracksFromQueue(trackIds: ids)
    }

    func removeTracksFromQueue(trackIds: Set<String>) {
        guard !trackIds.isEmpty, !queue.isEmpty else { return }
        let previousId = activeTrack?.id
        queue.removeAll { trackIds.contains($0.id) }
        userQueuedTrackIds.subtract(trackIds)
        clearTrackOriginPlaylists(trackIds)
        if queue.isEmpty {
            reset()
            return
        }
        if let previousId, let idx = queue.firstIndex(where: { $0.id == previousId }) {
            currentIndex = idx
            refreshEnqueuedNextItem()
            return
        }
        currentIndex = min(currentIndex, queue.count - 1)
        captureAutoPlayIntentForAdvance()
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func reloadForEqualizerSettingsChange() async {
        guard hasActivePlaybackOutput, queue.indices.contains(currentIndex) else { return }
        let wasPlaying = isPlaying
        let pos = playbackHead
        let epoch = beginPlaybackSession()
        teardownPlayer()
        do {
            try await startCurrentItem(epoch: epoch, startSeconds: pos, autoPlay: wasPlaying)
            if wasPlaying {
                isPlaying = true
            }
        } catch {
            isPlaying = false
        }
    }

    func togglePlayPause() {
        // Tapping the spinner while a track is still loading = "stop trying".
        // Invalidate the epoch so the in-flight load can't attach, and leave the
        // queue staged — the next tap goes through the pending-restore path.
        if player == nil, isBuffering {
            cancelPendingAdvanceWork()
            _ = beginPlaybackSession()
            shouldAutoPlayAfterAdvance = false
            isPlaying = false
            setBuffering(false)
            refreshNowPlaying()
            return
        }
        if hasPendingRestore {
            schedulePendingRestorePlayback()
            return
        }
        if let equalizedPlayer {
            if equalizedPlayer.isPlaying {
                equalizedPlayer.pause()
                isPlaying = false
            } else {
                equalizedPlayer.play(rate: playbackRate)
                isPlaying = true
            }
            playbackHead = equalizedPlayer.currentPlaybackTime()
            currentTime = playbackHead
            lastEmittedUIProgress = playbackHead
            revealMiniPlayerChrome()
            refreshNowPlaying()
            return
        }
        guard let player else { return }
        if player.rate > 0.01 {
            player.pause()
            isPlaying = false
        } else {
            // Track finished with nothing queued behind it (repeatMode .off, last track) →
            // AVPlayer is parked at duration; play() would be a no-op. Restart from 0.
            if let item = player.currentItem {
                let cur = item.currentTime().seconds
                let dur = item.duration.seconds
                if dur.isFinite, dur > 0, cur >= dur - 0.25 {
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            beginPlayback(on: player)
            isPlaying = true
        }
        playbackHead = player.currentTime().seconds
        currentTime = playbackHead
        lastEmittedUIProgress = playbackHead
        revealMiniPlayerChrome()
        refreshNowPlaying()
    }

    private func resumePlaybackFromRemoteCommand() {
        if hasPendingRestore {
            schedulePendingRestorePlayback()
            return
        }
        activateAudioSession()
        if let equalizedPlayer {
            if !equalizedPlayer.isPlaying {
                equalizedPlayer.play(rate: playbackRate)
                isPlaying = true
                playbackHead = equalizedPlayer.currentPlaybackTime()
            }
            return
        }
        guard player != nil else { return }
        if player?.rate ?? 0 < 0.01, let player {
            beginPlayback(on: player)
            isPlaying = true
            playbackHead = player.currentTime().seconds
        }
    }

    private func pausePlaybackFromRemoteCommand() {
        pausePlayback()
    }

    func pausePlayback() {
        if let equalizedPlayer {
            if equalizedPlayer.isPlaying {
                equalizedPlayer.pause()
                isPlaying = false
                playbackHead = equalizedPlayer.currentPlaybackTime()
                refreshNowPlaying()
            }
            return
        }
        guard let player else { return }
        if player.rate > 0.01 {
            player.pause()
            isPlaying = false
            playbackHead = player.currentTime().seconds
            refreshNowPlaying()
        }
    }

    /// Resolved length for scrubbing — prefers live `AVPlayerItem` duration, then cached engine/track metadata.
    var playbackDuration: TimeInterval {
        effectivePlaybackDuration()
    }

    /// Seek to a normalized scrub fraction in `0...1`.
    func seek(toFraction fraction: Double, completion: (() -> Void)? = nil) {
        Task {
            let d = await resolvePlaybackDuration()
            guard d > 0 else {
                completion?()
                return
            }
            let targetSeconds = max(0, min(fraction, 1)) * d
            await performSeek(toSeconds: targetSeconds, completion: completion)
        }
    }

    /// Backward-compatible alias — only values in `0...1` are valid fractions.
    func seek(to fraction: Double, completion: (() -> Void)? = nil) {
        seek(toFraction: fraction, completion: completion)
    }

    func seek(toSeconds targetSeconds: TimeInterval, completion: (() -> Void)? = nil) {
        Task {
            await performSeek(toSeconds: targetSeconds, completion: completion)
        }
    }

    private func performSeek(toSeconds targetSeconds: TimeInterval, completion: (() -> Void)?) async {
        let d = await resolvePlaybackDuration()
        guard d > 0 else {
            completion?()
            return
        }
        // Never land on the exact end — that fires AVPlayerItemDidPlayToEndTime
        // and advances the queue (same guard skipForward uses).
        let clamped = max(0, min(targetSeconds, max(0, d - 1.0)))
        pbLog("seek target=\(targetSeconds) resolvedDur=\(d) clamped=\(clamped) itemDur=\(player?.currentItem?.duration.seconds ?? -1)")

        if let equalizedPlayer,
           let asset = equalizedPlaybackAsset {
            seekGeneration += 1
            let generation = seekGeneration
            isSeeking = true
            seekSettleDeadline = ContinuousClock.now + .milliseconds(900)
            currentTime = clamped
            lastEmittedUIProgress = clamped
            playbackHead = clamped
            let wasPlaying = isPlaying && equalizedPlayer.isPlaying
            do {
                try await equalizedPlayer.seek(
                    to: clamped,
                    asset: asset,
                    fileURL: equalizedPlaybackURL?.isFileURL == true ? equalizedPlaybackURL : nil,
                    gains: equalizerBandGains,
                    bypass: equalizerBypass,
                    autoPlay: wasPlaying,
                    rate: playbackRate,
                )
                if wasPlaying { isPlaying = true }
            } catch {
                isPlaying = false
            }
            guard generation == seekGeneration else {
                completion?()
                return
            }
            playbackHead = equalizedPlayer.currentPlaybackTime()
            currentTime = playbackHead
            lastEmittedUIProgress = playbackHead
            isSeeking = false
            seekSettleDeadline = ContinuousClock.now + .milliseconds(400)
            refreshNowPlaying()
            completion?()
            return
        }

        guard let player else {
            completion?()
            return
        }

        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        seekSettleDeadline = ContinuousClock.now + .milliseconds(900)
        currentTime = clamped
        lastEmittedUIProgress = clamped
        playbackHead = clamped

        let wasPlaying = isPlaying && player.rate > 0.01
        player.pause()

        var ok = await awaitPlayerSeek(player, to: clamped)
        if !ok || !seekPositionMatches(player.currentTime().seconds, target: clamped) {
            ok = await awaitPlayerSeek(player, to: clamped, tolerance: 0.05)
        }

        if wasPlaying {
            beginPlayback(on: player)
            isPlaying = true
        }

        guard generation == seekGeneration else {
            completion?()
            return
        }

        let actual = player.currentTime().seconds
        if actual.isFinite, seekPositionMatches(actual, target: clamped) {
            playbackHead = actual
            currentTime = actual
            lastEmittedUIProgress = actual
        }

        isSeeking = false
        seekSettleDeadline = ContinuousClock.now + .milliseconds(400)
        refreshNowPlaying()
        completion?()
    }

    private func seekPositionMatches(_ actual: TimeInterval, target: TimeInterval) -> Bool {
        guard actual.isFinite else { return false }
        if target < 2 { return actual < 3 }
        return abs(actual - target) < 2.5
    }

    /// Ensures duration is known — critical for offline files where track metadata is often `0`.
    private func resolvePlaybackDuration() async -> TimeInterval {
        if localFileDuration > 0 { return localFileDuration }
        if duration > 0 { return duration }
        if let item = player?.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
                persistOfflineDurationIfNeeded(itemDuration)
                return itemDuration
            }
            let assetDuration = await LocalMediaDuration.seconds(asset: item.asset)
            if assetDuration > 0 {
                duration = assetDuration
                if (item.asset as? AVURLAsset)?.url.isFileURL == true {
                    localFileDuration = assetDuration
                }
                persistOfflineDurationIfNeeded(assetDuration)
                return assetDuration
            }
        }
        if let trackId = activeTrack?.id, let local = offline?.localFile(for: trackId) {
            let fileDuration = await LocalMediaDuration.seconds(at: local)
            if fileDuration > 0 {
                duration = fileDuration
                localFileDuration = fileDuration
                persistOfflineDurationIfNeeded(fileDuration)
                patchActiveQueueTrackDuration(fileDuration)
                return fileDuration
            }
        }
        if let trackDuration = activeTrack?.duration, trackDuration > 0 {
            duration = trackDuration
            return trackDuration
        }
        return 0
    }

    private func effectivePlaybackDuration() -> TimeInterval {
        if localFileDuration > 0 { return localFileDuration }
        if duration > 0 { return duration }
        if let item = player?.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 { return itemDuration }
        }
        if let trackDuration = activeTrack?.duration, trackDuration > 0 { return trackDuration }
        return 0
    }

    private func persistOfflineDurationIfNeeded(_ seconds: TimeInterval) {
        guard seconds > 0, let trackId = activeTrack?.id else { return }
        try? offline?.updateCachedTrackDuration(trackId: trackId, duration: seconds)
    }

    private func patchActiveQueueTrackDuration(_ seconds: TimeInterval) {
        guard seconds > 0, queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        guard track.duration <= 0 else { return }
        queue[currentIndex] = track.withDuration(seconds)
    }

    func skipNext() {
        pbLog("skipNext from idx=\(currentIndex)")
        // Shuffle is a queue-reordering action — advance sequentially regardless of mode.
        guard currentIndex + 1 < queue.count else { return }
        let outgoing = queue[currentIndex]
        onTrackSkipped?(outgoing, playbackSource)
        captureAutoPlayIntentForAdvance()
        currentIndex += 1
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func skipPrevious() {
        pbLog("skipPrevious from idx=\(currentIndex) currentTime=\(currentTime)")
        if currentTime > 3 {
            seek(toSeconds: 0)
            return
        }
        guard currentIndex > 0 else {
            seek(toSeconds: 0)
            return
        }
        captureAutoPlayIntentForAdvance()
        currentIndex -= 1
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func skipForward(by interval: TimeInterval? = nil) {
        let step = interval ?? skipForwardInterval
        guard step > 0 else { return }
        let head = currentPlaybackPosition()
        let d = effectivePlaybackDuration()
        guard d > 0 else { return }
        // Seeking to the exact end fires AVPlayerItemDidPlayToEndTime and advances the queue.
        let endGuard: TimeInterval = 1.0
        let maxTarget = max(0, d - endGuard)
        let target = min(maxTarget, head + step)
        guard target > head + 0.05 else { return }
        seek(toSeconds: target)
    }

    func skipBackward(by interval: TimeInterval? = nil) {
        let step = interval ?? skipBackwardInterval
        guard step > 0 else { return }
        let head = currentPlaybackPosition()
        let target = max(0, head - step)
        guard abs(target - head) > 0.05 else { return }
        seek(toSeconds: target)
    }

    /// Best-effort live playhead for interval skips (lock screen must not use throttled ``currentTime``).
    private func currentPlaybackPosition() -> TimeInterval {
        if let player {
            let t = player.currentTime().seconds
            if t.isFinite, t >= 0 { return t }
        }
        if playbackHead.isFinite, playbackHead > 0 { return playbackHead }
        return currentTime
    }

    func cyclePlaybackRate() {
        let rates = PlaybackRateOption.allCases.map(\.rawValue)
        guard let idx = rates.firstIndex(of: playbackRate) else {
            playbackRate = 1.0
            applyPlaybackRateToPlayer()
            return
        }
        let next = rates[(idx + 1) % rates.count]
        playbackRate = next
        applyPlaybackRateToPlayer()
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        applyPlaybackRateToPlayer()
    }

    func startSleepTimer(minutes: Int) {
        guard minutes > 0 else { return }
        startSleepTimer(until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func startSleepTimer(until endDate: Date) {
        cancelSleepTimer()
        sleepTimerEndDate = endDate
        let interval = endDate.timeIntervalSinceNow
        guard interval > 0 else {
            sleepTimerEndDate = nil
            return
        }
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.pausePlayback()
            self?.sleepTimerEndDate = nil
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    func updateRemoteCommands() {
        configureRemoteCommandsIfNeeded()
        let center = MPRemoteCommandCenter.shared()

        if let nextTrackRemoteTarget {
            center.nextTrackCommand.removeTarget(nextTrackRemoteTarget)
            self.nextTrackRemoteTarget = nil
        }
        if let previousTrackRemoteTarget {
            center.previousTrackCommand.removeTarget(previousTrackRemoteTarget)
            self.previousTrackRemoteTarget = nil
        }
        if let skipForwardRemoteTarget {
            center.skipForwardCommand.removeTarget(skipForwardRemoteTarget)
            self.skipForwardRemoteTarget = nil
        }
        if let skipBackwardRemoteTarget {
            center.skipBackwardCommand.removeTarget(skipBackwardRemoteTarget)
            self.skipBackwardRemoteTarget = nil
        }
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)

        switch remoteControlMode {
        case .skipTrack:
            center.nextTrackCommand.isEnabled = true
            center.previousTrackCommand.isEnabled = true
            center.skipForwardCommand.isEnabled = false
            center.skipBackwardCommand.isEnabled = false

            nextTrackRemoteTarget = center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skipNext() }
                return .success
            }
            previousTrackRemoteTarget = center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skipPrevious() }
                return .success
            }
        case .skipInterval:
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
            center.skipForwardCommand.isEnabled = true
            center.skipBackwardCommand.isEnabled = true
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]

            skipForwardRemoteTarget = center.skipForwardCommand.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                let step = (event as? MPSkipIntervalCommandEvent)?.interval ?? self.skipForwardInterval
                Task { @MainActor in self.skipForward(by: step) }
                return .success
            }
            skipBackwardRemoteTarget = center.skipBackwardCommand.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                let step = (event as? MPSkipIntervalCommandEvent)?.interval ?? self.skipBackwardInterval
                Task { @MainActor in self.skipBackward(by: step) }
                return .success
            }
        }
    }

    /// True when the "continue playing" section is out of the natural source order, but shuffle
    /// was not used — e.g. the user dragged tracks in the queue. Also returns true when
    /// `shuffleMode == .on` so the shuffle button stays lit in both entry paths.
    var isQueueOutOfNaturalOrder: Bool {
        if shuffleMode == .on { return true }
        guard let source = sourceQueueOrder,
              let current = activeTrack,
              let sourceIdx = source.firstIndex(where: { $0.id == current.id })
        else { return false }
        let continuePlaying = queue[(currentIndex + 1)...].filter { !userQueuedTrackIds.contains($0.id) }
        let expectedTail = Array(source[(sourceIdx + 1)...])
        guard continuePlaying.count == expectedTail.count else { return true }
        return zip(continuePlaying, expectedTail).contains { $0.id != $1.id }
    }

    func toggleShuffle() {
        if shuffleMode == .off {
            // Turning shuffle ON: save current queue and randomize the rest.
            // Bail if there's no valid current track (empty/invalid queue) —
            // remove(at:) below would otherwise crash on an out-of-range index.
            guard queue.indices.contains(currentIndex) else { return }
            unshuffledQueue = queue
            let currentTrack = activeTrack
            var remaining = queue
            remaining.remove(at: currentIndex)
            remaining.shuffle()
            if let current = currentTrack {
                queue = [current] + remaining
                currentIndex = 0
            }
            shuffleMode = .on
        } else {
            // Turning shuffle OFF: restore original queue order
            if let original = unshuffledQueue {
                if let currentTrack = activeTrack, let originalIndex = original.firstIndex(where: { $0.id == currentTrack.id }) {
                    queue = original
                    currentIndex = originalIndex
                } else {
                    queue = original
                }
                unshuffledQueue = nil
            } else if let source = sourceQueueOrder,
                      let currentTrack = activeTrack,
                      let sourceIdx = source.firstIndex(where: { $0.id == currentTrack.id }) {
                // Manually reordered without using shuffle button — restore natural tail,
                // keeping user-queued tracks at their current positions.
                let naturalTail = Array(source[(sourceIdx + 1)...])
                let userQueued = Array(queue[(currentIndex + 1)...].filter { userQueuedTrackIds.contains($0.id) })
                let prefix = Array(queue[...currentIndex])
                queue = prefix + userQueued + naturalTail
            }
            shuffleMode = .off
        }
        refreshEnqueuedNextItem()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        refreshEnqueuedNextItem()
    }

    func jumpToQueueItem(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        captureAutoPlayIntentForAdvance()
        currentIndex = index
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func moveUpNextItem(from source: IndexSet, to destination: Int) {
        let offset = currentIndex + 1
        guard offset <= queue.count else { return }
        var upNext = Array(queue[offset...])
        upNext.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(offset..., with: upNext)
        refreshEnqueuedNextItem()
    }

    private func captureAutoPlayIntentForAdvance() {
        if isPlaying || (player?.rate ?? 0) > 0.01 {
            shouldAutoPlayAfterAdvance = true
        }
    }

    private func resetUIProgressForTrackHandoff() {
        currentTime = 0
        playbackHead = 0
        lastEmittedUIProgress = -10_000
        lastNowPlayingInfoRefresh = -10_000
        // Format badge is per-track: clear on handoff, NOT in teardownPlayer —
        // teardown also runs for same-track reloads (stall recovery, EQ
        // handoff) and nil-ing there made the badge flicker out mid-song.
        if nowPlayingFormatLabel != nil { pbLog("format label cleared (track handoff)") }
        nowPlayingFormatLabel = nil
        spuriousEndRecoveryAttempted = false
    }

    private func cancelPendingAdvanceWork() {
        advanceWork?.cancel()
        advanceWork = nil
        autoplayVerifyTask?.cancel()
        autoplayVerifyTask = nil
    }

    private func scheduleAdvance() {
        advanceWork?.cancel()
        advanceWork = Task { [weak self] in
            guard let self else { return }
            try? await self.advance()
        }
    }

    private func advance() async throws {
        // A skip/jump abandons the saved playhead for the previously-active track.
        pendingRestoreSeconds = 0
        // Capture before teardown — new AVPlayer starts `.paused` and KVO must not clear intent.
        let shouldAutoPlay = shouldAutoPlayAfterAdvance || isPlaying || (player?.rate ?? 0) > 0.01 || (equalizedPlayer?.isPlaying ?? false)
        shouldAutoPlayAfterAdvance = false
        if shouldAutoPlay { setBuffering(true) }
        if let track = currentTrack, refreshTrackBeforePlay != nil {
            let refreshed = await refreshedTrackForPlay(track)
            if refreshed.id != track.id, queue.indices.contains(currentIndex) {
                queue[currentIndex] = refreshed
            }
        }
        let epoch = beginPlaybackSession()
        isAdvancingToNextItem = true
        defer { isAdvancingToNextItem = false }
        teardownPlayer()
        scheduleLyricsLoad()
        guard isPlaybackEpochCurrent(epoch) else { return }
        activateAudioSession()
        // We already ran `refreshTrackBeforePlay` above — don't pay for it a
        // second time inside startCurrentItem.
        try await startCurrentItem(epoch: epoch, autoPlay: shouldAutoPlay, skipTrackRefresh: true)
        guard isPlaybackEpochCurrent(epoch), hasActivePlaybackOutput else {
            isPlaying = false
            refreshNowPlaying()
            return
        }
        if shouldAutoPlay {
            if let player {
                beginPlayback(on: player)
                ensurePlaybackStarted(on: player, epoch: epoch)
            } else if let equalizedPlayer {
                equalizedPlayer.play(rate: playbackRate)
            }
            isPlaying = true
        } else {
            isPlaying = false
            refreshNowPlaying()
        }
        scrobbledForCurrentTrack = false
        revealMiniPlayerChrome()
        schedulePrewarmNextTrack()
        if let started = activeTrack {
            userQueuedTrackIds.remove(started.id)
            onTrackStarted?(started)
        }
    }

    /// AVPlayer sometimes stays paused after `playImmediately` (especially on the first
    /// stream load or right after a handoff). Re-kick without churning the audio session.
    private func ensurePlaybackStarted(on player: AVPlayer, epoch: UInt) {
        autoplayVerifyTask?.cancel()
        autoplayVerifyTask = Task { @MainActor [weak self] in
            var kicks = 0
            for _ in 0 ..< 12 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self, self.isPlaybackEpochCurrent(epoch), self.player === player else { return }
                let status = player.timeControlStatus
                if status == .playing { return }
                if status == .waitingToPlayAtSpecifiedRate { continue }
                guard self.isPlaying, kicks < 2 else { return }
                player.playImmediately(atRate: self.playbackRate)
                kicks += 1
            }
        }
    }

    /// Starts AVPlayer and updates lock screen / Dynamic Island playback rate.
    private func beginPlayback(on player: AVPlayer) {
        activateAudioSession()
        player.playImmediately(atRate: playbackRate)
        refreshNowPlaying()
    }

    private func applyPlaybackRateToPlayer() {
        if let equalizedPlayer, isPlaying {
            equalizedPlayer.play(rate: playbackRate)
        } else if let player, isPlaying {
            player.rate = playbackRate
        }
        refreshNowPlaying()
    }

    func applyLiveEqualizerGains() {
        equalizedPlayer?.applyGains(equalizerBandGains, bypass: equalizerBypass)
    }

    private func beginPlaybackSession() -> UInt {
        playbackEpoch &+= 1
        return playbackEpoch
    }

    private func isPlaybackEpochCurrent(_ epoch: UInt) -> Bool {
        epoch == playbackEpoch
    }

    private func schedulePendingRestorePlayback() {
        guard !isStartingPlayback else { return }
        isStartingPlayback = true
        Task {
            defer { isStartingPlayback = false }
            await startFromPendingRestore()
        }
    }

    private func stopPlayer(_ p: AVPlayer?) {
        guard let p else { return }
        p.pause()
        // AVQueuePlayer doesn't support replaceCurrentItem(with: nil) — clear its
        // whole queue (current + any enqueued next) instead.
        if let queue = p as? AVQueuePlayer {
            queue.removeAllItems()
        } else {
            p.replaceCurrentItem(with: nil)
        }
    }

    private func detachPlayerKeepingQueueState() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        cancelStallRecovery()
        stopPlayer(player)
        player = nil
        enqueuedNextItem = nil
        enqueuedNextIndex = nil
        enqueuedNextTrack = nil
        equalizedPlayer?.stop()
        equalizedPlayer = nil
        equalizedPlaybackURL = nil
        equalizedPlaybackAsset = nil
        equalizedPlaybackHeaders = [:]
        eqCacheHandoffTask?.cancel()
        eqCacheHandoffTask = nil
    }

    /// Pending delayed spinner — see `setBuffering(_:debounced:)`.
    private var bufferingDebounceTask: Task<Void, Never>?

    private func setBuffering(_ buffering: Bool, debounced: Bool = false) {
        bufferingDebounceTask?.cancel()
        bufferingDebounceTask = nil
        if buffering, debounced, !isBuffering {
            // `timeControlStatus` flaps into `.waitingToPlayAtSpecifiedRate` for a
            // frame or two around seeks, track handoff, and queue staging. Only
            // surface the spinner when the stall actually persists — a flashing
            // play/pause button reads as "always loading".
            bufferingDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.bufferingDebounceTask = nil
                self.applyBuffering(true)
            }
            return
        }
        applyBuffering(buffering)
    }

    private func applyBuffering(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        isBuffering = buffering
        // Lock screen / Control Center must drop to rate 0 while stalled so the
        // system UI doesn't advance a phantom playhead.
        refreshNowPlaying()
    }

    /// How long the player may sit in `.waitingToPlayAtSpecifiedRate` before the
    /// engine assumes the connection is dead and reloads the item. Long enough
    /// that ordinary slow-network buffering finishes first.
    private static let stallRecoveryBudget: Duration = .seconds(15)

    private func scheduleStallRecoveryIfNeeded() {
        guard stallRecoveryTask == nil else { return }
        stallRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stallRecoveryBudget)
            guard !Task.isCancelled, let self else { return }
            self.recoverFromPlaybackStall()
        }
    }

    private func cancelStallRecovery() {
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
    }

    /// A stall outlived its budget: tear the wedged AVPlayer down and reload the
    /// current track at the playhead. Reuses the normal load path, so the offline
    /// copy / cache / fallback-format candidates all get another chance and stale
    /// recovery still applies if the stream id died mid-play.
    private func recoverFromPlaybackStall() {
        stallRecoveryTask = nil
        guard let player, player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        guard let track = currentTrack, !track.isInternetRadioStream else { return }
        let playerTime = player.currentTime().seconds
        let resumeAt = max(playbackHead, playerTime.isFinite ? playerTime : 0)
        pbLog("stall recovery firing → reload idx=\(currentIndex) at \(resumeAt)")
        let epoch = beginPlaybackSession()
        cancelPendingAdvanceWork()
        advanceWork = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startCurrentItem(
                    epoch: epoch,
                    startSeconds: resumeAt,
                    autoPlay: true,
                    skipTrackRefresh: true,
                )
            } catch {
                guard self.isPlaybackEpochCurrent(epoch) else { return }
                self.isPlaying = false
                self.setBuffering(false)
                self.refreshNowPlaying()
            }
        }
    }

    private func teardownPlayer() {
        seekGeneration += 1
        seekSettleDeadline = nil
        isSeeking = false
        localFileDuration = 0
        probingLocalFileURL = nil
        setBuffering(false)
        detachPlayerKeepingQueueState()
        currentTime = 0
        playbackHead = 0
        lastEmittedUIProgress = -10_000
        lastNowPlayingInfoRefresh = -10_000
    }

    private func makePlaybackAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        if url.isFileURL {
            return AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        }
        // Reuse a pre-warmed asset for this exact URL if we staged one for the
        // upcoming track — its network handshake is already in flight or done.
        if let warm = prewarmedAssets.removeValue(forKey: url.absoluteString) {
            return warm
        }
        if headers.isEmpty {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    /// The queue index that will play when the current track ends, mirroring the
    /// branch logic in ``handleEnded`` (repeat-one stays put; repeat-all wraps;
    /// repeat-off stops at the end).
    /// Up to `limit` queue indices that will play after the current track, in
    /// order, mirroring ``handleEnded``'s branch logic (repeat-one stays put;
    /// repeat-all wraps; repeat-off stops at the end). De-duplicated so short
    /// queues don't stage the same track twice.
    private func upcomingQueueIndices(limit: Int) -> [Int] {
        guard !queue.isEmpty, limit > 0 else { return [] }
        switch repeatMode {
        case .one:
            return [currentIndex]
        case .all:
            var result: [Int] = []
            var seen: Set<Int> = [currentIndex]
            var step = 1
            while result.count < limit, step <= queue.count {
                let idx = (currentIndex + step) % queue.count
                if seen.insert(idx).inserted { result.append(idx) }
                step += 1
            }
            return result
        case .off:
            var result: [Int] = []
            var idx = currentIndex + 1
            while idx < queue.count, result.count < limit {
                result.append(idx)
                idx += 1
            }
            return result
        }
    }

    /// The primary remote stream candidate for a track — the first URL
    /// ``startCurrentItem`` would try after any offline copy. Used for pre-warming.
    private func primaryRemoteCandidate(for track: Track) -> (url: URL, headers: [String: String])? {
        if let direct = track.streamOverrideURL { return (direct, [:]) }
        guard let library else { return nil }
        let headers = library.httpHeadersForMediaRequests()
        if let jellyfin = library as? JellyfinMusicClient {
            guard let url = jellyfin.allStreamingURLs(for: track).first else { return nil }
            return (url, headers)
        }
        guard let url = try? library.streamURL(for: track) else { return nil }
        return (url, headers)
    }

    /// How many upcoming tracks to pre-warm. Kept small on purpose: warming opens
    /// a connection + loads playability per track, so more than a couple wastes
    /// bandwidth/connections on songs the user may skip past (Apple's own guidance
    /// for queue prefetch is to stay within a few items).
    private static let prewarmDepth = 2

    /// Stage the next couple of tracks' assets while the current one plays so a
    /// skip (or two) is near-instant. No-op for locally downloaded next tracks
    /// (already instant) and internet-radio streams (live; nothing to pre-roll).
    /// Reuses any already-warmed asset and drops ones no longer upcoming.
    private func schedulePrewarmNextTrack() {
        let indices = upcomingQueueIndices(limit: Self.prewarmDepth)
        guard !indices.isEmpty else {
            prewarmedAssets.removeAll()
            return
        }
        var staged: [String: AVURLAsset] = [:]
        for idx in indices {
            guard queue.indices.contains(idx) else { continue }
            let track = queue[idx]
            if track.isInternetRadioStream { continue }
            if offline?.localFile(for: track.id) != nil { continue }
            guard let candidate = primaryRemoteCandidate(for: track) else { continue }
            let key = candidate.url.absoluteString
            if staged[key] != nil { continue }
            // Reuse an already-warmed asset instead of restarting its handshake.
            if let existing = prewarmedAssets[key] {
                staged[key] = existing
                continue
            }
            let asset = candidate.headers.isEmpty
                ? AVURLAsset(url: candidate.url)
                : AVURLAsset(
                    url: candidate.url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": candidate.headers],
                )
            staged[key] = asset
            Task.detached(priority: .utility) {
                _ = try? await asset.load(.isPlayable)
            }
        }
        prewarmedAssets = staged
    }

    private func awaitPlayerSeek(
        _ player: AVPlayer,
        to seconds: TimeInterval,
        tolerance: TimeInterval = 0,
    ) async -> Bool {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 1000)
        let tol = CMTime(seconds: tolerance, preferredTimescale: 1000)
        return await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    private func waitForPlayerItemReady(_ item: AVPlayerItem, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch item.status {
            case .readyToPlay: return
            case .failed: throw item.error ?? URLError(.badServerResponse)
            // Poll tightly so we resume within ~20ms of the item flipping ready,
            // instead of eating up to a tenth of a second of dead time per play.
            case .unknown: try await Task.sleep(for: .milliseconds(20))
            @unknown default: try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw URLError(.timedOut)
    }

    private func playbackFailedAfterReady(
        item: AVPlayerItem,
        observeBudget: Duration,
        expectedPosition: TimeInterval = 0,
    ) async -> Bool {
        let minProgress = expectedPosition > 1 ? expectedPosition * 0.45 : 0.05
        let deadline = ContinuousClock.now + observeBudget
        while ContinuousClock.now < deadline {
            if item.status == .failed { return true }
            if item.error != nil { return true }
            if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                return false
            }
            if let p = player {
                if p.timeControlStatus == .playing { return false }
                let t = p.currentTime().seconds
                if t.isFinite, t >= minProgress { return false }
                if p.rate > 0.01, t.isFinite, t >= 0.01 { return false }
            }
            try? await Task.sleep(for: .milliseconds(95))
        }
        if let p = player {
            let status = p.timeControlStatus
            if status == .playing || status == .waitingToPlayAtSpecifiedRate { return false }
            if isPlaying, p.rate > 0.01 { return false }
        }
        return true
    }

    func applyTrackSwaps(_ swaps: [String: Track]) {
        guard !swaps.isEmpty else { return }
        queue = queue.map { swaps[$0.id] ?? $0 }
        if var uq = unshuffledQueue {
            uq = uq.map { swaps[$0.id] ?? $0 }
            unshuffledQueue = uq
        }
        if var sq = sourceQueueOrder {
            sq = sq.map { swaps[$0.id] ?? $0 }
            sourceQueueOrder = sq
        }
        var nextUserQueued = userQueuedTrackIds
        for (oldId, newTrack) in swaps {
            if nextUserQueued.remove(oldId) != nil {
                nextUserQueued.insert(newTrack.id)
            }
            if let playlistId = trackOriginPlaylistIds.removeValue(forKey: oldId) {
                trackOriginPlaylistIds[newTrack.id] = playlistId
            }
        }
        userQueuedTrackIds = nextUserQueued
    }

    /// Budget for the proactive metadata refresh before play. On a slow network
    /// the refresh must never gate time-to-first-audio — past the budget the
    /// fetch is cancelled and the existing track plays as-is (reactive stale-id
    /// recovery still runs if every stream candidate then fails).
    private static let trackRefreshBudget: Duration = .seconds(2)

    /// Runs ``refreshTrackBeforePlay`` with a hard time budget. The refresh
    /// closure tolerates cancellation (it returns the original track), so the
    /// watchdog can cancel it mid-flight without breaking the play pipeline.
    private func refreshedTrackForPlay(_ track: Track) async -> Track {
        guard let refresh = refreshTrackBeforePlay else { return track }
        let work = Task { await refresh(track) }
        let watchdog = Task {
            try? await Task.sleep(for: Self.trackRefreshBudget)
            work.cancel()
        }
        let refreshed = await work.value
        watchdog.cancel()
        return refreshed
    }

    private func startCurrentItem(epoch: UInt, startSeconds: TimeInterval = 0, autoPlay: Bool = false, allowStaleRecovery: Bool = true, skipTrackRefresh: Bool = false) async throws {
        guard isPlaybackEpochCurrent(epoch) else { return }
        guard let track = currentTrack else { throw PlaybackEngineError.missingTrack }
        // The user expects audio — show the buffering spinner through the whole
        // load (metadata refresh, handshake, pre-buffer), not just AVPlayer stalls.
        if autoPlay { setBuffering(true) }

        if !skipTrackRefresh, refreshTrackBeforePlay != nil {
            let refreshed = await refreshedTrackForPlay(track)
            if refreshed.id != track.id, queue.indices.contains(currentIndex) {
                queue[currentIndex] = refreshed
            }
        }
        guard let activeTrack = currentTrack else { throw PlaybackEngineError.missingTrack }

        var candidates: [(url: URL, headers: [String: String])] = []
        if let saved = offline?.localFile(for: activeTrack.id) {
            candidates.append((saved, [:]))
        }
        var seen = Set(candidates.map { $0.url.absoluteString })
        let cacheEnabled = streamingDiskCacheEnabled || equalizerEnabled
        func appendUnique(_ u: URL, _ h: [String: String]) {
            // Prefer a fully-cached local copy of this exact stream over the network.
            if cacheEnabled, !activeTrack.isInternetRadioStream, CachingResourceLoaderDelegate.isCacheable(u),
               let cached = StreamingMediaDiskCache.shared.peekCachedFileURL(forKey: StreamingMediaDiskCache.key(for: u)),
               !seen.contains(cached.absoluteString) {
                seen.insert(cached.absoluteString)
                candidates.append((cached, [:]))
            }
            let key = u.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            candidates.append((u, h))
        }
        if let direct = activeTrack.streamOverrideURL {
            appendUnique(direct, [:])
        }
        if let library {
            let serverHeaders = library.httpHeadersForMediaRequests()
            if let jellyfin = library as? JellyfinMusicClient {
                for u in jellyfin.allStreamingURLs(for: activeTrack) {
                    appendUnique(u, serverHeaders)
                }
            } else {
                appendUnique(try library.streamURL(for: activeTrack), serverHeaders)
                for u in library.fallbackStreamURLs(for: activeTrack) {
                    appendUnique(u, serverHeaders)
                }
            }
        }
        guard !candidates.isEmpty else {
            throw library == nil ? PlaybackEngineError.missingLibrary : URLError(.cannotLoadFromNetwork)
        }

        if equalizerEnabled,
           isEqualizerEligible(for: activeTrack),
           !candidates.contains(where: { isEqualizerEligibleLocalFile($0.url, for: activeTrack) }),
           let remote = candidates.first(where: { !$0.url.isFileURL && CachingResourceLoaderDelegate.isCacheable($0.url) }) {
            // Brief off-main wait for a cache hit — fast networks get EQ on first play.
            if let cached = await tryQuickEqualizerCache(for: remote, maxWait: 2.5) {
                guard isPlaybackEpochCurrent(epoch) else { return }
                insertEqualizerCacheCandidate(cached, into: &candidates, seen: &seen, track: activeTrack)
            }
            StreamingMediaDiskCache.shared.prefetchInBackground(url: remote.url, headers: remote.headers)
        }

        var lastError: Error?
        for candidate in candidates {
            guard isPlaybackEpochCurrent(epoch) else { return }
            detachPlayerKeepingQueueState()
            do {
                if try await loadPlayerItem(
                    epoch: epoch,
                    candidate: candidate,
                    track: activeTrack,
                    startSeconds: startSeconds,
                    autoPlay: autoPlay,
                ) {
                    return
                }
                lastError = URLError(.cannotParseResponse)
            } catch {
                lastError = error
            }
        }

        guard isPlaybackEpochCurrent(epoch) else { return }
        if allowStaleRecovery,
           let recovery = recoverStaleTrackOnFailure,
           let result = await recovery(activeTrack),
           !result.swaps.isEmpty {
            applyTrackSwaps(result.swaps)
            try await startCurrentItem(
                epoch: epoch,
                startSeconds: startSeconds,
                autoPlay: autoPlay,
                allowStaleRecovery: false,
            )
            return
        }
        teardownPlayer()
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    private func loadPlayerItem(
        epoch: UInt,
        candidate: (url: URL, headers: [String: String]),
        track: Track,
        startSeconds: TimeInterval,
        autoPlay: Bool,
    ) async throws -> Bool {
        guard isPlaybackEpochCurrent(epoch) else { return false }
        if equalizerEnabled, isEqualizerEligible(for: track), isEqualizerEligibleLocalFile(candidate.url, for: track) {
            do {
                if try await loadEqualizedPlayerItem(
                    epoch: epoch,
                    candidate: candidate,
                    track: track,
                    startSeconds: startSeconds,
                    autoPlay: autoPlay,
                ) {
                    return true
                }
            } catch {
                // EQ decode failed — fall through to AVPlayer without EQ on the same file.
            }
        }
        return try await loadAVPlayerItem(
            epoch: epoch,
            candidate: candidate,
            track: track,
            startSeconds: startSeconds,
            autoPlay: autoPlay,
        )
    }

    private func loadAVPlayerItem(
        epoch: UInt,
        candidate: (url: URL, headers: [String: String]),
        track: Track,
        startSeconds: TimeInterval,
        autoPlay: Bool,
    ) async throws -> Bool {
        guard isPlaybackEpochCurrent(epoch) else { return false }
        let asset = makePlaybackAsset(url: candidate.url, headers: candidate.headers)
        if candidate.url.isFileURL, let urlAsset = asset as? AVURLAsset {
            _ = try? await urlAsset.load(.isPlayable, .duration)
        }
        var resolvedDuration = track.duration
        if resolvedDuration <= 0, candidate.url.isFileURL {
            resolvedDuration = await LocalMediaDuration.seconds(at: candidate.url)
        }
        let item = AVPlayerItem(asset: asset)
        let p = AVQueuePlayer(playerItem: item)
        // Auto-advance to the enqueued next item at end of track (the OS-managed,
        // background-safe transition). Falls back to pausing when nothing's queued.
        p.actionAtItemEnd = .advance
        if candidate.url.isFileURL {
            p.automaticallyWaitsToMinimizeStalling = false
        } else {
            // Start playing as soon as ~2s is buffered instead of letting the
            // system pre-buffer several seconds first. Reset to system-managed
            // (0) once playback is confirmed so steady-state buffering is normal.
            item.preferredForwardBufferDuration = 2
        }
        try await waitForPlayerItemReady(item, timeout: candidate.url.isFileURL ? .seconds(12) : .seconds(22))
        guard isPlaybackEpochCurrent(epoch) else {
            stopPlayer(p)
            return false
        }
        if resolvedDuration <= 0 {
            let fromAsset = await LocalMediaDuration.seconds(asset: asset)
            if fromAsset > 0 { resolvedDuration = fromAsset }
        }
        guard isPlaybackEpochCurrent(epoch) else {
            stopPlayer(p)
            return false
        }
        attachPlayer(p, item: item, track: track, initialTime: startSeconds, resolvedDuration: resolvedDuration)

        if startSeconds > 0.05 {
            _ = await awaitPlayerSeek(p, to: startSeconds)
            currentTime = startSeconds
            playbackHead = startSeconds
            lastEmittedUIProgress = startSeconds
        }

        if autoPlay {
            beginPlayback(on: p)
            isPlaying = true
        }

        let readyBudget: Duration = candidate.url.isFileURL
            ? (startSeconds > 1 ? .seconds(4) : .seconds(2))
            : (startSeconds > 1 ? .seconds(12) : .seconds(10))
        if await playbackFailedAfterReady(
            item: item,
            observeBudget: readyBudget,
            expectedPosition: startSeconds,
        ) {
            guard isPlaybackEpochCurrent(epoch) else {
                stopPlayer(p)
                return false
            }
            detachPlayerKeepingQueueState()
            return false
        }
        guard isPlaybackEpochCurrent(epoch) else {
            detachPlayerKeepingQueueState()
            return false
        }
        // Playback is confirmed — hand buffering back to the system so it can
        // read further ahead than the lowered startup target.
        if !candidate.url.isFileURL {
            item.preferredForwardBufferDuration = 0
        }
        if resolvedDuration > 0 {
            duration = resolvedDuration
            if candidate.url.isFileURL {
                localFileDuration = resolvedDuration
            }
            persistOfflineDurationIfNeeded(resolvedDuration)
            patchActiveQueueTrackDuration(resolvedDuration)
        }
        // Never replace a known label with nil — a same-track reload (EQ
        // handoff, stall recovery) may resolve less than the original load did.
        if let label = deliveredFormatLabel(candidateURL: candidate.url, track: track) {
            nowPlayingFormatLabel = label
        } else if nowPlayingFormatLabel == nil {
            // Raw stream + no codec metadata on the track (stale snapshot /
            // minimal server payload) — read the format off the loaded asset.
            probeDeliveredFormat(asset: asset, epoch: epoch)
        }
        // Stage the next track so the OS can pre-roll and transition to it without
        // any app work at the boundary.
        refreshEnqueuedNextItem()
        if equalizerEnabled,
           isEqualizerEligible(for: track),
           !candidate.url.isFileURL,
           CachingResourceLoaderDelegate.isCacheable(candidate.url) {
            scheduleEqualizerHandoffWhenCached(
                streamURL: candidate.url,
                headers: candidate.headers,
                track: track,
                epoch: epoch,
            )
        }
        return true
    }

    private func loadEqualizedPlayerItem(
        epoch: UInt,
        candidate: (url: URL, headers: [String: String]),
        track: Track,
        startSeconds: TimeInterval,
        autoPlay: Bool,
    ) async throws -> Bool {
        let asset = makePlaybackAsset(url: candidate.url, headers: candidate.headers)
        guard let urlAsset = asset as? AVURLAsset else { return false }

        var resolvedDuration = track.duration
        if resolvedDuration <= 0, candidate.url.isFileURL {
            resolvedDuration = await LocalMediaDuration.seconds(at: candidate.url)
        }
        if resolvedDuration <= 0 {
            let fromAsset = await LocalMediaDuration.seconds(asset: asset)
            if fromAsset > 0 { resolvedDuration = fromAsset }
        }

        if !candidate.url.isFileURL {
            _ = try await urlAsset.load(.isPlayable)
        }
        guard isPlaybackEpochCurrent(epoch) else { return false }

        activateAudioSession()
        let session = EqualizedAudioEnginePlayer()
        equalizedEndEpoch = epoch
        session.onTimeUpdate = { [weak self] elapsed in
            Task { @MainActor in
                guard let self, self.equalizedEndEpoch == epoch else { return }
                self.periodicEqualizedTimeObserverTick(
                    elapsed: elapsed,
                    track: track,
                    epoch: epoch,
                )
            }
        }
        session.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.equalizedEndEpoch == epoch else { return }
                self.handleEnded()
            }
        }
        session.onPlaybackFailed = { [weak self] in
            Task { @MainActor in
                guard let self, self.equalizedEndEpoch == epoch else { return }
                self.detachPlayerKeepingQueueState()
                self.isPlaying = false
                self.refreshNowPlaying()
            }
        }

        try await session.load(
            asset: urlAsset,
            fileURL: candidate.url.isFileURL ? candidate.url : nil,
            startSeconds: startSeconds,
            gains: equalizerBandGains,
            bypass: equalizerBypass,
        )
        guard isPlaybackEpochCurrent(epoch) else {
            session.stop()
            return false
        }

        equalizedPlayer = session
        equalizedPlaybackURL = candidate.url
        equalizedPlaybackAsset = urlAsset
        equalizedPlaybackHeaders = candidate.headers
        if isCommittedStreamCacheFile(candidate.url) {
            StreamingMediaDiskCache.shared.markAccessed(fileURL: candidate.url)
        }
        isSeeking = false
        let head = max(0, startSeconds)
        playbackHead = head
        currentTime = head
        lastEmittedUIProgress = head > 0 ? head : -10_000
        lastNowPlayingInfoRefresh = head > 0 ? head : -10_000
        duration = resolvedDuration > 0 ? resolvedDuration : duration
        if candidate.url.isFileURL, resolvedDuration > 0 {
            localFileDuration = resolvedDuration
        }

        if autoPlay {
            session.play(rate: playbackRate)
            isPlaying = true
        } else {
            isPlaying = false
        }
        // The EQ engine has no `timeControlStatus` to observe — the AVPlayer
        // KVO that normally clears the load spinner never fires on this path,
        // so the play button stays a spinner forever without this.
        setBuffering(false)
        refreshNowPlaying()

        if resolvedDuration > 0 {
            persistOfflineDurationIfNeeded(resolvedDuration)
            patchActiveQueueTrackDuration(resolvedDuration)
        }
        if let label = deliveredFormatLabel(candidateURL: candidate.url, track: track) {
            nowPlayingFormatLabel = label
        } else if nowPlayingFormatLabel == nil {
            probeDeliveredFormat(asset: urlAsset, epoch: epoch)
        }
        return true
    }

    // MARK: - Delivered format badge

    /// Resolves the badge text for whatever candidate actually loaded.
    /// Local downloads report their file extension; stream-cache files mirror
    /// the primary remote stream's bytes, so they re-derive from that URL.
    private func deliveredFormatLabel(candidateURL: URL, track: Track) -> String? {
        var label: String?
        if candidateURL.isFileURL {
            let ext = candidateURL.pathExtension.lowercased()
            if !ext.isEmpty, ext != "cache" {
                label = formatLabel(codec: ext, transcodeKbps: nil, track: track)
            }
            // Stream-cache files carry no extension — they mirror the remote
            // stream's bytes, so derive from the URL the cache shadows.
            if label == nil, let remote = primaryRemoteCandidate(for: track)?.url {
                label = formatLabel(remoteURL: remote, track: track)
            }
        } else {
            label = formatLabel(remoteURL: candidateURL, track: track)
        }
        // Last resort: the track's own codec metadata.
        if label == nil {
            label = formatLabel(codec: track.audioCodec, transcodeKbps: nil, track: track)
        }
        pbLog("format label derive: url=\(candidateURL.isFileURL ? "file:.\(candidateURL.pathExtension)" : candidateURL.lastPathComponent) trackCodec=\(track.audioCodec ?? "nil") → \(label ?? "nil")")
        return label
    }

    private func formatLabel(remoteURL: URL, track: Track) -> String? {
        let items = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        // Subsonic: an explicit `format` query param means a server-side
        // transcode ("mp3_rg" → mp3); absent/raw streams the original file.
        if remoteURL.path.lowercased().hasSuffix("/rest/stream.view") || remoteURL.path.lowercased().hasSuffix("/rest/stream") {
            if let format = query("format")?.lowercased(), !format.isEmpty, format != "raw" {
                let codec = format.components(separatedBy: "_").first ?? format
                return formatLabel(codec: codec, transcodeKbps: query("maxBitRate").flatMap(Int.init), track: track)
            }
            return formatLabel(codec: track.audioCodec, transcodeKbps: nil, track: track)
        }
        // Jellyfin progressive: /Audio/{id}/stream.<container>; Static=true or a
        // container matching the source codec is direct play.
        let last = remoteURL.lastPathComponent.lowercased()
        if last.hasPrefix("stream."), let ext = last.components(separatedBy: ".").last, !ext.isEmpty {
            let sourceCodec = track.audioCodec?.lowercased() ?? ""
            let isDirect = query("Static")?.lowercased() == "true" || ext == sourceCodec
            let bps = query("audioBitRate").flatMap(Int.init) ?? query("maxStreamingBitrate").flatMap(Int.init)
            return formatLabel(
                codec: isDirect && !sourceCodec.isEmpty ? sourceCodec : ext,
                transcodeKbps: isDirect ? nil : bps.map { $0 / 1000 },
                track: track,
            )
        }
        // Internet radio / direct override URLs.
        let ext = remoteURL.pathExtension.lowercased()
        return ext.isEmpty ? nil : formatLabel(codec: ext, transcodeKbps: nil, track: track)
    }

    /// Last-resort badge source: reads the codec straight off the loaded
    /// asset's audio format description. Used when the URL/track metadata
    /// give nothing (raw stream + codec-less track payloads).
    private func probeDeliveredFormat(asset: AVURLAsset, epoch: UInt) {
        Task { [weak self] in
            guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
                  let desc = (try? await audio.load(.formatDescriptions))?.first else { return }
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            let dataRate = (try? await audio.load(.estimatedDataRate)) ?? 0
            let kbps = dataRate > 0 ? Int(dataRate / 1000) : nil
            await MainActor.run {
                guard let self, self.isPlaybackEpochCurrent(epoch),
                      self.nowPlayingFormatLabel == nil else { return }
                self.nowPlayingFormatLabel = Self.formatLabel(audioSubtype: subtype, kbps: kbps)
                self.pbLog("format label probe: subtype=\(subtype) kbps=\(kbps ?? -1) → \(self.nowPlayingFormatLabel ?? "nil")")
            }
        }
    }

    private static func formatLabel(audioSubtype subtype: FourCharCode, kbps: Int?) -> String? {
        let name: String?
        switch subtype {
        case kAudioFormatFLAC: name = "FLAC"
        case kAudioFormatMPEGLayer3: name = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: name = "AAC"
        case kAudioFormatAppleLossless: name = "ALAC"
        case kAudioFormatOpus: name = "Opus"
        case kAudioFormatLinearPCM: name = "PCM"
        default: name = nil
        }
        guard let name else { return nil }
        if ["FLAC", "ALAC", "PCM"].contains(name) { return name }
        if let kbps, kbps > 0 { return "\(name) \(kbps)" }
        return name
    }

    /// `transcodeKbps` is the server-side cap for lossy transcodes; original
    /// (non-transcoded) lossy files fall back to the track's reported bitrate.
    private func formatLabel(codec rawCodec: String?, transcodeKbps: Int?, track: Track) -> String? {
        guard let raw = rawCodec?.lowercased(), !raw.isEmpty else { return nil }
        let names: [String: String] = [
            "mp3": "MP3", "mpeg": "MP3", "flac": "FLAC", "alac": "ALAC",
            "aac": "AAC", "m4a": "AAC", "m4b": "AAC", "opus": "Opus",
            "ogg": "OGG", "oga": "OGG", "vorbis": "OGG", "wav": "WAV",
            "aif": "AIFF", "aiff": "AIFF", "wma": "WMA", "ape": "APE",
            "dsf": "DSD", "dff": "DSD", "wv": "WavPack",
        ]
        guard let name = names[raw] else { return raw.uppercased() }
        let lossless: Set<String> = ["FLAC", "ALAC", "WAV", "AIFF", "APE", "DSD", "WavPack"]
        if lossless.contains(name) { return name }
        let kbps = transcodeKbps ?? track.audioBitRateKbps
        if let kbps, kbps > 0 { return "\(name) \(kbps)" }
        return name
    }

    /// On-disk download from ``OfflineDownloadManager``.
    private func isOfflineDownloadFile(_ url: URL, for track: Track) -> Bool {
        guard url.isFileURL, let local = offline?.localFile(for: track.id) else { return false }
        return local.standardizedFileURL == url.standardizedFileURL
    }

    /// Live internet radio never uses the EQ engine — streams are continuous and
    /// must stay on AVPlayer for reliable playback.
    private func isEqualizerEligible(for track: Track) -> Bool {
        !track.isInternetRadioStream
    }

    /// Local file the EQ engine can read: offline download or committed stream-cache file.
    private func isEqualizerEligibleLocalFile(_ url: URL, for track: Track) -> Bool {
        guard isEqualizerEligible(for: track) else { return false }
        guard url.isFileURL else { return false }
        if isOfflineDownloadFile(url, for: track) { return true }
        return isCommittedStreamCacheFile(url)
    }

    private func isCommittedStreamCacheFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              !url.lastPathComponent.hasPrefix("tmp-"),
              url.path.contains("/LyraMusic/stream-cache/")
        else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func insertEqualizerCacheCandidate(
        _ cached: URL,
        into candidates: inout [(url: URL, headers: [String: String])],
        seen: inout Set<String>,
        track: Track,
    ) {
        let cacheKey = cached.absoluteString
        guard !seen.contains(cacheKey) else { return }
        seen.insert(cacheKey)
        let insertAt: Int
        if let first = candidates.first, isOfflineDownloadFile(first.url, for: track) {
            insertAt = 1
        } else {
            insertAt = 0
        }
        candidates.insert((cached, [:]), at: insertAt)
    }

    /// Waits up to `maxWait` seconds for a cache file (network work stays off the main actor).
    private func tryQuickEqualizerCache(
        for remote: (url: URL, headers: [String: String]),
        maxWait: TimeInterval,
    ) async -> URL? {
        let key = StreamingMediaDiskCache.key(for: remote.url)
        if let hit = StreamingMediaDiskCache.shared.peekCachedFileURL(forKey: key) {
            return hit
        }
        return await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                try? await StreamingMediaDiskCache.shared.ensureCached(
                    url: remote.url,
                    headers: remote.headers,
                    timeout: maxWait + 30,
                )
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(maxWait))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func scheduleEqualizerHandoffWhenCached(
        streamURL: URL,
        headers: [String: String],
        track: Track,
        epoch: UInt,
    ) {
        guard equalizerEnabled, isEqualizerEligible(for: track) else { return }
        let trackId = track.id
        eqCacheHandoffTask?.cancel()
        eqCacheHandoffTask = Task {
            let cached: URL?
            let key = StreamingMediaDiskCache.key(for: streamURL)
            if let hit = StreamingMediaDiskCache.shared.peekCachedFileURL(forKey: key) {
                cached = hit
            } else {
                cached = try? await StreamingMediaDiskCache.shared.ensureCached(
                    url: streamURL,
                    headers: headers,
                )
            }
            guard !Task.isCancelled, let cached else { return }
            await swapActiveItemToEqualizerIfNeeded(
                cachedURL: cached,
                track: track,
                trackId: trackId,
                epoch: epoch,
            )
        }
    }

    private func swapActiveItemToEqualizerIfNeeded(
        cachedURL: URL,
        track: Track,
        trackId: String,
        epoch: UInt,
    ) async {
        guard isPlaybackEpochCurrent(epoch),
              currentTrack?.id == trackId,
              equalizerEnabled,
              equalizedPlayer == nil,
              player != nil,
              isEqualizerEligibleLocalFile(cachedURL, for: track)
        else { return }

        let position = playbackHead
        let shouldPlay = isPlaying
        eqCacheHandoffTask = nil
        detachPlayerKeepingQueueState()
        guard isPlaybackEpochCurrent(epoch) else { return }

        do {
            guard try await loadEqualizedPlayerItem(
                epoch: epoch,
                candidate: (cachedURL, [:]),
                track: track,
                startSeconds: position,
                autoPlay: shouldPlay,
            ) else { return }
            if shouldPlay {
                equalizedPlayer?.play(rate: playbackRate)
                isPlaying = true
            }
            refreshNowPlaying()
        } catch {
            // Stay on whatever path the user had — handoff is best-effort.
        }
    }

    private func periodicEqualizedTimeObserverTick(
        elapsed: TimeInterval,
        track: Track,
        epoch: UInt,
    ) {
        guard equalizedEndEpoch == epoch else { return }
        playbackHead = elapsed

        let playing = equalizedPlayer?.isPlaying ?? false
        let playStateChanged = playing != isPlaying
        if playStateChanged { isPlaying = playing }

        maybeScrobble(track: track, position: elapsed)
        if playStateChanged
            || elapsed - lastNowPlayingInfoRefresh >= 0.55
            || abs(elapsed - lastNowPlayingInfoRefresh) > 1.25
        {
            lastNowPlayingInfoRefresh = elapsed
            refreshNowPlaying()
        }

        guard !isSeeking else { return }
        if let deadline = seekSettleDeadline, ContinuousClock.now < deadline { return }
        seekSettleDeadline = nil
        if elapsed + 1.5 < currentTime { return }
        if currentTime > 3, elapsed < 1 { return }
        if elapsed - lastEmittedUIProgress >= 0.55 || abs(elapsed - currentTime) > 1.25 {
            lastEmittedUIProgress = elapsed
            currentTime = elapsed
        }
    }

    private func attachPlayer(
        _ p: AVPlayer,
        item: AVPlayerItem,
        track: Track,
        initialTime: TimeInterval = 0,
        resolvedDuration: TimeInterval = 0,
    ) {
        p.isMuted = false
        p.volume = 1.0
        player = p
        isSeeking = false
        let head = max(0, initialTime)
        playbackHead = head
        currentTime = head
        lastEmittedUIProgress = head > 0 ? head : -10_000
        lastNowPlayingInfoRefresh = head > 0 ? head : -10_000
        let fromItem = item.duration.seconds
        if resolvedDuration > 0 {
            duration = resolvedDuration
        } else if fromItem.isFinite, fromItem > 0 {
            duration = fromItem
        } else {
            duration = track.duration > 0 ? track.duration : 0
        }

        // Authoritative state observer — `timeControlStatus` flips to `.paused`
        // for any external pause (route change, Control Center, audio session
        // steal, end of item), so this keeps ``isPlaying`` in sync without
        // having to enumerate every cause individually.
        timeControlStatusObservation = p.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                let status = player.timeControlStatus
                if status == .paused, self.isPlaying, !self.isAdvancingToNextItem {
                    // Startup/handoff can report `.paused` briefly before `playImmediately` sticks.
                    if self.autoplayVerifyTask != nil { return }
                    self.isPlaying = false
                    self.refreshNowPlaying()
                } else if status == .playing, !self.isPlaying {
                    self.isPlaying = true
                    self.refreshNowPlaying()
                }
                // `.waitingToPlayAtSpecifiedRate` = buffering — the user still
                // intends to play, so keep ``isPlaying`` but surface the stall
                // through ``isBuffering`` and arm the stall watchdog.
                if status == .waitingToPlayAtSpecifiedRate {
                    self.setBuffering(player.reasonForWaitingToPlay != .noItemToPlay, debounced: true)
                    self.scheduleStallRecoveryIfNeeded()
                } else {
                    self.cancelStallRecovery()
                    self.setBuffering(false)
                }
            }
        }

        bindItemObservers(item: item, track: track, player: p)
        refreshNowPlaying()
    }

    /// (Re)bind the per-item observers — periodic progress + end-of-track — to a
    /// specific item/track on `p`. Used both for a freshly-attached player and,
    /// after an OS auto-advance, to rebind onto the now-current enqueued item
    /// without tearing the player down. The `timeControlStatus` KVO is per-player
    /// and set once in ``attachPlayer``, so it isn't touched here.
    private func bindItemObservers(item: AVPlayerItem, track: Track, player p: AVPlayer) {
        if let timeObserver { p.removeTimeObserver(timeObserver) }
        let interval = CMTime(seconds: 0.35, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.periodicTimeObserverTick(
                    elapsed: time.seconds,
                    item: item,
                    track: track,
                    player: p,
                )
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main,
        ) { [weak self, weak item] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleEnded(endedItem: item)
            }
        }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main,
        ) { [weak self, weak item] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // A failed item routes through the same spurious-end recovery:
                // the AVQueuePlayer auto-advances on failure too, which used to
                // silently skip the song (e.g. seeking into an unbuffered part
                // of a chunked transcode). handleEnded reloads in place when
                // the playhead is nowhere near the end.
                self.handleEnded(endedItem: item)
            }
        }
    }

    private func periodicTimeObserverTick(
        elapsed: TimeInterval,
        item: AVPlayerItem,
        track: Track,
        player p: AVPlayer,
    ) {
        playbackHead = elapsed

        let newDuration = item.duration.seconds.isFinite ? item.duration.seconds : 0
        if localFileDuration > 0 {
            // Keep probed file length; AVPlayerItem.duration can be wrong briefly on local files.
        } else if newDuration > 0, newDuration != duration {
            duration = newDuration
            persistOfflineDurationIfNeeded(newDuration)
            patchActiveQueueTrackDuration(newDuration)
        } else if duration <= 0, item.asset is AVURLAsset,
                  let urlAsset = item.asset as? AVURLAsset, urlAsset.url.isFileURL,
                  probingLocalFileURL != urlAsset.url {
            probingLocalFileURL = urlAsset.url
            let fileURL = urlAsset.url
            Task {
                let probed = await LocalMediaDuration.seconds(at: fileURL)
                guard probed > 0 else { return }
                duration = probed
                localFileDuration = probed
                persistOfflineDurationIfNeeded(probed)
                patchActiveQueueTrackDuration(probed)
            }
        }

        let playing = p.rate > 0.01
        let playStateChanged = playing != isPlaying
        if playStateChanged { isPlaying = playing }

        maybeScrobble(track: track, position: elapsed)
        if playStateChanged
            || elapsed - lastNowPlayingInfoRefresh >= 0.55
            || abs(elapsed - lastNowPlayingInfoRefresh) > 1.25
        {
            lastNowPlayingInfoRefresh = elapsed
            refreshNowPlaying()
        }

        guard !isSeeking else { return }
        if let deadline = seekSettleDeadline, ContinuousClock.now < deadline {
            return
        }
        seekSettleDeadline = nil
        // Drop stale samples that arrive right after a seek (often ~0s before the player catches up).
        if elapsed + 1.5 < currentTime { return }
        if currentTime > 3, elapsed < 1 { return }
        if elapsed - lastEmittedUIProgress >= 0.55 || abs(elapsed - currentTime) > 1.25 {
            lastEmittedUIProgress = elapsed
            currentTime = elapsed
        }
    }

    /// Console diagnostics for playback-flow debugging — grep the Xcode
    /// console for "[LYRA-PB]". DEBUG builds only.
    private func pbLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[LYRA-PB]", message())
#endif
    }

    /// One-shot guard so a track with bad duration metadata can't loop forever
    /// through spurious-end recovery. Reset on every track handoff.
    private var spuriousEndRecoveryAttempted = false

    private func handleEnded(endedItem: AVPlayerItem? = nil) {
        let endedAtLog = endedItem?.currentTime().seconds ?? -1
        let itemDurLog = endedItem?.duration.seconds ?? -1
        pbLog("handleEnded endedItem=\(endedItem == nil ? "nil" : "set") endedAt=\(endedAtLog) itemDur=\(itemDurLog) engineDur=\(duration) idx=\(currentIndex) recoveryTried=\(spuriousEndRecoveryAttempted)")
        // Spurious end: chunked/transcoded streams can't seek past the data
        // AVFoundation has buffered — a scrub into an unloaded region plays out
        // the loaded tail and fires DidPlayToEndTime mid-song, which used to
        // skip to the next track. If the *ended item's* playhead is nowhere
        // near its duration, reload the same track at that position instead.
        if !spuriousEndRecoveryAttempted,
           let endedItem,
           queue.indices.contains(currentIndex) {
            let endedAt = endedItem.currentTime().seconds
            let itemDuration = endedItem.duration.seconds
            let knownDuration = (itemDuration.isFinite && itemDuration > 0) ? itemDuration : duration
            if endedAt.isFinite, knownDuration > 0, endedAt < knownDuration - 5 {
                spuriousEndRecoveryAttempted = true
                shouldAutoPlayAfterAdvance = isPlaying
                let resumeAt = min(max(0, endedAt), max(0, knownDuration - 2))
                pbLog("SPURIOUS end → reloading same track at \(resumeAt)")
                cancelPendingAdvanceWork()
                advanceWork = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let epoch = self.beginPlaybackSession()
                    self.teardownPlayer()
                    try? await self.startCurrentItem(
                        epoch: epoch,
                        startSeconds: resumeAt,
                        autoPlay: true,
                        skipTrackRefresh: true,
                    )
                }
                return
            }
        }

        // Fast path: the OS queue auto-advanced to the item we pre-enqueued and the
        // queue hasn't changed underneath it — promote bookkeeping in place. Audio
        // never stopped, so this works reliably while backgrounded (no app-driven
        // teardown/rebuild that the OS would suspend mid-transition).
        if repeatMode != .one,
           let qp = queuePlayer,
           let nextItem = enqueuedNextItem,
           let nextIndex = enqueuedNextIndex,
           qp.currentItem === nextItem,
           nextIndex == upcomingQueueIndices(limit: 1).first,
           queue.indices.contains(nextIndex),
           enqueuedNextTrack?.id == queue[nextIndex].id {
            pbLog("gapless promote → idx=\(nextIndex)")
            promoteToEnqueuedNext(item: nextItem, index: nextIndex, track: queue[nextIndex])
            return
        }
        pbLog("slow-path advance repeatMode=\(repeatMode)")

        // Slow path: nothing usable pre-enqueued (repeat-one, end of queue, queue
        // edited, or enqueue failed) — rebuild as before.
        // Shuffle is a queue-reordering action (see ``toggleShuffle``) — once shuffled,
        // advance through the queue sequentially, otherwise every track end would re-randomize.
        switch repeatMode {
        case .one:
            shouldAutoPlayAfterAdvance = true
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
        case .all:
            shouldAutoPlayAfterAdvance = true
            currentIndex = (currentIndex + 1) % max(queue.count, 1)
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
        case .off:
            if currentIndex + 1 < queue.count {
                shouldAutoPlayAfterAdvance = true
                currentIndex += 1
                resetUIProgressForTrackHandoff()
                scheduleAdvance()
            } else {
                isPlaying = false
                // AVQueuePlayer advanced past the final item, so `currentItem` is
                // now nil and the single-player "seek to 0 and replay" path can't
                // work. Drop to a clean pending-restore so a later play tap rebuilds
                // the last track from the start (matching the prior behavior).
                teardownPlayer()
                refreshNowPlaying()
            }
        }
    }

    /// Adopt the just-auto-advanced item as the current track without tearing the
    /// player down. The audio is already playing the new item; this only updates
    /// bookkeeping, rebinds the per-item observers, and stages the following track.
    private func promoteToEnqueuedNext(item: AVPlayerItem, index: Int, track: Track) {
        enqueuedNextItem = nil
        enqueuedNextIndex = nil
        enqueuedNextTrack = nil

        // New track is current — invalidate any in-flight load and refresh the
        // epoch the lyrics fetch keys off of.
        let epoch = beginPlaybackSession()

        currentIndex = index
        scrobbledForCurrentTrack = false
        resetUIProgressForTrackHandoff()
        localFileDuration = 0
        probingLocalFileURL = nil

        // The handoff reset cleared the format badge — re-derive it from the
        // item the OS just advanced to (no reload happens on this path).
        if let urlAsset = item.asset as? AVURLAsset {
            nowPlayingFormatLabel = deliveredFormatLabel(candidateURL: urlAsset.url, track: track)
            if nowPlayingFormatLabel == nil {
                probeDeliveredFormat(asset: urlAsset, epoch: epoch)
            }
        }

        let fromItem = item.duration.seconds
        duration = (fromItem.isFinite && fromItem > 0) ? fromItem : (track.duration > 0 ? track.duration : 0)

        if let p = player {
            bindItemObservers(item: item, track: track, player: p)
        }

        isPlaying = (player?.rate ?? 0) > 0.01
        scheduleLyricsLoad()
        refreshNowPlaying()
        revealMiniPlayerChrome()

        userQueuedTrackIds.remove(track.id)
        onTrackStarted?(track)

        // Stage the track after this one for the next boundary.
        refreshEnqueuedNextItem()
    }

    /// Keep the next track enqueued on the queue player so the OS pre-rolls and
    /// transitions to it at end-of-track. Rebuilds the staged item whenever the
    /// upcoming track changes (queue edit, shuffle/repeat change, skip). Builds a
    /// plain asset (never the resource-loader cache) so the OS owns its buffering
    /// — in-process URLSession fetching would stall a background pre-roll.
    private func refreshEnqueuedNextItem() {
        guard let qp = queuePlayer else {
            enqueuedNextItem = nil
            enqueuedNextIndex = nil
            enqueuedNextTrack = nil
            return
        }
        // Repeat-one replays the same item (which AVQueuePlayer can't do), and
        // end-of-queue has no successor — stage nothing in those cases.
        let nextIndex: Int? = repeatMode == .one ? nil : upcomingQueueIndices(limit: 1).first

        // Already correctly staged? Leave the in-flight pre-roll alone.
        if let nextIndex,
           let staged = enqueuedNextItem,
           enqueuedNextIndex == nextIndex,
           queue.indices.contains(nextIndex),
           enqueuedNextTrack?.id == queue[nextIndex].id,
           qp.items().contains(staged) {
            return
        }

        if let staged = enqueuedNextItem, qp.items().contains(staged) {
            qp.remove(staged)
        }
        enqueuedNextItem = nil
        enqueuedNextIndex = nil
        enqueuedNextTrack = nil

        guard let nextIndex, queue.indices.contains(nextIndex) else { return }
        let track = queue[nextIndex]
        if track.isInternetRadioStream { return }

        let item: AVPlayerItem
        if let saved = offline?.localFile(for: track.id) {
            item = AVPlayerItem(asset: AVURLAsset(url: saved, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        } else if let candidate = primaryRemoteCandidate(for: track) {
            let asset: AVURLAsset = candidate.headers.isEmpty
                ? AVURLAsset(url: candidate.url)
                : AVURLAsset(url: candidate.url, options: ["AVURLAssetHTTPHeaderFieldsKey": candidate.headers])
            item = AVPlayerItem(asset: asset)
        } else {
            return
        }

        guard qp.canInsert(item, after: nil) else { return }
        qp.insert(item, after: nil)
        enqueuedNextItem = item
        enqueuedNextIndex = nextIndex
        enqueuedNextTrack = track
    }

    private var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Lyrics are not on the audio critical path. Loading them inline (a full
    /// `lyrics(for:)` round-trip) used to gate time-to-first-audio on every track
    /// start. Fire-and-forget instead: clear immediately so the previous track's
    /// lyrics don't linger, then fetch in the background. ``loadLyrics`` re-checks
    /// the playback epoch + track id before publishing, so a stale result for a
    /// track the user already skipped past is dropped.
    private func scheduleLyricsLoad() {
        lyrics = []
        Task { [weak self] in try? await self?.loadLyrics() }
    }

    private func loadLyrics() async throws {
        guard let library, let track = currentTrack, !track.isInternetRadioStream else {
            lyrics = []
            return
        }
        let trackId = track.id
        let epoch = playbackEpoch
        let fetched = (try? await library.lyrics(for: track)) ?? []
        guard isPlaybackEpochCurrent(epoch), currentTrack?.id == trackId else { return }
        lyrics = fetched
    }

    private func resolvedArtworkURL(for track: Track) -> URL? {
        if let local = offline?.localArtworkURL(forTrackId: track.id) { return local }
        if let localAlbum = offline?.localArtworkURL(forAlbumId: track.albumId) { return localAlbum }
        if let file = track.artworkURL, file.isFileURL,
           FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        return resolveArtwork?(track) ?? track.artworkURL
    }

    private func refreshNowPlaying() {
        guard let track = currentTrack else {
            cancelNowPlayingArtworkLoad()
            updateNowPlaying(nil)
            return
        }
        let metadata = nowPlayingMetadata(for: track)
        if nowPlayingArtworkTrackId == track.id {
            updateNowPlaying(metadata, artwork: nowPlayingArtwork)
        } else {
            nowPlayingArtworkTrackId = track.id
            nowPlayingArtwork = nil
            updateNowPlaying(metadata, artwork: nil)
            scheduleNowPlayingArtworkLoad(for: track)
        }
    }

    private func nowPlayingMetadata(for track: Track) -> (title: String, artist: String, albumTitle: String?, duration: TimeInterval) {
        (
            title: track.title,
            artist: track.artist,
            albumTitle: track.albumTitle.isEmpty ? nil : track.albumTitle,
            duration: duration > 0 ? duration : track.duration,
        )
    }

    private func cancelNowPlayingArtworkLoad() {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingArtworkTrackId = nil
        nowPlayingArtwork = nil
    }

    private func scheduleNowPlayingArtworkLoad(for track: Track) {
        nowPlayingArtworkTask?.cancel()
        let trackId = track.id
        nowPlayingArtworkTask = Task { [weak self] in
            guard let self else { return }
            let cgImage = await self.loadNowPlayingArtworkCGImage(for: track)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.currentTrack?.id == trackId else { return }
                if let cgImage {
                    self.nowPlayingArtworkTrackId = trackId
                    self.nowPlayingArtwork = Self.makeNowPlayingArtwork(cgImage: cgImage)
                } else {
                    self.nowPlayingArtwork = nil
                }
                self.updateNowPlaying(self.nowPlayingMetadata(for: track), artwork: self.nowPlayingArtwork)
            }
        }
    }

    private func loadNowPlayingArtworkCGImage(for track: Track) async -> CGImage? {
        let pixelSize: CGFloat = 600
        if let url = resolvedArtworkURL(for: track) {
            return await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: pixelSize)
        }
        if track.isInternetRadioStream, let seedKey = RadioStationMeshArtwork.seedKey(for: track) {
            return await renderMeshNowPlayingArtwork(seedKey: seedKey, side: pixelSize)
        }
        return nil
    }

    @MainActor
    private func renderMeshNowPlayingArtwork(seedKey: String, side: CGFloat) -> CGImage? {
        #if os(iOS)
        let content = RadioStationMeshArtworkView(seedKey: seedKey, cornerRadius: 0)
            .frame(width: side, height: side)
        let renderer = ImageRenderer(content: content)
        renderer.scale = UIScreen.main.scale
        return renderer.cgImage
        #else
        return nil
        #endif
    }

    private static func makeNowPlayingArtwork(cgImage: CGImage) -> MPMediaItemArtwork {
        let bounds = CGSize(width: cgImage.width, height: cgImage.height)
        #if canImport(UIKit)
        return MPMediaItemArtwork(boundsSize: bounds) { requestedSize in
            let image = UIImage(cgImage: cgImage)
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: requestedSize, format: format)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
        #elseif canImport(AppKit)
        return MPMediaItemArtwork(boundsSize: bounds) { requestedSize in
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)),
            )
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            let scaled = NSImage(size: requestedSize)
            scaled.lockFocus()
            image.draw(
                in: NSRect(origin: .zero, size: requestedSize),
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1,
            )
            scaled.unlockFocus()
            return scaled
        }
        #else
        return MPMediaItemArtwork(boundsSize: bounds) { _ in UIImage() }
        #endif
    }

    private func updateNowPlaying(
        _ info: (title: String, artist: String, albumTitle: String?, duration: TimeInterval)?,
        artwork: MPMediaItemArtwork? = nil,
    ) {
        var now = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let info {
            now[MPMediaItemPropertyTitle] = info.title
            now[MPMediaItemPropertyArtist] = info.artist
            if let albumTitle = info.albumTitle {
                now[MPMediaItemPropertyAlbumTitle] = albumTitle
            } else {
                now.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
            }
            now[MPMediaItemPropertyPlaybackDuration] = info.duration
            now[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackHead
            // Report rate 0 while buffering — playback isn't progressing, and a
            // non-zero rate makes the lock screen advance a phantom playhead.
            now[MPNowPlayingInfoPropertyPlaybackRate] = (isPlaying && !isBuffering) ? playbackRate : 0.0
            now[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            if let artwork {
                now[MPMediaItemPropertyArtwork] = artwork
            } else {
                now.removeValue(forKey: MPMediaItemPropertyArtwork)
            }
        } else {
            now.removeAll()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = now
    }

    private func maybeScrobble(track: Track, position: TimeInterval) {
        guard !scrobbledForCurrentTrack, !track.isInternetRadioStream else { return }
        let half = max(track.duration * 0.5, 30)
        if position >= half {
            scrobbledForCurrentTrack = true
            onTrackScrobbled?(track, playbackSource)
        }
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumePlaybackFromRemoteCommand() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlaybackFromRemoteCommand() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                positionEvent.positionTime.isFinite
            else { return .commandFailed }
            Task { @MainActor in self.seek(toSeconds: positionEvent.positionTime) }
            return .success
        }
        updateRemoteCommands()
    }
}

extension Error {
    var musicPlaybackToastMessage: String {
        let ns = self as NSError
        if ns.domain == NSOSStatusErrorDomain {
            return "Playback failed while decoding audio. The app will try other stream formats when possible."
        }
        return localizedDescription
    }
}
