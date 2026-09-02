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
    /// Track id ``lyrics`` were loaded for — or that a load is in flight for. Lets a track
    /// start ask for lyrics without knowing whether some earlier path already did
    /// (``scheduleLyricsLoadIfNeeded(for:)``).
    private var lyricsTrackId: String?
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
    @Published private(set) var showsMiniPlayerChrome = false {
        didSet {
#if DEBUG
            // T054: this flag is forwarded into `AppModel.objectWillChange`, so a flip is a
            // whole-tree invalidation. If one lands mid-drag it would explain the stall.
            if oldValue != showsMiniPlayerChrome {
                DebugUIRemote.log("NP-CHROME showsMiniPlayerChrome=\(showsMiniPlayerChrome)")
            }
#endif
        }
    }
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
    /// Identity for the in-flight autoplay-verify task so it can clear its own
    /// handle on completion without clobbering a newer task's handle.
    private var autoplayVerifyToken = UUID()
    /// Captured at skip/jump/end before the async ``advance()`` task runs — avoids losing play intent.
    private var shouldAutoPlayAfterAdvance = false
    /// When a track is inserted via Play Next / Add to Queue from a playlist detail view, remember
    /// which playlist it came from so Now Playing → Go to Playlist navigates correctly.
    private var trackOriginPlaylistIds: [String: String] = [:]
    /// True while ``advance()`` is loading the next item — ignores stale `.paused` KVO during handoff.
    private var isAdvancingToNextItem = false
    /// Brief window after an intentional play where `.paused` KVO must not flip ``isPlaying`` —
    /// startup, handoff, and lock-screen resume report `.paused` before `playImmediately` sticks.
    private var playIntentUntil: ContinuousClock.Instant?

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
    // The second transport is gone.
    //
    // There used to be an `EqualizedAudioEnginePlayer` here — an `AVAudioEngine` graph used
    // whenever the equalizer was on and the source was a local file — plus the state needed to
    // hand a track over from `AVPlayer` to it mid-song once a stream finished caching. That
    // handoff is the bug: the EQ was simply absent from the first part of every streamed track,
    // and the swap itself was audible.
    //
    // There is now one transport, `AVQueuePlayer`, for everything. The equalizer rides along as an
    // `MTAudioProcessingTap` attached to each item's `audioMix` before it is inserted — see
    // `TapPlayerItem` and `EqualizerAudioTap`. Nothing swaps mid-track, because there is nothing
    // to swap to.
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
    /// On-disk stream cache for instant replays of fully cached tracks. Live
    /// streams always use plain http(s) URLs — AVFoundation probes custom-scheme
    /// asset URLs with URLSession and breaks playback.
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

    /// Fires when a track reaches its **natural end** (end-of-playback advance), NOT
    /// on a user skip. Drives Kill Mode's "played fully → kept (green)" path —
    /// `AppModel` marks the outgoing track listened when the source is a kill-mode
    /// playlist.
    var onTrackCompleted: ((Track, PlaybackSource?) -> Void)?

    /// Fires when playback has genuinely failed and the transport has already been corrected.
    ///
    /// The engine had **no error channel at all** before this: `startCurrentItem` threw, and every
    /// caller on a skip, auto-advance, route-change or EQ path threw the error away. `AppModel`
    /// wires this to the app's usual transient toast, which is the only reason a mid-queue failure
    /// can now say anything to the user.
    var onPlaybackFailure: ((Track?, Error?) -> Void)?

    /// Set by `AppModel` during an active Kill Mode session: returns true for tracks
    /// already "listened" (played fully or skipped) that must not be auto-advanced into,
    /// so each song plays once per run. Nil during normal playback (no effect).
    var autoAdvanceExclusion: ((Track) -> Bool)?

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
    private var appBackgroundObserver: NSObjectProtocol?
    private var appForegroundObserver: NSObjectProtocol?
    private var didInstallAudioSessionObservers = false
    /// True while the app is in the background. The periodic time observer uses
    /// this to skip Now-Playing rebuilds and published-progress writes that are
    /// redundant/invisible in the background and burn battery during background
    /// audio. Set by the app-lifecycle observers installed alongside the audio
    /// session observers.
    private var isAppBackgrounded = false
    /// Debounced task that releases the audio session after we go idle so iOS
    /// can suspend the app. Cancelled if playback resumes within the window.
    private var audioSessionDeactivateTask: Task<Void, Never>?
    /// Whether ``activateAudioSession()`` currently believes the session is active, so repeat
    /// calls can skip the `mediaserverd` round trip. Cleared by every path that gives the
    /// session up — interruption, our own deactivation, and returning to the foreground while
    /// paused (iOS may have torn the session down while suspended).
    ///
    /// A stale `false` is harmless (one redundant activation); a stale `true` would skip a
    /// required activation, so this is cleared aggressively.
    private var isAudioSessionActive = false
    /// When ``reconcilePlaybackSessionAfterUIMilestone()`` last ran, so the second of the two
    /// milestones one player open produces can skip the redundant Now-Playing re-stamp.
    private var lastUIMilestoneReconcile: TimeInterval = 0
    /// Context for (re)installing the periodic time observer at a new cadence
    /// (foreground 0.35s vs background 2.0s).
    private var timeObserverContext: (item: AVPlayerItem, track: Track, player: AVPlayer)?
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
        appBackgroundObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAppBackgrounded = true
                // Widen the periodic time-observer cadence for the background.
                self.installPeriodicTimeObserver()
                // Stamp one fresh Now-Playing baseline (rate + elapsed +
                // timestamp) so the lock screen can extrapolate the playhead on
                // its own while we stop pushing per-tick updates.
                self.refreshNowPlaying()
                // If we are backgrounded while paused, release the session now
                // (don't wait out the debounce, which suspension may cut off)
                // so the app can suspend.
                if !self.isPlaying { self.deactivateAudioSessionNow() }
            }
        }
        appForegroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAppBackgrounded = false
                // iOS may have torn down the session while we were suspended, so
                // let the next play path re-assert it instead of trusting the flag.
                if !self.isPlaying { self.isAudioSessionActive = false }
                // Restore the fast foreground time-observer cadence.
                self.installPeriodicTimeObserver()
                // Resync the scrubber + Now-Playing after a stretch of
                // throttled background ticks.
                self.currentTime = self.playbackHead
                self.refreshNowPlaying()
            }
        }
    }
    #endif

    func reconcilePlaybackSessionAfterUIMilestone() {
        activateAudioSession()
        // One player open produces *two* UI milestones: the mini player's tap action calls this
        // synchronously (before `present()` can even be reached), and the player's own
        // `onAppear` calls it again a moment later. The corrective branches below are cheap and
        // must always run. The `refreshNowPlaying()` re-stamp is the expensive half — a read and
        // a write of `MPNowPlayingInfoCenter`, both synchronous IPC — and running it twice
        // milliseconds apart wrote the same values twice. Only the repeat is skipped; the
        // periodic time observer re-stamps on its own cadence regardless, so nothing is lost.
        let elapsed = Date.timeIntervalSinceReferenceDate - lastUIMilestoneReconcile
        let isRepeatMilestone = elapsed < 0.3
        lastUIMilestoneReconcile = Date.timeIntervalSinceReferenceDate
        if !isRepeatMilestone {
            refreshNowPlaying()
        }
        guard let player else { return }
        player.isMuted = false
        if player.volume < 0.001 { player.volume = 1.0 }
        if isPlaying, player.rate < 0.01 { beginPlayback(on: player) }
        else if !isRepeatMilestone { refreshNowPlaying() }
    }

    /// Bring the audio session up, unless it is already up.
    ///
    /// `setCategory` + `setActive` are synchronous IPC round trips into `mediaserverd`, and this
    /// is called from a dozen places — including twice per player open, once from the mini
    /// player's tap action (which delays the runloop returning, and so delays the present
    /// itself) and again from the player's `onAppear`. Neither call knew the other had happened,
    /// so both paid the full cost inside the transition's setup window.
    ///
    /// The guard is only safe because every path that can take the session away from us clears
    /// the flag: our own deactivation, and a system interruption (`.began`), where iOS hands the
    /// session to a call or Siri. A failed activation deliberately does not set the flag, so the
    /// next caller retries rather than assuming success — which is also stricter than the old
    /// `try?`, where a failure was simply swallowed and never revisited.
    private func activateAudioSession() {
        #if os(iOS)
        // Unconditional: a pending deferred deactivation has to be called off even when the
        // session is already active, or it will tear down a session we just said we want.
        audioSessionDeactivateTask?.cancel()
        audioSessionDeactivateTask = nil
        guard !isAudioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        // Reading the configuration is cheap; setting it is not, and setting it
        // while the session is active fails with `-50`. Only write when it
        // actually differs (e.g. the hearing test left `.mixWithOthers` behind).
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .allowAirPlay]
        let unwanted: AVAudioSession.CategoryOptions = [.mixWithOthers, .duckOthers]
        if session.category != .playback
            || session.mode != .default
            || !session.categoryOptions.contains(options)
            || !session.categoryOptions.isDisjoint(with: unwanted) {
            try? session.setCategory(.playback, mode: .default, options: options)
        }
        // Activation stays synchronous: playback paths call this immediately
        // before starting a player and need the session live first.
        do {
            try session.setActive(true, options: [])
            isAudioSessionActive = true
        } catch {
            isAudioSessionActive = false
        }
        #endif
    }

    /// Release the audio session a few seconds after going idle so iOS can
    /// suspend the app (and power down the audio route) instead of keeping it
    /// active indefinitely. Cancelled by ``activateAudioSession()`` if playback
    /// resumes first. The session was previously never deactivated, so a paused
    /// app stayed audio-active and never suspended.
    private func scheduleAudioSessionDeactivation() {
        #if os(iOS)
        audioSessionDeactivateTask?.cancel()
        audioSessionDeactivateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.deactivateAudioSessionNow() }
        }
        #endif
    }

    private func deactivateAudioSessionNow() {
        #if os(iOS)
        audioSessionDeactivateTask?.cancel()
        audioSessionDeactivateTask = nil
        guard !isPlaying, isAudioSessionActive else { return }
        isAudioSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
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
            // One transport now, so `isPlaying` is the whole answer — the incoming
            // `|| equalizedPlayer?.isPlaying` guard died with the EQ engine.
            wasPlayingBeforeInterruption = isPlaying
            // The session is no longer ours — a call or Siri has it. The `.ended` branch
            // must be able to re-activate it rather than short-circuit on a stale active
            // flag: anything that skipped reactivating because it looked active would
            // come back to silence.
            isAudioSessionActive = false
            clearPlayIntent()
            isPlaying = false
            refreshNowPlaying()
        case .ended:
            let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            let shouldResume = wasPlayingBeforeInterruption && opts.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }
            markPlayIntent()
            activateAudioSession()
            if let player {
                beginPlayback(on: player)
                ensurePlaybackStarted(on: player, epoch: playbackEpoch)
            }
            isPlaying = true
            refreshNowPlaying()
        @unknown default:
            break
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        // Don't auto-resume — when the user unplugs headphones the system pauses us on purpose
        // (HIG: respect that intent), and the `timeControlStatus` KVO syncs ``isPlaying`` to match.
        //
        // Nothing to do by hand any more. The second transport used to need an explicit stop here,
        // because an `AVAudioEngine` gets no system pause on an unplug and would keep playing out
        // of the loudspeaker. `AVQueuePlayer` is paused by the system like any other player.
        //
        // A route change does still matter to the tap: it can tear the audio machinery down and
        // rebuild it at a **different sample rate**, which fires `prepare` a second time. The tap
        // recomputes its coefficients there, from the format it is handed, which is why they are
        // never computed once at init.
        PlaybackTapLog.eq("route-change reason=\(notification.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "?")")
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
        lyricsTrackId = nil
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
            userQueuedTrackIds: Array(userQueuedTrackIds),
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
        // Nothing is loaded yet and nothing is fetching: leave the id unclaimed so the first
        // play tap's `startCurrentItem` fetches this track's lyrics.
        lyrics = []
        lyricsTrackId = nil
        scrobbledForCurrentTrack = false
        isPlaying = false
        unshuffledQueue = snapshot.unshuffledQueue
        sourceQueueOrder = snapshot.sourceQueueOrder
        // Snapshots written before this field existed decode as nil — start empty rather
        // than inheriting the previous session's ids.
        userQueuedTrackIds = Set(snapshot.userQueuedTrackIds ?? [])
        pruneUserQueuedIds()
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
        player == nil && queue.indices.contains(currentIndex)
    }

    private var hasActivePlaybackOutput: Bool {
        player != nil
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
            isPlaying = true
            markPlayIntent()
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
        let shuffled = tracks.shuffled()
        try await playAlbum(library: library, tracks: shuffled, startIndex: 0, source: source)
        // `playAlbum` suspends. If another album started meanwhile, these stamps would land
        // on *that* queue — and a later shuffle-off would then restore `unshuffledQueue`,
        // swapping this album wholesale into the queue the user is actually listening to.
        guard queue.elementsEqual(shuffled, by: { $0.id == $1.id }) else { return }
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
        // End of the user-queued block, NOT the end of the array. Now Playing renders
        // "Queue" above "Continue Playing", so appending past the source tail would show
        // these tracks at the top of up-next while playing them dead last.
        let insertAt = userQueueBlockEnd
        for (i, t) in normalized.enumerated() {
            queue.insert(t, at: insertAt + i)
            userQueuedTrackIds.insert(t.id)
        }
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

    /// Index just past the contiguous run of user-queued tracks sitting directly after the
    /// cursor. "Play Next" inserts at the front of that block, "Add to Queue" at its end,
    /// which keeps the block contiguous so the rendered order is the play order.
    private var userQueueBlockEnd: Int {
        var idx = min(currentIndex + 1, queue.count)
        while idx < queue.count, userQueuedTrackIds.contains(queue[idx].id) { idx += 1 }
        return idx
    }

    /// Drops ids whose tracks are no longer anywhere in the queue. Without this the set
    /// outlives its tracks and mis-tags an unrelated track that later enters the queue
    /// under a matching id — and both the Queue section and ``isQueueOutOfNaturalOrder``
    /// read it.
    private func pruneUserQueuedIds() {
        guard !userQueuedTrackIds.isEmpty else { return }
        userQueuedTrackIds.formIntersection(Set(queue.map(\.id)))
    }

    /// Removes specific up-next **rows**, by position.
    ///
    /// Queue rows must be addressed positionally, never by `Track.id`. A queue can legitimately
    /// hold the same id more than once — a playlist with a repeated song (nothing dedupes on that
    /// path), or Play Next / Add to Queue invoked on the track that is *already playing*, which
    /// leaves the original at `currentIndex` and inserts a second copy after it. An id therefore
    /// identifies a *song*, not a *row*.
    ///
    /// `offsets` are relative to the start of up-next (`currentIndex + 1`) — the same coordinate
    /// space ``moveUpNextItem(from:to:)`` uses. Nothing at or before `currentIndex` is addressable,
    /// so this **cannot remove the playing track**: no teardown, no `scheduleAdvance()`, no
    /// re-indexing, and the song the user is listening to keeps playing.
    ///
    /// ``removeTracksFromQueue(trackIds:)`` is the id-based sibling. It stays as it is, because its
    /// one remaining caller — deleting a track from the server library — genuinely does want every
    /// copy gone, including the playing one.
    func removeUpNextItems(at offsets: IndexSet) {
        let start = currentIndex + 1
        guard start <= queue.count else { return }
        let absolute = offsets.map { start + $0 }.filter { queue.indices.contains($0) }
        guard !absolute.isEmpty else { return }
        let removedIds = Set(absolute.map { queue[$0].id })
        // Descending, so each removal cannot invalidate the indices still to be removed.
        for index in absolute.sorted(by: >) {
            queue.remove(at: index)
        }
        // Forget an id only once its LAST copy is gone: another row may still be queued, or may be
        // the one currently playing. Dropping the id on the first removal is what would re-break
        // the duplicate case from the other direction.
        let orphanedIds = removedIds.subtracting(Set(queue.map(\.id)))
        userQueuedTrackIds.subtract(orphanedIds)
        clearTrackOriginPlaylists(orphanedIds)
        refreshEnqueuedNextItem()
    }

    /// Removes everything in the user-queued section (Now Playing → Queue → "Clear").
    /// The active track and the source's natural Continue Playing list are preserved.
    ///
    /// Selects **rows after the cursor**, rather than passing `userQueuedTrackIds` to the id-based
    /// removal. That is what preserves the active track *by construction*: if the playing track
    /// also sits in the user queue (Play Next on the song already playing), its own row is at
    /// `currentIndex` and is simply not in the set of offsets this builds. Previously Clear removed
    /// both copies, lost the cursor, and advanced to a different song.
    func clearUserQueue() {
        guard !userQueuedTrackIds.isEmpty else { return }
        let start = currentIndex + 1
        guard start < queue.count else { return }
        let offsets = IndexSet(
            queue[start...]
                .enumerated()
                .filter { userQueuedTrackIds.contains($0.element.id) }
                .map(\.offset)
        )
        guard !offsets.isEmpty else { return }
        removeUpNextItems(at: offsets)
    }

    /// Removes **every** copy of the given ids, the playing one included, advancing if the active
    /// track was among them.
    ///
    /// That is correct for its one caller — `AppModel.deleteTrackFromLibrary`, where the file is
    /// gone from the server and no copy may keep playing — and wrong for anything driven by a queue
    /// row, which means one row and must not touch the cursor. Queue rows call
    /// ``removeUpNextItems(at:)`` instead. Do not point a row action back at this.
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

    /// Applies new equalizer settings to audio that is already playing.
    ///
    /// **Nothing reloads any more.** Every item carries a tap from the moment it is created, so a
    /// settings change is a coefficient update published to the live taps — the playhead does not
    /// move, no buffer is re-fetched, and there is no audible seam.
    ///
    /// This function used to be the opposite: with the EQ off, turning it on tore the player down
    /// and rebuilt it at the current position, because the equalizer lived in a second transport
    /// that the track had to be moved onto. That teardown is why toggling the EQ mid-song was
    /// audible, and it is gone.
    ///
    /// Kept under its old name so callers do not change; it is no longer a reload of anything.
    func reloadForEqualizerSettingsChange() async {
        EqualizerTapRegistry.shared.updateAllTaps(
            gains: equalizerBandGains,
            bypassed: effectiveEqualizerBypass || !equalizerEnabled,
        )
    }

    /// After a same-track reload (EQ on/off), the requested `startSeconds` can
    /// disagree with where audio actually started. Snap the scrubber / lock-screen
    /// elapsed time to the live playhead so the bar does not keep running from
    /// the old position.
    private func syncProgressToActualPlaybackHead() {
        let actual: TimeInterval
        if let player {
            let t = player.currentTime().seconds
            actual = t.isFinite ? max(0, t) : 0
        } else {
            actual = 0
        }
        playbackHead = actual
        currentTime = actual
        lastEmittedUIProgress = actual > 0.05 ? actual : -10_000
        lastNowPlayingInfoRefresh = -10_000
        refreshNowPlaying()
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
        guard let player else { return }
        // `performSeek` parks the player for the duration of a seek, so `player.rate` reads 0
        // mid-scrub even though the button is drawn as "pause" and the user is trying to stop.
        // Branching on rate alone sent that tap into the resume branch and started audio — the
        // opposite of what was pressed. Inside the seek window, intent decides.
        if player.rate > 0.01 || (isSeeking && isPlaying) {
            player.pause()
            isPlaying = false
            seekResumeIntent = false
            scheduleAudioSessionDeactivation()
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
            markPlayIntent()
            beginPlayback(on: player)
            ensurePlaybackStarted(on: player, epoch: playbackEpoch)
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
        markPlayIntent()
        if player == nil {
            guard queue.indices.contains(currentIndex) else { return }
            shouldAutoPlayAfterAdvance = true
            scheduleAdvance()
            return
        }
        guard let player else { return }
        if player.rate < 0.01 {
            if let item = player.currentItem {
                let cur = item.currentTime().seconds
                let dur = item.duration.seconds
                if dur.isFinite, dur > 0, cur >= dur - 0.25 {
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            beginPlayback(on: player)
            ensurePlaybackStarted(on: player, epoch: playbackEpoch)
        }
        isPlaying = true
        playbackHead = player.currentTime().seconds
        currentTime = playbackHead
        revealMiniPlayerChrome()
        refreshNowPlaying()
    }

    private func pausePlaybackFromRemoteCommand() {
        pausePlayback()
    }

    func pausePlayback() {
        clearPlayIntent()
        // An in-flight seek must not resume playback the user has just stopped.
        seekResumeIntent = false
        guard let player else {
            isPlaying = false
            refreshNowPlaying()
            return
        }
        if player.rate > 0.01 {
            player.pause()
        }
        isPlaying = false
        PlaybackCPUSampler.playbackDidStop()
        playbackHead = player.currentTime().seconds
        refreshNowPlaying()
        scheduleAudioSessionDeactivation()
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
            // An offline track whose duration never resolved still has a staged restore position
            // worth moving. Without this the seek is the same silent no-op, just with no duration
            // to clamp against.
            if hasPendingRestore { stagePendingRestore(at: max(0, targetSeconds)) }
            completion?()
            return
        }
        // Never land on the exact end — that fires AVPlayerItemDidPlayToEndTime
        // and advances the queue (same guard skipForward uses).
        let clamped = max(0, min(targetSeconds, max(0, d - 1.0)))
        // Whether a seek was ALREADY in flight, read before this one marks itself as one.
        let seekAlreadyInFlight = isSeeking

        // A whole second seek implementation used to sit here, for the EQ engine, and it worked by
        // **reloading the audio file at the new position** — an 18-second-timeout stream load in
        // the worst case, for a scrub. All of the machinery around it (a burst-intent rule for
        // overlapping seeks, a pause that could not reach a node mid-reload, a generation guard to
        // stop a superseded reload resuming audio) existed only to manage that reload.
        //
        // A tap does not care where the playhead is. Seeking is now just `AVPlayer` seeking,
        // below, with the tap continuing to filter whatever comes out — so this path is not
        // simplified, it is deleted.

        // Cold-launch restore: the queue and position are staged but no player exists yet, so every
        // seek entry point — the scrubber, ±15s, Previous (which routes to seek(toSeconds: 0)),
        // and the lock-screen scrubber — fell through the `guard let player` below and silently did
        // nothing until the user pressed Play. Move the staged position instead, which is what
        // `togglePlayPause` and the remote resume command already do on their own paths.
        if hasPendingRestore {
            stagePendingRestore(at: clamped)
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

        // Overlapping seeks cannot each sample this for themselves. The first one calls
        // `player.pause()` below, whose KVO clears `isPlaying`, so a second seek arriving a moment
        // later reads "paused" and leaves the music stopped — measured, not theorised: sampling
        // `isPlaying` per task silenced playback after every rapid double-scrub. The first seek of
        // a burst records the intent, later seeks inherit it, and an explicit pause clears it so a
        // pause issued mid-seek still wins.
        let wantsPlayback = seekAlreadyInFlight ? seekResumeIntent : (isPlaying || player.rate > 0.01)
        seekResumeIntent = wantsPlayback
        player.pause()

        var ok = await awaitPlayerSeek(player, to: clamped)
        // AVPlayer resumes a pending seek's continuation with `finished == false` the instant a
        // newer seek is issued. Retrying here dragged the player back to THIS task's stale target
        // and interrupted the newer one, so bail *before* the retry rather than two side effects
        // after it. Returning without `completion` is deliberate: running it from a superseded
        // task cleared the scrubber's `isScrubbing` before the real seek landed.
        guard generation == seekGeneration else { return }
        if !ok || !seekPositionMatches(player.currentTime().seconds, target: clamped) {
            ok = await awaitPlayerSeek(player, to: clamped, tolerance: 0.05)
        }
        guard generation == seekGeneration else { return }

        // Re-read the intent after the awaits — not the snapshot taken before them. A pause issued
        // while the seek was in flight clears `seekResumeIntent`, so it wins. Previously this
        // resumed unconditionally, which is what silently undid the pause and restarted audio at
        // the new position.
        if seekResumeIntent {
            beginPlayback(on: player)
            isPlaying = true
        } else if player.rate > 0.01 {
            player.pause()
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
        guard currentIndex + 1 < queue.count else {
            guard repeatMode == .all, !queue.isEmpty else { return }
            let outgoing = queue[currentIndex]
            onTrackSkipped?(outgoing, playbackSource)
            captureAutoPlayIntentForAdvance()
            currentIndex = 0
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
            return
        }
        let outgoing = queue[currentIndex]
        onTrackSkipped?(outgoing, playbackSource)
        captureAutoPlayIntentForAdvance()
        currentIndex += 1
        resetUIProgressForTrackHandoff()
        scheduleAdvance()
    }

    func skipPrevious() {
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

    /// Keeps the remote controls honest about what they will actually do.
    ///
    /// Enablement used to be written once — `updateRemoteCommands()` set next/previous to `true`
    /// unconditionally and only ever ran on a settings change, and
    /// `changePlaybackPositionCommand` was enabled once for the life of the process. So the lock
    /// screen and CarPlay drew a lit Next button on the last track of a queue that did nothing when
    /// pressed, and offered a scrubber on live radio where the seek is always discarded.
    ///
    /// Called from `refreshNowPlaying()`, which already runs on every meaningful transport change,
    /// and cached so the common case is two comparisons.
    ///
    /// `previousTrackCommand` is deliberately left alone: at the start of a queue it seeks to 0,
    /// which is the standard restart-the-track behaviour and a real, visible response — not a
    /// silent no-op.
    private func refreshRemoteCommandAvailability() {
        guard didConfigureRemoteCommands else { return }
        let center = MPRemoteCommandCenter.shared()

        let canSkipNext = currentIndex + 1 < queue.count || (repeatMode == .all && !queue.isEmpty)
        let nextEnabled = remoteControlMode == .skipTrack && canSkipNext
        if lastRemoteNextEnabled != nextEnabled {
            lastRemoteNextEnabled = nextEnabled
            center.nextTrackCommand.isEnabled = nextEnabled
        }

        // A live stream has no finite duration, so `performSeek`'s `d > 0` guard drops every
        // position change. The app already knows this — it greys out its own scrubber — but the
        // flag never reached the command center.
        let canSeek = activeTrack?.isInternetRadioStream != true
        if lastRemoteSeekEnabled != canSeek {
            lastRemoteSeekEnabled = canSeek
            center.changePlaybackPositionCommand.isEnabled = canSeek
        }
    }

    private var lastRemoteNextEnabled: Bool?
    private var lastRemoteSeekEnabled: Bool?

    /// What playback should be doing once the current burst of seeks settles.
    ///
    /// Set by the first seek of a burst and inherited by any that overlap it, because a seek calls
    /// `player.pause()` and the resulting KVO clears `isPlaying` — so a second seek sampling for
    /// itself would read "paused" and leave the music stopped. Cleared by every explicit pause, so
    /// a pause issued while a seek is in flight is honoured rather than undone when it completes.
    private var seekResumeIntent = false

    func updateRemoteCommands() {
        configureRemoteCommandsIfNeeded()
        let center = MPRemoteCommandCenter.shared()
        // This function writes `isEnabled` directly below, so the cache must not shadow it.
        lastRemoteNextEnabled = nil
        lastRemoteSeekEnabled = nil
        defer { refreshRemoteCommandAvailability() }

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
                DispatchQueue.main.async { self?.skipNext() }
                return .success
            }
            previousTrackRemoteTarget = center.previousTrackCommand.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.skipPrevious() }
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
                DispatchQueue.main.async { self.skipForward(by: step) }
                return .success
            }
            skipBackwardRemoteTarget = center.skipBackwardCommand.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                let step = (event as? MPSkipIntervalCommandEvent)?.interval ?? self.skipBackwardInterval
                DispatchQueue.main.async { self.skipBackward(by: step) }
                return .success
            }
        }
    }

    /// Tracks the user explicitly queued (Play Next / Add to Queue) that have not played
    /// yet. Starting a new source discards exactly these, so it drives the confirmation
    /// prompt. Counts the up-next slice rather than the whole set: ids linger in
    /// `userQueuedTrackIds` for tracks already behind the cursor.
    var pendingUserQueuedCount: Int {
        guard !userQueuedTrackIds.isEmpty, currentIndex + 1 < queue.count else { return 0 }
        return queue[(currentIndex + 1)...].filter { userQueuedTrackIds.contains($0.id) }.count
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
        // Ignore tracks that Play Next pulled out of the natural tail into the user queue.
        // Relocating a track is not a manual reorder and must not light the shuffle button.
        let expectedTail = source[(sourceIdx + 1)...].filter { !userQueuedTrackIds.contains($0.id) }
        guard continuePlaying.count == expectedTail.count else { return true }
        return zip(continuePlaying, expectedTail).contains { $0.id != $1.id }
    }

    func toggleShuffle() {
        // Branch on the same property the button lights from. Branching on `shuffleMode`
        // while the button read `isQueueOutOfNaturalOrder` inverted the affordance: a lit
        // button would re-randomize instead of restoring natural order.
        if isQueueOutOfNaturalOrder {
            restoreNaturalQueueOrder()
        } else {
            shuffleQueueFromCurrentTrack()
        }
        refreshEnqueuedNextItem()
    }

    /// Turning shuffle ON: snapshot the current order and randomize everything after the
    /// playing track.
    private func shuffleQueueFromCurrentTrack() {
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
    }

    /// Turning shuffle OFF (or undoing a manual reorder): rebuild the natural order while
    /// preserving everything the user explicitly queued.
    private func restoreNaturalQueueOrder() {
        defer {
            shuffleMode = .off
            pruneUserQueuedIds()
        }
        // Play Next / Add to Queue items added *after* shuffle was turned on are absent
        // from `unshuffledQueue`, so restoring that snapshot verbatim silently deleted
        // them. Carry the whole up-next user block across in its current order.
        let upNextStart = min(currentIndex + 1, queue.count)
        let carried = Array(queue[upNextStart...]).filter { userQueuedTrackIds.contains($0.id) }
        let carriedIds = Set(carried.map(\.id))

        if let original = unshuffledQueue {
            unshuffledQueue = nil
            if let current = activeTrack,
               let originalIndex = original.firstIndex(where: { $0.id == current.id }) {
                let head = Array(original[...originalIndex])
                let tail = original[(originalIndex + 1)...].filter { !carriedIds.contains($0.id) }
                queue = head + carried + tail
                currentIndex = originalIndex
            } else if let current = activeTrack {
                // The playing track was itself queued while shuffle was on, so it isn't in
                // the snapshot. Keep it under the cursor rather than leaving `currentIndex`
                // pointing into a different array while audio keeps playing.
                let tail = original.filter { !carriedIds.contains($0.id) && $0.id != current.id }
                queue = [current] + carried + tail
                currentIndex = 0
            } else {
                queue = original
                currentIndex = min(max(0, currentIndex), max(original.count - 1, 0))
            }
            return
        }

        guard let source = sourceQueueOrder,
              let current = activeTrack,
              let sourceIdx = source.firstIndex(where: { $0.id == current.id })
        else { return }
        // Manually reordered without using the shuffle button — restore the natural tail,
        // keeping user-queued tracks at the front of up-next.
        let naturalTail = source[(sourceIdx + 1)...].filter { !carriedIds.contains($0.id) }
        queue = Array(queue[...currentIndex]) + carried + naturalTail
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
        nowPlayingFormatLabel = nil
        spuriousEndRecoveryAttempted = false
    }

    private func cancelPendingAdvanceWork() {
        advanceWork?.cancel()
        advanceWork = nil
        autoplayVerifyTask?.cancel()
        autoplayVerifyTask = nil
    }

    /// The one place a playback failure is handled.
    ///
    /// Five separate paths used to discard their failures — the config-change rebuild and
    /// `scheduleAdvance` (both `try?`), every `play(rate:)` call site that ignored the returned
    /// `Bool`, and the gapless promote, which never inspected the item's status at all. Each left
    /// `isPlaying == true` with no audio, which is exactly what the listener saw: a pause glyph
    /// over silence, a lock screen still reporting rate 1.0, and no way out but a force-quit.
    ///
    /// Correcting the transport is the first job; telling the user is the second. `refreshNowPlaying()`
    /// is what drops the reported rate to 0.
    ///
    /// **Deliberately does not retry and does not auto-skip.** Whether a dead track should be
    /// skipped past — and after how many attempts — is a product decision, not part of fixing a
    /// swallowed error, so this stops honestly rather than inventing a policy.
    private func reportPlaybackFailure(_ error: Error?, track: Track?, context: String) {
        isPlaying = false
        shouldAutoPlayAfterAdvance = false
        setBuffering(false)
        refreshNowPlaying()
        // One real failure can arrive here twice — `play(rate:)` returns false *and* notifies the
        // session's `onPlaybackFailed`. Correct the transport every time; tell the user once.
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPlaybackFailureReportedAt > 2 else { return }
        lastPlaybackFailureReportedAt = now
        onPlaybackFailure?(track ?? activeTrack, error)
    }

    private var lastPlaybackFailureReportedAt: TimeInterval = -1_000

    // `startEqualizedPlayback` was the guard that stopped the audio-engine transport lying about
    // whether it had actually started. With one transport there is nothing to reconcile:
    // `AVPlayer` reports its own state through `timeControlStatus`, which is observed.

    private func scheduleAdvance() {
        advanceWork?.cancel()
        advanceWork = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.advance()
            } catch {
                // A superseded skip cancels this task on purpose — that is not a failure and must
                // not raise a toast. Only a genuine load failure reaches the user.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.reportPlaybackFailure(error, track: self.currentTrack, context: "advance")
            }
        }
    }

    private func advance() async throws {
        // A skip/jump abandons the saved playhead for the previously-active track.
        pendingRestoreSeconds = 0
        // Capture before teardown — new AVPlayer starts `.paused` and KVO must not clear intent.
        let shouldAutoPlay = shouldAutoPlayAfterAdvance || isPlaying || (player?.rate ?? 0) > 0.01
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
            markPlayIntent()
            if let player {
                beginPlayback(on: player)
                ensurePlaybackStarted(on: player, epoch: epoch)
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
        let token = UUID()
        autoplayVerifyToken = token
        autoplayVerifyTask = Task { @MainActor [weak self] in
            // Clear our own handle when the verify window ends (any exit path) so the
            // timeControlStatus KVO stops ignoring genuine external pauses (headphone
            // unplug, Control Center). The token guard stops a cancelled/older task
            // from nil-ing a newer one's handle.
            defer { if let self, self.autoplayVerifyToken == token { self.autoplayVerifyTask = nil } }
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
        markPlayIntent()
        activateAudioSession()
        player.playImmediately(atRate: playbackRate)
        PlaybackCPUSampler.playbackDidStart()
        refreshNowPlaying()
    }

    private func markPlayIntent() {
        playIntentUntil = ContinuousClock.now + .milliseconds(1800)
    }

    private func clearPlayIntent() {
        playIntentUntil = nil
    }

    private var shouldIgnoreTransientPausedObservation: Bool {
        guard let until = playIntentUntil else { return false }
        if ContinuousClock.now < until { return true }
        playIntentUntil = nil
        return false
    }

    private func handleTimeControlStatusChange(player: AVPlayer) {
        let status = player.timeControlStatus
        if status == .paused, isPlaying, !isAdvancingToNextItem {
            // Startup/handoff can report `.paused` briefly before `playImmediately` sticks.
            if autoplayVerifyTask != nil { return }
            if shouldIgnoreTransientPausedObservation { return }
            isPlaying = false
            refreshNowPlaying()
        } else if status == .playing, !isPlaying {
            isPlaying = true
            refreshNowPlaying()
        }
        // `.waitingToPlayAtSpecifiedRate` = buffering — the user still
        // intends to play, so keep ``isPlaying`` but surface the stall
        // through ``isBuffering`` and arm the stall watchdog.
        if status == .waitingToPlayAtSpecifiedRate {
            setBuffering(player.reasonForWaitingToPlay != .noItemToPlay, debounced: true)
            scheduleStallRecoveryIfNeeded()
        } else {
            cancelStallRecovery()
            setBuffering(false)
        }
    }

    private func applyPlaybackRateToPlayer() {
        if let player, isPlaying {
            player.rate = playbackRate
        }
        refreshNowPlaying()
    }

    private var effectiveEqualizerBypass: Bool { equalizerBypass || !equalizerEnabled }

    /// Live gain changes, e.g. dragging a slider in the equalizer UI.
    ///
    /// Goes to every live tap — the playing item and any gapless next one — so a curve set now is
    /// already in place when the next track begins, rather than arriving a track late.
    func applyLiveEqualizerGains() {
        EqualizerTapRegistry.shared.updateAllTaps(
            gains: equalizerBandGains,
            bypassed: effectiveEqualizerBypass,
        )
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
        // Taps are retired with their items, so the render-thread state they own is freed rather
        // than kept alive for a future reuse. There is no session to park: the tap dies with the
        // `AVPlayerItem` it was attached to.
        retireAllTaps()
    }

    /// Releases every tap this engine is holding. Safe to call more than once.
    private func retireAllTaps() {
        for tag in liveTapTags { EqualizerTapRegistry.shared.retire(itemTag: tag) }
        liveTapTags.removeAll()
        EqualizerTapRegistry.shared.setCurrentItem(tag: 0, title: "")
    }

    /// Item tags for taps created by this engine, so they can be retired on teardown.
    private var liveTapTags: [UInt64] = []

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
                if seen.insert(idx).inserted, !isExcludedFromAutoAdvance(idx) { result.append(idx) }
                step += 1
            }
            return result
        case .off:
            var result: [Int] = []
            var idx = currentIndex + 1
            while idx < queue.count, result.count < limit {
                if !isExcludedFromAutoAdvance(idx) { result.append(idx) }
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
        scheduleLyricsLoadIfNeeded(for: activeTrack)

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
                if isUnreadableStreamCacheError(error) {
                    evictFailedStreamCacheCandidate(candidate.url)
                }
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
        // One path. There is no "is this file EQ-eligible, and can the other transport decode it"
        // fork any more — every item gets a tap and the equalizer is either curved or flat.
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
        allowEqualizerHandoff: Bool = true,
    ) async throws -> Bool {
        guard isPlaybackEpochCurrent(epoch) else { return false }
        let asset = makePlaybackAsset(url: candidate.url, headers: candidate.headers)
        if candidate.url.isFileURL,
           !isCommittedStreamCacheFile(candidate.url),
           let urlAsset = asset as? AVURLAsset {
            _ = try? await urlAsset.load(.isPlayable, .duration)
        }
        var resolvedDuration = track.duration
        if resolvedDuration <= 0, candidate.url.isFileURL {
            resolvedDuration = await LocalMediaDuration.seconds(at: candidate.url)
        }
        // The tap is attached here, **before** the item reaches the player. `TapPlayerItem` awaits
        // the asset's tracks first, because an audio mix built against tracks that have not loaded
        // is silently ignored — the item plays with no tap and nothing reports an error.
        let (item, tap) = await TapPlayerItem.make(
            asset: asset,
            track: track,
            gains: equalizerBandGains,
            bypassed: effectiveEqualizerBypass,
            eligibleForEqualizer: isEqualizerEligible(for: track),
        )
        if let tap {
            liveTapTags.append(tap.itemTag)
            EqualizerTapRegistry.shared.setCurrentItem(tag: tap.itemTag, title: track.title)
            PlaybackCPUSampler.currentItemProvider = { (tag: tap.itemTag, title: track.title) }
        }
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
            let ok = await awaitPlayerSeek(p, to: startSeconds)
            let playerTime = p.currentTime().seconds
            let actual = ok && playerTime.isFinite && playerTime > 0.05
                ? playerTime
                : (playerTime.isFinite ? max(0, playerTime) : 0)
            currentTime = actual
            playbackHead = actual
            lastEmittedUIProgress = actual > 0.05 ? actual : -10_000
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
        // Nothing is scheduled here any more. A streamed track used to kick off a background
        // download so the equalizer could take over once a local file existed; the tap needs no
        // local file, so the EQ is in the audio from the first buffer and there is nothing to wait
        // for.
        return true
    }

    // `loadEqualizedPlayerItem` used to sit here: a parallel item-loading path that built an
    // `AVAudioEngine` session, wired up its own time observer, end-of-track callback, failure
    // callback and configuration-change rebuild, and then became the transport for that track.
    // Every one of those callbacks existed because the second transport had none of the machinery
    // `AVPlayer` already provides.
    //
    // Deleted with the transport. There is one loading path now — `loadAVPlayerItem` — and the
    // equalizer is a tap on the item it produces.

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
              url.path.contains("/VellumMusic/stream-cache/")
        else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func evictFailedStreamCacheCandidate(_ url: URL) {
        guard isCommittedStreamCacheFile(url) else { return }
        StreamingMediaDiskCache.shared.evict(fileURL: url)
    }

    /// Timeouts and stalls are not proof the file is bad — only decode/parse
    /// failures are. Evicting on timeout deleted valid cache entries.
    private func isUnreadableStreamCacheError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain { return true }
        if ns.domain == AVFoundationErrorDomain { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse:
            return true
        default:
            return false
        }
    }

    private func stagePendingRestore(at seconds: TimeInterval) {
        let resumeAt = max(0, seconds)
        pendingRestoreSeconds = resumeAt
        playbackHead = resumeAt
        currentTime = resumeAt
        lastEmittedUIProgress = resumeAt > 0.05 ? resumeAt : -10_000
        isPlaying = false
        setBuffering(false)
        refreshNowPlaying()
    }

    // MARK: - The mid-track EQ handoff, and why it is gone
    //
    // Four functions used to live here and they were the bug:
    //
    //   `scheduleEqualizerHandoffWhenCached` — start a background download of the stream so the
    //   equalizer could eventually have a local file to work from.
    //   `swapActiveItemToEqualizerIfNeeded` — once it arrived, tear `AVPlayer` down mid-song and
    //   rebuild the track on the audio-engine transport at the same position.
    //   `restorePlaybackAfterFailedEqualizerHandoff` — put the user back on `AVPlayer` when that
    //   failed, because the swap had already detached the thing making sound.
    //   `rebuildEqualizedSessionAfterConfigChange` — redo the whole thing after a route change.
    //
    // The consequence was that on a streamed track the equalizer was **not in the audio at all**
    // until the download completed and the swap landed, and the swap itself was audible. None of
    // it is needed once the equalizer is a tap on the item: the tap is attached before the item is
    // inserted, so it is in the audio from the first buffer, and there is nothing to hand over to.
    //
    // Deliberately not replaced with anything. The absence is the fix.

    // `periodicEqualizedTimeObserverTick` was here too — a hand-rolled duplicate of the
    // `AVPlayer` periodic time observer, needed only because the audio-engine transport had no
    // `timeControlStatus` and no time observer of its own. One transport, one observer.

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
            guard let self else { return }
            let apply = {
                MainActor.assumeIsolated {
                    self.handleTimeControlStatusChange(player: player)
                }
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
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
    /// Foreground cadence (0.35s) drives the smooth scrubber; backgrounded we
    /// widen to 2.0s (~6x fewer main-thread wakeups) since nothing on screen
    /// needs per-tick updates and the lock screen extrapolates the playhead
    /// from the Now-Playing rate.
    private func periodicTimeObserverInterval() -> Double {
        #if os(iOS)
        return isAppBackgrounded ? 2.0 : 0.35
        #else
        return 0.35
        #endif
    }

    private func installPeriodicTimeObserver() {
        guard let ctx = timeObserverContext else { return }
        let p = ctx.player
        if let obs = timeObserver { p.removeTimeObserver(obs); timeObserver = nil }
        let interval = CMTime(seconds: periodicTimeObserverInterval(), preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.periodicTimeObserverTick(
                    elapsed: time.seconds,
                    item: ctx.item,
                    track: ctx.track,
                    player: p,
                )
            }
        }
    }

    private func bindItemObservers(item: AVPlayerItem, track: Track, player p: AVPlayer) {
        timeObserverContext = (item, track, p)
        installPeriodicTimeObserver()

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

    /// One-shot guard so a track with bad duration metadata can't loop forever
    /// through spurious-end recovery. Reset on every track handoff.
    private var spuriousEndRecoveryAttempted = false

    private func handleEnded(endedItem: AVPlayerItem? = nil) {
        let endedAtLog = endedItem?.currentTime().seconds ?? -1
        let itemDurLog = endedItem?.duration.seconds ?? -1
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

        // Natural end-of-track (past spurious-end recovery). Notify BEFORE the advance
        // moves currentIndex — Kill Mode marks the just-finished track "kept (green)".
        if queue.indices.contains(currentIndex) {
            onTrackCompleted?(queue[currentIndex], playbackSource)
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
            promoteToEnqueuedNext(item: nextItem, index: nextIndex, track: queue[nextIndex])
            return
        }

        // Slow path: nothing usable pre-enqueued (repeat-one, end of queue, queue
        // edited, or enqueue failed) — rebuild as before.
        // Shuffle is a queue-reordering action (see ``toggleShuffle``) — once shuffled,
        // advance through the queue sequentially, otherwise every track end would re-randomize.
        if repeatMode == .one {
            shouldAutoPlayAfterAdvance = true
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
        } else if let next = nextAdvanceIndex() {
            shouldAutoPlayAfterAdvance = true
            currentIndex = next
            resetUIProgressForTrackHandoff()
            scheduleAdvance()
        } else {
            isPlaying = false
            // No next track: end of a repeat-off queue, or (Kill Mode) every other
            // track has already been listened to and is excluded. AVQueuePlayer
            // advanced past the final item, so `currentItem` is nil and the
            // single-player "seek to 0 and replay" path can't work. Drop to a clean
            // pending-restore so a later play tap rebuilds from the start.
            teardownPlayer()
            refreshNowPlaying()
        }
    }

    /// Index the natural-end advance should move to, honoring repeat mode and the
    /// Kill Mode auto-advance exclusion. Returns nil when nothing qualifies (end of a
    /// repeat-off queue, or every candidate excluded). `.all` may return the current
    /// index as a last resort so a single-track repeat-all still loops.
    private func nextAdvanceIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return currentIndex
        case .all:
            var step = 1
            while step <= queue.count {
                let idx = (currentIndex + step) % queue.count
                if !isExcludedFromAutoAdvance(idx) { return idx }
                step += 1
            }
            return nil
        case .off:
            var idx = currentIndex + 1
            while idx < queue.count {
                if !isExcludedFromAutoAdvance(idx) { return idx }
                idx += 1
            }
            return nil
        }
    }

    private func isExcludedFromAutoAdvance(_ index: Int) -> Bool {
        guard let exclude = autoAdvanceExclusion, queue.indices.contains(index) else { return false }
        return exclude(queue[index])
    }

    /// Adopt the just-auto-advanced item as the current track without tearing the
    /// player down. The audio is already playing the new item; this only updates
    /// bookkeeping, rebinds the per-item observers, and stages the following track.
    private func promoteToEnqueuedNext(item: AVPlayerItem, index: Int, track: Track) {
        enqueuedNextItem = nil
        enqueuedNextIndex = nil
        enqueuedNextTrack = nil

        // The OS advanced onto an item that was staged while the previous track played. If its URL
        // went bad in the meantime (token expired, server restarted, track removed) this used to
        // adopt it anyway — announcing the title, firing `onTrackStarted`, setting `isPlaying`
        // true — with no audio behind any of it. Nothing corrected it afterwards: the one KVO that
        // would is edge-triggered and gets swallowed by the autoplay-verify short-circuit, and the
        // stall watchdog only fires for `.waitingToPlayAtSpecifiedRate`, which a failed item never
        // reports. This path deliberately bypasses the candidate-fallback machinery in
        // `startCurrentItem`, so the status has to be checked right here.
        if item.status == .failed {
            // The OS has already moved onto this item, so the cursor has to follow it or the app
            // reports the previous track as current. Reset the progress readout too, otherwise the
            // outgoing track's position sits under the new title.
            currentIndex = index
            resetUIProgressForTrackHandoff()
            reportPlaybackFailure(item.error, track: track, context: "gapless advance")
            return
        }

        // The OS has moved onto the staged item, so the tap that has been sitting on it since it
        // was staged is now the one in the audio. Tell the registry, so the EQ-activity stream
        // reports the right item from the boundary onwards rather than a track late.
        if let tag = EqualizerTapRegistry.shared.itemTag(forTrackId: track.id) {
            EqualizerTapRegistry.shared.setCurrentItem(tag: tag, title: track.title)
            PlaybackCPUSampler.currentItemProvider = { (tag: tag, title: track.title) }
        }

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

        markPlayIntent()
        if let p = player, p.rate < 0.01 {
            beginPlayback(on: p)
            ensurePlaybackStarted(on: p, epoch: epoch)
            isPlaying = true
        } else {
            isPlaying = (player?.rate ?? 0) > 0.01
        }
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

        let asset: AVURLAsset
        if let saved = offline?.localFile(for: track.id) {
            asset = AVURLAsset(url: saved, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else if let candidate = primaryRemoteCandidate(for: track) {
            asset = candidate.headers.isEmpty
                ? AVURLAsset(url: candidate.url)
                : AVURLAsset(url: candidate.url, options: ["AVURLAssetHTTPHeaderFieldsKey": candidate.headers])
        } else {
            return
        }

        // Attaching the tap needs the asset's tracks loaded, which is asynchronous, and this
        // function has ten synchronous callers. So the staging finishes on a task, guarded by a
        // generation counter: if anything re-stages in the meantime — a skip, a queue edit — the
        // superseded task discards its item instead of inserting a second one.
        //
        // Being asynchronous is not a compromise here. Staging deliberately happens *early*, long
        // before the boundary, which is the whole reason the next item's tap can be prepared in
        // time. Tests 2 and 3 measure exactly that: the next tap's `prepare` must appear in the log
        // before the current item's last `process`.
        stagingGeneration &+= 1
        let generation = stagingGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (item, tap) = await TapPlayerItem.make(
                asset: asset,
                track: track,
                gains: self.equalizerBandGains,
                bypassed: self.effectiveEqualizerBypass,
                eligibleForEqualizer: self.isEqualizerEligible(for: track),
            )
            guard self.stagingGeneration == generation,
                  let qp = self.queuePlayer,
                  self.queue.indices.contains(nextIndex),
                  self.queue[nextIndex].id == track.id,
                  qp.canInsert(item, after: nil)
            else {
                if let tap { EqualizerTapRegistry.shared.retire(itemTag: tap.itemTag) }
                return
            }
            if let tap {
                self.liveTapTags.append(tap.itemTag)
                PlaybackTapLog.tap(
                    "staged-next item=\(tap.itemTag) track=\(track.id) title=\"\(track.title)\" "
                        + "queueIndex=\(nextIndex)"
                )
            }
            qp.insert(item, after: nil)
            self.enqueuedNextItem = item
            self.enqueuedNextIndex = nextIndex
            self.enqueuedNextTrack = track
        }
    }

    /// Bumped every time the next item is re-staged, so a superseded staging task does not insert.
    private var stagingGeneration: UInt64 = 0

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
        lyricsTrackId = currentTrack?.id
        Task { [weak self] in try? await self?.loadLyrics() }
    }

    /// Lyrics for a track start that no other path has claimed.
    ///
    /// ``playAlbum`` / ``advance`` schedule the load themselves, before the (slow) item
    /// start, so the previous track's lines leave the screen immediately — this then finds
    /// the id already claimed and does nothing. What it catches is every *other* way a track
    /// can start: the first play after a cold restore (``startFromPendingRestore``, which was
    /// the one path that reached playback with no lyrics load anywhere behind it), and a
    /// reload that changed the track id under us (stale-id recovery). A same-track reload —
    /// EQ toggle, stall recovery, spurious end — keeps what is already on screen.
    private func scheduleLyricsLoadIfNeeded(for track: Track) {
        guard lyricsTrackId != track.id else { return }
        scheduleLyricsLoad()
    }

    private func loadLyrics() async throws {
        guard let library, let track = currentTrack, !track.isInternetRadioStream else {
#if DEBUG
            DebugUIRemote.log("NP-LYRICS skip library=\(self.library != nil) track=\(currentTrack?.id ?? "nil")")
#endif
            lyrics = []
            lyricsTrackId = nil
            return
        }
        let trackId = track.id
        let fetched = (try? await library.lyrics(for: track)) ?? []
#if DEBUG
        DebugUIRemote.log(
            "NP-LYRICS fetched=\(fetched.count) id=\(trackId) current=\(currentTrack?.id ?? "nil")"
        )
#endif
        // Keyed on the track alone, not the playback epoch. Lyrics depend on nothing else, so
        // a result that arrives after a same-track reload (EQ handoff, stall recovery — each
        // begins a new epoch) is still the right text; dropping it left the song playing with
        // an empty lyrics tab until the next track.
        guard currentTrack?.id == trackId else { return }
        lyrics = fetched
        lyricsTrackId = trackId
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
        // Enablement has to track the queue, not just settings changes — this is the only hook that
        // already runs on every track change, queue edit and transport update.
        refreshRemoteCommandAvailability()
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
            // Queue position so CarPlay / car head units show "N/M" instead of "1/1".
            // The underlying AVQueuePlayer is fed one item at a time, so the system
            // can't derive this — we report the engine's own queue cursor. In shuffle
            // the queue array is already shuffled, so currentIndex is the shown spot.
            if queue.indices.contains(currentIndex) {
                now[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
                now[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
            } else {
                now.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueIndex)
                now.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackQueueCount)
            }
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
            DispatchQueue.main.async { self?.resumePlaybackFromRemoteCommand() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pausePlaybackFromRemoteCommand() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                positionEvent.positionTime.isFinite
            else { return .commandFailed }
            DispatchQueue.main.async { self.seek(toSeconds: positionEvent.positionTime) }
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
