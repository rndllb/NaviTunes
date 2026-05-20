import AVFoundation
import MediaPlayer
import SwiftUI

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
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lyrics: [LyricLine] = []
    @Published var shuffleMode: ShuffleMode = .off
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var playbackSource: PlaybackSource?
    /// Drives the tab-bar mini player pill — false after a cold restore until the user starts playback.
    @Published private(set) var showsMiniPlayerChrome = false

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

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private var library: MusicLibraryProviding?
    private weak var lastFm: LastFmScrobbler?
    private weak var offline: OfflineDownloadManager?
    private var scrobbledForCurrentTrack = false

    /// Fires once per track when scrobble threshold is reached (~50% / 30s). `AppModel`
    /// uses this to stamp the played playlist (or album, for ad-hoc queues) into the
    /// Recently Played shelf on the Home tab.
    var onTrackScrobbled: ((Track, PlaybackSource?) -> Void)?

    /// Fires the moment a track becomes the active item at position 0 — whether the
    /// user tapped it, jumped to it, or auto-advanced. Drives the per-track Now Playing
    /// → Queue → History list, which records on start (not on scrobble threshold).
    var onTrackStarted: ((Track) -> Void)?

    private var didConfigureRemoteCommands = false

    #if os(iOS)
    private var audioSessionInterruptionObserver: NSObjectProtocol?
    private var audioSessionRouteObserver: NSObjectProtocol?
    private var didInstallAudioSessionObservers = false
    #endif

    func bind(lastFm: LastFmScrobbler, offline: OfflineDownloadManager? = nil) {
        self.lastFm = lastFm
        self.offline = offline
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
        if isPlaying, player.rate < 0.01 { player.play() }
        refreshNowPlaying()
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
        if case .ended = type {
            let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            guard opts.contains(.shouldResume), isPlaying else { return }
            activateAudioSession()
            player?.play()
            refreshNowPlaying()
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard isPlaying, player?.rate ?? 0 < 0.01 else { return }
        activateAudioSession()
        player?.play()
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
        )
    }

    /// Repopulates the queue + index + transport modes from a saved snapshot **without** starting playback.
    /// The first play tap (mini player / lock screen) resumes from `pendingRestoreSeconds`.
    func restore(library: MusicLibraryProviding?, snapshot: PlaybackQueueSnapshot) {
        guard !snapshot.queue.isEmpty else { return }
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
        duration = activeTrack?.duration ?? 0
        showsMiniPlayerChrome = false
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
        let startAt = pendingRestoreSeconds
        pendingRestoreSeconds = 0
        activateAudioSession()
        do {
            try await startCurrentItem(startSeconds: startAt)
            player?.play()
            isPlaying = true
        } catch {
            // If the restored stream can't be reached (offline, server moved), leave the queue
            // intact and paused — the user can still skip/jump or try again later.
            isPlaying = false
        }
        revealMiniPlayerChrome()
    }

    func playAlbum(library: MusicLibraryProviding?, tracks: [Track], startIndex: Int = 0, source: PlaybackSource? = nil) async throws {
        if let library { self.library = library }
        teardownPlayer()
        queue = tracks
        currentIndex = min(max(0, startIndex), max(tracks.count - 1, 0))
        playbackSource = source
        // Fresh source = no user-queued items yet.
        userQueuedTrackIds.removeAll()
        lastEmittedUIProgress = -10_000
        playbackHead = 0
        try await loadLyrics()
        activateAudioSession()
        try await startCurrentItem()
        player?.play()
        isPlaying = true
        scrobbledForCurrentTrack = false
        configureRemoteCommands()
        revealMiniPlayerChrome()
        if let started = activeTrack { onTrackStarted?(started) }
    }

    func playNext(library: MusicLibraryProviding?, track: Track) async throws {
        if let library { self.library = library }
        if queue.isEmpty {
            try await playAlbum(library: library, tracks: [track], startIndex: 0)
            return
        }
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertAt)
        userQueuedTrackIds.insert(track.id)
    }

    func playTracksNext(library: MusicLibraryProviding?, tracks: [Track]) async throws {
        guard !tracks.isEmpty else { return }
        if let library { self.library = library }
        if queue.isEmpty {
            try await playAlbum(library: library, tracks: tracks, startIndex: 0)
            return
        }
        let insertAt = min(currentIndex + 1, queue.count)
        for (i, t) in tracks.enumerated() {
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
        queue.append(contentsOf: tracks)
        for t in tracks { userQueuedTrackIds.insert(t.id) }
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
        Task { try? await advance() }
    }

    func togglePlayPause() {
        if hasPendingRestore {
            Task { await startFromPendingRestore() }
            return
        }
        guard let player else { return }
        if player.rate > 0.01 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
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
            Task { await startFromPendingRestore() }
            return
        }
        activateAudioSession()
        guard player != nil else { return }
        if player?.rate ?? 0 < 0.01 {
            player?.play()
            isPlaying = true
            playbackHead = player?.currentTime().seconds ?? playbackHead
            refreshNowPlaying()
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
            player.play()
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
        if shuffleMode == .on {
            let remaining = queue.indices.filter { $0 != currentIndex }
            guard let next = remaining.randomElement() else { return }
            currentIndex = next
        } else {
            guard currentIndex + 1 < queue.count else { return }
            currentIndex += 1
        }
        Task { try? await advance() }
    }

    func skipPrevious() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if shuffleMode == .on {
            let remaining = queue.indices.filter { $0 != currentIndex }
            guard let prev = remaining.randomElement() else { return }
            currentIndex = prev
        } else {
            guard currentIndex > 0 else {
                seek(to: 0)
                return
            }
            currentIndex -= 1
        }
        Task { try? await advance() }
    }

    func toggleShuffle() {
        shuffleMode = shuffleMode == .off ? .on : .off
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func jumpToQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        Task { try? await advance() }
    }

    func moveUpNextItem(from source: IndexSet, to destination: Int) {
        let offset = currentIndex + 1
        guard offset <= queue.count else { return }
        var upNext = Array(queue[offset...])
        upNext.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(offset..., with: upNext)
    }

    private func advance() async throws {
        // A skip/jump abandons the saved playhead for the previously-active track.
        pendingRestoreSeconds = 0
        teardownPlayer()
        try await loadLyrics()
        activateAudioSession()
        try await startCurrentItem()
        player?.play()
        isPlaying = true
        scrobbledForCurrentTrack = false
        revealMiniPlayerChrome()
        if let started = activeTrack {
            // Consumed from the user queue (if it was there) — it's now the active
            // track, no longer "queued".
            userQueuedTrackIds.remove(started.id)
            onTrackStarted?(started)
        }
    }

    private func detachPlayerKeepingQueueState() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }

    private func teardownPlayer() {
        seekGeneration += 1
        seekSettleDeadline = nil
        isSeeking = false
        localFileDuration = 0
        detachPlayerKeepingQueueState()
        playbackHead = 0
        lastEmittedUIProgress = -10_000
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

    private func startCurrentItem(startSeconds: TimeInterval = 0) async throws {
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
            detachPlayerKeepingQueueState()
            do {
                if try await loadPlayerItem(
                    candidate: candidate,
                    track: track,
                    startSeconds: startSeconds,
                ) {
                    return
                }
                lastError = URLError(.cannotParseResponse)
            } catch {
                lastError = error
            }
        }

        teardownPlayer()
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    private func loadPlayerItem(
        candidate: (url: URL, headers: [String: String]),
        track: Track,
        startSeconds: TimeInterval,
    ) async throws -> Bool {
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
        if resolvedDuration <= 0 {
            let fromAsset = await LocalMediaDuration.seconds(asset: asset)
            if fromAsset > 0 { resolvedDuration = fromAsset }
        }
        attachPlayer(p, item: item, track: track, initialTime: startSeconds, resolvedDuration: resolvedDuration)

        if startSeconds > 0.05 {
            _ = await awaitPlayerSeek(p, to: startSeconds)
            currentTime = startSeconds
            playbackHead = startSeconds
            lastEmittedUIProgress = startSeconds
        }

        p.play()
        isPlaying = true

        let readyBudget: Duration = candidate.url.isFileURL
            ? (startSeconds > 1 ? .seconds(4) : .seconds(2))
            : (startSeconds > 1 ? .seconds(12) : .seconds(10))
        if await playbackFailedAfterReady(
            item: item,
            observeBudget: readyBudget,
            expectedPosition: startSeconds,
        ) {
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

        let interval = CMTime(seconds: 0.35, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = time.seconds
                self.playbackHead = elapsed

                let newDuration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                if self.localFileDuration > 0 {
                    // Keep probed file length; AVPlayerItem.duration can be wrong briefly on local files.
                } else if newDuration > 0, newDuration != self.duration {
                    self.duration = newDuration
                    self.persistOfflineDurationIfNeeded(newDuration)
                    self.patchActiveQueueTrackDuration(newDuration)
                } else if self.duration <= 0, item.asset is AVURLAsset,
                          let urlAsset = item.asset as? AVURLAsset, urlAsset.url.isFileURL {
                    Task {
                        let probed = await LocalMediaDuration.seconds(at: urlAsset.url)
                        guard probed > 0 else { return }
                        self.duration = probed
                        if urlAsset.url.isFileURL {
                            self.localFileDuration = probed
                        }
                        self.persistOfflineDurationIfNeeded(probed)
                        self.patchActiveQueueTrackDuration(probed)
                    }
                }

                let playing = p.rate > 0.01
                let playStateChanged = playing != self.isPlaying
                if playStateChanged { self.isPlaying = playing }

                self.maybeScrobble(track: track, position: elapsed)
                if playStateChanged
                    || elapsed - self.lastNowPlayingInfoRefresh >= 0.55
                    || abs(elapsed - self.lastNowPlayingInfoRefresh) > 1.25
                {
                    self.lastNowPlayingInfoRefresh = elapsed
                    self.refreshNowPlaying()
                }

                guard !self.isSeeking else { return }
                if let deadline = self.seekSettleDeadline, ContinuousClock.now < deadline {
                    return
                }
                self.seekSettleDeadline = nil
                // Drop stale samples that arrive right after a seek (often ~0s before the player catches up).
                if elapsed + 1.5 < self.currentTime { return }
                if self.currentTime > 3, elapsed < 1 { return }
                if elapsed - self.lastEmittedUIProgress >= 0.55 || abs(elapsed - self.currentTime) > 1.25 {
                    self.lastEmittedUIProgress = elapsed
                    self.currentTime = elapsed
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }
    }

    private func handleEnded() {
        switch repeatMode {
        case .one:
            Task { try? await advance() }
        case .all:
            if shuffleMode == .on {
                let remaining = queue.indices.filter { $0 != currentIndex }
                currentIndex = remaining.randomElement() ?? 0
            } else {
                currentIndex = (currentIndex + 1) % max(queue.count, 1)
            }
            Task { try? await advance() }
        case .off:
            if shuffleMode == .on {
                let remaining = queue.indices.filter { $0 != currentIndex }
                if let next = remaining.randomElement() {
                    currentIndex = next
                    Task { try? await advance() }
                } else {
                    isPlaying = false
                }
            } else if currentIndex + 1 < queue.count {
                currentIndex += 1
                Task { try? await advance() }
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

    private func refreshNowPlaying() {
        guard let track = currentTrack else {
            updateNowPlaying(nil)
            return
        }
        updateNowPlaying(
            (title: track.title, artist: track.artist, duration: duration > 0 ? duration : track.duration),
        )
    }

    private func updateNowPlaying(_ info: (title: String, artist: String, duration: TimeInterval)?) {
        var now = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let info {
            now[MPMediaItemPropertyTitle] = info.title
            now[MPMediaItemPropertyArtist] = info.artist
            now[MPMediaItemPropertyPlaybackDuration] = info.duration
            now[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackHead
            now[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
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
            Task { await lastFm?.scrobble(track: track, timestamp: Date()) }
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
