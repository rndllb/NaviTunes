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

@MainActor
final class PlaybackEngine: NSObject, ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int = 0
    /// IDs of tracks that were inserted into the queue via "Play Next" / "Add to Queue"
    /// (vs. items that came from the active source like an album or playlist). Drives the
    /// Now Playing → Queue → "Queue" vs "Continue Playing" split.
    @Published private(set) var userQueuedTrackIds: Set<String> = []
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    /// Live playhead updated every periodic observer tick. Prefer over ``currentTime`` for synced lyrics — ``currentTime`` is UI-throttled.
    var livePlaybackTime: TimeInterval { playbackHead }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lyrics: [LyricLine] = []
    @Published var shuffleMode: ShuffleMode = .off
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var playbackSource: PlaybackSource?
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
    /// Captured at skip/jump/end before the async ``advance()`` task runs — avoids losing play intent.
    private var shouldAutoPlayAfterAdvance = false
    /// True while ``advance()`` is loading the next item — ignores stale `.paused` KVO during handoff.
    private var isAdvancingToNextItem = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// KVO on `AVPlayer.timeControlStatus` — the system-set property reflecting
    /// what playback is actually doing. Catches every external pause cause
    /// (headphone unplug, Control Center, network stall, audio session steal)
    /// in one place so ``isPlaying`` never goes stale.
    private var timeControlStatusObservation: NSKeyValueObservation?
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

    private var didConfigureRemoteCommands = false
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
    }
    #endif

    var activeTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
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
        configureRemoteCommands()
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
        player == nil && queue.indices.contains(currentIndex)
    }

    private func startFromPendingRestore() async {
        let epoch = beginPlaybackSession()
        let startAt = pendingRestoreSeconds
        pendingRestoreSeconds = 0
        activateAudioSession()
        do {
            try await startCurrentItem(epoch: epoch, startSeconds: startAt, autoPlay: true)
            guard isPlaybackEpochCurrent(epoch), let player else {
                isPlaying = false
                return
            }
            if player.rate < 0.01 { beginPlayback(on: player) }
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
        unshuffledQueue = nil
        sourceQueueOrder = normalized
        // Caller may flip this back to `.on` (e.g. ``playAlbumShuffled``) after the queue lands.
        shuffleMode = .off
        lastEmittedUIProgress = -10_000
        playbackHead = 0
        try await loadLyrics()
        guard isPlaybackEpochCurrent(epoch) else { return }
        activateAudioSession()
        try await startCurrentItem(epoch: epoch, autoPlay: true)
        guard isPlaybackEpochCurrent(epoch), let player else { return }
        beginPlayback(on: player)
        isPlaying = true
        scrobbledForCurrentTrack = false
        configureRemoteCommands()
        revealMiniPlayerChrome()
        if let started = activeTrack { onTrackStarted?(started) }
    }

    func playNext(library: MusicLibraryProviding?, track: Track) async throws {
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
    }

    func playTracksNext(library: MusicLibraryProviding?, tracks: [Track]) async throws {
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
    }

    func addToQueue(library: MusicLibraryProviding?, track: Track) async throws {
        try await addTracksToQueue(library: library, tracks: [track])
    }

    func addTracksToQueue(library: MusicLibraryProviding?, tracks: [Track]) async throws {
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
        if queue.isEmpty {
            reset()
            return
        }
        if let previousId, let idx = queue.firstIndex(where: { $0.id == previousId }) {
            currentIndex = idx
            return
        }
        currentIndex = min(currentIndex, queue.count - 1)
        captureAutoPlayIntentForAdvance()
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func togglePlayPause() {
        if hasPendingRestore {
            schedulePendingRestorePlayback()
            return
        }
        guard let player else { return }
        if player.rate > 0.01 {
            player.pause()
            isPlaying = false
        } else {
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
        guard player != nil else { return }
        if player?.rate ?? 0 < 0.01, let player {
            beginPlayback(on: player)
            isPlaying = true
            playbackHead = player.currentTime().seconds
        }
    }

    private func pausePlaybackFromRemoteCommand() {
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

    func seek(to fraction: Double, completion: (() -> Void)? = nil) {
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

    func seek(toSeconds targetSeconds: TimeInterval, completion: (() -> Void)? = nil) {
        Task {
            await performSeek(toSeconds: targetSeconds, completion: completion)
        }
    }

    private func performSeek(toSeconds targetSeconds: TimeInterval, completion: (() -> Void)?) async {
        let d = await resolvePlaybackDuration()
        guard d > 0, let player else {
            completion?()
            return
        }
        let clamped = max(0, min(targetSeconds, d))

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
        // Shuffle is a queue-reordering action — advance sequentially regardless of mode.
        guard currentIndex + 1 < queue.count else { return }
        captureAutoPlayIntentForAdvance()
        currentIndex += 1
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func skipPrevious() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard currentIndex > 0 else {
            seek(to: 0)
            return
        }
        captureAutoPlayIntentForAdvance()
        currentIndex -= 1
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
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
            // Turning shuffle ON: save current queue and randomize the rest
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
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
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
    }

    private func cancelPendingAdvanceWork() {
        advanceWork?.cancel()
        advanceWork = nil
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
        let shouldAutoPlay = shouldAutoPlayAfterAdvance || isPlaying || (player?.rate ?? 0) > 0.01
        shouldAutoPlayAfterAdvance = false
        let epoch = beginPlaybackSession()
        isAdvancingToNextItem = true
        defer { isAdvancingToNextItem = false }
        teardownPlayer()
        try await loadLyrics()
        guard isPlaybackEpochCurrent(epoch) else { return }
        activateAudioSession()
        try await startCurrentItem(epoch: epoch, autoPlay: shouldAutoPlay)
        guard isPlaybackEpochCurrent(epoch), let player else {
            isPlaying = false
            refreshNowPlaying()
            return
        }
        if shouldAutoPlay {
            beginPlayback(on: player)
            isPlaying = true
        } else {
            isPlaying = false
            refreshNowPlaying()
        }
        scrobbledForCurrentTrack = false
        revealMiniPlayerChrome()
        if let started = activeTrack {
            userQueuedTrackIds.remove(started.id)
            onTrackStarted?(started)
        }
    }

    /// Starts AVPlayer and updates lock screen / Dynamic Island playback rate.
    private func beginPlayback(on player: AVPlayer) {
        activateAudioSession()
        player.playImmediately(atRate: 1.0)
        refreshNowPlaying()
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
        p.replaceCurrentItem(with: nil)
    }

    private func detachPlayerKeepingQueueState() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        stopPlayer(player)
        player = nil
    }

    private func teardownPlayer() {
        seekGeneration += 1
        seekSettleDeadline = nil
        isSeeking = false
        localFileDuration = 0
        probingLocalFileURL = nil
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
        if headers.isEmpty {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
            case .unknown: try await Task.sleep(for: .milliseconds(110))
            @unknown default: try await Task.sleep(for: .milliseconds(110))
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
        return true
    }

    private func startCurrentItem(epoch: UInt, startSeconds: TimeInterval = 0, autoPlay: Bool = false) async throws {
        guard isPlaybackEpochCurrent(epoch) else { return }
        guard let track = currentTrack else { throw PlaybackEngineError.missingTrack }

        var candidates: [(url: URL, headers: [String: String])] = []
        if let saved = offline?.localFile(for: track.id) {
            candidates.append((saved, [:]))
        }
        var seen = Set(candidates.map { $0.url.absoluteString })
        func appendUnique(_ u: URL, _ h: [String: String]) {
            let key = u.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            candidates.append((u, h))
        }
        if let direct = track.streamOverrideURL {
            appendUnique(direct, [:])
        }
        if let library {
            let serverHeaders = library.httpHeadersForMediaRequests()
            if let jellyfin = library as? JellyfinMusicClient {
                for u in jellyfin.allStreamingURLs(for: track) {
                    appendUnique(u, serverHeaders)
                }
            } else {
                appendUnique(try library.streamURL(for: track), serverHeaders)
                for u in library.fallbackStreamURLs(for: track) {
                    appendUnique(u, serverHeaders)
                }
            }
        }
        guard !candidates.isEmpty else {
            throw library == nil ? PlaybackEngineError.missingLibrary : URLError(.cannotLoadFromNetwork)
        }

        var lastError: Error?
        for candidate in candidates {
            guard isPlaybackEpochCurrent(epoch) else { return }
            detachPlayerKeepingQueueState()
            do {
                if try await loadPlayerItem(
                    epoch: epoch,
                    candidate: candidate,
                    track: track,
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
        let asset = makePlaybackAsset(url: candidate.url, headers: candidate.headers)
        if candidate.url.isFileURL, let urlAsset = asset as? AVURLAsset {
            _ = try? await urlAsset.load(.isPlayable, .duration)
        }
        var resolvedDuration = track.duration
        if resolvedDuration <= 0, candidate.url.isFileURL {
            resolvedDuration = await LocalMediaDuration.seconds(at: candidate.url)
        }
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        if candidate.url.isFileURL {
            p.automaticallyWaitsToMinimizeStalling = false
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
        if resolvedDuration > 0 {
            duration = resolvedDuration
            if candidate.url.isFileURL {
                localFileDuration = resolvedDuration
            }
            persistOfflineDurationIfNeeded(resolvedDuration)
            patchActiveQueueTrackDuration(resolvedDuration)
        }
        return true
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
                    self.isPlaying = false
                    self.refreshNowPlaying()
                } else if status == .playing, !self.isPlaying {
                    self.isPlaying = true
                    self.refreshNowPlaying()
                }
                // `.waitingToPlayAtSpecifiedRate` = buffering — leave the
                // current flag alone, the user still intends to play.
            }
        }

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

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleEnded()
            }
        }

        refreshNowPlaying()
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

    private func handleEnded() {
        // Shuffle is a queue-reordering action (see ``toggleShuffle``) — once shuffled,
        // advance through the queue sequentially, otherwise every track end would re-randomize.
        switch repeatMode {
        case .one:
            captureAutoPlayIntentForAdvance()
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
        case .all:
            captureAutoPlayIntentForAdvance()
            currentIndex = (currentIndex + 1) % max(queue.count, 1)
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
        case .off:
            if currentIndex + 1 < queue.count {
                captureAutoPlayIntentForAdvance()
                currentIndex += 1
                resetUIProgressForTrackHandoff()
                scheduleAdvance()
            } else {
                isPlaying = false
            }
        }
    }

    private var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    private func loadLyrics() async throws {
        guard let library, let track = currentTrack, !track.isInternetRadioStream else {
            lyrics = []
            return
        }
        lyrics = (try? await library.lyrics(for: track)) ?? []
    }

    private func resolvedArtworkURL(for track: Track) -> URL? {
        if let local = offline?.localArtworkURL(forTrackId: track.id) { return local }
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
            now[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
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

    private func configureRemoteCommands() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumePlaybackFromRemoteCommand() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlaybackFromRemoteCommand() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipPrevious() }
            return .success
        }
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
