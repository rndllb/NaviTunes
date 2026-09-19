import Combine
import Network
import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
import WidgetKit
#endif

public enum BackendKind: String, CaseIterable, Identifiable {
    case jellyfin
    case navidrome

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .navidrome: return "Navidrome"
        }
    }
}

enum ActiveServerURLRole: String, Equatable {
    case primary
    case secondary
}

enum NewTabBrowseBackend: Equatable {
    case none
    case server
    case lidarr
}

/// On-disk record of a recently-played item. Plays sourced from a playlist record the playlist;
/// everything else falls back to the track's album so the Home shelf still has something to show.
struct RecentPlayedEntry: Codable, Hashable {
    enum Kind: String, Codable { case album, playlist }
    let kind: Kind
    let id: String
}

/// UI-side resolved version of ``RecentPlayedEntry`` — the actual `AlbumSummary` or `PlaylistSummary`
/// pulled from the in-memory library catalog so the Home shelf can render the right tile.
enum RecentPlayedItem: Identifiable, Hashable {
    case album(AlbumSummary)
    case playlist(PlaylistSummary)

    var id: String {
        switch self {
        case .album(let a): return "album:\(a.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        }
    }
}

/// Payload for the app-wide transient toast. Plain confirmations carry just a
/// `title`; the add-to-playlist flow also sets `subtitle` (playlist name) and
/// `artworkURL` for the Apple-Music-style "1 song added" banner.
struct TransientToastContent: Equatable {
    var title: String
    var subtitle: String? = nil
    var artworkURL: URL? = nil
}

/// A tap-to-play request held back pending confirmation, because starting it would replace
/// a queue containing tracks the user hand-added via Play Next / Add to Queue.
/// Driven by ``AppModel/pendingQueueReplacement``; rendered by ``MusicQueueReplacementChrome``.
struct PendingQueueReplacement: Identifiable {
    let id = UUID()
    /// Unplayed user-queued tracks this request would discard — shown in the prompt.
    let queuedCount: Int
    let play: @MainActor @Sendable () async -> Void
}

/// Holds a UIKit background assertion for the life of a bulk operation.
///
/// Without one, iOS suspends the app a few seconds after it leaves the foreground, which
/// stops a long removal loop dead partway through — exactly the "it timed out because I
/// tabbed out" failure. The assertion buys the run the usual ~30 s of background execution,
/// which is far more than a batched purge needs. No-ops off iOS.
@MainActor
final class BulkOperationBackgroundAssertion {
#if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
#endif

    init(name: String) {
#if os(iOS)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Expiration can fire on any queue; hop back before touching UIApplication.
            Task { @MainActor [weak self] in self?.end() }
        }
#endif
    }

    /// Idempotent — safe to call from both the expiration handler and the caller's `defer`.
    func end() {
#if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
#endif
    }
}

@MainActor
public final class AppModel: ObservableObject {
    /// Weak reference set on init so AppIntents (e.g. PlayWidgetItemIntent) can reach the live model.
    public static weak var shared: AppModel?

    /// Default album fetch size for library grid / sync (raised for large Jellyfin / Navidrome libraries).
    public static let defaultLibraryAlbumFetchLimit = 500
    @Published var accentPresetId: String = UserDefaults.standard.string(forKey: AppAccentPreset.accentPresetIdKey) ?? AppAccentPreset.defaultId {
        didSet {
            // Accent color and app icon are independent — changing the accent must NOT change
            // the home-screen icon. The icon is controlled solely by `appIconPresetId`.
            UserDefaults.standard.set(accentPresetId, forKey: AppAccentPreset.accentPresetIdKey)
        }
    }

    @Published var customAccentHex: String = UserDefaults.standard.string(forKey: AppAccentPreset.customAccentHexKey) ?? AppAccentPreset.defaultCustomHex {
        didSet {
            let normalized = AppAccentPreset.normalizedHex(customAccentHex) ?? customAccentHex
            if normalized != customAccentHex {
                customAccentHex = normalized
                return
            }
            UserDefaults.standard.set(customAccentHex, forKey: AppAccentPreset.customAccentHexKey)
        }
    }

    /// Home-screen icon artwork — independent from ``accentPresetId`` (custom accents have no matching icon set).
    @Published var appIconPresetId: String = AppModel.loadAppIconPresetId() {
        didSet {
            let resolved = AppAccentPreset.validIconPresetId(appIconPresetId)
            if resolved != appIconPresetId {
                appIconPresetId = resolved
                return
            }
            UserDefaults.standard.set(appIconPresetId, forKey: AppAccentPreset.appIconPresetIdKey)
            syncHomeScreenIconIfNeeded()
        }
    }

    @Published var backendKind: BackendKind = .jellyfin
    @Published var baseURLString: String = ""
    @Published var secondaryURLString: String = ""
    @Published var serverFailoverMode: ServerFailoverMode = .disabled {
        didSet { UserDefaults.standard.set(serverFailoverMode.rawValue, forKey: Self.serverFailoverModeKey) }
    }
    /// Which configured server URL is currently wired into the active client.
    @Published var activeServerURLRole: ActiveServerURLRole = .primary
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var isSignedIn: Bool = false
    /// True while ``signIn()`` is in flight (manual or keychain restore).
    @Published var isAuthenticating: Bool = false
    @Published var selectedTab: AppTab = AppModel.loadLaunchTab().appTab
    /// Tab opened after launch / sign-in. Search is not offered.
    @Published var launchTabPreference: LaunchTabPreference = AppModel.loadLaunchTab() {
        didSet {
            UserDefaults.standard.set(launchTabPreference.rawValue, forKey: Self.launchTabPreferenceKey)
        }
    }
    /// "Go to Album / Playlist / Artist" deep link pushed onto the user's current tab after the
    /// Now Playing player dismisses. Set together with ``deepLinkTab`` so only the tab that was
    /// active at trigger time consumes the push (tab bar stays visible during the destination).
    @Published var presentedDeepLink: NowPlayingDeepLink? = nil
    @Published var deepLinkTab: AppTab? = nil
    /// Incremented to ask ``RootView`` to raise the full-screen Now Playing cover.
    ///
    /// A counter rather than a `Bool` because the request is an *event*: the cover's own
    /// presentation state lives in `RootView`, and the user can dismiss it without telling
    /// AppModel. A flag would have to be reset by whoever consumed it and would go stale the
    /// first time a second request arrived while the first was still true.
    ///
    /// Raised by the lock-screen / home-screen Now Playing widget (``handleWidgetDeepLink``),
    /// and by ``DebugUIRemote`` in DEBUG builds.
    @Published var openNowPlayingRequests = 0
#if DEBUG
    /// Incremented by ``DebugUIRemote`` to pop the active tab's stack — see that file.
    @Published var debugPopRequests = 0
#endif

    /// Scroll signal consumed by an already-visible ``ServerPlaylistDetailView`` so "Go to Playlist"
    /// scrolls to the now-playing track even when the user is already on that playlist.
    @Published var pendingPlaylistScroll: PendingPlaylistScroll? = nil

    /// Same as ``pendingPlaylistScroll`` but for album-mode detail views.
    @Published var pendingAlbumScroll: PendingAlbumScroll? = nil

    /// Set by ``ServerPlaylistDetailView`` while it's mounted so Now Playing → Go to Playlist
    /// can detect "destination already visible behind player" and skip a redundant push.
    /// Deliberately NOT `@Published`: no view renders from these — they're written on every
    /// detail push/pop, and publishing them invalidated every mounted view (including large
    /// tracklists in the nav stack) mid-transition.
    var currentlyVisiblePlaylistId: String? = nil
    /// Album equivalent of ``currentlyVisiblePlaylistId``.
    var currentlyVisibleAlbumId: String? = nil

    /// A tap-to-play request held back because starting it would discard tracks the user
    /// explicitly queued. Presented as a confirmation; cleared on either choice.
    @Published var pendingQueueReplacement: PendingQueueReplacement? = nil

    /// Brief bottom toast (e.g. "Added to Queue"). Auto-clears after ``showTransientToast``
    /// is called; the ``MusicTransientToastChrome`` view modifier renders it.
    @Published var transientToast: TransientToastContent? = nil
    private var transientToastTask: Task<Void, Never>? = nil

    @Published var errorMessage: String?
    @Published private(set) var hasInternetPath: Bool = true
    @Published private(set) var serverConnectionHealth: ServerConnectionHealth = .unknown

    /// True when the playback engine has at least one queued item (empty ↔ non-empty only).
    /// Used for swipe actions so Home/Library rows don't observe `player.queue` directly.
    @Published private(set) var hasActivePlaybackQueue = false
    /// Active queue item id; updates on track changes only (not every queue edit).
    @Published private(set) var nowPlayingTrackId: String?

    /// Shared catalog for Listen / Library / Search tabs.
    @Published private(set) var libraryAlbums: [AlbumSummary] = [] {
        didSet {
            rebuildLibraryAlbumIndex()
        }
    }
    @Published private(set) var recentlyAddedAlbums: [AlbumSummary] = []
    /// Backend-side play history (Jellyfin `DatePlayed`, Subsonic `getAlbumList2?type=recent`).
    /// Stored separately from the local list so the merged Home shelf can update live as either side changes.
    @Published private(set) var homeRecentlyPlayedServerAlbums: [AlbumSummary] = []
    @Published private(set) var homeGenreShelves: [(genre: String, albums: [AlbumSummary])] = []
    /// Sticky per-session pick of which genres get a shelf on Home — chosen from listening
    /// taste on the first successful ``refreshHome()`` of the session; subsequent refreshes
    /// reuse it so the layout doesn't reshuffle on every tab visit or pull-to-refresh.
    /// Cleared on sign-out and server-identity changes (alongside ``homeGenreShelves``).
    private var homeSelectedGenres: [LibraryGenreSummary]?
    private static let homeGenreShelfCount = 4
    private static let homeGenreShelfAlbumLimit = 9
    private static let homeTopPickCount = 8
    private static let homeNewReleaseCount = 20
    /// Taste-ranked server-catalog albums for Home → Top Picks (excludes personal library).
    @Published private(set) var homeTopPickAlbums: [AlbumSummary] = []
    /// Next taste-ranked server-catalog rows after Top Picks (same pool, excludes personal library).
    @Published private(set) var homeNewReleaseAlbums: [AlbumSummary] = []
    /// True while ``refreshHome()`` is running — drives skeleton shelves on the Home tab.
    @Published private(set) var homeRefreshInFlight = false
    /// Bumped after Settings cache clears so Downloads counts refresh.
    @Published private(set) var localCacheRevision: UInt = 0

    /// Live merge of the local play log and the server's recently-played albums.
    @Published private(set) var homeRecentlyPlayed: [RecentPlayedItem] = []
    /// On-device personalized mixes for the Home → Made for You shelf.
    @Published private(set) var homeMixes: [HomeMix] = []
    @Published private(set) var libraryAlbumsLoadError: String?

    /// Normalized track titles → normalized artist strings (for the request backend vs library matching).
    @Published private(set) var libraryTrackTitleIndex: [String: Set<String>] = [:]
    /// Snapshot of tracks used to build ``libraryTrackTitleIndex`` (resolve the request backend rows → `Track`).
    @Published private(set) var discoveryLibraryTracks: [Track] = [] {
        didSet {
            invalidateMembershipLookups()
            rebuildDiscoveryTrackIndices()
        }
    }
    /// O(1) "is this chart row in the user's library?" lookup. Rebuilt with ``libraryTrackTitleIndex``.
    private(set) var libraryChartTrackIndex: LibraryChartTrackIndex = .empty
    /// O(1) track lookup for downloaded-library resolution (rebuilt with ``discoveryLibraryTracks``).
    private(set) var discoveryTrackById: [String: Track] = [:]
    @Published private(set) var isIndexingLibraryTracks = false
    @Published private(set) var libraryTrackIndexLoadError: String?

    /// External (iTunes) browse shelves for the New tab.
    @Published private(set) var newTabTopTracks: [ChartTrack] = []
    @Published private(set) var newTabTopAlbums: [ChartAlbum] = []
    @Published private(set) var newTabRecentReleases: [ChartAlbum] = []
    @Published private(set) var newTabFromYourArtists: [ChartAlbum] = []
    @Published private(set) var newTabDiscoverReleases: [ChartAlbum] = []
    @Published private(set) var newTabArtistHighlights: [NewTabArtistHighlight] = []
    @Published private(set) var newTabIsPersonalized = false
    @Published private(set) var newTabBrowseLoading = false
    /// Set when iTunes browse fails so the New tab can show a concrete reason instead of an empty shelf.
    @Published private(set) var newTabBrowseError: String?
    /// Which catalog populated the **New** tab on the last successful refresh.
    @Published private(set) var newTabBrowseBackend: NewTabBrowseBackend = .none

    let player = PlaybackEngine()
    let offline = OfflineDownloadManager()
    let acquisition = AcquisitionManager()

    /// Follow-artist / discography-completeness automation (the Lidarr-style "brain"),
    /// backed by the iTunes Search API floor so it works regardless of which
    /// acquisition/library plugins are configured. Assigned in `init`.
    private(set) var subscriptions: MusicSubscriptionEngine!

    private var libraryAlbumsById: [String: AlbumSummary] = [:]
    /// O(1) "is this chart album in the user's library?" lookup. Rebuilt alongside ``libraryAlbumsById``.
    private(set) var libraryAlbumReleaseIndex: LibraryAlbumReleaseIndex = .empty

    /// O(1) catalog-album lookup for view code. Callers that need to resolve a handful of
    /// ids **must** use this instead of building their own `Dictionary` over
    /// ``libraryAlbums`` — that array is the whole server catalog and rebuilding a map of
    /// it inside a SwiftUI `body` is a main-thread hang on large libraries.
    func catalogAlbum(id: String) -> AlbumSummary? { libraryAlbumsById[id] }

    /// O(1) playlist lookup, rebuilt with ``libraryPlaylists``. Same rule as
    /// ``catalogAlbum(id:)`` — never map ``libraryPlaylists`` from a view body.
    func libraryPlaylist(id: String) -> PlaylistSummary? { libraryPlaylistsById[id] }

    /// O(1) track lookup over the indexed library. Same rule as ``catalogAlbum(id:)``.
    func indexedTrack(id: String) -> Track? { discoveryTrackById[id] }

    private var libraryPlaylistsById: [String: PlaylistSummary] = [:]
    private var libraryBootstrapTask: Task<Void, Never>?
    /// Cold-launch disk snapshot restore; awaited before network bootstrap.
    private var libraryDiskRestoreTask: Task<Void, Never>?
    /// Polls the server magic playlist so personal-library changes from other devices land here.
    private var libraryMembershipSyncTask: Task<Void, Never>?
    private var lastLibraryMembershipRefresh = Date.distantPast
    private var trackIndexTask: Task<Void, Never>?
    /// In-memory playlist tracklists for instant detail hydration (Go to Playlist, revisit).
    private var playlistRowsCache: [String: [PlaylistRowItem]] = [:]
    /// Instant album-detail hydration: read/write the existing ``albumTracksCache`` as plain
    /// `[Track]` so reopening an album doesn't re-fetch from the server each time.
    func cachedAlbumTracks(albumId: String) -> [Track]? {
        let key = albumId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return albumTracksCache[key]?.tracks
    }

    func cacheAlbumTracks(albumId: String, tracks: [Track]) {
        let key = albumId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !tracks.isEmpty else { return }
        albumTracksCache[key] = CachedAlbumTracks(tracks: tracks, retrievedAt: Date())
    }
    /// In-flight playlist row fetches keyed by playlist id — see ``fetchPlaylistRows(playlistId:)``.
    private var playlistRowsFetchTasks: [String: Task<[PlaylistRowItem], Error>] = [:]
    /// Background sync-ahead of playlist tracklists — see ``warmPlaylistRowsCache()``.
    private var playlistRowsWarmupTask: Task<Void, Never>?
    /// Set once the on-disk rows cache has been merged in; warming before that
    /// would re-fetch playlists whose rows were already persisted.
    private var playlistRowsDiskRestoreCompleted = false

    private static let favoriteTrackIdsKey = "VellumMusic.favoriteTrackIds"
    @Published private(set) var favoriteTrackIds: Set<String> = []

    /// Per-playlist "Kill Mode" toggle. When a playlist id is in this set, any user-initiated
    /// `skipNext` while playing FROM that playlist appends the outgoing track to the playlist's
    /// pending-removal set. Disabling Kill Mode does NOT clear the pending list.
    @Published private(set) var killModeEnabledPlaylistIds: Set<String> = []

    /// playlistId → ordered list of track ids queued for removal by Kill Mode, newest first.
    /// Order matters: the kill list view renders most-recent skips at the top. Reviewed and
    /// committed by the user via the kill list view (per-row swipe or "Remove All").
    @Published private(set) var killModePendingRemovals: [String: [String]] = [:]

    /// playlistId → set of track ids "kept (green)": played fully to their natural end
    /// while Kill Mode was on. Together with `killModePendingRemovals` (skipped/red) this
    /// is the "listened" set — excluded from future runs so each song plays once. Persists
    /// across disable/re-enable; reset only by "Clear listen history". Marked good (not
    /// removed): never deletes from the playlist.
    @Published private(set) var killModePassedTracks: [String: Set<String>] = [:]

    /// Memoized `pending ∪ passed` per playlist. The auto-advance exclusion predicate is
    /// hit in tight loops (`refreshEnqueuedNextItem` runs on every transport event), so we
    /// avoid rebuilding the union Set each call. Cleared on any kill-mode mutation.
    /// Live state of a bulk Kill Mode removal, so the UI can show determinate progress
    /// ("Removing 12 of 148") instead of an indefinite spinner. `nil` when idle.
    @Published private(set) var killModeRemovalProgress: KillModeRemovalProgress?

    /// Outcome of the last bulk removal — kept after the run so the sheet can report
    /// "removed N, failed M" instead of silently closing. Cleared by the UI on dismiss.
    @Published var killModeRemovalSummary: KillModeRemovalSummary?

    /// Songs per backend request during a bulk removal. Small enough that progress ticks
    /// stay meaningful and each committed chunk is a real resume point, large enough that a
    /// 150-song purge is three requests rather than 150.
    static let killModeRemovalChunkSize = 50

    private var killModeListenedCache: [String: Set<String>] = [:]
    private func invalidateKillModeListenedCache() { killModeListenedCache.removeAll() }

    /// Set of artists the user has manually favorited from ``ArtistPageView``.
    /// Stored as `LibraryTrackMatcher.normalize`d names so the same artist hits the
    /// same key regardless of source (server artist row vs Last.fm row vs typed search).
    /// Local-only — neither Jellyfin nor Subsonic has a "favorite artist" concept
    /// universally enough to sync against.
    private static let favoriteArtistNamesKey = "VellumMusic.favoriteArtistNames"
    @Published private(set) var favoriteArtistNames: Set<String> = []

    /// Local "recently played" history (mix of playlist + album entries) so Home can show a
    /// Recently Played shelf even when the backend doesn't expose play history. Newest first.
    /// Persisted in UserDefaults as JSON.
    private static let recentlyPlayedEntriesKey = "VellumMusic.recentlyPlayedEntries"
    /// Legacy key (album ids only) — read once on launch and migrated into ``recentlyPlayedEntries``.
    private static let recentlyPlayedAlbumIdsKey = "VellumMusic.recentlyPlayedAlbumIds"
    private static let recentlyPlayedEntriesLimit = 50
    @Published private(set) var recentlyPlayedEntries: [RecentPlayedEntry] = []

    /// Track-level play history for Now Playing → Queue → History. Only songs that
    /// crossed the scrobble threshold (~50% played) are appended, so skipping doesn't
    /// pollute the list. Survives queue changes since it lives on `AppModel`, not on
    /// the player's transient queue. Newest first.
    private static let recentlyPlayedTracksKey = "VellumMusic.recentlyPlayedTracks"
    private static let recentlyPlayedTracksLimit = 100
    /// Guards against an older off-main history encode landing after a newer one.
    private var recentlyPlayedSaveGeneration = 0
    @Published private(set) var recentlyPlayedTracks: [Track] = []

    /// Playlist id → last time the user meaningfully played from that playlist (scrobble threshold).
    private static let playlistLastPlayedDatesKey = "VellumMusic.playlistLastPlayedDates"
    @Published private(set) var playlistLastPlayedDates: [String: Date] = [:]

    /// Playlist id → when the user created it in this app. Used so a freshly-made playlist sorts
    /// to the top of Library → Recently Added even before the server reports its `created` date.
    private static let playlistCreatedDatesKey = "VellumMusic.playlistCreatedDates"
    @Published private(set) var playlistCreatedDates: [String: Date] = [:]

    func localPlaylistCreatedDate(_ id: String) -> Date? {
        playlistCreatedDates[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Playlists the user most recently added songs to from the add-to-playlist
    /// sheet, newest first — drives its "Recents" section. Local-only.
    private static let recentAddToPlaylistIdsKey = "VellumMusic.recentAddToPlaylistIds"
    private static let recentAddToPlaylistIdsLimit = 3
    @Published private(set) var recentAddToPlaylistIds: [String] = []

    /// Jellyfin / Navidrome playlists (excludes in-app “Favorite Songs”).
    /// True when the last playlist refresh threw. See C78 in ``refreshLibraryPlaylists()``.
    ///
    /// The refresh no longer turns a failure into an empty list, so this is the second line:
    /// it stops ``persistLibrarySnapshot()`` writing an empty playlist array to disk while we
    /// are known to be out of contact with the server.
    @Published private(set) var libraryPlaylistsFetchFailed = false

    @Published private(set) var libraryPlaylists: [PlaylistSummary] = [] {
        didSet {
            libraryPlaylistsById = Dictionary(libraryPlaylists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Vellum "My Library" magic playlist
    //
    // One private playlist per (backend, user) acts as the canonical store of what the
    // user has personally added to *their* library, server-side. The playlist's track
    // list is the song-membership set; the playlist's `comment` / `Overview` field
    // carries a JSON ``LibraryMembershipPayload`` covering album + playlist membership.
    // Filtered out of every user-facing playlist surface by id and by name prefix.

    /// Server-side id of the resolved magic playlist for the active session. `nil` until
    /// ``refreshLibraryMembership()`` succeeds at least once after sign-in.
    @Published private(set) var libraryMagicPlaylistId: String?

    /// True while the last read of the magic playlist's membership payload was unreadable.
    ///
    /// Blocks writes back to the server: the in-memory entries cannot be trusted to reflect
    /// what is there, and overwriting a library we failed to read is not recoverable. Cleared
    /// by the next readable payload. See C15 in ``applyMagicPlaylistFetch``.
    @Published private(set) var libraryMembershipWriteBlocked = false
    /// Song IDs the user has added to their library (mirrors magic playlist tracks).
    @Published private(set) var librarySongIds: Set<String> = [] {
        didSet { invalidateMembershipLookups() }
    }
    /// Album IDs in the user's library, with per-album add date (from the magic
    /// playlist's JSON comment payload).
    @Published private(set) var libraryAlbumEntries: [LibraryMembershipPayload.Entry] = [] {
        didSet { invalidateMembershipLookups() }
    }
    /// Playlist IDs the user has added to their library (separate from the magic
    /// playlist itself; the magic playlist is never listed here).
    @Published private(set) var libraryPlaylistEntries: [LibraryMembershipPayload.Entry] = []
    /// `true` while ``refreshLibraryMembership()`` is in flight. Used by Add/Remove
    /// buttons to guard against double-tap reentrancy.
    @Published private(set) var isResolvingLibraryMembership = false

    /// When non-nil, presents ``AddToPlaylistSheet`` from the tab shell. While the
    /// Now Playing cover is up, ``presentAddToPlaylist`` routes through UIKit instead
    /// so a SwiftUI `.sheet` never enters the cover's zoom-transition tree.
    @Published var playlistPickerPayload: PlaylistPickerPayload?
    /// Mirrored from ``MainShellView``'s `showNowPlaying` for add-to-playlist routing.
    var isNowPlayingCoverPresented = false

    /// When non-nil, the app root (and the Now Playing cover) is asking the user to confirm a
    /// removal. Every path that can take something out of the library funnels through here —
    /// see ``LibraryRemovalRequest``.
    @Published var pendingLibraryRemoval: LibraryRemovalRequest?

    /// Incremented after destructive library edits so screens reload cached track lists.
    @Published private(set) var libraryCatalogEpoch: UInt = 0

    // MARK: - Acquisition plugins (optional)

    /// True when the active acquisition plugin has the credentials it needs.
    var acquisitionConfigured: Bool { acquisition.isConfigured }
    /// Capabilities of the active plugin, for gating request UI.
    var acquisitionCapabilities: AcquisitionCapabilities { acquisition.capabilities }

    private static let themePreferenceKey = "vellumThemePreference"
    private static let launchTabPreferenceKey = "vellumLaunchTabPreference"
    private static let wifiStreamQualityKey = "vellumWifiStreamQuality"
    private static let cellularStreamQualityKey = "vellumCellularStreamQuality"
    private static let downloadQualityKey = "vellumDownloadQuality"
    private static let wifiStreamBitRateKey = "vellumWifiStreamBitRate"
    private static let cellularStreamBitRateKey = "vellumCellularStreamBitRate"
    private static let wifiStreamFormatKey = "vellumWifiStreamFormat"
    private static let cellularStreamFormatKey = "vellumCellularStreamFormat"
    private static let downloadFormatKey = "vellumDownloadFormat"
    private static let skipBackwardIntervalKey = "vellumSkipBackwardInterval"
    private static let skipForwardIntervalKey = "vellumSkipForwardInterval"
    private static let showSkipIntervalButtonsKey = "vellumShowSkipIntervalButtons"
    private static let showSleepTimerButtonKey = "vellumShowSleepTimerButton"
    private static let remoteControlModeKey = "vellumRemoteControlMode"
    private static let playbackRateKey = "vellumPlaybackRate"
    private static let artistPlayModeKey = "vellumArtistPlayMode"
    private static let showHomeMixesInPlaylistsKey = "vellumShowHomeMixesInPlaylists"
    private static let metadataRefreshThresholdKey = "vellumMetadataRefreshThreshold"
    private static let serverFailoverModeKey = "vellumServerFailoverMode"
    private static let playbackSettingsMigratedV2Key = "vellumPlaybackSettingsMigratedV2"
    private static let songListItemSizeKey = "vellumSongListItemSize"
    private static let lastLibrarySyncAtKey = "vellumLastLibrarySyncAt"
    private static let volumeNormalizationKey = "vellumVolumeNormalization"
    private static let albumBackdropEnabledKey = "vellumAlbumBackdropEnabled"
    private static let playlistBackdropEnabledKey = "vellumPlaylistBackdropEnabled"
    private static let playerBackdropEnabledKey = "vellumPlayerBackdropEnabled"
    private static let offlineModeKey = "vellumOfflineMode"
    private static let autoOfflineEnabledKey = "vellumAutoOfflineEnabled"
    private static let autoOfflineModeKey = "vellumAutoOfflineMode"
    private static let homeWifiSSIDsKey = "vellumHomeWifiSSIDs"
    private static let wifiOnlyDownloadsKey = "vellumWifiOnlyDownloads"
    private static let maxConcurrentDownloadsKey = "vellumMaxConcurrentDownloads"
    private static let storageLimitModeKey = "vellumStorageLimitMode"
    private static let maxCacheSizeGBKey = "vellumMaxCacheSizeGB"
    private static let favoritesAutoDownloadKey = "vellumFavoritesAutoDownload"

    @Published var themePreference: AppThemePreference = .system {
        didSet {
            UserDefaults.standard.set(themePreference.rawValue, forKey: Self.themePreferenceKey)
        }
    }

    @Published var wifiStreamQuality: StreamQualityTier = .original {
        didSet {
            UserDefaults.standard.set(wifiStreamQuality.rawValue, forKey: Self.wifiStreamQualityKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var cellularStreamQuality: StreamQualityTier = .capped320 {
        didSet {
            UserDefaults.standard.set(cellularStreamQuality.rawValue, forKey: Self.cellularStreamQualityKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var downloadQualityTier: DownloadQualityTier = .kbps320 {
        didSet {
            UserDefaults.standard.set(downloadQualityTier.rawValue, forKey: Self.downloadQualityKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var wifiStreamBitRate: StreamBitRateOption = .none {
        didSet {
            UserDefaults.standard.set(wifiStreamBitRate.rawValue, forKey: Self.wifiStreamBitRateKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var cellularStreamBitRate: StreamBitRateOption = .kbps320 {
        didSet {
            UserDefaults.standard.set(cellularStreamBitRate.rawValue, forKey: Self.cellularStreamBitRateKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var wifiStreamFormat: StreamFormatOption = .raw {
        didSet {
            UserDefaults.standard.set(wifiStreamFormat.rawValue, forKey: Self.wifiStreamFormatKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var cellularStreamFormat: StreamFormatOption = .raw {
        didSet {
            UserDefaults.standard.set(cellularStreamFormat.rawValue, forKey: Self.cellularStreamFormatKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var downloadFormat: DownloadFormatOption = .mp3 {
        didSet {
            UserDefaults.standard.set(downloadFormat.rawValue, forKey: Self.downloadFormatKey)
            pushQualitySettingsToClients()
        }
    }

    @Published var skipBackwardInterval: SkipIntervalOption = .s15 {
        didSet {
            UserDefaults.standard.set(skipBackwardInterval.rawValue, forKey: Self.skipBackwardIntervalKey)
            syncPlaybackPreferencesToEngine()
        }
    }

    @Published var skipForwardInterval: SkipIntervalOption = .s30 {
        didSet {
            UserDefaults.standard.set(skipForwardInterval.rawValue, forKey: Self.skipForwardIntervalKey)
            syncPlaybackPreferencesToEngine()
        }
    }

    @Published var showSkipIntervalButtons = false {
        didSet {
            UserDefaults.standard.set(showSkipIntervalButtons, forKey: Self.showSkipIntervalButtonsKey)
            syncPlaybackPreferencesToEngine()
        }
    }

    @Published var showSleepTimerButton = false {
        didSet {
            UserDefaults.standard.set(showSleepTimerButton, forKey: Self.showSleepTimerButtonKey)
            syncPlaybackPreferencesToEngine()
        }
    }

    @Published var remoteControlMode: RemoteControlMode = .skipTrack {
        didSet {
            UserDefaults.standard.set(remoteControlMode.rawValue, forKey: Self.remoteControlModeKey)
            syncPlaybackPreferencesToEngine()
        }
    }

    @Published var defaultPlaybackRate: PlaybackRateOption = .normal {
        didSet {
            UserDefaults.standard.set(defaultPlaybackRate.rawValue, forKey: Self.playbackRateKey)
            player.playbackRate = defaultPlaybackRate.rawValue
        }
    }

    @Published var artistPlayMode: ArtistPlayMode = .topSongs {
        didSet {
            UserDefaults.standard.set(artistPlayMode.rawValue, forKey: Self.artistPlayModeKey)
        }
    }

    /// When on, personalized Made for You mixes also appear in Library → Playlists (All).
    @Published var showHomeMixesInPlaylists = true {
        didSet {
            UserDefaults.standard.set(showHomeMixesInPlaylists, forKey: Self.showHomeMixesInPlaylistsKey)
        }
    }

    @Published var metadataRefreshThreshold: MetadataRefreshThreshold = .oneWeek {
        didSet {
            UserDefaults.standard.set(metadataRefreshThreshold.rawValue, forKey: Self.metadataRefreshThresholdKey)
        }
    }

    /// Cached album track lists for proactive metadata refresh before playback.
    private(set) var albumTracksCache: [String: CachedAlbumTracks] = [:]

    let scrobbleService = ScrobbleService()

    @Published var offlineMode = false {
        didSet {
            UserDefaults.standard.set(offlineMode, forKey: Self.offlineModeKey)
            applyEffectiveOfflinePresentation()
        }
    }

    @Published var autoOfflineEnabled = false {
        didSet {
            UserDefaults.standard.set(autoOfflineEnabled, forKey: Self.autoOfflineEnabledKey)
            Task { await evaluateAutoOfflineMode() }
        }
    }

    @Published var autoOfflineMode: AutoOfflineMode = .wifiOnly {
        didSet {
            UserDefaults.standard.set(autoOfflineMode.rawValue, forKey: Self.autoOfflineModeKey)
            Task { await evaluateAutoOfflineMode() }
        }
    }

    @Published private(set) var homeWifiSSIDs: [String] = []

    @Published var wifiOnlyDownloads = false {
        didSet {
            UserDefaults.standard.set(wifiOnlyDownloads, forKey: Self.wifiOnlyDownloadsKey)
            offline.wifiOnlyDownloads = wifiOnlyDownloads
            offline.kickQueueWorker()
        }
    }

    @Published var maxConcurrentDownloads: OfflineMaxConcurrentDownloads = .three {
        didSet {
            UserDefaults.standard.set(maxConcurrentDownloads.rawValue, forKey: Self.maxConcurrentDownloadsKey)
            offline.maxConcurrentDownloads = maxConcurrentDownloads
            offline.kickQueueWorker()
        }
    }

    @Published var offlineStorageLimitMode: OfflineStorageLimitMode = .none {
        didSet {
            UserDefaults.standard.set(offlineStorageLimitMode.rawValue, forKey: Self.storageLimitModeKey)
            offline.storageLimitMode = offlineStorageLimitMode
            offline.recalculateCacheBytes()
        }
    }

    @Published var maxCacheSizeGB: Double = 10 {
        didSet {
            UserDefaults.standard.set(maxCacheSizeGB, forKey: Self.maxCacheSizeGBKey)
            offline.maxCacheSizeGB = maxCacheSizeGB
            offline.recalculateCacheBytes()
        }
    }

    @Published var favoritesAutoDownload = false {
        didSet {
            UserDefaults.standard.set(favoritesAutoDownload, forKey: Self.favoritesAutoDownloadKey)
        }
    }

    /// Manual offline toggle or auto-offline policy (Wi‑Fi / home SSID).
    var effectiveOfflineMode: Bool { offlineMode || autoOfflineActive }
    private var autoOfflineActive = false
    private var prefersWifiLikePath = true

    @Published var songListItemSize: SongListItemSize = .medium {
        didSet {
            UserDefaults.standard.set(songListItemSize.rawValue, forKey: Self.songListItemSizeKey)
        }
    }

    /// When true (cellular-like path active), ``cellularStreamQuality`` applies; otherwise ``wifiStreamQuality``.
    @Published private(set) var prefersCellularStreamingQuality = false

    @Published private(set) var lastLibrarySyncAt: Date?

    @Published private(set) var isLibrarySyncing = false

    @Published private(set) var libraryStatistics: LibraryStatistics = .empty

    @Published var volumeNormalizationEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(volumeNormalizationEnabled, forKey: Self.volumeNormalizationKey)
        }
    }

    @Published var equalizerEnabled: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.enabledKey) {
        didSet {
            UserDefaults.standard.set(equalizerEnabled, forKey: EqualizerStorage.enabledKey)
            if equalizerEnabled {
                UserDefaults.standard.set(true, forKey: "streamingDiskCacheEnabled")
            }
            syncEqualizerToEngine()
            Task { await player.reloadForEqualizerSettingsChange() }
        }
    }

    @Published var equalizerBypass: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.bypassKey) {
        didSet {
            UserDefaults.standard.set(equalizerBypass, forKey: EqualizerStorage.bypassKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerPresetId: String = UserDefaults.standard.string(forKey: EqualizerStorage.presetIdKey) ?? EqualizerPreset.catalog[0].id {
        didSet {
            UserDefaults.standard.set(equalizerPresetId, forKey: EqualizerStorage.presetIdKey)
        }
    }

    @Published var equalizerBandGains: [Float] = EqualizerStorage.loadGains() {
        didSet {
            EqualizerStorage.saveGains(equalizerBandGains)
            syncEqualizerToEngine()
        }
    }

    @Published private(set) var equalizerHistory = EqualizerHistory()

    @Published var equalizerPrecisionDraw: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.precisionDrawKey) {
        didSet { UserDefaults.standard.set(equalizerPrecisionDraw, forKey: EqualizerStorage.precisionDrawKey) }
    }

    @Published var equalizerStereoWidth: EqualizerStereoWidth = {
        let raw = UserDefaults.standard.string(forKey: EqualizerStorage.stereoWidthKey) ?? EqualizerStereoWidth.normal.rawValue
        return EqualizerStereoWidth(rawValue: raw) ?? .normal
    }() {
        didSet {
            UserDefaults.standard.set(equalizerStereoWidth.rawValue, forKey: EqualizerStorage.stereoWidthKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerVintageMode: EqualizerVintageMode = {
        let raw = UserDefaults.standard.string(forKey: EqualizerStorage.vintageModeKey) ?? EqualizerVintageMode.off.rawValue
        return EqualizerVintageMode(rawValue: raw) ?? .off
    }() {
        didSet {
            UserDefaults.standard.set(equalizerVintageMode.rawValue, forKey: EqualizerStorage.vintageModeKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerAdaptiveEnabled: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.adaptiveEnabledKey) {
        didSet {
            UserDefaults.standard.set(equalizerAdaptiveEnabled, forKey: EqualizerStorage.adaptiveEnabledKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerAdaptiveStrength: EqualizerAdaptiveStrength = {
        let raw = UserDefaults.standard.string(forKey: EqualizerStorage.adaptiveStrengthKey) ?? EqualizerAdaptiveStrength.balanced.rawValue
        return EqualizerAdaptiveStrength(rawValue: raw) ?? .balanced
    }() {
        didSet {
            UserDefaults.standard.set(equalizerAdaptiveStrength.rawValue, forKey: EqualizerStorage.adaptiveStrengthKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerHeadphoneProfileId: String? = UserDefaults.standard.string(forKey: EqualizerStorage.headphoneProfileKey) {
        didSet {
            if let equalizerHeadphoneProfileId {
                UserDefaults.standard.set(equalizerHeadphoneProfileId, forKey: EqualizerStorage.headphoneProfileKey)
            } else {
                UserDefaults.standard.removeObject(forKey: EqualizerStorage.headphoneProfileKey)
            }
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerFrequencyToolMode: EqualizerFrequencyToolMode = {
        let raw = UserDefaults.standard.string(forKey: EqualizerStorage.frequencyToolModeKey) ?? EqualizerFrequencyToolMode.off.rawValue
        return EqualizerFrequencyToolMode(rawValue: raw) ?? .off
    }() {
        didSet {
            UserDefaults.standard.set(equalizerFrequencyToolMode.rawValue, forKey: EqualizerStorage.frequencyToolModeKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerFrequencyToolBand: Int = UserDefaults.standard.object(forKey: EqualizerStorage.frequencyToolBandKey) as? Int ?? 4 {
        didSet {
            UserDefaults.standard.set(equalizerFrequencyToolBand, forKey: EqualizerStorage.frequencyToolBandKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerHearingOffset: [Float] = EqualizerStorage.loadHearingOffset() {
        didSet {
            let normalized = EqualizerPreset.normalizedGains(equalizerHearingOffset)
            UserDefaults.standard.set(normalized.map(Double.init), forKey: EqualizerStorage.hearingOffsetKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerBassEnhancement: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.bassEnhancementKey) {
        didSet {
            UserDefaults.standard.set(equalizerBassEnhancement, forKey: EqualizerStorage.bassEnhancementKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerVocalEnhancement: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.vocalEnhancementKey) {
        didSet {
            UserDefaults.standard.set(equalizerVocalEnhancement, forKey: EqualizerStorage.vocalEnhancementKey)
            syncEqualizerToEngine()
        }
    }

    @Published var equalizerLoudnessCompensation: Bool = UserDefaults.standard.bool(forKey: EqualizerStorage.loudnessCompensationKey) {
        didSet {
            UserDefaults.standard.set(equalizerLoudnessCompensation, forKey: EqualizerStorage.loudnessCompensationKey)
            syncEqualizerToEngine()
        }
    }

    @Published private(set) var equalizerProfiles: [EqualizerProfile] = EqualizerProfileStore.load()

    private var equalizerUserOverride = false
    private var equalizerHistorySuppressed = false
    private var equalizerEditSessionBaseline: [Float]?

    @Published var albumBackdropEnabled: Bool = true {
        didSet { UserDefaults.standard.set(albumBackdropEnabled, forKey: Self.albumBackdropEnabledKey) }
    }

    @Published var playlistBackdropEnabled: Bool = true {
        didSet { UserDefaults.standard.set(playlistBackdropEnabled, forKey: Self.playlistBackdropEnabledKey) }
    }

    @Published var playerBackdropEnabled: Bool = true {
        didSet { UserDefaults.standard.set(playerBackdropEnabled, forKey: Self.playerBackdropEnabledKey) }
    }

    private var jellyfin: JellyfinMusicClient?
    private var navidrome: NavidromeClient?
    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "VellumMusic.networkPath")

    var activeLibrary: MusicLibraryProviding? {
        switch backendKind {
        case .jellyfin: return jellyfin
        case .navidrome: return navidrome
        }
    }

    /// True when the active server account may delete library tracks from this app.
    /// Jellyfin: admins always can; non-admins need EnableContentDeletion in their policy.
    /// Navidrome: no deletion API.
    @Published private(set) var canDeleteFromLibrary: Bool = false

    /// Full Subsonic `getUser` payload for the signed-in Navidrome account. `nil` on Jellyfin
    /// or before the first sign-in / metadata refresh completes.
    @Published private(set) var navidromeUserMetadata: NavidromeUserMetadata?

    /// `getCoverArt` URL for the Vellum magic playlist when Navidrome reports a user-uploaded /
    /// external image on it (i.e. *not* the auto-generated mosaic). Used to override the
    /// account avatar so users can manage their PFP by setting the magic playlist's cover.
    @Published private(set) var navidromeMagicPlaylistAvatarURL: URL? {
        didSet {
            // Persisted per server + user so the profile picture paints from the on-disk
            // avatar cache immediately on launch, before the membership sync re-confirms it.
            guard let key = magicPlaylistAvatarDefaultsKey else { return }
            if let url = navidromeMagicPlaylistAvatarURL {
                UserDefaults.standard.set(url.absoluteString, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private var magicPlaylistAvatarDefaultsKey: String? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !user.isEmpty,
              let server = LibraryMembership.normalizedServerKey(from: baseURLString),
              !server.isEmpty else { return nil }
        return "navidrome.magicPlaylistAvatarURL.\(server).\(user)"
    }

    /// Restores the last known magic-playlist avatar URL for the current server + user.
    private func restoreMagicPlaylistAvatarURL() {
        guard backendKind == .navidrome, navidromeMagicPlaylistAvatarURL == nil,
              let key = magicPlaylistAvatarDefaultsKey,
              let raw = UserDefaults.standard.string(forKey: key),
              let url = URL(string: raw) else { return }
        navidromeMagicPlaylistAvatarURL = url
    }

    /// `true` while ``updateProfilePictureFromImageData(_:)`` is in flight, so Settings can
    /// disable the picker and show a spinner.
    @Published private(set) var isUpdatingProfilePicture: Bool = false
    /// Most-recent profile-picture upload error (cleared by the next successful upload).
    @Published var profilePictureUpdateError: String?

    private func updateDeleteCapability() {
        guard isSignedIn else { canDeleteFromLibrary = false; return }
        switch backendKind {
        case .jellyfin:
            canDeleteFromLibrary = jellyfin?.isLibraryAdmin == true || jellyfin?.canDeleteLibraryMedia == true
        case .navidrome:
            canDeleteFromLibrary = false
        }
    }

    /// Bumps when the on-disk account avatar is refreshed (toolbar listens for instant cache display).
    @Published private(set) var accountAvatarRevision: UInt = 0

    /// Stable cache key for the signed-in account on the current server.
    var accountAvatarIdentity: AccountAvatarIdentity? {
        guard isSignedIn,
              let base = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        switch backendKind {
        case .jellyfin:
            guard let uid = jellyfin?.sessionUserId, !uid.isEmpty else { return nil }
            return AccountAvatarCache.identity(backend: .jellyfin, baseURL: base, userKey: uid)
        case .navidrome:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else { return nil }
            // Suffix the user key when the avatar is sourced from the magic playlist's
            // cover so cached bytes for the two sources never collide on disk.
            let suffix = navidromeMagicPlaylistAvatarURL != nil ? "@magicpl" : ""
            return AccountAvatarCache.identity(
                backend: .navidrome,
                baseURL: base,
                userKey: user.lowercased() + suffix,
            )
        }
    }

    /// Remote URL for the signed-in user's profile image. On Navidrome, prefers the magic
    /// playlist's cover art when the user has uploaded a custom image for it; otherwise
    /// falls back to the Subsonic `getAvatar` URL. Jellyfin uses the primary user image.
    var accountAvatarURL: URL? {
        switch backendKind {
        case .jellyfin:
            return jellyfin?.accountPrimaryImageURL(maxWidth: 256)
        case .navidrome:
            return navidromeMagicPlaylistAvatarURL ?? navidrome?.accountAvatarURL(username: username)
        }
    }

    /// Loads cached bytes immediately when possible; refreshes from the server in the background.
    func prefetchAccountAvatar() {
        guard let identity = accountAvatarIdentity, let url = accountAvatarURL else { return }
        Task(priority: .userInitiated) {
            await AccountAvatarCache.prefetch(url: url, identity: identity)
            await MainActor.run { accountAvatarRevision &+= 1 }
        }
    }

    public init() {
        LegacyLyraMigration.runIfNeeded()
        AppModel.shared = self
        // Stream caching is on by default: replaying a track should not re-download it, the
        // store is LRU-capped at 512 MB so it cannot grow without bound, and leaving it off
        // meant the equalizer silently did nothing on a track's first play. Still a toggle for
        // anyone who wants the disk back.
        UserDefaults.standard.register(defaults: ["streamingDiskCacheEnabled": true])
        registerWidgetCommandObserver()
        player.bind(offline: offline, resolveArtwork: { [weak self] track in
            self?.resolvedArtworkURL(for: track)
        })
#if DEBUG
        // T054: attribute the shell re-render churn during a dismiss drag to its driver.
        objectWillChange
            .sink { _ in
                DebugUIRemote.appPublishes += 1
                DebugUIRemote.logPublishOrigin("AppModel")
            }
            .store(in: &cancellables)
        player.objectWillChange
            .sink { _ in DebugUIRemote.playerPublishes += 1 }
            .store(in: &cancellables)
#endif
        // Mini-player chrome is the only playback signal most tabs need from AppModel.
        player.$showsMiniPlayerChrome
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$queue
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] active in self?.hasActivePlaybackQueue = active }
            .store(in: &cancellables)
        Publishers.CombineLatest(player.$queue, player.$currentIndex)
            .map { queue, index -> String? in
                guard queue.indices.contains(index) else { return nil }
                return queue[index].id
            }
            .removeDuplicates()
            .sink { [weak self] trackId in
                self?.nowPlayingTrackId = trackId
                self?.writeWidgetData()
            }
            .store(in: &cancellables)
        // Keep the home-screen widget's play/pause glyph in sync with actual
        // playback. Pause/resume from the mini-player, lock screen, route change,
        // or interruption flips isPlaying without changing the track, and the
        // CombineLatest above only fires on track/queue change — so without this
        // the widget showed a stale transport state until the next track.
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.writeWidgetData() }
            .store(in: &cancellables)
        // Throttled, because `removeDuplicates()` never suppresses anything here: each track
        // that finishes downloading inserts into the Set, so every value is strictly larger than
        // the last and always "different". Saving an album therefore fired one full-tree
        // invalidation per track — and ~40 view files hold `@EnvironmentObject var app`,
        // including RootView, NowPlayingView and MiniPlayerView, i.e. exactly the views alive
        // during a cover zoom. `latest: true` guarantees the final state still arrives, so a
        // download-complete checkmark can be up to 250ms late but is never dropped.
        offline.$downloadedTrackIds
            .removeDuplicates()
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        acquisition.onJobFinished = { [weak self] job in
            guard let self else { return }
            Task { await self.handleAcquisitionJobFinished(job) }
        }
        subscriptions = MusicSubscriptionEngine(env: .init(
            serverAlbumsForArtist: { [weak self] name in
                await self?.serverAlbums(forArtistName: name) ?? []
            },
            enqueue: { [weak self] request in
                await self?.acquisition.enqueue(request) ?? .notConfigured
            },
            isAcquisitionConfigured: { [weak self] in
                self?.acquisition.isConfigured ?? false
            },
            acquisitionGranularity: { [weak self] in
                self?.acquisition.capabilities.granularity ?? .album
            },
            artistReleases: { [weak self] name in
                await self?.acquisition.artistReleases(named: name) ?? []
            }
        ))
        loadPersistedSettings()
        wireOfflineDownloadManager()
        startNetworkMonitor()
        loadKeychain()
        loadFavoriteTrackIdsFromDefaults()
        loadRecentlyPlayedEntriesFromDefaults()
        loadRecentlyPlayedTracksFromDefaults()
        loadPlaylistLastPlayedDatesFromDefaults()
        loadPlaylistCreatedDatesFromDefaults()
        loadRecentAddToPlaylistIdsFromDefaults()
        reloadCustomRadioStations()
        // After `loadKeychain()`, which is what resolves the account the state is scoped to.
        reloadKillModeStateForAccount()
        scrobbleService.bind(app: self)
        player.refreshTrackBeforePlay = { [weak self] track in
            await self?.refreshAlbumTracksIfNeeded(for: track) ?? track
        }
        player.recoverStaleTrackOnFailure = { [weak self] track in
            await self?.recoverStaleSongIDs(for: track)
        }
        syncPlaybackPreferencesToEngine()
        pushQualitySettingsToClients()
        player.onTrackScrobbled = { [weak self] track, source in
            Task { @MainActor in
                self?.recordRecentPlay(track: track, source: source)
                self?.scrobbleService.recordCompletedScrobble(track: track, source: source)
            }
        }
        player.onTrackStarted = { [weak self] track in
            Task { @MainActor in
                self?.recordRecentTrackPlay(track)
                self?.scrobbleService.sendNowPlaying(track: track, source: self?.player.playbackSource)
                self?.applyEqualizerAutomationForTrack(track)
            }
        }
        Self.wireKillModeHooks(
            on: player,
            skipped: { [weak self] track, source, wasUserQueued in
                self?.handleKillModeSkip(track: track, source: source, wasUserQueued: wasUserQueued)
            },
            completed: { [weak self] track, source, wasUserQueued in
                self?.handleKillModeCompletion(track: track, source: source, wasUserQueued: wasUserQueued)
            },
            excludes: { [weak self] track in
                self?.killModeExcludesFromAutoAdvance(track) ?? false
            }
        )
        player.onQueueReplaced = { [weak self] in
            self?.captureKillModeRunGate()
        }
        player.isKillModeRun = { [weak self] in
            guard let self else { return false }
            return Self.killModeRunPlaylistId(source: self.player.playbackSource, enabledPlaylistIds: self.killModeEnabledPlaylistIds) != nil
        }
        player.onAudioRouteChanged = { [weak self] in
            Task { @MainActor in
                self?.applyEqualizerAutomationForRouteChange()
            }
        }
        // Playback failures used to be invisible: a skip or auto-advance onto a dead track stopped
        // the music with no message anywhere. A transient toast is the app's existing convention
        // for "that didn't work" (see "Couldn't start mix"), and unlike `errorMessage` — which
        // RootView renders as an alert — it does not interrupt what the user is doing.
        player.onPlaybackFailure = { [weak self] track, _ in
            Task { @MainActor in
                guard let self else { return }
                let title = track?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.showTransientToast(title.isEmpty ? "Couldn't play this track" : "Couldn't play \(title)")
            }
        }
        // A track the engine gave up on and moved past by itself. Silent auto-skips are
        // indistinguishable from a bug — and from a *deletion* — so every one of them says what
        // was skipped and why. Toast, not alert: the queue is still playing, nothing is blocked.
        player.onTrackAutoSkipped = { [weak self] track, reason in
            Task { @MainActor in
                guard let self else { return }
                let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let named = title.isEmpty ? "a song" : "“\(title)”"
                self.showTransientToast("Skipped \(named) — \(reason.skipClause)")
            }
        }
        // The runaway guard tripped: playback has stopped. This one is deliberately *not* a
        // toast. A 1.8s message that disappears is exactly how "my server is down" got
        // mistaken for "this playlist is empty" — the state is persistent, so the message has
        // to be too. `errorMessage` is the app's existing modal channel (RootView renders it
        // as an alert, and the Now Playing cover carries its own copy of that chrome).
        player.onPlaybackHalted = { [weak self] summary in
            Task { @MainActor in
                self?.errorMessage = summary.message
            }
        }
        installPlaybackQueueAutosave()
    }

    /// Saves the playback queue snapshot ~1s after the queue, current track, or transport modes
    /// change. Position is captured on-demand from the live AVPlayer at save time. Scene-phase
    /// transitions in `VellumMusicHostApp` flush a snapshot immediately via ``persistPlaybackQueue()``.
    private func installPlaybackQueueAutosave() {
        let triggers = Publishers.MergeMany(
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
            player.$shuffleMode.map { _ in () }.eraseToAnyPublisher(),
            player.$repeatMode.map { _ in () }.eraseToAnyPublisher(),
        )
        triggers
            .debounce(for: .milliseconds(1000), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistPlaybackQueue() }
            .store(in: &cancellables)
    }

    /// Writes the current playback queue snapshot to disk (or clears it when nothing is queued).
    /// Safe to call frequently — the underlying file write is atomic and cheap.
    public func persistPlaybackQueue() {
        guard isSignedIn else { return }
        if let snap = player.currentSnapshot() {
            PlaybackQueueStore.save(snap)
        } else {
            PlaybackQueueStore.clear()
        }
    }

    /// Restores the saved queue (paused) so the user can pick up where they left off.
    /// Called from the keychain-session restore path after the active backend client is wired up.
    private func restorePlaybackQueueFromDisk() {
        guard let snap = PlaybackQueueStore.load() else { return }
        player.restore(library: activeLibrary, snapshot: snap)
    }

    /// Updates the home screen icon when it does not match ``appIconPresetId`` (iOS shows its OK alert on change).
    public func syncHomeScreenIconIfNeeded() {
        #if canImport(UIKit)
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let target = AppAlternateIconSync.resolvedIconName(forIconPresetId: appIconPresetId)
        guard UIApplication.shared.alternateIconName != target else { return }
        AppAlternateIconSync.apply(iconPresetId: appIconPresetId, completion: nil)
        #endif
    }

    /// Migrates legacy installs that tied icon color to accent selection.
    private static func loadAppIconPresetId() -> String {
        if let stored = UserDefaults.standard.string(forKey: AppAccentPreset.appIconPresetIdKey) {
            return AppAccentPreset.validIconPresetId(stored)
        }
        let accent = UserDefaults.standard.string(forKey: AppAccentPreset.accentPresetIdKey) ?? AppAccentPreset.defaultId
        if accent != AppAccentPreset.customId {
            return AppAccentPreset.validIconPresetId(accent)
        }
        return AppAccentPreset.defaultId
    }

    private static func loadLaunchTab() -> LaunchTabPreference {
        guard let raw = UserDefaults.standard.string(forKey: launchTabPreferenceKey),
              let value = LaunchTabPreference(rawValue: raw)
        else { return .library }
        return value
    }

    /// Applies the user's preferred landing tab (used after sign-in / cold launch).
    func applyLaunchTab() {
        selectedTab = launchTabPreference.appTab
    }

    public func signIn() async {
        guard !isAuthenticating else { return }
        errorMessage = nil
        guard let base = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Invalid server URL"
            return
        }
        let secondary = normalizedServerURL(from: secondaryURLString)
        isAuthenticating = true
        defer { isAuthenticating = false }
        let priorSessionKey = mediaSessionKey
        do {
            switch backendKind {
            case .jellyfin:
                let client = JellyfinMusicClient(baseURL: base)
                try await client.signIn(username: username, password: password)
                jellyfin = client
                navidrome = nil
                try KeychainStore.saveJellyfin(
                    base: base,
                    secondaryBase: secondary,
                    user: username,
                    password: password,
                    accessToken: client.sessionAccessToken,
                    userId: client.sessionUserId,
                )
            case .navidrome:
                let client = NavidromeClient(baseURL: base)
                try await client.signIn(username: username, password: password)
                navidrome = client
                jellyfin = nil
                navidromeUserMetadata = client.currentUserMetadata
                try KeychainStore.saveNavidrome(
                    base: base,
                    secondaryBase: secondary,
                    user: username,
                    password: password,
                    subsonicToken: client.sessionToken,
                )
            }
            await clearMediaArtworkCaches()
            if priorSessionKey != mediaSessionKey {
                clearLibraryMediaCatalog()
            }
            if backendKind == .jellyfin, let client = jellyfin {
                await Self.registerMediaAuthHeaders(host: base.host, headers: client.httpHeadersForMediaRequests())
            }
            // Enter the app immediately after auth — library refresh can take a long time on large servers.
            isSignedIn = true
            reloadKillModeStateForAccount()
            applyLaunchTab()
            activeServerURLRole = .primary
            updateDeleteCapability()
            prefetchAccountAvatar()
            pushQualitySettingsToClients()
            scheduleLibraryBootstrap()
        } catch {
            let hadLocalSession = jellyfin != nil || navidrome != nil
            if !hadLocalSession {
                jellyfin = nil
                navidrome = nil
                isSignedIn = false
                hasCompletedLibraryBootstrap = false
                serverConnectionHealth = .unknown
                errorMessage = error.localizedDescription
            } else {
                errorMessage = nil
                serverConnectionHealth = connectionHealth(for: error)
            }
        }
    }

    /// Refreshes ``navidromeUserMetadata`` from the server. No-op on Jellyfin or when signed out.
    public func refreshNavidromeUserMetadata() async {
        guard isSignedIn, backendKind == .navidrome, let client = navidrome else { return }
        if let metadata = try? await client.refreshUserMetadata() {
            navidromeUserMetadata = metadata
        }
    }

    /// Updates Settings server status without surfacing a global alert.
    public func refreshServerConnectionHealth() async {
        guard isSignedIn else {
            serverConnectionHealth = .unknown
            return
        }
        guard hasInternetPath else {
            serverConnectionHealth = .noNetwork
            return
        }
        serverConnectionHealth = .checking
        do {
            switch backendKind {
            case .jellyfin:
                guard let client = jellyfin else { throw URLError(.userAuthenticationRequired) }
                try await client.verifyServerReachable()
            case .navidrome:
                guard let client = navidrome else { throw URLError(.userAuthenticationRequired) }
                try await client.verifyServerReachable()
            }
            serverConnectionHealth = .connected
        } catch {
            serverConnectionHealth = connectionHealth(for: error)
            _ = await attemptAutomaticFailoverIfNeeded()
        }
    }

    private func connectionHealth(for error: Error) -> ServerConnectionHealth {
        if !hasInternetPath { return .noNetwork }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .noNetwork
            default:
                break
            }
        }
        let name = backendKind == .jellyfin ? "Jellyfin" : "Navidrome"
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if detail.isEmpty {
            return .unreachable("Cannot reach \(name). Check the server URL and network.")
        }
        return .unreachable("Cannot reach \(name). \(detail)")
    }

    public func signOut() {
        stopLibraryMembershipAutoSync()
        if let identity = accountAvatarIdentity {
            AccountAvatarCache.remove(identity: identity)
            accountAvatarRevision &+= 1
        }
        jellyfin = nil
        navidrome = nil
        navidromeUserMetadata = nil
        navidromeMagicPlaylistAvatarURL = nil
        isSignedIn = false
        // Signing out ends the session this flag describes — the next sign-in must bootstrap.
        hasCompletedLibraryBootstrap = false
        libraryAlbums = []
        recentlyAddedAlbums = []
        homeRecentlyPlayedServerAlbums = []
        homeGenreShelves = []
        homeTopPickAlbums = []
        homeNewReleaseAlbums = []
        homeMixes = []
        homeSelectedGenres = nil
        recentlyPlayedEntries = []
        UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedEntriesKey)
        UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedAlbumIdsKey)
        recentlyPlayedTracks = []
        UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedTracksKey)
        libraryAlbumsLoadError = nil
        newTabTopTracks = []
        newTabTopAlbums = []
        newTabRecentReleases = []
        newTabFromYourArtists = []
        newTabDiscoverReleases = []
        newTabArtistHighlights = []
        newTabIsPersonalized = false
        newTabBrowseError = nil
        newTabBrowseBackend = .none
        discoveryLibraryTracks = []
        libraryTrackIndexLoadError = nil
        isIndexingLibraryTracks = false
        libraryMagicPlaylistId = nil
        librarySongIds = []
        libraryAlbumEntries = []
        libraryPlaylistEntries = []
        KeychainStore.clear()
        UserDefaults.standard.removeObject(forKey: "lastfm_api_key")
        ["lastfm_secret", "lastfm_session"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        player.reset()
        unloadKillModeStateForSignOut()
        canDeleteFromLibrary = false
        favoriteTrackIds = []
        libraryPlaylists = []
        playlistPickerPayload = nil
        pendingLibraryRemoval = nil
        libraryCatalogEpoch = 0
        Task { await AlbumDetailArtistCatalogCache.shared.clear() }
        libraryStatistics = .empty
        lastLibrarySyncAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastLibrarySyncAtKey)
        playlistRowsWarmupTask?.cancel()
        clearInMemoryPlaylistRowsCache()
        LibrarySnapshotStore.clear()
        PlaylistRowsCacheStore.clear()
        StreamingMediaDiskCache.shared.clear()
        PlaybackQueueStore.clear()
        clearMediaArtworkCachesSync()
        hasInternetPath = true
        serverConnectionHealth = .unknown
    }

    /// Prefer on-disk artwork, then per-track URL, then cached album art, then server cover lookup.
    func resolvedArtworkURL(for track: Track) -> URL? {
        if track.isInternetRadioStream {
            if let file = track.artworkURL, file.isFileURL,
               FileManager.default.fileExists(atPath: file.path) {
                return file
            }
            // Directory favicons and custom `remoteArtworkURL` — not on the music server.
            if let remote = track.artworkURL, !remote.isFileURL {
                return remote
            }
            return nil
        }
        if let local = offline.localArtworkURL(forTrackId: track.id) { return local }
        if let localAlbum = offline.localArtworkURL(forAlbumId: track.albumId) { return localAlbum }
        if let file = track.artworkURL, file.isFileURL,
           FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        switch backendKind {
        case .navidrome:
            return navidromeFreshCoverArtURL(
                coverArtId: navidromeCoverArtId(for: track),
                fallbackId: track.albumId
            )
        case .jellyfin:
            if let trackArt = sanitizeArtworkURL(track.artworkURL) { return trackArt }
            if let album = libraryAlbumsById[track.albumId] {
                if let localAlbum = offline.localArtworkURL(forAlbumId: album.id) { return localAlbum }
                if let albumArt = sanitizeArtworkURL(album.artworkURL) { return albumArt }
            }
            return jellyfin?.albumPrimaryImageURL(albumId: track.albumId)
        }
    }

    func trackWithResolvedArtwork(_ track: Track) -> Track {
        let art = resolvedArtworkURL(for: track)
        guard art != track.artworkURL else { return track }
        return track.withArtworkURL(art)
    }

    func resolvedArtworkURL(for album: AlbumSummary) -> URL? {
        if let local = offline.localArtworkURL(forAlbumId: album.id) { return local }
        if let file = album.artworkURL, file.isFileURL,
           FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        switch backendKind {
        case .navidrome:
            return navidromeFreshCoverArtURL(
                coverArtId: album.coverArtId ?? navidromeCoverArtId(from: album.artworkURL),
                fallbackId: album.id
            )
        case .jellyfin:
            if let albumArt = sanitizeArtworkURL(album.artworkURL) { return albumArt }
            return jellyfin?.albumPrimaryImageURL(albumId: album.id)
        }
    }

    func resolvedArtworkURL(for playlist: PlaylistSummary) -> URL? {
        switch backendKind {
        case .navidrome:
            return navidromeFreshCoverArtURL(
                coverArtId: playlist.coverArtId ?? navidromeCoverArtId(from: playlist.artworkURL),
                fallbackId: playlist.id
            )
        case .jellyfin:
            if let art = sanitizeArtworkURL(playlist.artworkURL) { return art }
            return jellyfin?.albumPrimaryImageURL(albumId: playlist.id)
        }
    }

    /// Cover art for a track we know only by id.
    ///
    /// The artwork path proper needs a `Track`, which means the track has to be in one of the
    /// local caches. A scrobble row can outlive all of them — it keeps only an id, a title and
    /// an artist — and then had no art at all. Both backends will serve a cover for a *song* id
    /// directly (Subsonic `getCoverArt?id=`, Jellyfin `/Items/{id}/Images/Primary`), so the id
    /// on the scrobble is enough. Used as a fallback only; a cached `Track` is still preferred
    /// because it carries the album's own cover id.
    func artworkURLForTrackId(_ id: String) -> URL? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch backendKind {
        case .navidrome:
            return navidrome?.coverArtURL(forId: trimmed, size: 400)
        case .jellyfin:
            return jellyfin?.albumPrimaryImageURL(albumId: trimmed)
        }
    }

    private func navidromeCoverArtId(for track: Track) -> String? {
        if let fromTrack = navidromeCoverArtId(from: track.artworkURL) { return fromTrack }
        if let album = libraryAlbumsById[track.albumId] {
            return album.coverArtId ?? navidromeCoverArtId(from: album.artworkURL)
        }
        return nil
    }

    private func navidromeCoverArtId(from url: URL?) -> String? {
        guard let url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value
        else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Navidrome embeds salted auth in cover URLs — always rebuild from the active client
    /// so snapshot / re-login never leaves stale `t`/`s` tokens that 401 in the loader.
    private func navidromeFreshCoverArtURL(coverArtId: String?, fallbackId: String) -> URL? {
        let id = coverArtId ?? fallbackId
        guard !id.isEmpty else { return nil }
        return navidrome?.coverArtURL(forId: id, size: 400)
    }

    private var activeServerBaseURL: URL? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var mediaSessionKey: String {
        let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(backendKind)|\(base)|\(user)"
    }

    /// Rejects artwork URLs baked into an old snapshot/client (e.g. Jellyfin URLs after switching to Navidrome).
    private func sanitizeArtworkURL(_ url: URL?) -> URL? {
        guard let url, artworkURLMatchesActiveSession(url) else { return nil }
        return url
    }

    private func artworkURLMatchesActiveSession(_ url: URL) -> Bool {
        guard isSignedIn,
              let base = activeServerBaseURL,
              let baseHost = base.host?.lowercased(),
              let urlHost = url.host?.lowercased(),
              baseHost == urlHost
        else { return false }

        let basePort = base.port ?? (base.scheme == "https" ? 443 : 80)
        let urlPort = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard basePort == urlPort else { return false }

        let path = url.path.lowercased()
        switch backendKind {
        case .jellyfin:
            return !path.contains("/rest/")
        case .navidrome:
            return path.contains("/rest/")
        }
    }

    private func clearMediaArtworkCaches() async {
        ArtworkURLCache.clearAll()
        DecodedArtworkCache.clearAll()
        ArtworkDynamicGradient.clearPaletteCache()
        HomeTopPickBleedCache.clear()
        URLCache.shared.removeAllCachedResponses()
        await MediaAuthHeaderRegistry.shared.clear()
    }

    private func clearMediaArtworkCachesSync() {
        ArtworkURLCache.clearAll()
        DecodedArtworkCache.clearAll()
        ArtworkDynamicGradient.clearPaletteCache()
        HomeTopPickBleedCache.clear()
        URLCache.shared.removeAllCachedResponses()
        Task { await MediaAuthHeaderRegistry.shared.clear() }
    }

    /// Drops in-memory library media when the active server identity changes without an explicit sign-out.
    private func clearLibraryMediaCatalog() {
        libraryAlbums = []
        recentlyAddedAlbums = []
        homeRecentlyPlayedServerAlbums = []
        homeGenreShelves = []
        homeTopPickAlbums = []
        homeNewReleaseAlbums = []
        homeMixes = []
        homeSelectedGenres = nil
        discoveryLibraryTracks = []
        libraryPlaylists = []
        libraryMagicPlaylistId = nil
        librarySongIds = []
        libraryAlbumEntries = []
        libraryPlaylistEntries = []
        libraryCatalogEpoch = 0
        libraryStatistics = .empty
        lastLibrarySyncAt = nil
        playlistRowsWarmupTask?.cancel()
        playlistRowsCache.removeAll()
        LibrarySnapshotStore.clear()
        PlaylistRowsCacheStore.clear()
    }

    func persistLibrarySnapshot() {
        // C78. Never let a known-failed refresh write an empty playlist array over a good
        // snapshot. `refreshLibraryPlaylists()` already declines to clear the in-memory list on
        // failure, so this only fires if the list was empty for some other reason while we are
        // also out of contact — in which case the disk copy is the better record of the truth.
        guard !(libraryPlaylistsFetchFailed && libraryPlaylists.isEmpty) else { return }
        PerfLog.measure("persistLibrarySnapshot.capture", details: "albums=\(libraryAlbums.count) tracks=\(discoveryLibraryTracks.count) playlists=\(libraryPlaylists.count) songIds=\(librarySongIds.count)") {
            // Capture a value snapshot on the main actor (cheap thanks to Swift CoW),
            // then hand the JSON encode + atomic disk write to a background task so
            // the main thread isn't blocked while we serialize the full library.
            let snapshot = LibrarySnapshot(
                albums: libraryAlbums,
                tracks: discoveryLibraryTracks,
                playlists: libraryPlaylists,
                favoriteTrackIds: Array(favoriteTrackIds),
                libraryMagicPlaylistId: libraryMagicPlaylistId,
                librarySongIds: Array(librarySongIds),
                libraryAlbumEntries: libraryAlbumEntries,
                libraryPlaylistEntries: libraryPlaylistEntries,
            )
            LibrarySnapshotStore.saveAsync(snapshot)
        }
    }

    /// Fire-and-forget restore for error / offline fallbacks.
    private func restoreLibraryFromDisk() {
        Task { [weak self] in
            await self?.restoreLibraryFromDiskAsync()
        }
    }

    /// Loads the on-disk library snapshot and paints UI before network bootstrap.
    /// Returns after albums / membership are on screen; track indices continue in the
    /// background so a 50k-track catalog doesn't delay auth probe + bootstrap.
    private func restoreLibraryFromDiskAsync() async {
        let snap = await LibrarySnapshotStore.loadAsync()
        applyRestoredSnapshotLight(snap)
        let rowsCache = await PlaylistRowsCacheStore.loadAsync()
        applyRestoredPlaylistRowsCache(rowsCache)
        playlistRowsDiskRestoreCompleted = true
        warmPlaylistRowsCache()
        // Heavy track-index work continues without blocking cold-launch bootstrap.
        Task { [weak self] in
            await self?.applyRestoredSnapshotTracks(snap)
        }
    }

    /// Seed the in-memory playlist-row cache from disk on cold launch so the first
    /// open of a previously-viewed playlist renders instantly. Never clobbers an
    /// entry already fetched fresh this session, and skips empties.
    private func applyRestoredPlaylistRowsCache(_ cache: PlaylistRowsCache?) {
        guard let cache, !cache.rowsByPlaylistId.isEmpty else { return }
        for (id, rows) in cache.rowsByPlaylistId where playlistRowsCache[id] == nil && !rows.isEmpty {
            playlistRowsCache[id] = rows
        }
    }

    private func persistPlaylistRowsCache() {
        PlaylistRowsCacheStore.saveAsync(playlistRowsCache)
    }

    /// Phase 1 — albums / playlists / membership so Library + Home paint immediately.
    private func applyRestoredSnapshotLight(_ snap: LibrarySnapshot?) {
        let details = snap.map {
            "albums=\($0.albums.count) playlists=\($0.playlists.count) songIds=\($0.librarySongIds.count)"
        } ?? "nil"
        PerfLog.measure("applyRestoredSnapshot.light", details: details) {
            withCoalescedLibraryIndexRebuild {
                if let snap {
                    if !snap.albums.isEmpty { libraryAlbums = snap.albums }
                    if !snap.playlists.isEmpty { libraryPlaylists = snap.playlists }
                    if !snap.favoriteTrackIds.isEmpty {
                        favoriteTrackIds = Set(snap.favoriteTrackIds)
                    }
                    if let id = snap.libraryMagicPlaylistId, !id.isEmpty {
                        libraryMagicPlaylistId = id
                    }
                    if !snap.librarySongIds.isEmpty {
                        librarySongIds = Set(snap.librarySongIds)
                    }
                    if !snap.libraryAlbumEntries.isEmpty {
                        libraryAlbumEntries = snap.libraryAlbumEntries
                    }
                    if !snap.libraryPlaylistEntries.isEmpty {
                        libraryPlaylistEntries = snap.libraryPlaylistEntries
                    }
                }
            }
            rebuildHomeRecentlyPlayed()
            rebuildHomeDiscoveryShelves()
        }
    }

    /// Phase 2 — discovery tracks + indices (off-main build, main-actor assign).
    private func applyRestoredSnapshotTracks(_ snap: LibrarySnapshot?) async {
        let tracks = snap?.tracks ?? []
        guard !tracks.isEmpty else {
            offline.backfillRecordsIfMissing(knownTracks: [])
            mergeOfflineCatalog()
            return
        }
        // Don't clobber a fresher in-session index (bootstrap / New-tab refresh won the race).
        if !discoveryLibraryTracks.isEmpty,
           discoveryLibraryTracks.count >= tracks.count,
           !libraryTrackTitleIndex.isEmpty {
            offline.backfillRecordsIfMissing(knownTracks: discoveryLibraryTracks)
            mergeOfflineCatalog()
            return
        }

        let computed = await PerfLog.measureAsync(
            "applyRestoredSnapshot.buildTrackIndices",
            context: .background,
            details: "tracks=\(tracks.count)"
        ) {
            await Task.detached(priority: .userInitiated) {
                () -> (byId: [String: Track], titles: [String: Set<String>], chart: LibraryChartTrackIndex) in
                let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let titles = LibraryTrackMatcher.titleIndex(from: tracks)
                let chart = LibraryChartTrackIndex(tracks: tracks)
                return (byId, titles, chart)
            }.value
        }
        // Re-check after the off-main build — a live refresh may have landed meanwhile.
        if !libraryTrackTitleIndex.isEmpty,
           discoveryLibraryTracks.count > tracks.count {
            offline.backfillRecordsIfMissing(knownTracks: discoveryLibraryTracks)
            mergeOfflineCatalog()
            return
        }
        PerfLog.measure("applyRestoredSnapshot.assignTracks", details: "tracks=\(tracks.count)") {
            skipDiscoveryIndexRebuild = true
            discoveryLibraryTracks = tracks
            skipDiscoveryIndexRebuild = false
            discoveryTrackById = computed.byId
            libraryTrackTitleIndex = computed.titles
            libraryChartTrackIndex = computed.chart
            libraryAlbumsById = Dictionary(
                libraryAlbums.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            libraryAlbumReleaseIndex = LibraryAlbumReleaseIndex(albums: libraryAlbums)
            invalidateMembershipLookups()
        }
        offline.backfillRecordsIfMissing(knownTracks: tracks)
        rebuildHomeMixes()
        mergeOfflineCatalog()
        Task {
            await offline.enrichCachedDurationsIfNeeded()
            mergeOfflineCatalog()
        }
    }

    func mergeOfflineCatalogFromDownloads() {
        mergeOfflineCatalog()
    }

    private func mergeOfflineCatalog() {
        PerfLog.measure("mergeOfflineCatalog", details: "lib=\(libraryAlbums.count)/\(discoveryLibraryTracks.count)") {
            let offlineTracks = offline.cachedTracks()
            let offlineAlbums = offline.cachedAlbums()
            guard !offlineTracks.isEmpty || !offlineAlbums.isEmpty else { return }

            // Skip the full rebuild when every download is already indexed — common on
            // cold launch after the snapshot restore already included those tracks.
            let missingTrackIds = offlineTracks.filter { discoveryTrackById[$0.id] == nil }
            let missingAlbums = offlineAlbums.filter { libraryAlbumsById[$0.id] == nil }
            if missingTrackIds.isEmpty && missingAlbums.isEmpty {
                return
            }

            withCoalescedLibraryIndexRebuild {
                if !offlineTracks.isEmpty {
                    var trackById = Dictionary(uniqueKeysWithValues: discoveryLibraryTracks.map { ($0.id, $0) })
                    for t in offlineTracks {
                        trackById[t.id] = t
                    }
                    discoveryLibraryTracks = Array(trackById.values)
                }

                if !offlineAlbums.isEmpty {
                    var albumById = Dictionary(uniqueKeysWithValues: libraryAlbums.map { ($0.id, $0) })
                    for album in offlineAlbums {
                        albumById[album.id] = album
                    }
                    libraryAlbums = albumById.values.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                }
            }
            libraryCatalogEpoch &+= 1
        }
    }

    // MARK: - Removal confirmations
    //
    // Nothing leaves the library without passing through here. Call sites hand over the thing
    // being removed and the work to do; ``LibraryRemovalCopy`` writes the question (name +
    // count + how far it reaches) so no surface can invent its own vaguer wording.

    func requestLibraryRemoval(_ request: LibraryRemovalRequest) {
        pendingLibraryRemoval = request
    }

    /// Songs of `albumId` that are actually in the user's library, for the confirmation's count.
    ///
    /// Counts what ``removeAlbumFromLibrary(_:)`` would really drop rather than the album's total
    /// track count, so the number in the dialog is the number that leaves. Falls back to the
    /// server's track count while the discovery index is still filling in, and to `nil` (the copy
    /// then says "every song on this album") when we know neither.
    func libraryTrackCount(forAlbumId albumId: String) -> Int? {
        let indexed = discoveryLibraryTracks.reduce(into: 0) { total, track in
            if track.albumId == albumId, librarySongIds.contains(track.id) { total += 1 }
        }
        if indexed > 0 { return indexed }
        if let cached = albumTracksCache[albumId]?.tracks {
            let inLibrary = cached.filter { librarySongIds.contains($0.id) }.count
            if inLibrary > 0 { return inLibrary }
        }
        return catalogAlbum(id: albumId)?.trackCount
    }

    /// Confirm, then remove a single song from the user's library.
    func requestRemoveSongFromLibrary(_ track: Track) {
        requestLibraryRemoval(
            LibraryRemovalCopy.song(track) { [weak self] in
                await self?.removeSongFromLibrary(track)
            }
        )
    }

    /// Confirm, then remove an album and its library songs.
    func requestRemoveAlbumFromLibrary(_ album: AlbumSummary) {
        requestLibraryRemoval(
            LibraryRemovalCopy.album(album, songCount: libraryTrackCount(forAlbumId: album.id)) { [weak self] in
                await self?.removeAlbumFromLibrary(album)
            }
        )
    }

    /// Confirm, then drop a playlist from the user's library (the playlist itself is untouched).
    func requestRemovePlaylistFromLibrary(_ playlist: PlaylistSummary) {
        requestLibraryRemoval(
            LibraryRemovalCopy.playlist(playlist) { [weak self] in
                await self?.removePlaylistFromLibrary(playlist)
            }
        )
    }

    /// Confirm, then delete the track's file from the **server** — a different act from every
    /// other entry point here, and worded as one. Jellyfin admins only (``canDeleteFromLibrary``).
    func beginLibraryTrackDeletion(_ track: Track) {
        guard canDeleteFromLibrary else { return }
        requestLibraryRemoval(
            LibraryRemovalCopy.serverTrackDelete(track) { [weak self] in
                await self?.deleteTrackFromLibrary(track)
            }
        )
    }

    private func deleteTrackFromLibrary(_ track: Track) async {
        errorMessage = nil
        do {
            switch backendKind {
            case .jellyfin:
                guard let client = jellyfin else { return }
                try await client.deleteTrackFromLibrary(trackId: track.id)
            case .navidrome:
                guard let client = navidrome else { return }
                try await client.deleteTrackFromLibrary(trackId: track.id)
            }
            favoriteTrackIds.remove(track.id)
            UserDefaults.standard.set(Array(favoriteTrackIds), forKey: Self.favoriteTrackIdsKey)
            try? offline.remove(trackId: track.id)
            player.removeTracksFromQueue(trackIds: Set([track.id]))
            libraryCatalogEpoch &+= 1
            await refreshLibraryAlbums()
            await refreshLibraryPlaylists()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshHome(forceDiscoveryReshuffle: Bool = false) async {
        guard let lib = activeLibrary else { return }
        homeRefreshInFlight = true
        defer { homeRefreshInFlight = false }
        let needsGenrePick = homeSelectedGenres == nil
        async let played = (try? await lib.recentlyPlayed(limit: 12)) ?? []
        async let genres: [LibraryGenreSummary] = {
            guard needsGenrePick else { return [] }
            return (try? await lib.libraryGenres(limit: 100)) ?? []
        }()
        let (playedResult, genresResult) = await (played, genres)
        homeRecentlyPlayedServerAlbums = playedResult
        rebuildHomeRecentlyPlayed()
        // Paint from memory immediately so the shelf doesn't pop in empty, then enrich once below.
        if homeTopPickAlbums.isEmpty {
            rebuildHomeDiscoveryShelves()
        }

        let pickedGenres: [LibraryGenreSummary]
        if let locked = homeSelectedGenres {
            pickedGenres = locked
        } else {
            pickedGenres = homeTasteGenrePicks(from: genresResult, limit: Self.homeGenreShelfCount)
            if !pickedGenres.isEmpty {
                homeSelectedGenres = pickedGenres
            }
        }

        async let genreShelfRows = withTaskGroup(of: (Int, (genre: String, albums: [AlbumSummary]))?.self) { group in
            for (idx, g) in pickedGenres.enumerated() {
                group.addTask { @MainActor in
                    let raw = (try? await lib.albums(inGenre: g, limit: Self.homeGenreShelfAlbumLimit)) ?? []
                    let albums = self.homeDiscoveryCatalogAlbums(from: raw)
                    guard !albums.isEmpty else { return nil }
                    return (idx, (genre: GenreCanonicalizer.canonical(for: g.name), albums: albums))
                }
            }
            var rows: [(Int, (genre: String, albums: [AlbumSummary]))] = []
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows
        }
        async let genrePoolAlbums = fetchHomeTopPicksGenreCandidates(using: lib, tasteGenres: pickedGenres)

        let (indexed, poolAlbums) = await (genreShelfRows, genrePoolAlbums)
        homeGenreShelves = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        rebuildHomeDiscoveryShelves(
            extraGenreAlbums: poolAlbums,
            forceReplace: forceDiscoveryReshuffle,
        )
        rebuildHomeMixes()
    }

    func playHomeMix(_ mix: HomeMix, shuffle: Bool = true) async {
        guard let lib = activeLibrary else { return }
        let tracks = mix.tracks
        guard !tracks.isEmpty else { return }
        player.shuffleMode = shuffle ? .on : .off
        do {
            try await player.playAlbum(library: lib, tracks: shuffle ? tracks.shuffled() : tracks, startIndex: 0)
            showTransientToast(shuffle ? "Shuffling \(mix.title)" : "Playing \(mix.title)")
        } catch {
            showTransientToast("Couldn't start mix")
        }
    }

    func refreshHomeMixes() {
        rebuildHomeMixes()
    }

    func homeMix(forLibraryPlaylistId id: String) -> HomeMix? {
        guard let mixId = HomeMix.mixId(fromLibraryPlaylistId: id) else { return nil }
        return homeMixes.first { $0.id == mixId }
    }

    private func rebuildHomeMixes() {
        let personalAlbumIds = Set(libraryAlbumEntries.map(\.id))
        let recentlyAddedPersonal = libraryAlbumEntries
            .sorted { $0.added > $1.added }
            .map(\.id)
        let context = HomeMixBuilder.Context(
            completedScrobbles: scrobbleService.store.completed,
            trackLookup: { [weak self] id in self?.cachedLibraryTrack(id: id) },
            artworkURL: { [weak self] track in
                guard let self else { return nil }
                return self.resolvedArtworkURL(for: track)
            },
            favoriteTrackIds: favoriteTrackIds,
            libraryAlbumIds: personalAlbumIds,
            recentlyAddedPersonalAlbumIds: recentlyAddedPersonal,
            indexedTracks: discoveryLibraryTracks
        )
        homeMixes = HomeMixBuilder.buildMixes(context)
    }

    func cachedLibraryTrack(id: String) -> Track? {
        if let track = discoveryTrackById[id] { return track }
        if let track = recentlyPlayedTracks.first(where: { $0.id == id }) { return track }
        for cached in albumTracksCache.values {
            if let track = cached.tracks.first(where: { $0.id == id }) { return track }
        }
        return nil
    }

    /// Single cold-start / sign-in library refresh (deduped).
    /// Whether a full bootstrap has already completed for the current session.
    ///
    /// The in-flight check below is not enough on its own. `RootView` kicks the bootstrap from a
    /// `.task` on the shell content, and that task is cancelled when the Now Playing cover is
    /// presented over the shell and re-fires when the shell comes back — so **every dismiss of
    /// the player re-ran a whole library bootstrap**, by which time the previous task had
    /// finished and nil'd itself, so nothing stopped it. Measured on device: each dismiss drag
    /// carried 8–22 `AppModel` publishes (`refreshLibraryAlbums` → `mergeOfflineCatalog` →
    /// `rebuildDiscoveryTrackIndices`, plus the home rebuild), every one a whole-tree
    /// invalidation across the ~40 views holding `@EnvironmentObject var app` — and one of the
    /// resulting render passes was a ~290ms SwiftUI layout+commit, which is the swipe-down lag
    /// spike. One drag in the same session happened to carry zero publishes and had no stall at
    /// all, which is what tied the two together.
    ///
    /// Reset wherever the session ends, so signing out and back in bootstraps properly.
    private var hasCompletedLibraryBootstrap = false

    public func scheduleLibraryBootstrap() {
        guard isSignedIn else { return }
        if let libraryBootstrapTask, !libraryBootstrapTask.isCancelled { return }
        // Already done for this session: a re-fired `.task` must not redo the whole thing.
        // Explicit refreshes (pull-to-refresh, "Refresh library", sync) call
        // `refreshLibraryAlbums` / `syncLibraryNow` directly and are unaffected.
        if hasCompletedLibraryBootstrap { return }
        libraryBootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.runLibraryBootstrap()
            self.hasCompletedLibraryBootstrap = true
            self.libraryBootstrapTask = nil
        }
    }

    private func runLibraryBootstrap() async {
        await PerfLog.measureAsync("runLibraryBootstrap", context: .network) {
            // Paint Home from the restored catalog immediately so cold launch isn't
            // a skeleton wall while `refreshLibraryAlbums` / genre fetches round-trip.
            if homeTopPickAlbums.isEmpty, !libraryAlbums.isEmpty {
                rebuildHomeDiscoveryShelves()
            }
            await refreshLibraryAlbums()
            recordSuccessfulLibrarySync()
            // Only the surfaces visible at launch (Home shelves + personal-library
            // membership) run during bootstrap. Statistics (Settings) and the New tab's
            // New-tab browse and discovery index are pulled when their views first appear — they were
            // contributing to the on-launch main-thread crunch without being on screen.
            async let home: Void = refreshHome()
            async let membership: Void = refreshLibraryMembership()
            _ = await (home, membership)
            startLibraryMembershipAutoSync()
        }
    }

    // MARK: - Library membership (magic playlist)

    /// Stable server identity for the magic playlist hash (host + non-default port).
    private var libraryMagicPlaylistServerKey: String? {
        LibraryMembership.normalizedServerKey(from: baseURLString)
    }

    /// Stable per-user identifier used in the magic playlist name hash + cache key.
    /// Jellyfin: the session user UUID. Navidrome: the lowercased username.
    private var libraryMagicPlaylistUserKey: String? {
        switch backendKind {
        case .jellyfin:
            let uid = jellyfin?.sessionUserId ?? ""
            return uid.isEmpty ? nil : uid
        case .navidrome:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return user.isEmpty ? nil : user
        }
    }

    /// Convenience tuple of the identifying inputs to the magic playlist + its cache.
    /// `nil` when sign-in state isn't sufficient to resolve a playlist yet.
    private var libraryMagicPlaylistIdentity: (name: String, serverKey: String?, userKey: String, baseURL: String)? {
        guard isSignedIn, let userKey = libraryMagicPlaylistUserKey else { return nil }
        let serverKey = libraryMagicPlaylistServerKey
        let name = LibraryMembership.magicPlaylistName(backend: backendKind, serverKey: serverKey, userKey: userKey)
        return (name, serverKey, userKey, baseURLString)
    }

    /// Resolves the user's magic playlist on the server (find by deterministic name,
    /// create when absent), then loads tracks + JSON membership into published state.
    /// Safe to call repeatedly — used on sign-in, foreground, and a background poll.
    func refreshLibraryMembership() async {
        guard let identity = libraryMagicPlaylistIdentity else {
            libraryMagicPlaylistId = nil
            librarySongIds = []
            libraryAlbumEntries = []
            libraryPlaylistEntries = []
            return
        }
        // Only surface the resolving spinner on the *initial* resolve (nothing shown yet).
        // Background polls already have content on screen — toggling this every cycle made
        // the Recently Added section flash a spinner.
        let isInitialResolve = libraryMagicPlaylistId == nil
        if isInitialResolve { isResolvingLibraryMembership = true }
        defer { if isInitialResolve { isResolvingLibraryMembership = false } }
        do {
            let resolvedId = try await resolveMagicPlaylistId(identity: identity)
            let fetch = try await fetchMagicPlaylistContents(playlistId: resolvedId)
            #if DEBUG
            print("[MAGIC-SYNC] resolved id=\(resolvedId) name=\(fetch.name) tracks=\(fetch.trackIds.count) commentLen=\(fetch.comment?.count ?? -1)")
            #endif
            let expectedNames = Set(
                LibraryMembership.candidateMagicPlaylistNames(
                    backend: backendKind,
                    serverKey: identity.serverKey,
                    userKey: identity.userKey,
                    baseURLString: identity.baseURL,
                )
            )
            if !expectedNames.contains(fetch.name), !LibraryMembership.isMagicPlaylistName(fetch.name) {
                // Name drift (user renamed the magic playlist via web UI). Re-resolve from scratch.
                LibraryMembership.clearCachedPlaylistId(
                    backend: backendKind, serverKey: identity.serverKey, userKey: identity.userKey,
                )
                let freshId = try await resolveMagicPlaylistId(identity: identity)
                let freshFetch = try await fetchMagicPlaylistContents(playlistId: freshId)
                applyMagicPlaylistFetch(playlistId: freshId, fetch: freshFetch)
            } else {
                applyMagicPlaylistFetch(playlistId: resolvedId, fetch: fetch)
            }
            lastLibraryMembershipRefresh = Date()
        } catch {
            // Keep cached membership and playlist id — clearing breaks add/remove until
            // the next successful refresh while UI still shows stale snapshot data.
            if libraryMagicPlaylistId == nil,
               let identity = libraryMagicPlaylistIdentity,
               let cached = LibraryMembership.cachedPlaylistId(
                   backend: backendKind, serverKey: identity.serverKey, userKey: identity.userKey
               ) {
                libraryMagicPlaylistId = cached
            }
        }
    }

    /// Foreground / manual refresh with a short debounce so rapid scene-phase churn
    /// doesn't spam the server.
    func refreshLibraryMembershipIfStale(minimumInterval: TimeInterval = 8) async {
        guard isSignedIn else { return }
        if Date().timeIntervalSince(lastLibraryMembershipRefresh) < minimumInterval { return }
        await refreshLibraryMembership()
    }

    /// Keeps the personal library converged with the server magic playlist while signed in.
    func startLibraryMembershipAutoSync() {
        guard isSignedIn, libraryMembershipSyncTask == nil else { return }
        libraryMembershipSyncTask = Task { [weak self] in
            defer { Task { @MainActor in self?.libraryMembershipSyncTask = nil } }
            while !Task.isCancelled {
                guard let self, self.isSignedIn else { return }
                await self.refreshLibraryMembership()
                // 60s convergence safety net (was 20s). Real membership edits
                // refresh immediately via the change publisher + scene-active;
                // this poll is only a backstop, so a slower cadence cuts
                // background radio wake-ups with no UX cost.
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    public func stopLibraryMembershipAutoSync() {
        libraryMembershipSyncTask?.cancel()
        libraryMembershipSyncTask = nil
    }

    private struct LibraryPlaylistFetchShape {
        let id: String
        let name: String
        let trackIds: [String]
        let comment: String?
    }

    private func resolveMagicPlaylistId(
        identity: (name: String, serverKey: String?, userKey: String, baseURL: String),
    ) async throws -> String {
        let candidateNames = LibraryMembership.candidateMagicPlaylistNames(
            backend: backendKind,
            serverKey: identity.serverKey,
            userKey: identity.userKey,
            baseURLString: identity.baseURL,
        )
        for name in candidateNames {
            if let existing = try await findMagicPlaylistByName(name) {
                LibraryMembership.cachePlaylistId(
                    existing, backend: backendKind, serverKey: identity.serverKey, userKey: identity.userKey,
                )
                return existing
            }
        }
        // One-time Lyra → Vellum migration: no `__vellum_…` playlist exists yet, so look for the
        // user's pre-rebrand `__lyra_…` playlist (same hash, old prefix) and rename it in place so
        // their existing library carries over instead of starting empty.
        if let migratedId = try await migrateLegacyLyraMagicPlaylistIfNeeded(identity: identity) {
            LibraryMembership.cachePlaylistId(
                migratedId, backend: backendKind, serverKey: identity.serverKey, userKey: identity.userKey,
            )
            return migratedId
        }
        if let cached = LibraryMembership.cachedPlaylistId(
            backend: backendKind, serverKey: identity.serverKey, userKey: identity.userKey,
        ),
           let fetch = try? await fetchMagicPlaylistContents(playlistId: cached),
           LibraryMembership.isMagicPlaylistName(fetch.name) {
            return cached
        }
        let created = try await createEmptyMagicPlaylist(name: identity.name)
        LibraryMembership.cachePlaylistId(
            created, backend: backendKind, serverKey: identity.serverKey, userKey: identity.userKey,
        )
        return created
    }

    /// Find the user's pre-rebrand `__lyra_…` magic playlist and rename it to the current
    /// `__vellum_…` name so their existing "My Library" (albums, songs, playlists, add-dates)
    /// carries over after the Lyra → Vellum rename. Returns the renamed playlist's id, or `nil`
    /// when there's nothing to migrate. Safe to call every resolve — it only fires when a legacy
    /// playlist exists and no new one does (the caller checks `__vellum_` names first).
    private func migrateLegacyLyraMagicPlaylistIfNeeded(
        identity: (name: String, serverKey: String?, userKey: String, baseURL: String),
    ) async throws -> String? {
        let legacyNames = LibraryMembership.legacyLyraMagicPlaylistNames(
            backend: backendKind,
            serverKey: identity.serverKey,
            userKey: identity.userKey,
            baseURLString: identity.baseURL,
        )
        for legacyName in legacyNames {
            guard let legacyId = try await findMagicPlaylistByName(legacyName) else { continue }
            // Rename the existing playlist in place to the new hidden name.
            try await renamePlaylist(playlistId: legacyId, name: identity.name)
            #if DEBUG
            print("[MAGIC-SYNC] migrated legacy \(legacyName) → \(identity.name) (id=\(legacyId))")
            #endif
            return legacyId
        }
        return nil
    }

    private func findMagicPlaylistByName(_ name: String) async throws -> String? {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { throw URLError(.userAuthenticationRequired) }
            return try await client.findPlaylistByName(name)?.id
        case .navidrome:
            guard let client = navidrome else { throw URLError(.userAuthenticationRequired) }
            return try await client.findPlaylistByName(name)?.id
        }
    }

    private func createEmptyMagicPlaylist(name: String) async throws -> String {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { throw URLError(.userAuthenticationRequired) }
            return try await client.createEmptyPrivatePlaylist(name: name)
        case .navidrome:
            guard let client = navidrome else { throw URLError(.userAuthenticationRequired) }
            return try await client.createEmptyPrivatePlaylist(name: name)
        }
    }

    private func fetchMagicPlaylistContents(playlistId: String) async throws -> LibraryPlaylistFetchShape {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { throw URLError(.userAuthenticationRequired) }
            let fetch = try await client.fetchLibraryPlaylist(playlistId: playlistId)
            return LibraryPlaylistFetchShape(id: fetch.id, name: fetch.name, trackIds: fetch.trackIds, comment: fetch.comment)
        case .navidrome:
            guard let client = navidrome else { throw URLError(.userAuthenticationRequired) }
            let fetch = try await client.fetchLibraryPlaylist(playlistId: playlistId)
            return LibraryPlaylistFetchShape(id: fetch.id, name: fetch.name, trackIds: fetch.trackIds, comment: fetch.comment)
        }
    }

    private func applyMagicPlaylistFetch(playlistId: String, fetch: LibraryPlaylistFetchShape) {
        let outcome = LibraryMembershipPayload.decodeOutcome(fetch.comment)
        // C15. A comment that was present and did not parse says nothing about what the user
        // has. It used to decode to an empty payload, and because a truncated read usually
        // loses the track ids too, `fetch.trackIds.isEmpty` was true as well — so the guard
        // below took the "library is genuinely empty" branch and cleared the entries. The next
        // mutation then wrote that emptiness to the server, permanently.
        //
        // Refuse instead of repairing: touch nothing, and block writes until a readable payload
        // arrives. A stale in-memory library is recoverable; an erased server one is not.
        if case .malformed = outcome {
            if !libraryMembershipWriteBlocked {
                libraryMembershipWriteBlocked = true
                showTransientToast("Couldn't read library from server")
            }
            return
        }
        libraryMembershipWriteBlocked = false
        let payload: LibraryMembershipPayload = {
            if case .valid(let decoded) = outcome { return decoded }
            return .empty
        }()
        #if DEBUG
        print("[MAGIC-SYNC] apply id=\(playlistId) tracks=\(fetch.trackIds.count) payloadAlbums=\(payload.albums.count) payloadPlaylists=\(payload.playlists.count) curEntries=\(libraryAlbumEntries.count) curCatalog=\(libraryAlbums.count)")
        #endif
        // The ~20s background poll runs this every cycle. Only mutate @Published state when it
        // actually changed — otherwise each poll reassigns identical data, fires objectWillChange,
        // and re-renders the Library, making the Recently Added shelf flicker out and back in.
        // Only mutate @Published state when the poll actually changed something —
        // otherwise each cycle re-captures the full library snapshot on the main thread.
        var didMutate = false
        if libraryMagicPlaylistId != playlistId {
            libraryMagicPlaylistId = playlistId
            didMutate = true
        }
        let newSongIds = Set(fetch.trackIds)
        if librarySongIds != newSongIds {
            librarySongIds = newSongIds
            didMutate = true
        }
        // A poll can transiently return the playlist without its comment/Overview JSON
        // (or with a garbled one), which decodes to an empty payload. Overwriting with that
        // wiped the Recently Added shelf. Only replace entries when the payload actually has
        // content, or when the library is genuinely empty (no tracks). Direct add/remove
        // mutations still update these arrays immediately.
        let payloadHasContent = !payload.albums.isEmpty || !payload.playlists.isEmpty
        if payloadHasContent || fetch.trackIds.isEmpty {
            if libraryAlbumEntries != payload.albums {
                libraryAlbumEntries = payload.albums
                didMutate = true
            }
            if libraryPlaylistEntries != payload.playlists {
                libraryPlaylistEntries = payload.playlists
                didMutate = true
            }
        }
        invalidatePlaylistRowsCache(playlistId: playlistId)
        if didMutate {
            rebuildHomeTopPicksFromMemory()
            Task { await backfillMissingLibraryAlbumSummaries() }
            if backendKind == .navidrome {
                Task { await refreshMagicPlaylistAvatar(playlistId: playlistId) }
            }
            persistLibrarySnapshot()
        } else if backendKind == .navidrome, navidromeMagicPlaylistAvatarURL == nil {
            // The avatar used to be resolved *only* when the membership payload changed.
            // On a fresh launch the first fetch usually matches the persisted snapshot, so
            // the check never ran, the URL stayed nil, and the profile picture fell back to
            // the (usually blank) Subsonic `getAvatar` until the library next mutated —
            // "the PFP resets every time the app restarts". Resolve it whenever it's unknown.
            Task { await refreshMagicPlaylistAvatar(playlistId: playlistId) }
        }
    }

    /// Asks Navidrome's native API whether the magic playlist has a user-uploaded /
    /// external image, and routes the account avatar to its `getCoverArt` URL when so.
    /// Falls back to the Subsonic `getAvatar` when there's only the auto-generated mosaic.
    ///
    /// When the cover actually changes between runs (and we already had a prior value), we
    /// kick off ``syncLibraryNow()`` — a PFP change means the user has been editing the
    /// magic playlist via Navidrome's web UI, so anything else they touched there should be
    /// pulled too. The first-ever discovery (`nil` → URL during bootstrap) is suppressed so
    /// we don't cascade a sync into the sync that just fetched the membership.
    private func refreshMagicPlaylistAvatar(playlistId: String) async {
        guard backendKind == .navidrome, let client = navidrome else { return }
        let hasCustom: Bool
        do {
            hasCustom = try await client.playlistHasCustomCover(playlistId: playlistId)
#if DEBUG
            DebugUIRemote.log("AVATAR customCover=\(hasCustom) playlist=\(playlistId)")
#endif
        } catch {
            // Swallowing this silently turned a native-API/auth failure into "no custom
            // cover" and a blank profile picture. Keep the previous URL on error instead of
            // downgrading to getAvatar, and make the failure visible in the debug log.
#if DEBUG
            DebugUIRemote.log("AVATAR customCover check FAILED playlist=\(playlistId) error=\(error)")
#endif
            return
        }
        let newURL: URL? = hasCustom ? client.coverArtURL(forId: playlistId, size: 256) : nil
        let previousURL = navidromeMagicPlaylistAvatarURL
        guard previousURL != newURL else { return }
        navidromeMagicPlaylistAvatarURL = newURL
        accountAvatarRevision &+= 1
        prefetchAccountAvatar()
        let isFirstDiscovery = (previousURL == nil)
        if !isFirstDiscovery, !isLibrarySyncing {
            Task { await syncLibraryNow() }
        }
    }

    /// Sets the user's Vellum profile picture by uploading `imageData` as the cover art of
    /// the magic playlist on Navidrome. The PFP everywhere in the app then reflects that
    /// cover automatically via ``accountAvatarURL``. Jellyfin / signed-out are no-ops.
    func updateProfilePictureFromImageData(_ imageData: Data) async {
        guard isSignedIn, backendKind == .navidrome,
              let client = navidrome,
              let playlistId = libraryMagicPlaylistId
        else {
            profilePictureUpdateError = "Sign in to Navidrome and let your library sync before changing your profile picture."
            return
        }
        isUpdatingProfilePicture = true
        defer { isUpdatingProfilePicture = false }
        do {
            try await client.uploadPlaylistImage(playlistId: playlistId, imageData: imageData)
            profilePictureUpdateError = nil
            // Force a fresh fetch by busting both our on-disk cache and URLSession's cache:
            // the `getCoverArt?id=<playlistId>` URL stays stable across uploads, so without
            // a bust the toolbar would keep serving the old bytes.
            if let identity = accountAvatarIdentity {
                AccountAvatarCache.remove(identity: identity)
            }
            let bustedURL = client.coverArtURL(forId: playlistId, size: 256)
                .map { appendCacheBust(to: $0) }
            navidromeMagicPlaylistAvatarURL = bustedURL
            accountAvatarRevision &+= 1
            prefetchAccountAvatar()
        } catch {
            profilePictureUpdateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func appendCacheBust(to url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "_ts", value: "\(Int(Date().timeIntervalSince1970))"))
        comps.queryItems = items
        return comps.url ?? url
    }

    /// Fetches AlbumSummary for any library-entry album id that isn't yet in the in-memory
    /// catalog and merges the results into `libraryAlbums`. Without this, albums the user
    /// added that fall outside the paged `albums(limit:)` listing would silently fail to
    /// render in Library → Albums and Recently Added.
    private func backfillMissingLibraryAlbumSummaries() async {
        let knownIds = Set(libraryAlbumsById.keys)
        let staleNavidromeIds = libraryAlbumEntries.map(\.id).filter { id in
            guard backendKind == .navidrome, let album = libraryAlbumsById[id] else { return false }
            return album.coverArtId == nil
        }
        let missingIds = libraryAlbumEntries.map(\.id).filter { !knownIds.contains($0) }
        let idsToFetch = Array(Set(missingIds + staleNavidromeIds))
        guard !idsToFetch.isEmpty else { return }
        PerfLog.event("backfillMissingLibraryAlbumSummaries.start", details: "missing=\(idsToFetch.count)")
        // Bounded concurrency: N sequential round-trips on first launch was a major
        // contributor to "library catalog is empty until bootstrap finishes."
        let backend = backendKind
        let jellyfinClient = jellyfin
        let navidromeClient = navidrome
        let maxConcurrent = 6
        let fetched: [AlbumSummary] = await withTaskGroup(of: AlbumSummary?.self) { group in
            var iterator = idsToFetch.makeIterator()
            var inflight = 0
            while inflight < maxConcurrent, let id = iterator.next() {
                group.addTask {
                    switch backend {
                    case .jellyfin: return try? await jellyfinClient?.albumSummary(forId: id)
                    case .navidrome: return try? await navidromeClient?.albumSummary(forId: id)
                    }
                }
                inflight += 1
            }
            var results: [AlbumSummary] = []
            results.reserveCapacity(idsToFetch.count)
            while let summary = await group.next() {
                if let summary { results.append(summary) }
                if let id = iterator.next() {
                    group.addTask {
                        switch backend {
                        case .jellyfin: return try? await jellyfinClient?.albumSummary(forId: id)
                        case .navidrome: return try? await navidromeClient?.albumSummary(forId: id)
                        }
                    }
                }
            }
            return results
        }
        guard !fetched.isEmpty else { return }
        // Idempotent merge: only touch `libraryAlbums` when a fetched summary actually differs
        // from what we already have. The ~20s poll re-runs this every cycle, and for Navidrome
        // it re-fetches albums whose `coverArtId` stays nil forever — reassigning `libraryAlbums`
        // (and reordering it) every poll re-rendered the Library and jolted the Recently Added
        // grid. Preserve existing order; append only genuinely-new albums.
        var byId = Dictionary(uniqueKeysWithValues: libraryAlbums.map { ($0.id, $0) })
        var changed = false
        for album in fetched where byId[album.id] != album {
            byId[album.id] = album
            changed = true
        }
        guard changed else { return }
        let existingIds = Set(libraryAlbums.map(\.id))
        var merged = libraryAlbums.map { byId[$0.id] ?? $0 }
        for album in fetched where !existingIds.contains(album.id) {
            merged.append(album)
        }
        libraryAlbums = merged
        persistLibrarySnapshot()
    }

    /// Re-encodes the current album/playlist membership and writes it back to the magic
    /// playlist's comment field. Safe to call after every mutation; idempotent.
    private func persistLibraryMembershipPayload() async {
        guard let playlistId = libraryMagicPlaylistId else { return }
        // C15. The last read of this playlist's membership was unreadable, so the in-memory
        // entries may not reflect what is actually on the server. Writing now would replace a
        // library we could not read with one we inferred. Blocked until a readable payload
        // arrives — see `applyMagicPlaylistFetch`.
        guard !libraryMembershipWriteBlocked else {
            showTransientToast("Library sync paused — couldn't read server copy")
            return
        }
        let payload = LibraryMembershipPayload(
            albums: libraryAlbumEntries,
            playlists: libraryPlaylistEntries,
        )
        do {
            switch backendKind {
            case .jellyfin:
                try await jellyfin?.setPlaylistOverview(playlistId: playlistId, overview: payload.encoded())
            case .navidrome:
                try await navidrome?.setPlaylistComment(playlistId: playlistId, comment: payload.encoded())
            }
        } catch {
            showTransientToast("Couldn't sync library to server")
        }
    }

    // MARK: - Library membership: queries + mutations

    /// In-memory search across the user's personal library (magic playlist contents).
    /// Empty `query` returns the full personal-library snapshot. Pure local — never
    /// hits the network. Songs are pulled from ``discoveryLibraryTracks`` (best-effort
    /// cache); items the cache hasn't loaded yet simply won't appear until it has.
    func searchPersonalLibrary(query: String) -> PersonalLibrarySearchResults {
        let albumIds = Set(libraryAlbumEntries.map(\.id))
        let playlistIds = Set(libraryPlaylistEntries.map(\.id))
        let playlistCache = Dictionary(uniqueKeysWithValues: libraryPlaylists.map { ($0.id, $0) })
        return PersonalLibrarySearch.search(
            query: query,
            songIds: librarySongIds,
            albumIds: albumIds,
            playlistIds: playlistIds,
            trackCache: discoveryLibraryTracks,
            albumCache: libraryAlbumsById,
            playlistCache: playlistCache,
        )
    }

    /// `true` when the song is in the user's magic playlist (server-backed).
    func isSongInLibrary(_ id: String) -> Bool { librarySongIds.contains(id) }

    /// `true` when the album appears in the user's library — explicit album entry
    /// on the magic playlist, or any track from the album is in ``librarySongIds``.
    func isAlbumInLibrary(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let lookups = membershipLookups
        return lookups.albumEntryIds.contains(id) || lookups.albumIdsWithLibrarySongs.contains(id)
    }

    // MARK: - Library membership fast lookups
    //
    // ``isAlbumInLibrary`` / ``isEligibleForHomeTopPick`` are called straight from SwiftUI
    // bodies — the Home shelves test every candidate album, dozens of times per render.
    // They previously linear-scanned ``discoveryLibraryTracks`` (the whole track index) and
    // re-ran ``catalogReleaseIdentityKey``'s regex normalization per owned album per call,
    // which is a multi-hundred-millisecond main-thread hang on a large library. These sets
    // are derived once per membership change instead.

    private struct MembershipLookups {
        let albumEntryIds: Set<String>
        /// Album ids with at least one track in ``librarySongIds``.
        let albumIdsWithLibrarySongs: Set<String>
        /// ``AlbumSummary/catalogReleaseIdentityKey`` for every owned album.
        let ownedReleaseKeys: Set<String>
    }

    private var membershipLookupCache: MembershipLookups?

    /// Drops the derived membership sets. Must be called from every path that mutates
    /// ``libraryAlbumEntries``, ``librarySongIds``, ``discoveryLibraryTracks`` or the
    /// album-id index.
    private func invalidateMembershipLookups() {
        membershipLookupCache = nil
    }

    private var membershipLookups: MembershipLookups {
        if let cached = membershipLookupCache { return cached }
        let entryIds = Set(libraryAlbumEntries.map(\.id))

        var albumIdsWithSongs: Set<String> = []
        if !librarySongIds.isEmpty {
            for track in discoveryLibraryTracks where !track.albumId.isEmpty {
                if librarySongIds.contains(track.id) { albumIdsWithSongs.insert(track.albumId) }
            }
        }

        var releaseKeys: Set<String> = []
        for id in entryIds {
            guard let owned = libraryAlbumsById[id] else { continue }
            releaseKeys.insert(owned.catalogReleaseIdentityKey)
        }

        let lookups = MembershipLookups(
            albumEntryIds: entryIds,
            albumIdsWithLibrarySongs: albumIdsWithSongs,
            ownedReleaseKeys: releaseKeys,
        )
        membershipLookupCache = lookups
        return lookups
    }

    /// Server-catalog rows for Home discovery shelves (Top Picks, New Releases, genres, …).
    func homeDiscoveryCatalogAlbums(from albums: [AlbumSummary]) -> [AlbumSummary] {
        albums.filter { isEligibleForHomeTopPick($0) }
    }

    /// Server-catalog album the user has **not** added to their magic-playlist library.
    func isEligibleForHomeTopPick(_ album: AlbumSummary) -> Bool {
        if isAlbumInLibrary(album.id) { return false }
        return !membershipLookups.ownedReleaseKeys.contains(album.catalogReleaseIdentityKey)
    }

    /// Removes cached offline files for the given track IDs (no-op when not downloaded).
    func removeOfflineDownloads<S: Sequence>(trackIds: S) where S.Element == String {
        for id in trackIds {
            try? offline.remove(trackId: id)
        }
    }

    func removeOfflineCachedItem(itemId: String) {
        try? offline.removeCachedItem(itemId: itemId)
    }

    func enqueueOfflineAlbum(_ album: AlbumSummary, tracks: [Track]) {
        offline.enqueueAlbum(album, tracks: tracks)
    }

    func enqueueOfflinePlaylist(_ playlist: PlaylistSummary, tracks: [Track]) {
        offline.enqueuePlaylist(playlist, tracks: tracks)
    }

    func enqueueOfflineFavorites(tracks: [Track]) {
        offline.enqueueFavorites(tracks: tracks)
    }

    func enqueueOfflineTrack(_ track: Track) {
        offline.enqueueTrack(trackWithResolvedArtwork(track))
    }

    public func handleAppBecameActive() {
        offline.handleAppBecameActive()
        Task { await evaluateAutoOfflineMode() }
        writeWidgetData()
        // Pick up any widget command that fired while the app wasn't running
        handleWidgetCommandFromNotification()
        // Resume the library-membership poll paused on background. Guarded
        // against double-start; the loop refreshes immediately on resume.
        if isSignedIn { startLibraryMembershipAutoSync() }
    }

    public func handleWidgetDeepLink(_ url: URL) {
        // Routing — including the already-open guard — lives in `WidgetDeepLink` so every
        // surface that sends one of these URLs is covered once. See that type for why the guard
        // is not in the presenting view.
        switch WidgetDeepLink.route(for: url, isNowPlayingPresented: isNowPlayingCoverPresented) {
        case .ignore:
            return
        case .openNowPlaying:
            // The Now Playing widget is about what is playing, so its tap asks for the player.
            // No id is compared: the widget may be a refresh behind, but the user tapped
            // "what's playing", and the answer to that is whatever is playing now.
            //
            // `RootView` ignores the request when nothing is loaded, so a tap on a stale widget
            // after playback ended still just opens the app rather than raising a blank cover.
            openNowPlayingRequests += 1
        case .album(let id):
            if let album = libraryAlbums.first(where: { $0.id == id }) {
                selectedTab = .library
                deepLinkTab = .library
                presentedDeepLink = .album(album)
            } else {
                selectedTab = .home
            }
        case .home:
            selectedTab = .home
        }
    }

    public func handleWidgetPlayCommand(itemId: String, itemKind: String) async {
        let currentAlbumId = player.activeTrack?.albumId.isEmpty == false
            ? player.activeTrack!.albumId
            : player.activeTrack?.id ?? ""
        if currentAlbumId == itemId {
            player.togglePlayPause()
            writeWidgetData()
            return
        }
        guard let lib = activeLibrary else { return }
        do {
            let tracks = try await lib.tracks(forAlbumId: itemId)
            guard !tracks.isEmpty else { return }
            try await player.playAlbum(library: lib, tracks: tracks, startIndex: 0)
            writeWidgetData()
        } catch {}
    }

    private func registerWidgetCommandObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.handleWidgetCommandFromNotification() }
        }, widgetCommandNotification, nil, .deliverImmediately)
    }

    deinit {
        // The widget-command observer is registered with `passUnretained(self)`; remove it so
        // a deallocated AppModel can never be invoked via a dangling pointer.
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
        )
    }

    private func handleWidgetCommandFromNotification() {
        guard let defaults = UserDefaults(suiteName: WidgetDataStore.appGroupID),
              let command = defaults.string(forKey: widgetCommandKey)
        else { return }
        defaults.removeObject(forKey: widgetCommandKey)

        switch command {
        case widgetCommandToggle:
            player.togglePlayPause()
            writeWidgetData()
        case widgetCommandPlay:
            let itemId   = defaults.string(forKey: widgetCommandPlayIdKey) ?? ""
            let itemKind = defaults.string(forKey: widgetCommandPlayKindKey) ?? "album"
            defaults.removeObject(forKey: widgetCommandPlayIdKey)
            defaults.removeObject(forKey: widgetCommandPlayKindKey)
            guard !itemId.isEmpty else { return }
            Task { await handleWidgetPlayCommand(itemId: itemId, itemKind: itemKind) }
        default: break
        }
    }

    func addHomeWifiSSID(_ ssid: String) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !homeWifiSSIDs.contains(trimmed) else { return }
        homeWifiSSIDs.append(trimmed)
        UserDefaults.standard.set(homeWifiSSIDs, forKey: Self.homeWifiSSIDsKey)
        Task { await evaluateAutoOfflineMode() }
    }

    func removeHomeWifiSSID(_ ssid: String) {
        homeWifiSSIDs.removeAll { $0 == ssid }
        UserDefaults.standard.set(homeWifiSSIDs, forKey: Self.homeWifiSSIDsKey)
        Task { await evaluateAutoOfflineMode() }
    }

    func searchOfflineCatalog(query: String, limit: Int = 30) -> CatalogSearchResults {
        offline.searchCachedCatalog(query: query, limit: limit)
    }

    func localCacheUsageSummary() -> LocalCacheUsageSummary {
        let remoteArt = ArtworkURLCache.listDiskEntries()
        let offlineArt = offline.listOfflineArtworkEntries()
        return offline.cacheUsageSummary(
            imageCacheBytes: remoteArt.reduce(0) { $0 + $1.fileBytes } + offlineArt.reduce(0) { $0 + $1.fileBytes },
            imageCacheCount: remoteArt.count + offlineArt.count,
        )
    }

    /// Off-main disk + snapshot scan for Settings rows — avoids decoding the library snapshot during scroll.
    func localCacheUsageSummaryAsync() async -> LocalCacheUsageSummary {
        let trackCount = offline.downloadedTrackIds.count
        return await Task.detached(priority: .utility) {
            OfflineDiskCacheMetrics.computeLocalCacheUsageSummary(downloadedTrackCount: trackCount)
        }.value
    }

    func clearImageCaches() async {
        await clearMediaArtworkCaches()
        offline.clearOfflineArtworkCache()
        AccountAvatarCache.clearAll()
        noteLocalCacheChanged()
    }

    func clearDownloadedMusic() {
        offline.clearAllDownloads()
        noteLocalCacheChanged()
    }

    func clearMetadataCache() {
        LibrarySnapshotStore.clear()
        PlaylistRowsCacheStore.clear()
        StreamingMediaDiskCache.shared.clear()
        // MusicBrainz payloads are metadata on disk, so a metadata clear has to take them
        // too. Expiry alone never removes them — a user asking to reclaim disk is the one
        // case where deleting a cached payload is the right answer.
        MusicBrainzCacheStore.clearAll()
        // Track lists have no expiry of their own, so a user-initiated clear is the only thing
        // that ever removes them.
        AcquisitionTrackListCache.clearAll()
        clearInMemoryPlaylistRowsCache()
        Task {
            await ArtistEnrichmentCache.shared.clear()
            await AlbumDetailArtistCatalogCache.shared.clear()
            await LidarrAcquisitionPlugin.resetSessionCaches()
        }
        noteLocalCacheChanged()
    }

    func clearAllLocalCaches() async {
        clearDownloadedMusic()
        LibrarySnapshotStore.clear()
        PlaylistRowsCacheStore.clear()
        StreamingMediaDiskCache.shared.clear()
        MusicBrainzCacheStore.clearAll()
        // Track lists have no expiry of their own, so a user-initiated clear is the only thing
        // that ever removes them.
        AcquisitionTrackListCache.clearAll()
        clearInMemoryPlaylistRowsCache()
        await ArtistEnrichmentCache.shared.clear()
        await AlbumDetailArtistCatalogCache.shared.clear()
        await LidarrAcquisitionPlugin.resetSessionCaches()
        await clearImageCaches()
    }

    private func noteLocalCacheChanged() {
        localCacheRevision &+= 1
        offline.recalculateCacheBytes()
    }

    func clearInMemoryPlaylistRowsCache() {
        playlistRowsCache.removeAll()
    }

    /// Tracks to show under Library → Downloaded: manifest records first, then library catalog matches.
    func tracksForDownloadedLibrary() -> [Track] {
        let cached = offline.cachedTracks()
        if !cached.isEmpty { return cached }
        return offline.tracksMatchingDownloadedIds(catalogById: discoveryTrackById)
    }

    /// Tracks for **Library → Songs** — loads the magic playlist from the server so every
    /// library song appears, not only rows already present in the discovery index or offline cache.
    func tracksForPersonalLibrary() async -> [Track] {
        guard isSignedIn else { return [] }

        var resolved: [Track] = []
        if let playlistId = libraryMagicPlaylistId {
            let rows: [PlaylistRowItem]
            if let cached = cachedPlaylistRows(playlistId: playlistId) {
                rows = cached
            } else if let fetched = try? await fetchPlaylistRows(playlistId: playlistId) {
                rows = fetched
            } else {
                rows = []
            }
            resolved = rows.map { trackWithResolvedArtwork($0.track) }
        }

        if !librarySongIds.isEmpty {
            if resolved.isEmpty {
                resolved = personalLibraryTracksFromCatalog()
            } else {
                let allowed = librarySongIds
                resolved = resolved.filter { allowed.contains($0.id) }
            }
        }

        var seen = Set(resolved.map(\.id))
        for track in personalLibraryTracksFromCatalog() where seen.insert(track.id).inserted {
            resolved.append(track)
        }
        return resolved
    }

    /// Best-effort resolve of ``librarySongIds`` against the in-memory catalog + offline manifest.
    func personalLibraryTracksFromCatalog() -> [Track] {
        let ids = librarySongIds
        guard !ids.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Track] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            if let track = discoveryTrackById[id], seen.insert(id).inserted {
                out.append(trackWithResolvedArtwork(track))
            }
        }
        for track in offline.cachedTracks() where ids.contains(track.id) {
            if seen.insert(track.id).inserted {
                out.append(trackWithResolvedArtwork(track))
            }
        }
        return out
    }

    /// `true` when the playlist is in the user's library (separate from the user's
    /// owned playlists — only those they explicitly added via ``addPlaylistToLibrary``).
    func isPlaylistInLibrary(_ id: String) -> Bool {
        libraryPlaylistEntries.contains(where: { $0.id == id })
    }

    /// Adds one song to the user's library. Per the locked Apple-Music model:
    ///   * Only this song is added to the magic playlist's tracks.
    ///   * The song's album is registered in `comment.albums` so the album appears in
    ///     Library → Albums; the album detail filters to the added rows.
    ///   * Other tracks of the album are *not* added — the user must Add the album
    ///     explicitly (or the song-level "+" on more rows) to grow the set.
    func addSongToLibrary(_ track: Track) async {
        guard let playlistId = libraryMagicPlaylistId else { return }
        guard !librarySongIds.contains(track.id) else { return }
        let snapshotSongs = librarySongIds
        let snapshotAlbums = libraryAlbumEntries
        librarySongIds.insert(track.id)
        if !track.albumId.isEmpty, !libraryAlbumEntries.contains(where: { $0.id == track.albumId }) {
            libraryAlbumEntries.append(.init(id: track.albumId, added: Date()))
            ensureAlbumInCatalog(albumIdOrFallback: track.albumId, derivedFrom: track)
        }
        do {
            try await addTracksToServerMagicPlaylist(playlistId: playlistId, trackIds: [track.id])
        } catch {
            librarySongIds = snapshotSongs
            libraryAlbumEntries = snapshotAlbums
            return
        }
        await persistLibraryMembershipPayload()
        persistLibrarySnapshot()
        invalidatePlaylistRowsCache(playlistId: playlistId)
        // Signal that the catalog state changed so library/album detail views
        // refetch their server rows. Without this, the album-merge view keeps its
        // pre-download `rows` snapshot — `librarySongIds` includes the new track
        // but the rows list doesn't, so the merge still classifies the preview
        // row as missing and the UI shows "needs download".
        libraryCatalogEpoch &+= 1
    }

    /// Best-effort server `Track` for a **New** tab chart row (for library-style ⋯ menus).
    func resolvedServerTrack(for chart: ChartTrack) -> Track? {
        if case .libraryTrack(let track) = newTabChartRowState(for: chart) {
            return track
        }
        return libraryChartTrackIndex.firstMatch(chart: chart)
    }

    /// Chart row on the **New** tab → a library track, a catalog album, or still missing.
    func newTabChartRowState(for chart: ChartTrack) -> NewTabChartRowState {
        if let album = resolvedNewTabServerAlbum(for: chart) {
            return .serverAlbum(album)
        }
        if let track = libraryChartTrackIndex.firstMatch(chart: chart) {
            return .libraryTrack(track)
        }
        return .missing
    }

    /// Catalog album for a chart row when the release is on the connected server.
    private func resolvedNewTabServerAlbum(for chart: ChartTrack) -> AlbumSummary? {
        if let album = libraryAlbumMatchingBrowseRelease(artist: chart.artistName, albumTitle: chart.name) {
            return album
        }
        if let track = libraryChartTrackIndex.firstMatch(chart: chart),
           let album = albumSummaryForNewTabChartTrack(track, chart: chart) {
            return album
        }
        return nil
    }

    private func albumSummaryForNewTabChartTrack(_ track: Track, chart: ChartTrack) -> AlbumSummary? {
        if let cached = libraryAlbumsById[track.albumId] {
            return cached
        }
        return AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? chart.name : track.albumTitle,
            artist: track.artist.isEmpty ? chart.artistName : track.artist,
            artworkURL: track.artworkURL,
            coverArtId: navidromeCoverArtId(for: track),
            trackCount: nil,
            libraryAddedDate: track.libraryAddedDate,
            genres: track.genres,
            releaseYear: track.releaseYear,
        )
    }

    /// First matching server album for a chart / browse release title (handles `` - Single`` variants).
    func libraryAlbumMatchingBrowseRelease(artist: String, albumTitle: String) -> AlbumSummary? {
        for title in AlbumSummary.browseReleaseTitleLookupVariants(albumTitle) {
            if let album = libraryAlbumReleaseIndex.firstMatch(artist: artist, albumTitle: title) {
                return album
            }
        }
        return nil
    }

    /// Search the connected server and merge a browse/chart release into local catalog indices.
    func reconcileBrowseChartRelease(artist: String, albumTitle: String, kind: String) async {
        let chart = ChartTrack(
            id: "browse:\(artist):\(albumTitle)",
            name: albumTitle,
            artistName: artist,
            imageURL: nil,
            playcount: 0,
            browseKind: kind
        )
        if newTabChartRowState(for: chart).isOnServer { return }
        guard let lib = activeLibrary else { return }

        for title in AlbumSummary.browseReleaseTitleLookupVariants(albumTitle) {
            if Task.isCancelled { return }
            let query = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            guard !query.isEmpty else { continue }
            let results = (try? await lib.searchCatalog(query: query, limit: 30)) ?? .empty

            for variant in AlbumSummary.browseReleaseTitleLookupVariants(albumTitle) {
                if let album = results.albums.first(where: { $0.matchesNewTabRelease(artist: artist, albumTitle: variant) }) {
                    ensureAlbumInCatalog(album)
                    if let tracks = try? await lib.tracks(forAlbumId: album.id) {
                        retainTracksForLibraryPin(tracks)
                    }
                    libraryCatalogEpoch &+= 1
                    return
                }
            }

            let matched = results.songs.filter {
                Self.serverTrackMatchesBrowseRelease($0, artist: artist, albumTitle: albumTitle, kind: kind)
            }
            retainTracksForLibraryPin(matched)

            if newTabChartRowState(for: chart).isOnServer {
                libraryCatalogEpoch &+= 1
                return
            }
        }
    }

    private static func serverTrackMatchesBrowseRelease(
        _ track: Track,
        artist: String,
        albumTitle: String,
        kind: String
    ) -> Bool {
        let chartArtists = LibraryTrackMatcher.normalizedChartArtistTokens(artist)
        guard !chartArtists.isEmpty else { return false }
        let libArtist = LibraryTrackMatcher.normalize(track.artist)
        guard !libArtist.isEmpty,
              LibraryTrackMatcher.artistsOverlap(chartArtists, Set([libArtist])) else { return false }

        for variant in AlbumSummary.browseReleaseTitleLookupVariants(albumTitle) {
            if LibraryTrackMatcher.trackMatchesChartAlbumTitle(
                track.albumTitle,
                chartAlbumTitle: variant,
                chartArtists: chartArtists,
                trackArtist: track.artist
            ) {
                return true
            }
            if kind.caseInsensitiveCompare("Single") == .orderedSame {
                let wantKeys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: variant))
                let trackKeys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: track.title))
                if !wantKeys.isDisjoint(with: trackKeys) { return true }
            }
        }
        return false
    }

    /// Probes the server catalog for **New** tab chart rows that still read as missing
    /// (common when `libraryAlbums` is a capped page but tracks/albums exist on disk).
    func reconcileNewTabChartServerPresence() async {
        guard let lib = activeLibrary else { return }
        let charts = newTabTopTracks.filter { !newTabChartRowState(for: $0).isOnServer }
        guard !charts.isEmpty else { return }

        // Collect pins across all chart probes, then apply once. Per-track retain used to
        // rebuild the full discovery index on main (~3s × N) and freeze the New tab.
        var pendingPins: [Track] = []
        pendingPins.reserveCapacity(64)

        for chart in charts {
            if Task.isCancelled { return }
            for title in AlbumSummary.browseReleaseTitleLookupVariants(chart.name) {
                let query = [chart.artistName, title].filter { !$0.isEmpty }.joined(separator: " ")
                guard !query.isEmpty else { continue }
                let results = (try? await lib.searchCatalog(query: query, limit: 24)) ?? .empty

                if chart.browseKind.caseInsensitiveCompare("Album") == .orderedSame
                    || chart.browseKind.caseInsensitiveCompare("Single") == .orderedSame {
                    for variant in AlbumSummary.browseReleaseTitleLookupVariants(chart.name) {
                        if let album = results.albums.first(where: { $0.matchesNewTabRelease(artist: chart.artistName, albumTitle: variant) }) {
                            ensureAlbumInCatalog(album)
                        }
                    }
                    pendingPins.append(contentsOf: results.songs.filter {
                        Self.serverTrackMatchesBrowseRelease(
                            $0,
                            artist: chart.artistName,
                            albumTitle: chart.name,
                            kind: chart.browseKind
                        )
                    })
                } else {
                    pendingPins.append(contentsOf: results.songs.filter {
                        LibraryTrackMatcher.trackMatchesChart($0, chart: chart)
                    })
                }

                // Cheap presence check against already-collected pins + live indices.
                retainTracksForLibraryPin(pendingPins)
                pendingPins.removeAll(keepingCapacity: true)
                if newTabChartRowState(for: chart).isOnServer { break }
            }
            if newTabChartRowState(for: chart).isOnServer { continue }
        }
        if !pendingPins.isEmpty {
            retainTracksForLibraryPin(pendingPins)
        }
        libraryCatalogEpoch &+= 1
    }

    /// Called when an acquisition job finishes (any plugin). On success, ask the backend
    /// to scan (Subsonic `startScan` / Jellyfin `Library/Refresh`) and then keep retrying
    /// `searchCatalog` until the new file surfaces — typically within a few seconds of the
    /// scan, but Navidrome/Jellyfin schedules vary so we give it up to a minute. When
    /// found, add the track to the personal library.
    func handleAcquisitionJobFinished(_ job: AcquisitionJob) async {
        guard job.status == .done else {
            if job.status == .failed {
                showTransientToast("Download failed")
            }
            return
        }
        guard let lib = activeLibrary else { return }
        let title = job.title ?? ""
        let artist = job.artist ?? ""
        guard !title.isEmpty else { return }

        let isAlbumJob = !(job.albumTitle?.isEmpty ?? true) && job.albumTitle == title

        // Kick off the server-side scan immediately so it can race the retry loop.
        Task { try? await lib.triggerLibraryScan() }

        let probe = MatchableSong(songId: job.id, name: title,
                                 artists: artist.isEmpty ? [] : [artist],
                                 albumName: job.albumTitle ?? "", url: job.id, coverURL: nil, year: nil, explicit: false)
        // ~60s total budget: 20 attempts × 3s. The early attempts catch fast scans
        // (Navidrome typically), the later ones catch slow ones (Jellyfin libraries
        // with many items). First check fires immediately in case the file was
        // already scanned by a prior pass.
        for attempt in 0..<20 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            let query = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            let results = (try? await lib.searchCatalog(query: query, limit: 30)) ?? .empty

            if isAlbumJob, let albumTitle = job.albumTitle {
                if let album = results.albums.first(where: { $0.matchesNewTabRelease(artist: artist, albumTitle: albumTitle) }) {
                    await finalizeAcquisitionCatalogAlbum(album, library: lib)
                    return
                }
                if let song = LibraryTrackMatcher.firstLibraryTrack(matching: probe, in: results.songs) {
                    await finalizeAcquisitionCatalogTrack(song)
                    return
                }
            } else if let match = LibraryTrackMatcher.firstLibraryTrack(matching: probe, in: results.songs) {
                await finalizeAcquisitionCatalogTrack(match)
                return
            }
        }
        // Downloaded but the backend hasn't surfaced it within the budget. The
        // file is on disk; the next scheduled scan will pick it up.
        showTransientToast("Downloaded “\(title)”")
    }

    private func finalizeAcquisitionCatalogTrack(_ track: Track) async {
        retainTrackForLibraryPin(track)
        await addSongToLibrary(track)
        await reconcileNewTabChartServerPresence()
        showTransientToast("Added “\(track.title)”")
    }

    private func finalizeAcquisitionCatalogAlbum(_ album: AlbumSummary, library: MusicLibraryProviding) async {
        ensureAlbumInCatalog(album)
        let tracks = (try? await library.tracks(forAlbumId: album.id)) ?? []
        retainTracksForLibraryPin(tracks)
        await addAlbumToLibrary(album, tracks: tracks.isEmpty ? nil : tracks)
        await reconcileNewTabChartServerPresence()
        showTransientToast("Added “\(album.title)”")
    }

    /// Adds every track of `album` to the magic playlist and records the album entry.
    /// Caller may supply already-loaded `tracks`; otherwise we fetch them.
    func addAlbumToLibrary(_ album: AlbumSummary, tracks providedTracks: [Track]? = nil) async {
        guard let playlistId = libraryMagicPlaylistId, let lib = activeLibrary else { return }
        let tracks: [Track]
        if let providedTracks { tracks = providedTracks } else {
            tracks = (try? await lib.tracks(forAlbumId: album.id)) ?? []
        }
        let toAdd = tracks.map(\.id).filter { !librarySongIds.contains($0) }
        let snapshotSongs = librarySongIds
        let snapshotAlbums = libraryAlbumEntries
        librarySongIds.formUnion(toAdd)
        if !libraryAlbumEntries.contains(where: { $0.id == album.id }) {
            libraryAlbumEntries.append(.init(id: album.id, added: Date()))
        }
        // Make sure the album summary is in the in-memory catalog so Library → Albums
        // renders it immediately, even when the album was loaded from a source outside
        // the first `libraryAlbums` page (search results, recently added shelf, etc.).
        ensureAlbumInCatalog(album)
        if !toAdd.isEmpty {
            do {
                try await addTracksToServerMagicPlaylist(playlistId: playlistId, trackIds: toAdd)
            } catch {
                librarySongIds = snapshotSongs
                libraryAlbumEntries = snapshotAlbums
                return
            }
        }
        await persistLibraryMembershipPayload()
        persistLibrarySnapshot()
        invalidatePlaylistRowsCache(playlistId: playlistId)
        rebuildHomeTopPicksFromMemory()
    }

    /// Appends an album to `libraryAlbums` if it isn't already cached, so views that
    /// resolve `libraryAlbumEntries` against the catalog don't drop newly-added albums.
    ///
    /// Index maintenance is **incremental** (O(1)) rather than a full rebuild: callers
    /// like ``reconcileNewTabChartServerPresence`` insert one row at a time in a loop, and
    /// a full `rebuildLibraryAlbumIndex` per row is O(catalog + tracks) of unicode folding
    /// and regex on the main actor — hundreds of milliseconds each on a real library.
    private func ensureAlbumInCatalog(_ album: AlbumSummary) {
        if libraryAlbumsById[album.id] != nil { return }
        appendCatalogAlbumIncrementally(album)
    }

    /// Batch form used by New-tab reconcile / pin restore — one skip-flag wrap for many albums.
    private func ensureAlbumsInCatalog(_ albums: [AlbumSummary]) {
        for album in albums {
            ensureAlbumInCatalog(album)
        }
    }

    /// Appends to ``libraryAlbums`` with the `didSet` rebuild suppressed, then folds the
    /// album into the derived indices by hand. Equivalent to what a full rebuild would
    /// produce, because both indices key off the same arrays this appends to.
    private func appendCatalogAlbumIncrementally(_ album: AlbumSummary) {
        let previousSkip = skipAlbumIndexRebuild
        skipAlbumIndexRebuild = true
        libraryAlbums.append(album)
        skipAlbumIndexRebuild = previousSkip
        libraryAlbumsById[album.id] = album
        libraryAlbumReleaseIndex.insert(album)
        invalidateMembershipLookups()
    }

    /// Ensures a pinned album can render in the Library hub grid before the next catalog refresh.
    func retainAlbumForLibraryPin(_ album: AlbumSummary) {
        ensureAlbumInCatalog(album)
    }

    /// Ensures a pinned song can render in the Library hub grid before the track index finishes loading.
    ///
    /// Same rule as ``ensureAlbumInCatalog(_:)`` — one appended track updates the four
    /// derived indices in place instead of rebuilding all of them over the whole library.
    func retainTrackForLibraryPin(_ track: Track) {
        retainTracksForLibraryPin([track])
    }

    /// Batch form of ``retainTrackForLibraryPin``. New-tab reconcile used to call the
    /// single-track path in a loop, which rebuilt the 50k-track title/chart indices on
    /// the main actor once per song and froze the UI. One pass, one index patch.
    func retainTracksForLibraryPin(_ tracks: [Track]) {
        var missing: [Track] = []
        missing.reserveCapacity(tracks.count)
        for track in tracks.map(trackWithResolvedArtwork) {
            if discoveryTrackById[track.id] == nil {
                missing.append(track)
            }
        }
        guard !missing.isEmpty else { return }

        let previousSkip = skipDiscoveryIndexRebuild
        skipDiscoveryIndexRebuild = true
        discoveryLibraryTracks.append(contentsOf: missing)
        skipDiscoveryIndexRebuild = previousSkip

        for resolved in missing {
            discoveryTrackById[resolved.id] = resolved
            LibraryTrackMatcher.insert(resolved, into: &libraryTrackTitleIndex)
            libraryChartTrackIndex.insert(resolved)
            // Mirrors the track-derived album merge in ``rebuildLibraryAlbumIndex``.
            if !resolved.albumId.isEmpty,
               !resolved.albumTitle.isEmpty,
               libraryAlbumsById[resolved.albumId] == nil {
                let derived = AlbumSummary(
                    id: resolved.albumId,
                    title: resolved.albumTitle,
                    artist: resolved.artist,
                    artworkURL: resolved.artworkURL,
                    coverArtId: navidromeCoverArtId(for: resolved),
                    trackCount: nil,
                    libraryAddedDate: resolved.libraryAddedDate,
                    genres: resolved.genres,
                    releaseYear: resolved.releaseYear,
                )
                libraryAlbumsById[derived.id] = derived
                libraryAlbumReleaseIndex.insert(derived)
            }
        }
        invalidateMembershipLookups()
    }

    /// Synthesizes a minimal AlbumSummary from a track and inserts it when the album
    /// isn't already known. Used by ``addSongToLibrary`` so the album appears in
    /// Library → Albums even when we never loaded its full summary.
    private func ensureAlbumInCatalog(albumIdOrFallback id: String, derivedFrom track: Track) {
        if libraryAlbumsById[id] != nil { return }
        let synthesized = AlbumSummary(
            id: id,
            title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: track.artworkURL,
            coverArtId: navidromeCoverArtId(for: track),
            trackCount: nil,
            libraryAddedDate: track.libraryAddedDate,
            genres: track.genres,
            releaseYear: track.releaseYear,
        )
        appendCatalogAlbumIncrementally(synthesized)
    }

    /// Removes a single song from the user's library (magic playlist tracks). Does NOT
    /// drop the album entry from `comment.albums` — the album stays in library and its
    /// detail view simply has one fewer track. Pair with ``removeAlbumFromLibrary`` for
    /// the full album sweep.
    func removeSongFromLibrary(_ track: Track) async {
        guard let playlistId = libraryMagicPlaylistId else { return }
        guard librarySongIds.contains(track.id) else { return }
        let snapshotSongs = librarySongIds
        librarySongIds.remove(track.id)
        do {
            try await removeTracksFromServerMagicPlaylist(
                playlistId: playlistId, trackIds: [track.id],
            )
        } catch {
            librarySongIds = snapshotSongs
            return
        }
        // Drop the album entry only when the title index is settled and no library
        // songs remain for this album — avoids removing the entry while indexing is
        // incomplete (discoveryLibraryTracks can be a partial snapshot mid-sync).
        if !track.albumId.isEmpty,
           !isIndexingLibraryTracks,
           libraryAlbumEntries.contains(where: { $0.id == track.albumId }) {
            let albumStillHasSongs = discoveryLibraryTracks.contains { other in
                other.albumId == track.albumId && librarySongIds.contains(other.id)
            }
            if !albumStillHasSongs {
                libraryAlbumEntries.removeAll { $0.id == track.albumId }
                await persistLibraryMembershipPayload()
            }
        }
        persistLibrarySnapshot()
        invalidatePlaylistRowsCache(playlistId: playlistId)
    }

    /// Removes every track of `album` from the magic playlist and drops the album entry.
    func removeAlbumFromLibrary(_ album: AlbumSummary) async {
        guard let playlistId = libraryMagicPlaylistId, let lib = activeLibrary else { return }
        // We need the album's full track list to know which IDs to drop; refetch in case
        // tracks were added on the server since last sync.
        let albumTracks = (try? await lib.tracks(forAlbumId: album.id)) ?? []
        let idsToRemove = Set(albumTracks.map(\.id)).intersection(librarySongIds)
        let snapshotSongs = librarySongIds
        let snapshotAlbums = libraryAlbumEntries
        librarySongIds.subtract(idsToRemove)
        libraryAlbumEntries.removeAll { $0.id == album.id }
        if !idsToRemove.isEmpty {
            do {
                try await removeTracksFromServerMagicPlaylist(
                    playlistId: playlistId, trackIds: idsToRemove,
                )
            } catch {
                librarySongIds = snapshotSongs
                libraryAlbumEntries = snapshotAlbums
                return
            }
        }
        await persistLibraryMembershipPayload()
        persistLibrarySnapshot()
        invalidatePlaylistRowsCache(playlistId: playlistId)
        rebuildHomeTopPicksFromMemory()
    }

    /// Registers a server playlist in the user's Vellum library. The playlist itself is
    /// untouched on the server — only our `comment` JSON gets a new entry.
    func addPlaylistToLibrary(_ playlist: PlaylistSummary) async {
        guard libraryMagicPlaylistId != nil else { return }
        guard !libraryPlaylistEntries.contains(where: { $0.id == playlist.id }) else { return }
        libraryPlaylistEntries.append(.init(id: playlist.id, added: Date()))
        await persistLibraryMembershipPayload()
        persistLibrarySnapshot()
    }

    func removePlaylistFromLibrary(_ playlist: PlaylistSummary) async {
        guard libraryMagicPlaylistId != nil else { return }
        guard libraryPlaylistEntries.contains(where: { $0.id == playlist.id }) else { return }
        libraryPlaylistEntries.removeAll { $0.id == playlist.id }
        await persistLibraryMembershipPayload()
        persistLibrarySnapshot()
    }

    private func addTracksToServerMagicPlaylist(playlistId: String, trackIds: [String]) async throws {
        guard !trackIds.isEmpty else { return }
        switch backendKind {
        case .jellyfin:
            try await jellyfin?.addTracksToPlaylist(playlistId: playlistId, trackIds: trackIds)
        case .navidrome:
            try await navidrome?.addTracksToPlaylist(playlistId: playlistId, trackIds: trackIds)
        }
    }

    /// Backend-specific quirks: Jellyfin removes by PlaylistItemId (entry id); Navidrome
    /// by zero-based index in the current playlist. Both require fetching the current
    /// playlist contents to map track ids → removal keys.
    private func removeTracksFromServerMagicPlaylist(
        playlistId: String, trackIds: Set<String>,
    ) async throws {
        guard !trackIds.isEmpty else { return }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { return }
            let rows = try await client.fetchPlaylistRows(playlistId: playlistId)
            let entryIds = rows
                .filter { trackIds.contains($0.track.id) }
                .compactMap { $0.jellyfinEntryId }
            try await client.removeTracksFromPlaylist(playlistId: playlistId, entryIds: entryIds)
        case .navidrome:
            guard let client = navidrome else { return }
            let rows = try await client.fetchPlaylistRows(playlistId: playlistId)
            let indexes = rows
                .filter { trackIds.contains($0.track.id) }
                .compactMap(\.navidromeIndex)
            try await client.removeTracksFromPlaylist(playlistId: playlistId, indexes: indexes)
        }
    }

    private func rebuildLibraryAlbumIndex() {
        if skipAlbumIndexRebuild {
            if isCoalescingLibraryIndexRebuild {
                pendingAlbumIndexRebuild = true
            }
            return
        }
        PerfLog.measure("rebuildLibraryAlbumIndex", details: "albums=\(libraryAlbums.count) tracks=\(discoveryLibraryTracks.count)") {
            var merged = libraryAlbums
            var seenIds = Set(libraryAlbums.map(\.id))
            for track in discoveryLibraryTracks {
                guard !track.albumId.isEmpty, !track.albumTitle.isEmpty else { continue }
                guard seenIds.insert(track.albumId).inserted else { continue }
                merged.append(
                    AlbumSummary(
                        id: track.albumId,
                        title: track.albumTitle,
                        artist: track.artist,
                        artworkURL: track.artworkURL,
                        coverArtId: navidromeCoverArtId(for: track),
                        trackCount: nil,
                        libraryAddedDate: track.libraryAddedDate,
                        genres: track.genres,
                        releaseYear: track.releaseYear,
                    )
                )
            }
            libraryAlbumsById = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            libraryAlbumReleaseIndex = LibraryAlbumReleaseIndex(albums: merged)
            // Owned release keys are derived from this index.
            invalidateMembershipLookups()
        }
    }

    /// Set while ``refreshLibraryTrackMatchIndex`` is doing the index work off-main
    /// and the resulting structures will be written directly. Suppresses the on-main
    /// rebuild that would otherwise duplicate the work in `didSet`.
    private var skipDiscoveryIndexRebuild = false
    /// Companion to ``skipDiscoveryIndexRebuild`` for the album index. Suppresses the
    /// ``libraryAlbums`` `didSet` rebuild while a coalesced batch is mutating state.
    private var skipAlbumIndexRebuild = false
    /// True while inside ``withCoalescedLibraryIndexRebuild`` so nested calls defer the
    /// single settle-time rebuild to the outermost scope.
    private var isCoalescingLibraryIndexRebuild = false
    /// Dirty flags for the coalesced rebuild — album-only mutations must not pay for a
    /// full 50k-track title/chart rebuild (that was freezing cold-launch bootstrap).
    private var pendingDiscoveryIndexRebuild = false
    private var pendingAlbumIndexRebuild = false

    /// Runs `mutate` with the ``libraryAlbums`` / ``discoveryLibraryTracks`` `didSet`
    /// index rebuilds suppressed, then rebuilds only the indices that were touched.
    /// Bootstrap and refresh reassign these arrays several times in a row (snapshot
    /// restore → offline merges → server refresh); without this each assignment ran a
    /// full O(n) main-thread rebuild. Nested calls defer to the outermost scope.
    private func withCoalescedLibraryIndexRebuild(_ mutate: () -> Void) {
        let wasCoalescing = isCoalescingLibraryIndexRebuild
        let prevSkipDiscovery = skipDiscoveryIndexRebuild
        let prevSkipAlbum = skipAlbumIndexRebuild
        isCoalescingLibraryIndexRebuild = true
        skipDiscoveryIndexRebuild = true
        skipAlbumIndexRebuild = true
        if !wasCoalescing {
            pendingDiscoveryIndexRebuild = false
            pendingAlbumIndexRebuild = false
        }
        mutate()
        isCoalescingLibraryIndexRebuild = wasCoalescing
        skipDiscoveryIndexRebuild = prevSkipDiscovery
        skipAlbumIndexRebuild = prevSkipAlbum
        guard !wasCoalescing else { return }
        if pendingDiscoveryIndexRebuild {
            rebuildDiscoveryTrackIndices()
        } else if pendingAlbumIndexRebuild {
            // Album-only mutations (bootstrap `refreshLibraryAlbums`) must not scan
            // every discovery track — that was ~100ms+ of wasted main-thread work and
            // used to pair with a full discovery rebuild before dirty flags existed.
            PerfLog.measure("rebuildLibraryAlbumIndex.albumsOnly", details: "albums=\(libraryAlbums.count)") {
                libraryAlbumsById = Dictionary(
                    libraryAlbums.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                libraryAlbumReleaseIndex = LibraryAlbumReleaseIndex(albums: libraryAlbums)
                invalidateMembershipLookups()
            }
        }
        pendingDiscoveryIndexRebuild = false
        pendingAlbumIndexRebuild = false
    }

    /// Rebuild both the title-index (used by the request backend match-Bool checks) and the
    /// chart-track index (used by New tab `Track` lookups) when the discovery
    /// snapshot is reassigned. Centralized so no caller can update one and forget
    /// the other.
    private func rebuildDiscoveryTrackIndices() {
        if skipDiscoveryIndexRebuild {
            if isCoalescingLibraryIndexRebuild {
                pendingDiscoveryIndexRebuild = true
            }
            return
        }
        PerfLog.measure("rebuildDiscoveryTrackIndices", details: "tracks=\(discoveryLibraryTracks.count)") {
            discoveryTrackById = Dictionary(discoveryLibraryTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            libraryTrackTitleIndex = LibraryTrackMatcher.titleIndex(from: discoveryLibraryTracks)
            libraryChartTrackIndex = LibraryChartTrackIndex(tracks: discoveryLibraryTracks)
            rebuildLibraryAlbumIndex()
        }
    }

    public func refreshLibraryAlbums(limit: Int = AppModel.defaultLibraryAlbumFetchLimit) async {
        guard let lib = activeLibrary else { return }
        libraryAlbumsLoadError = nil
        do {
            async let all = lib.albums(limit: limit)
            async let recent = lib.recentlyAdded(limit: 60)
            let fetched = try await all
            PerfLog.event("refreshLibraryAlbums.fetched", details: "count=\(fetched.count) limit=\(limit)")
            // The server's paged listing caps at `limit`; personal-library albums that fall
            // outside that page were previously dropped here and then re-added by
            // `backfillMissingLibraryAlbumSummaries`, oscillating `libraryAlbums` and flickering
            // the Recently Added shelf. Preserve summaries for personal-library album ids that
            // aren't in the fresh fetch so they stay put.
            let fetchedIds = Set(fetched.map(\.id))
            let personalIds = Set(libraryAlbumEntries.map(\.id))
            let preserved = libraryAlbums.filter { personalIds.contains($0.id) && !fetchedIds.contains($0.id) }
            withCoalescedLibraryIndexRebuild {
                libraryAlbums = fetched + preserved
                mergeOfflineCatalog()
            }
            recentlyAddedAlbums = (try? await recent) ?? []
            persistLibrarySnapshot()
            if let lib = activeLibrary {
                let genreAlbums = await fetchHomeTopPicksGenreCandidates(
                    using: lib,
                    tasteGenres: homeSelectedGenres ?? [],
                )
                rebuildHomeDiscoveryShelves(extraGenreAlbums: genreAlbums)
            } else {
                rebuildHomeDiscoveryShelves()
            }
            // Discovery / the request backend-match index is deferred — building it for tens of
            // thousands of tracks blocked the main thread on first launch. Views that
            // need it (LibrarySongsView, MusicNewTabView, DiscoverySearchView) call
            // ``scheduleDiscoveryTrackIndexRefreshIfNeeded`` on appear.
            await refreshFavoritesFromServer()
            await refreshLibraryPlaylists()
        } catch {
            libraryAlbumsLoadError = error.localizedDescription
            restoreLibraryFromDisk()
        }
    }

    func dismissPlaylistPicker() {
        #if canImport(UIKit)
        // Matches ``presentAddToPlaylist`` — the picker is always the UIKit presenter's sheet
        // on iOS, so dismiss it there and never clear a SwiftUI binding that could pop the cover.
        OverPlayerSheetPresenter.shared.dismiss()
        #else
        playlistPickerPayload = nil
        #endif
    }

    func presentAddToPlaylist(tracks: [Track]) {
        guard !tracks.isEmpty, isSignedIn else { return }
        let payload = PlaylistPickerPayload(tracks: tracks)
        #if canImport(UIKit)
        // Always present via the UIKit presenter so no SwiftUI `.sheet` ever coexists with the
        // Now Playing full-screen cover on the root host (the iOS 26.6 `_dismissViewController…`
        // abort). Visually identical (`.pageSheet`); the presenter targets whatever is topmost.
        OverPlayerSheetPresenter.shared.present(payload: payload, app: self)
        #else
        playlistPickerPayload = payload
        #endif
    }

    /// Shows a brief bottom toast (~1.8s) and fires a soft impact haptic. Replaces any
    /// in-flight toast so rapid actions don't pile up.
    func showTransientToast(_ message: String) {
        showTransientToast(TransientToastContent(title: message))
    }

    /// Rich variant — artwork + subtitle, used for Apple-Music-style
    /// "1 song added · ‹playlist›" confirmations from the add-to-playlist sheet.
    func showTransientToast(_ content: TransientToastContent) {
        transientToast = content
        transientToastTask?.cancel()
        transientToastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if self.transientToast == content { self.transientToast = nil }
            }
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }

    /// Refreshes ``libraryPlaylists`` from the active server (Jellyfin / Navidrome).
    /// Filters out the Vellum magic playlist by both id and `__vellum_` name prefix so it
    /// never appears in user-facing playlist surfaces.
    func refreshLibraryPlaylists() async {
        // C78. This used to be `(try? await …) ?? []`, which turned any thrown error — a dropped
        // connection, an auth blip, a 500 — into an empty list. `libraryPlaylists` was then set
        // to `[]`, and the next `persistLibrarySnapshot()` wrote `playlists: []` over the good
        // snapshot on disk. The load path guards with `if !snap.playlists.isEmpty`, but by then
        // the disk copy is already gone, so there is nothing left to guard.
        //
        // An error is not a fact about the user's playlists. On failure the existing list is
        // left exactly as it is and nothing is persisted; the next successful refresh replaces
        // it. Sign-out clears `libraryPlaylists` explicitly elsewhere, so a missing client here
        // is a transient state to wait out, not a reason to erase.
        let fetched: [PlaylistSummary]?
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { return }
            fetched = try? await client.fetchPlaylistSummaries()
        case .navidrome:
            guard let client = navidrome else { return }
            fetched = try? await client.fetchPlaylistSummaries()
        }
        guard let fetched else {
            libraryPlaylistsFetchFailed = true
            return
        }
        libraryPlaylistsFetchFailed = false
        libraryPlaylists = filterOutMagicPlaylist(fetched)
        rebuildHomeRecentlyPlayed()
        warmPlaylistRowsCache()
    }

    /// Apple-Music-style sync-ahead: resolve and persist tracklists for the user's
    /// playlists in the background so the *first* open of any playlist hydrates from
    /// cache instantly. Without this, a large playlist (1000+ songs) costs a full
    /// network fetch behind a spinner on first open. Serial, low-priority, and a
    /// no-op for playlists already cached with a matching song count.
    private func warmPlaylistRowsCache() {
        guard playlistRowsDiskRestoreCompleted, isSignedIn, !effectiveOfflineMode else { return }
        let missing = libraryPlaylists.filter { playlistRowsCache[$0.id] == nil }
        let stale = libraryPlaylists.filter { p in
            guard let cached = playlistRowsCache[p.id], let count = p.songCount else { return false }
            return cached.count != count
        }
        let candidates = Array((missing + stale).prefix(40))
        guard !candidates.isEmpty else { return }
        playlistRowsWarmupTask?.cancel()
        playlistRowsWarmupTask = Task(priority: .utility) { [weak self] in
            for playlist in candidates {
                guard let self, !Task.isCancelled else { return }
                guard self.isSignedIn, !self.effectiveOfflineMode else { return }
                _ = try? await self.fetchPlaylistRows(playlistId: playlist.id)
            }
        }
    }

    /// Strips the Vellum magic playlist from any list of server playlists. Belt-and-braces:
    /// matches by cached id when known *and* by `__vellum_` name prefix as a safety net.
    private func filterOutMagicPlaylist(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        let magicId = libraryMagicPlaylistId
        return playlists.filter { p in
            if let magicId, p.id == magicId { return false }
            if LibraryMembership.isMagicPlaylistName(p.name) { return false }
            return true
        }
    }

    func cachedPlaylistRows(playlistId: String) -> [PlaylistRowItem]? {
        playlistRowsCache[playlistId]
    }

    func prefetchPlaylistRows(playlistId: String) async {
        guard playlistRowsCache[playlistId] == nil else { return }
        _ = try? await fetchPlaylistRows(playlistId: playlistId)
    }

    func invalidatePlaylistRowsCache(playlistId: String) {
        playlistRowsCache.removeValue(forKey: playlistId)
    }

    /// Awaits a shared fetch task but forwards the *caller's* cancellation into
    /// it. `Task.value` alone is not a cancellation-responsive suspension — a
    /// detail view whose `.task` got cancelled by an immediate swipe-back would
    /// otherwise sit out the entire network fetch before it could bail, keeping
    /// its dismissal cleanup hostage. Cancelling the fetch is safe: the rows
    /// cache simply re-fills on the next open.
    private func cancellableValue<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func fetchPlaylistRows(playlistId: String) async throws -> [PlaylistRowItem] {
        // Concurrent callers (Go to Playlist prefetch + the pushed detail view's
        // load) share one network request instead of issuing duplicates. Skip an
        // in-flight task that's already been cancelled (a detail view that was
        // opened and immediately swiped away) so a quick reopen starts fresh
        // instead of inheriting the doomed fetch.
        if let inFlight = playlistRowsFetchTasks[playlistId], !inFlight.isCancelled {
            return try await cancellableValue(of: inFlight)
        }
        let task = Task { [backendKind, jellyfin, navidrome] () throws -> [PlaylistRowItem] in
#if DEBUG
            // Verification hook: lets UI tests stretch the fetch so it lands
            // inside a dismissal gesture deterministically (on-device the
            // gesture is instant and the network slow; on the simulator the
            // synthesized gesture is slow and the network fast).
            if let ms = ProcessInfo.processInfo.environment["VELLUM_DEBUG_SLOW_ROWS_MS"],
               let delay = UInt64(ms) {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
#endif
            switch backendKind {
            case .jellyfin:
                guard let client = jellyfin else {
                    throw URLError(.userAuthenticationRequired)
                }
                return try await client.fetchPlaylistRows(playlistId: playlistId)
            case .navidrome:
                guard let client = navidrome else {
                    throw URLError(.userAuthenticationRequired)
                }
                return try await client.fetchPlaylistRows(playlistId: playlistId)
            }
        }
        playlistRowsFetchTasks[playlistId] = task
        defer { playlistRowsFetchTasks.removeValue(forKey: playlistId) }
        let rows = try await cancellableValue(of: task)
        // Persist only when membership/order actually changed: every save encodes
        // the *entire* multi-playlist cache, and the detail view refreshes on each
        // open — re-encoding megabytes of unchanged JSON per visit is pure churn.
        let unchanged = playlistRowsCache[playlistId].map { $0.map(\.rowId) == rows.map(\.rowId) } ?? false
        playlistRowsCache[playlistId] = rows
        if !unchanged {
            persistPlaylistRowsCache()
        }
        return rows
    }

    @discardableResult
    func createPlaylist(name: String, initialTracks: [Track] = [], isPublic: Bool = false) async throws -> PlaylistSummary {
        let ids = initialTracks.map(\.id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "VellumMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist name cannot be empty."])
        }
        let summary: PlaylistSummary
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            summary = try await client.createPlaylist(name: trimmed, trackIds: ids, isPublic: isPublic)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            summary = try await client.createPlaylist(name: trimmed, trackIds: ids, isPublic: isPublic)
        }
        recordPlaylistCreated(summary.id)
        await refreshLibraryPlaylists()
        return summary
    }

    /// Adds tracks to a playlist, skipping any already present (per the cached
    /// rows, when known) so a double-tap or re-add doesn't create duplicates.
    /// Returns the number of tracks actually sent to the server (0 = all dupes).
    @discardableResult
    func addTracksToPlaylist(playlistId: String, tracks: [Track]) async throws -> Int {
        var pending = tracks
        if let existing = cachedPlaylistRows(playlistId: playlistId) {
            let existingIds = Set(existing.map(\.track.id))
            pending = tracks.filter { !existingIds.contains($0.id) }
        }
        let ids = pending.map(\.id)
        guard !ids.isEmpty else { return 0 }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.addTracksToPlaylist(playlistId: playlistId, trackIds: ids)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.addTracksToPlaylist(playlistId: playlistId, trackIds: ids)
        }
        // Rows changed — drop the stale cached copy so the next open refetches.
        invalidatePlaylistRowsCache(playlistId: playlistId)
        await refreshLibraryPlaylists()
        return ids.count
    }

    func removePlaylistRow(playlistId: String, row: PlaylistRowItem) async throws {
        try await removePlaylistRows(playlistId: playlistId, rows: [row])
    }

    /// Removes rows from a server playlist.
    ///
    /// **Callers may pass stale rows, and that is on purpose.** Every removal target is
    /// re-resolved against a fresh fetch by stable track id before anything reaches the server,
    /// because a Navidrome `navidromeIndex` is a *position* that only means what it says against
    /// the fetch it came from. A view that keeps its rows across a removal (`PlaylistEditSheet`,
    /// the Kill Mode list) is holding indices that have shifted down, and sending one verbatim
    /// deletes whichever song now sits there. Doing the re-resolve here rather than in each
    /// caller means no future surface can reintroduce that by forgetting to ask.
    func removePlaylistRows(playlistId: String, rows: [PlaylistRowItem]) async throws {
        guard !rows.isEmpty else { return }
        let (resolved, goneTrackIds, liveTrackIds) = try await resolveRowsForRemoval(playlistId: playlistId, rows: rows)
        // A target already removed elsewhere (another client, an earlier interrupted batch) is in
        // the desired end state — drop its pending mark and remove the rest instead of failing.
        if !goneTrackIds.isEmpty {
            killModeTracksLeftPlaylist(playlistId: playlistId, trackIds: PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
                candidates: goneTrackIds,
                liveTrackIds: liveTrackIds,
                committedRowTrackIds: []
            ))
            invalidatePlaylistRowsCache(playlistId: playlistId)
        }
        guard !resolved.isEmpty else {
            await refreshLibraryPlaylists()
            return
        }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            let entries = resolved.compactMap(\.jellyfinEntryId)
            guard entries.count == resolved.count else {
                throw NSError(domain: "VellumMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist entry id."])
            }
            try await client.removeTracksFromPlaylist(playlistId: playlistId, entryIds: entries)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            // One index per request, highest first, so earlier deletions can't shift
            // the positions still pending. Removal isn't atomic: on a mid-batch
            // failure the rows already deleted server-side must still lose their
            // Kill Mode pending marks, or a retry would abort on the id mismatch.
            let targets = try PlaylistRemovalTargeting.navidromeDeletionOrder(resolved)
            // A list, not a set: two rows of one song are two removals, and only the count tells
            // whether the song still has a row left.
            var removedIds: [String] = []
            do {
                for target in targets {
                    try await client.removeTracksFromPlaylist(playlistId: playlistId, indexes: [target.index])
                    removedIds.append(target.trackId)
                }
            } catch {
                killModeTracksLeftPlaylist(playlistId: playlistId, trackIds: PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
                    candidates: Set(removedIds),
                    liveTrackIds: liveTrackIds,
                    committedRowTrackIds: removedIds
                ))
                invalidatePlaylistRowsCache(playlistId: playlistId)
                await refreshLibraryPlaylists()
                throw error
            }
        }
        killModeTracksLeftPlaylist(playlistId: playlistId, trackIds: PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
            candidates: Set(resolved.map(\.track.id)),
            liveTrackIds: liveTrackIds,
            committedRowTrackIds: resolved.map(\.track.id)
        ))
        invalidatePlaylistRowsCache(playlistId: playlistId)
        await refreshLibraryPlaylists()
    }

    // MARK: - Kill Mode

    func isKillModeEnabled(playlistId: String) -> Bool {
        killModeEnabledPlaylistIds.contains(playlistId)
    }

    func toggleKillMode(playlistId: String) {
        if killModeEnabledPlaylistIds.contains(playlistId) {
            killModeEnabledPlaylistIds.remove(playlistId)
        } else {
            killModeEnabledPlaylistIds.insert(playlistId)
        }
        KillModeStore.saveEnabled(killModeEnabledPlaylistIds)
    }

    /// Membership lookup (unordered) — for badge counts and `contains` checks.
    func killModePendingTrackIds(playlistId: String) -> Set<String> {
        Set(killModePendingRemovals[playlistId] ?? [])
    }

    /// Ordered (newest skip first) — for the kill list view.
    func killModePendingOrderedTrackIds(playlistId: String) -> [String] {
        killModePendingRemovals[playlistId] ?? []
    }

    func clearKillModePending(playlistId: String) {
        guard killModePendingRemovals[playlistId] != nil else { return }
        killModePendingRemovals[playlistId] = nil
        KillModeStore.savePending(killModePendingRemovals)
        invalidateKillModeListenedCache()
    }

    /// Track ids "kept (green)" — played fully to their natural end under Kill Mode.
    func killModePassedTrackIds(playlistId: String) -> Set<String> {
        killModePassedTracks[playlistId] ?? []
    }

    /// The full "listened" set for a playlist: skipped (red) ∪ kept (green). These are
    /// excluded from future runs so each song plays once until listen history is cleared.
    func killModeListenedTrackIds(playlistId: String) -> Set<String> {
        if let cached = killModeListenedCache[playlistId] { return cached }
        let set = killModePendingTrackIds(playlistId: playlistId).union(killModePassedTrackIds(playlistId: playlistId))
        killModeListenedCache[playlistId] = set
        return set
    }

    /// Clears the "kept (green)" set only — kept songs become eligible to play again on
    /// the next run so the user can do another culling pass over the leftovers. The
    /// pending-removal (red) queue is left intact for review.
    func clearKillModeListenHistory(playlistId: String) {
        guard killModePassedTracks[playlistId] != nil else { return }
        killModePassedTracks[playlistId] = nil
        KillModeStore.savePassed(killModePassedTracks)
        invalidateKillModeListenedCache()
    }

    /// Filters a playlist's tracks for a Kill Mode run: drops already-listened songs so
    /// each plays once. An explicitly-chosen start track is always kept (an override, even
    /// if it was listened). Returns the filtered tracks and the remapped start index.
    /// Pass-through (no change) when the source isn't a kill-mode playlist.
    /// `keepStartTrack` distinguishes an explicit song tap (always honor the user's
    /// choice, listened or not) from the hero Play/Shuffle actions (start on the
    /// first unheard song). Returns an empty track list when every song has been
    /// listened — callers surface a toast instead of starting playback.
    /// True when Kill Mode's playback filter should stand down for this playlist, because every
    /// song the user is KEEPING has been listened to.
    ///
    /// - **Unlock only at 100%, never at 99.** This compares two `Int` counts with `==`. There is no
    ///   `Double`, no percentage and no rounding anywhere on this path, deliberately: 199 of 200 is
    ///   99.5%, which `Int((… * 100).rounded())` renders as "100%" — a displayed value that must
    ///   never reach a gate. Counting integers cannot round up.
    /// - **Only songs NOT scheduled for deletion count.** The pending-removal set is excluded from
    ///   both sides of the comparison, so marking a song for removal shrinks the denominator rather
    ///   than leaving an unreachable target.
    ///
    /// When EVERY song is scheduled for deletion the denominator is zero. That returns `false`, not
    /// `true`: an empty set satisfies "all listened" vacuously, but there is nothing being kept and
    /// therefore nothing to unlock. Playback of the removal queue keeps its existing behaviour.
    func killModeUnlockedForFullPlayback(playlistId: String, tracks: [Track]) -> Bool {
        guard killModeEnabledPlaylistIds.contains(playlistId) else { return false }
        return Self.killModeUnlocked(
            trackIds: tracks.lazy.map(\.id),
            pending: killModePendingTrackIds(playlistId: playlistId),
            passed: killModePassedTrackIds(playlistId: playlistId)
        )
    }

    /// The counting behind ``killModeUnlockedForFullPlayback(playlistId:tracks:)``, without the
    /// enabled check.
    static func killModeUnlocked<S: Sequence>(
        trackIds: S,
        pending: Set<String>,
        passed: Set<String>
    ) -> Bool where S.Element == String {
        var keptCount = 0
        var listenedKeptCount = 0
        for id in trackIds where !pending.contains(id) {
            keptCount += 1
            if passed.contains(id) { listenedKeptCount += 1 }
        }
        guard keptCount > 0 else { return false }
        return listenedKeptCount == keptCount
    }

    /// Kill Mode's unlock decision for the queue now playing, taken once, when that queue was built
    /// (``PlaybackEngine/onQueueReplaced``). Nil when the queue is not a kill-mode playlist run.
    ///
    /// Taken once rather than re-evaluated per advance because a live check flips mid-run: the
    /// moment the last unheard song completes, every kept song is green, and a live check would
    /// carry straight on into songs this run was started to avoid.
    private var killModeRunGate: (playlistId: String, unlocked: Bool)?

    private func captureKillModeRunGate() {
        guard case let .playlist(p)? = player.playbackSource,
              killModeEnabledPlaylistIds.contains(p.id) else {
            killModeRunGate = nil
            return
        }
        killModeRunGate = (p.id, killModeUnlockedForFullPlayback(playlistId: p.id, tracks: player.queue))
    }

    /// Kill Mode's auto-advance exclusion for the current queue. Hand-queued single songs are
    /// exempted before this is asked, by the engine (``UserQueueProvenance``).
    private func killModeExcludesFromAutoAdvance(_ track: Track) -> Bool {
        guard case let .playlist(p)? = player.playbackSource,
              killModeEnabledPlaylistIds.contains(p.id) else { return false }
        let runUnlocked = killModeRunGate?.playlistId == p.id && killModeRunGate?.unlocked == true
        return Self.killModeAutoAdvanceExcludes(
            isListened: killModeListenedTrackIds(playlistId: p.id).contains(track.id),
            isPending: runUnlocked && killModePendingRemovals[p.id]?.contains(track.id) == true,
            runUnlocked: runUnlocked
        )
    }

    /// Whether auto-advance may move into a song. A locked run skips everything listened; an
    /// unlocked run plays the same set the unlocked start filter does — every song not marked red.
    static func killModeAutoAdvanceExcludes(isListened: Bool, isPending: Bool, runUnlocked: Bool) -> Bool {
        runUnlocked ? isPending : isListened
    }

    func killModeFilteredPlayback(
        tracks: [Track],
        startIndex: Int,
        source: PlaybackSource?,
        keepStartTrack: Bool = true,
    ) -> (tracks: [Track], startIndex: Int) {
        guard case let .playlist(p)? = source else { return (tracks, startIndex) }
        return Self.killModeFilteredPlayback(
            tracks: tracks,
            startIndex: startIndex,
            keepStartTrack: keepStartTrack,
            isKillModeEnabled: killModeEnabledPlaylistIds.contains(p.id),
            pending: killModePendingTrackIds(playlistId: p.id),
            passed: killModePassedTrackIds(playlistId: p.id)
        )
    }

    /// The filter behind ``killModeFilteredPlayback(tracks:startIndex:source:keepStartTrack:)``,
    /// given one playlist's marks.
    static func killModeFilteredPlayback(
        tracks: [Track],
        startIndex: Int,
        keepStartTrack: Bool,
        isKillModeEnabled: Bool,
        pending: Set<String>,
        passed: Set<String>
    ) -> (tracks: [Track], startIndex: Int) {
        guard isKillModeEnabled else { return (tracks, startIndex) }
        // Unlocked at 100%: every kept song has been listened to, so the filter stands down and the
        // playlist plays again instead of returning nothing. Songs queued for removal stay out —
        // the user has already decided on those, and they leave when the removal is confirmed.
        if killModeUnlocked(trackIds: tracks.lazy.map(\.id), pending: pending, passed: passed) {
            let kept = tracks.filter { !pending.contains($0.id) }
            let startId = tracks.indices.contains(startIndex) ? tracks[startIndex].id : nil
            let unlockedStart = startId.flatMap { id in kept.firstIndex { $0.id == id } } ?? 0
            return (kept, unlockedStart)
        }
        let listened = pending.union(passed)
        guard !listened.isEmpty else { return (tracks, startIndex) }
        let startId = tracks.indices.contains(startIndex) ? tracks[startIndex].id : nil
        let filtered = tracks.enumerated().filter { idx, track in
            (keepStartTrack && idx == startIndex) || !listened.contains(track.id)
        }.map(\.element)
        let newStart = startId.flatMap { id in filtered.firstIndex { $0.id == id } } ?? 0
        return (filtered, newStart)
    }

    static let killModeEverythingListenedMessage =
        "Every song here has been listened. Clear listen history in Kill Mode to start over."

    /// A whole-collection action: the playlist or album hero buttons, and the same three items in
    /// a cell's long-press menu. Row taps are not collections — they go through ``playAlbumOrToast``.
    enum CollectionPlayIntent: Equatable {
        case play
        case shuffle
        case playNext
    }

    /// What a ``CollectionPlayIntent`` will do, decided without a player so it can be tested.
    struct CollectionPlaybackPlan {
        enum Action: Equatable {
            /// Replace the queue. `shuffled` routes to `playAlbumShuffled`, the only call that
            /// turns ``PlaybackEngine/shuffleMode`` on.
            case start(shuffled: Bool)
            /// Insert after the current track, through the collection entry point.
            case insertNext
            /// Kill Mode has nothing unheard left — say so rather than play nothing.
            case everythingListened
        }

        let action: Action
        let tracks: [Track]
        let startIndex: Int
    }

    /// Every collection action applies Kill Mode's filter the way hero Play does: listened songs
    /// are dropped and play starts on the first unheard song, never on a listened row 0.
    ///
    /// Play Next is filtered **before** the insert. The auto-advance exclusion only filters when
    /// the playing source is this playlist, so a Play Next onto any other queue would otherwise
    /// replay every listened song — the collection rule has to hold wherever the songs land.
    static func collectionPlaybackPlan(
        intent: CollectionPlayIntent,
        tracks: [Track],
        isKillModeEnabled: Bool,
        pending: Set<String>,
        passed: Set<String>
    ) -> CollectionPlaybackPlan {
        let filtered = killModeFilteredPlayback(
            tracks: tracks,
            startIndex: 0,
            keepStartTrack: false,
            isKillModeEnabled: isKillModeEnabled,
            pending: pending,
            passed: passed
        )
        guard !filtered.tracks.isEmpty else {
            return CollectionPlaybackPlan(action: .everythingListened, tracks: [], startIndex: 0)
        }
        switch intent {
        case .play:
            return CollectionPlaybackPlan(action: .start(shuffled: false), tracks: filtered.tracks, startIndex: filtered.startIndex)
        case .shuffle:
            return CollectionPlaybackPlan(action: .start(shuffled: true), tracks: filtered.tracks, startIndex: 0)
        case .playNext:
            return CollectionPlaybackPlan(action: .insertNext, tracks: filtered.tracks, startIndex: 0)
        }
    }

    /// The one path for whole-collection Play / Shuffle / Play Next, shared by the playlist hero
    /// and the cell long-press menus: Kill Mode's filter, the everything-listened toast, and the
    /// confirmation before replacing a queue that holds hand-queued songs.
    func playCollectionOrToast(tracks: [Track], source: PlaybackSource?, intent: CollectionPlayIntent) async {
        guard let lib = activeLibrary else {
            showTransientToast("Sign in to play music.")
            return
        }
        guard !tracks.isEmpty else { return }
        let playlistId: String?
        if case let .playlist(p)? = source { playlistId = p.id } else { playlistId = nil }
        let plan = Self.collectionPlaybackPlan(
            intent: intent,
            tracks: tracks,
            isKillModeEnabled: playlistId.map { killModeEnabledPlaylistIds.contains($0) } ?? false,
            pending: playlistId.map { killModePendingTrackIds(playlistId: $0) } ?? [],
            passed: playlistId.map { killModePassedTrackIds(playlistId: $0) } ?? []
        )
        let planTracks = plan.tracks
        let planStart = plan.startIndex
        switch plan.action {
        case .everythingListened:
            showTransientToast(Self.killModeEverythingListenedMessage)
        case .insertNext:
            do {
                try await player.playTracksNext(library: lib, tracks: planTracks, sourcePlaylistId: playlistId)
            } catch {
                showTransientToast(error.musicPlaybackToastMessage)
            }
        case let .start(shuffled):
            await playReplacingQueue { [weak self] in
                guard let self else { return }
                do {
                    if shuffled {
                        try await self.player.playAlbumShuffled(library: lib, tracks: planTracks, source: source)
                    } else {
                        try await self.player.playAlbum(library: lib, tracks: planTracks, startIndex: planStart, source: source)
                    }
                } catch {
                    self.showTransientToast(error.musicPlaybackToastMessage)
                }
            }
        }
    }

    // MARK: Kill Mode bookkeeping outside playback

    /// Follows a stale-id swap (``applyTrackIDSwaps(_:)``) through both mark sets, so a rescan does
    /// not strand marks on ids that no longer exist — the Kill List would drop them and burned-down
    /// songs would come back as unheard.
    ///
    /// The removal list keeps its newest-skip-first order; a swap onto an id already listed keeps
    /// the earlier (newer) entry. A song that ends up both red and green stays red, as it does
    /// everywhere else in Kill Mode.
    static func killModeMarksRemapped(
        pending: [String: [String]],
        passed: [String: Set<String>],
        swaps: [String: String]
    ) -> (pending: [String: [String]], passed: [String: Set<String>]) {
        guard !swaps.isEmpty else { return (pending, passed) }
        var nextPending: [String: [String]] = [:]
        for (playlistId, ids) in pending {
            var seen = Set<String>()
            var ordered: [String] = []
            for id in ids {
                let mapped = swaps[id] ?? id
                if seen.insert(mapped).inserted { ordered.append(mapped) }
            }
            nextPending[playlistId] = ordered
        }
        var nextPassed: [String: Set<String>] = [:]
        for (playlistId, ids) in passed {
            var mapped = Set(ids.map { swaps[$0] ?? $0 })
            if let red = nextPending[playlistId] { mapped.subtract(red) }
            if !mapped.isEmpty { nextPassed[playlistId] = mapped }
        }
        return (nextPending, nextPassed)
    }

    /// Kill Mode state with one playlist removed from all three stores — for a playlist deleted
    /// from the server, whose id could otherwise be handed out again later.
    static func killModeStateForgettingPlaylist(
        _ playlistId: String,
        enabled: Set<String>,
        pending: [String: [String]],
        passed: [String: Set<String>]
    ) -> (enabled: Set<String>, pending: [String: [String]], passed: [String: Set<String>]) {
        var enabled = enabled
        var pending = pending
        var passed = passed
        enabled.remove(playlistId)
        pending[playlistId] = nil
        passed[playlistId] = nil
        return (enabled, pending, passed)
    }

    private func forgetKillModeState(playlistId: String) {
        let next = Self.killModeStateForgettingPlaylist(
            playlistId,
            enabled: killModeEnabledPlaylistIds,
            pending: killModePendingRemovals,
            passed: killModePassedTracks
        )
        if next.enabled != killModeEnabledPlaylistIds {
            killModeEnabledPlaylistIds = next.enabled
            KillModeStore.saveEnabled(next.enabled)
        }
        if next.pending != killModePendingRemovals {
            killModePendingRemovals = next.pending
            KillModeStore.savePending(next.pending)
        }
        if next.passed != killModePassedTracks {
            killModePassedTracks = next.passed
            KillModeStore.savePassed(next.passed)
        }
        invalidateKillModeListenedCache()
    }

    /// Loads Kill Mode state for the signed-in account (backend + server + user), or clears it when
    /// no account is resolvable. Playlist ids are only unique per server, so marks from one server
    /// must never be read against another's playlists.
    private func reloadKillModeStateForAccount() {
        let scope = isSignedIn
            ? KillModeStore.scope(backend: backendKind, baseURLString: baseURLString, userKey: libraryMagicPlaylistUserKey)
            : nil
        KillModeStore.activeScope = scope
        let snapshot = scope.map { KillModeStore.load(scope: $0) } ?? KillModeStore.Snapshot()
        killModeEnabledPlaylistIds = snapshot.enabled
        killModePendingRemovals = snapshot.pending
        killModePassedTracks = snapshot.passed
        killModeRunGate = nil
        invalidateKillModeListenedCache()
    }

    /// Sign-out drops Kill Mode state from memory only. Nothing on disk is deleted: signing back in
    /// to the same server and user restores it (``reloadKillModeStateForAccount()``).
    private func unloadKillModeStateForSignOut() {
        KillModeStore.activeScope = nil
        killModeEnabledPlaylistIds = []
        killModePendingRemovals = [:]
        killModePassedTracks = [:]
        killModeRunGate = nil
        invalidateKillModeListenedCache()
    }

    /// Determinate progress for a bulk Kill Mode removal.
    struct KillModeRemovalProgress: Equatable {
        enum Phase: Equatable {
            /// Re-fetching the live playlist so positional indexes are current.
            case preparing
            /// Committing removals to the backend, chunk by chunk.
            case removing
            /// Removals are done; refreshing local caches and playlist metadata.
            case refreshing
        }

        var playlistId: String
        var phase: Phase
        var completed: Int
        var total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }
    }

    /// What actually happened in the last bulk removal, so the run ends with a summary
    /// rather than a sheet that just closes.
    struct KillModeRemovalSummary: Equatable {
        var playlistId: String
        /// Songs this run deleted from the playlist on the server.
        var removed: Int
        /// Songs that were already gone (removed elsewhere) and just had their mark cleared.
        var alreadyGone: Int
        /// Track ids still queued when the run stopped early. These keep their pending marks,
        /// so they stay listed and the user can continue without re-walking what succeeded.
        var remainingTrackIds: [String]
        var errorMessage: String?

        var failed: Int { remainingTrackIds.count }
        var isComplete: Bool { remainingTrackIds.isEmpty && errorMessage == nil }
    }

    /// Bulk-commits pending Kill Mode removals for one playlist.
    ///
    /// Differs from `commitKillModeRemovals` in three ways that matter for a long run:
    /// - **Determinate progress.** `killModeRemovalProgress` ticks per committed chunk.
    /// - **Survives backgrounding.** The whole run is wrapped in a UIKit background
    ///   assertion, so tabbing out of the app no longer suspends the loop mid-flight and
    ///   strands the playlist half-purged.
    /// - **Resumable.** Every committed chunk immediately drops its pending marks, and
    ///   anything left over stays marked and comes back in `remainingTrackIds` — so
    ///   "try again" only re-walks what actually failed.
    ///
    /// Safe to call with a run already in flight: it no-ops rather than double-removing.
    func runKillModeRemoval(playlistId: String, rows: [PlaylistRowItem]) async {
        guard !rows.isEmpty, killModeRemovalProgress == nil else { return }
        killModeRemovalSummary = nil
        killModeRemovalProgress = KillModeRemovalProgress(
            playlistId: playlistId,
            phase: .preparing,
            completed: 0,
            total: rows.count
        )
        let assertion = BulkOperationBackgroundAssertion(name: "KillModeRemoval")
        defer {
            assertion.end()
            killModeRemovalProgress = nil
        }

        // Phase 1 — re-resolve against the live playlist. One fetch, and it is what keeps
        // Navidrome's positional indexes honest.
        let resolved: [PlaylistRowItem]
        let alreadyGone: Int
        let liveTrackIds: [String]
        do {
            let (live, gone, liveIds) = try await resolveRowsForRemoval(playlistId: playlistId, rows: rows)
            resolved = live
            alreadyGone = gone.count
            liveTrackIds = liveIds
            if !gone.isEmpty {
                killModeTracksLeftPlaylist(playlistId: playlistId, trackIds: PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
                    candidates: gone,
                    liveTrackIds: liveIds,
                    committedRowTrackIds: []
                ))
                invalidatePlaylistRowsCache(playlistId: playlistId)
            }
        } catch {
            killModeRemovalSummary = KillModeRemovalSummary(
                playlistId: playlistId,
                removed: 0,
                alreadyGone: 0,
                remainingTrackIds: rows.map(\.track.id),
                errorMessage: error.localizedDescription
            )
            return
        }

        guard !resolved.isEmpty else {
            killModeRemovalSummary = KillModeRemovalSummary(
                playlistId: playlistId,
                removed: 0,
                alreadyGone: alreadyGone,
                remainingTrackIds: [],
                errorMessage: nil
            )
            invalidatePlaylistRowsCache(playlistId: playlistId)
            await refreshLibraryPlaylists()
            return
        }

        // Phase 2 — commit in chunks, persisting each one as it lands.
        killModeRemovalProgress = KillModeRemovalProgress(
            playlistId: playlistId,
            phase: .removing,
            completed: 0,
            total: resolved.count
        )
        var removedIds: Set<String> = []
        // Every committed row, duplicates kept, so a song's marks go only with its last row.
        var committedRowTrackIds: [String] = []
        // Counted separately from `removedIds`: a playlist can contain the same track twice,
        // so rows committed and distinct ids removed are NOT the same number. `total` is a
        // row count, so progress has to be a row count too or the bar never reaches the end.
        var completedRows = 0
        var failureMessage: String?
        do {
            try await performChunkedRemoval(playlistId: playlistId, rows: resolved) { committed in
                removedIds.formUnion(committed.map(\.track.id))
                committedRowTrackIds.append(contentsOf: committed.map(\.track.id))
                completedRows += committed.count
                // Persist immediately: an interrupted run must never make the user re-walk
                // songs the server has already deleted.
                killModeTracksLeftPlaylist(playlistId: playlistId, trackIds: PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
                    candidates: Set(committed.map(\.track.id)),
                    liveTrackIds: liveTrackIds,
                    committedRowTrackIds: committedRowTrackIds
                ))
                killModeRemovalProgress?.completed = completedRows
            }
        } catch {
            failureMessage = error.localizedDescription
        }

        // Phase 3 — one cache invalidation and one library refresh for the whole run,
        // rather than one per song.
        killModeRemovalProgress?.phase = .refreshing
        invalidatePlaylistRowsCache(playlistId: playlistId)
        await refreshLibraryPlaylists()

        let remaining = resolved.map(\.track.id).filter { !removedIds.contains($0) }
        killModeRemovalSummary = KillModeRemovalSummary(
            playlistId: playlistId,
            removed: completedRows,
            alreadyGone: alreadyGone,
            remainingTrackIds: remaining,
            errorMessage: failureMessage
        )
    }

    /// Backend removal of already-resolved rows, committed in chunks. Calls `onChunk` after
    /// each chunk the server has accepted. Deliberately does NOT touch the rows cache or
    /// refresh the library — the caller does that once, at the end.
    private func performChunkedRemoval(
        playlistId: String,
        rows: [PlaylistRowItem],
        onChunk: (_ committed: [PlaylistRowItem]) -> Void
    ) async throws {
        let size = Self.killModeRemovalChunkSize
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            let targets: [(entryId: String, row: PlaylistRowItem)] = try rows.map { row in
                guard let entryId = row.jellyfinEntryId else {
                    throw NSError(domain: "VellumMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist entry id."])
                }
                return (entryId, row)
            }
            var offset = 0
            while offset < targets.count {
                let upper = min(offset + size, targets.count)
                let chunk = Array(targets[offset..<upper])
                try await client.removeTracksFromPlaylist(playlistId: playlistId, entryIds: chunk.map(\.entryId))
                onChunk(chunk.map(\.row))
                offset = upper
            }
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            let targets: [(index: Int, row: PlaylistRowItem)] = try rows.map { row in
                guard let index = row.navidromeIndex else {
                    throw NSError(domain: "VellumMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist index."])
                }
                return (index, row)
            }
            // Highest index first ACROSS chunks as well as within them. A later chunk's
            // indexes are stale the moment an earlier chunk commits; ascending order
            // silently deletes the wrong songs. Removing a high position never shifts a
            // lower one, so descending is safe. Each chunk is one request.
            let ordered = targets.sorted { $0.index > $1.index }
            var offset = 0
            while offset < ordered.count {
                let upper = min(offset + size, ordered.count)
                let chunk = Array(ordered[offset..<upper])
                try await client.removeTracksFromPlaylist(playlistId: playlistId, indexes: chunk.map(\.index))
                onChunk(chunk.map(\.row))
                offset = upper
            }
        }
    }

    /// Removes a single track id from the pending set without touching the playlist.
    /// Used by the kill-list "Keep" action — undoes a skip-mark without deleting.
    func restoreFromKillList(playlistId: String, trackId: String) {
        stripKillModePending(playlistId: playlistId, trackIds: [trackId])
    }

    /// Commits a subset of pending removals to the backend, then strips them from the pending set.
    /// Caller passes the resolved `PlaylistRowItem`s (the kill-list view filters its current rows
    /// down to those whose track id is in the pending set).
    func commitKillModeRemovals(playlistId: String, rows: [PlaylistRowItem]) async throws {
        guard !rows.isEmpty else { return }
        // The kill-list view holds a static row snapshot, so its Navidrome positional indices go
        // stale after each prior single removal. `removePlaylistRows` re-resolves every target
        // against the live playlist by track id, which is exactly what that needs — this used to
        // resolve here as well, and the second fetch bought nothing.
        try await removePlaylistRows(playlistId: playlistId, rows: rows)
    }

    /// Re-resolves removal targets against a fresh fetch of the playlist. Navidrome
    /// maps by stable track id, consuming each matched live row so duplicate ids
    /// resolve to distinct positions; Jellyfin keeps its stable entry ids and only
    /// checks they still exist. Targets no longer in the playlist come back in
    /// `goneTrackIds` rather than failing the whole batch.
    private func resolveRowsForRemoval(
        playlistId: String,
        rows: [PlaylistRowItem]
    ) async throws -> (resolved: [PlaylistRowItem], goneTrackIds: Set<String>, liveTrackIds: [String]) {
        // `liveTrackIds` keeps duplicates: it is how many rows of each song the playlist holds, which
        // decides whether a removal takes a song's last row (see `trackIdsLeavingPlaylist`). Without a
        // client nothing is fetched, and the requested rows stand in — every one then reads as a last
        // row, which is the old behaviour; the removal throws before reaching the marks anyway.
        switch backendKind {
        case .navidrome:
            guard let client = navidrome else { return (rows, [], rows.map(\.track.id)) }
            let live = try await client.fetchPlaylistRows(playlistId: playlistId)
            let resolution = PlaylistRemovalTargeting.resolveByTrackId(requested: rows, live: live)
            return (resolution.resolved, resolution.goneTrackIds, live.map(\.track.id))
        case .jellyfin:
            guard let client = jellyfin else { return (rows, [], rows.map(\.track.id)) }
            let live = try await client.fetchPlaylistRows(playlistId: playlistId)
            let resolution = PlaylistRemovalTargeting.resolveByEntryId(requested: rows, live: live)
            return (resolution.resolved, resolution.goneTrackIds, live.map(\.track.id))
        }
    }

    /// Installs Kill Mode's three engine hooks. Static, taking the handlers as closures, so a test
    /// can wire a real engine exactly as the app does without constructing an `AppModel`.
    ///
    /// The handlers run **synchronously**. They used to hop through `Task { @MainActor in … }`, which
    /// bought nothing — `PlaybackEngine` and `AppModel` are both `@MainActor`, and the engine fires
    /// these from main-actor methods — and cost a song played twice: `handleEnded` picks the next
    /// index on the very next line after `onTrackCompleted`, so the green mark landed after the
    /// decision it was meant to feed. Under repeat-all the song that just ended was chosen again, and
    /// a back-to-back duplicate was not yet excluded.
    static func wireKillModeHooks(
        on player: PlaybackEngine,
        skipped: @escaping (Track, PlaybackSource?, Bool) -> Void,
        completed: @escaping (Track, PlaybackSource?, Bool) -> Void,
        excludes: @escaping (Track) -> Bool
    ) {
        player.onTrackSkipped = skipped
        player.onTrackCompleted = completed
        player.autoAdvanceExclusion = excludes
    }

    /// The playlist a Kill Mode skip or completion may be written to, or nil when it must not be.
    ///
    /// - `wasUserQueued` is the engine's capture from when the track *started*. Reading
    ///   `player.userQueuedTrackIds` here instead can never see a hand-queued song: the engine has
    ///   removed its id by then.
    /// - `isInSourceQueueOrder` stops a song that was never part of the playlist run being written
    ///   into that playlist's listened set, which outlives the session.
    static func killModeMarkPlaylistId(
        source: PlaybackSource?,
        enabledPlaylistIds: Set<String>,
        wasUserQueued: Bool,
        isInSourceQueueOrder: Bool
    ) -> String? {
        guard case let .playlist(p)? = source,
              enabledPlaylistIds.contains(p.id),
              !wasUserQueued,
              isInSourceQueueOrder else { return nil }
        return p.id
    }

    /// Callback hook from `PlaybackEngine.onTrackSkipped`. Marks the outgoing track red when
    /// ``killModeMarkPlaylistId(source:enabledPlaylistIds:wasUserQueued:isInSourceQueueOrder:)``
    /// names a playlist.
    private func handleKillModeSkip(track: Track, source: PlaybackSource?, wasUserQueued: Bool) {
        guard let playlistId = Self.killModeMarkPlaylistId(
            source: source,
            enabledPlaylistIds: killModeEnabledPlaylistIds,
            wasUserQueued: wasUserQueued,
            isInSourceQueueOrder: player.isInSourceQueueOrder(trackId: track.id)
        ) else { return }
        var current = killModePendingRemovals[playlistId] ?? []
        // Dedupe-then-prepend so a re-skipped track moves back to the top of the list.
        current.removeAll { $0 == track.id }
        current.insert(track.id, at: 0)
        killModePendingRemovals[playlistId] = current
        KillModeStore.savePending(killModePendingRemovals)
        // Skip wins over a prior "played fully" mark — the track is red, not green.
        if var passed = killModePassedTracks[playlistId], passed.remove(track.id) != nil {
            killModePassedTracks[playlistId] = passed.isEmpty ? nil : passed
            KillModeStore.savePassed(killModePassedTracks)
        }
        invalidateKillModeListenedCache()
    }

    /// Callback hook from `PlaybackEngine.onTrackCompleted`. Marks the finished track
    /// "kept (green)" when it played fully to its natural end and a playlist may be marked. A track
    /// already marked for removal (red) stays red.
    private func handleKillModeCompletion(track: Track, source: PlaybackSource?, wasUserQueued: Bool) {
        guard let playlistId = Self.killModeMarkPlaylistId(
            source: source,
            enabledPlaylistIds: killModeEnabledPlaylistIds,
            wasUserQueued: wasUserQueued,
            isInSourceQueueOrder: player.isInSourceQueueOrder(trackId: track.id)
        ),
            killModePendingRemovals[playlistId]?.contains(track.id) != true else { return }
        var passed = killModePassedTracks[playlistId] ?? []
        guard passed.insert(track.id).inserted else { return }
        killModePassedTracks[playlistId] = passed
        KillModeStore.savePassed(killModePassedTracks)
        invalidateKillModeListenedCache()
    }

    /// The kill-mode playlist a queue is a run of, or nil when it is not one.
    static func killModeRunPlaylistId(source: PlaybackSource?, enabledPlaylistIds: Set<String>) -> String? {
        guard case let .playlist(p)? = source, enabledPlaylistIds.contains(p.id) else { return nil }
        return p.id
    }

    /// Songs whose **last** row just left `playlistId` (callers narrow to those with
    /// `PlaylistRemovalTargeting.trackIdsLeavingPlaylist`). Their marks go, and if that playlist's
    /// Kill Mode run is playing they leave the run too — otherwise a removed song still ahead of the
    /// cursor plays and is marked again under a playlist it is no longer in.
    private func killModeTracksLeftPlaylist(playlistId: String, trackIds: Set<String>) {
        guard !trackIds.isEmpty else { return }
        stripKillModePending(playlistId: playlistId, trackIds: trackIds)
        guard Self.killModeRunPlaylistId(source: player.playbackSource, enabledPlaylistIds: killModeEnabledPlaylistIds) == playlistId else { return }
        player.dropTracksRemovedFromSource(trackIds)
    }

    /// Removes the given track ids from the pending list for a playlist and persists. Called
    /// after any successful playlist deletion path so the pending list never references tracks
    /// that are no longer in the playlist. Preserves the relative order of remaining entries.
    private func stripKillModePending(playlistId: String, trackIds: Set<String>) {
        invalidateKillModeListenedCache()
        // Tracks removed from the playlist no longer exist — drop them from the kept
        // (green) set too so listen history can't reference deleted tracks.
        if var passed = killModePassedTracks[playlistId], !passed.isDisjoint(with: trackIds) {
            passed.subtract(trackIds)
            killModePassedTracks[playlistId] = passed.isEmpty ? nil : passed
            KillModeStore.savePassed(killModePassedTracks)
        }
        guard var current = killModePendingRemovals[playlistId], !current.isEmpty else { return }
        let before = current.count
        current.removeAll { trackIds.contains($0) }
        guard current.count != before else { return }
        if current.isEmpty {
            killModePendingRemovals[playlistId] = nil
        } else {
            killModePendingRemovals[playlistId] = current
        }
        KillModeStore.savePending(killModePendingRemovals)
    }

    /// Uploads cover art for a library playlist and refreshes playlist metadata. Returns a cache-busted artwork URL for immediate UI refresh.
    @discardableResult
    func updatePlaylistCoverImage(playlistId: String, imageData: Data) async throws -> URL? {
        guard isSignedIn else {
            throw NSError(
                domain: "VellumMusic",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Sign in to change playlist artwork."],
            )
        }
        guard !imageData.isEmpty else {
            throw NSError(
                domain: "VellumMusic",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Could not read the selected image."],
            )
        }
        let upload = Self.inferredPlaylistCoverUpload(imageData)
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.uploadPlaylistImage(
                playlistId: playlistId,
                imageData: imageData,
                contentType: upload.contentType,
            )
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.uploadPlaylistImage(
                playlistId: playlistId,
                imageData: imageData,
                filename: upload.filename,
            )
        }
        await refreshLibraryPlaylists()
        if backendKind == .navidrome, playlistId == libraryMagicPlaylistId {
            if let identity = accountAvatarIdentity {
                AccountAvatarCache.remove(identity: identity)
            }
            let busted = navidrome?.coverArtURL(forId: playlistId, size: 256).map { appendCacheBust(to: $0) }
            navidromeMagicPlaylistAvatarURL = busted
            accountAvatarRevision &+= 1
            prefetchAccountAvatar()
        }
        return playlistArtworkURL(for: playlistId, cacheBust: true)
    }

    /// Removes a user-uploaded playlist cover so Navidrome regenerates one from the
    /// playlist's tracks. Navidrome-only — Jellyfin has no equivalent native route here.
    func clearPlaylistCoverImage(playlistId: String) async throws -> URL? {
        guard isSignedIn, backendKind == .navidrome, let client = navidrome else {
            throw NSError(
                domain: "VellumMusic",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Removing artwork is only supported on Navidrome."],
            )
        }
        try await client.deletePlaylistImage(playlistId: playlistId)
        await refreshLibraryPlaylists()
        if playlistId == libraryMagicPlaylistId {
            if let identity = accountAvatarIdentity {
                AccountAvatarCache.remove(identity: identity)
            }
            // No custom cover any more: the profile picture reverts to `getAvatar`.
            navidromeMagicPlaylistAvatarURL = nil
            accountAvatarRevision &+= 1
            prefetchAccountAvatar()
        }
        return playlistArtworkURL(for: playlistId, cacheBust: true)
    }

    /// Clears the profile picture by removing the magic playlist's uploaded cover.
    func clearProfilePicture() async {
        guard isSignedIn, backendKind == .navidrome, let playlistId = libraryMagicPlaylistId else {
            profilePictureUpdateError = "Sign in to Navidrome and let your library sync before changing your profile picture."
            return
        }
        isUpdatingProfilePicture = true
        defer { isUpdatingProfilePicture = false }
        do {
            _ = try await clearPlaylistCoverImage(playlistId: playlistId)
            profilePictureUpdateError = nil
        } catch {
            profilePictureUpdateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func playlistArtworkURL(for playlistId: String, cacheBust: Bool) -> URL? {
        var url = libraryPlaylists.first(where: { $0.id == playlistId })?.artworkURL
        if url == nil, backendKind == .navidrome {
            url = navidrome?.coverArtURL(forId: playlistId, size: 400)
        }
        guard let url else { return nil }
        return cacheBust ? appendCacheBust(to: url) : url
    }

    private static func inferredPlaylistCoverUpload(_ data: Data) -> (filename: String, contentType: String) {
        if data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ("cover.png", "image/png")
        }
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ("cover.jpg", "image/jpeg")
        }
        if data.count >= 6, data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return ("cover.gif", "image/gif")
        }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50
        {
            return ("cover.webp", "image/webp")
        }
        return ("cover.jpg", "image/jpeg")
    }

    func renamePlaylist(playlistId: String, name: String, isPublic: Bool? = nil) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "VellumMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist name cannot be empty."])
        }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.renamePlaylist(playlistId: playlistId, name: trimmed, isPublic: isPublic)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.renamePlaylist(playlistId: playlistId, name: trimmed, isPublic: isPublic)
        }
        await refreshLibraryPlaylists()
    }

    func deletePlaylist(playlistId: String) async throws {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.deletePlaylist(playlistId: playlistId)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.deletePlaylist(playlistId: playlistId)
        }
        forgetKillModeState(playlistId: playlistId)
        await refreshLibraryPlaylists()
    }

    /// Tracks for **Library → Playlists → Favorites** (server-backed favorites for Jellyfin and Navidrome).
    func favoritePlaylistTracks(limit: Int = 15_000) async throws -> [Track] {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await client.fetchFavoriteTracks(limit: limit)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await client.fetchFavoriteTracks(limit: limit)
        }
    }

    private func refreshFavoritesFromServer() async {
        let previous = favoriteTrackIds
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { return }
            do {
                favoriteTrackIds = try await client.fetchFavoriteTrackIds(limit: 20_000)
            } catch {
                favoriteTrackIds = previous
            }
        case .navidrome:
            guard let client = navidrome else { return }
            do {
                favoriteTrackIds = try await client.fetchFavoriteTrackIds(limit: 20_000)
            } catch {
                favoriteTrackIds = previous
            }
        }
    }

    private func scheduleLibraryTrackMatchIndexRefresh(limit: Int = 50_000) {
        trackIndexTask?.cancel()
        trackIndexTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshLibraryTrackMatchIndex(limit: limit)
            if !Task.isCancelled {
                self.trackIndexTask = nil
            }
        }
    }

    /// Schedules a deduped discovery track index build when the title index is still empty.
    /// Now that the index is built lazily (not during bootstrap), this is the only path
    /// that kicks it off — called from LibrarySongsView, MusicNewTabView, and
    /// DiscoverySearchView on appear.
    public func scheduleDiscoveryTrackIndexRefreshIfNeeded() {
        guard isSignedIn, libraryTrackTitleIndex.isEmpty else { return }
        scheduleLibraryTrackMatchIndexRefresh()
    }

    /// Loads up to `limit` audio tracks from the server and rebuilds `libraryTrackTitleIndex` for discovery matching.
    public func refreshLibraryTrackMatchIndex(limit: Int = 50_000) async {
        if isIndexingLibraryTracks { return }
        guard let lib = activeLibrary else {
            libraryTrackIndexLoadError = nil
            if discoveryLibraryTracks.isEmpty {
                restoreLibraryFromDisk()
            } else {
                offline.backfillRecordsIfMissing(knownTracks: discoveryLibraryTracks)
                mergeOfflineCatalog()
            }
            return
        }
        isIndexingLibraryTracks = true
        libraryTrackIndexLoadError = nil
        defer { isIndexingLibraryTracks = false }
        do {
            let tracks = try await PerfLog.measureAsync(
                "refreshLibraryTrackMatchIndex.fetch",
                context: .network,
                details: "limit=\(limit)"
            ) {
                try await lib.allTracks(limit: limit)
            }
            PerfLog.event("refreshLibraryTrackMatchIndex.fetched", details: "tracks=\(tracks.count)")
            // Title/chart indices don't need fresh cover URLs — resolve artwork lazily in UI.
            let computed = await PerfLog.measureAsync(
                "refreshLibraryTrackMatchIndex.buildIndices",
                context: .background,
                details: "tracks=\(tracks.count)"
            ) {
                await Task.detached(priority: .userInitiated) {
                    () -> (byId: [String: Track], titles: [String: Set<String>], chart: LibraryChartTrackIndex) in
                    let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let titles = LibraryTrackMatcher.titleIndex(from: tracks)
                    let chart = LibraryChartTrackIndex(tracks: tracks)
                    return (byId, titles, chart)
                }.value
            }
            PerfLog.measure(
                "refreshLibraryTrackMatchIndex.assign",
                details: "tracks=\(tracks.count) titleKeys=\(computed.titles.count)"
            ) {
                skipDiscoveryIndexRebuild = true
                discoveryLibraryTracks = tracks
                skipDiscoveryIndexRebuild = false
                discoveryTrackById = computed.byId
                libraryTrackTitleIndex = computed.titles
                libraryChartTrackIndex = computed.chart
            }
            offline.backfillRecordsIfMissing(knownTracks: tracks)
            mergeOfflineCatalog()
            persistLibrarySnapshot()
            rebuildHomeMixes()
        } catch {
            libraryTrackIndexLoadError = error.localizedDescription
            offline.backfillRecordsIfMissing(knownTracks: discoveryLibraryTracks)
            mergeOfflineCatalog()
        }
    }

    func albumSummary(for track: Track) -> AlbumSummary {
        if let cached = libraryAlbumsById[track.albumId] {
            let art = resolvedArtworkURL(for: cached)
            return AlbumSummary(
                id: cached.id,
                title: cached.title,
                artist: cached.artist,
                artworkURL: art,
                coverArtId: cached.coverArtId,
                trackCount: cached.trackCount,
                libraryAddedDate: cached.libraryAddedDate,
                genres: cached.genres,
                releaseYear: cached.releaseYear,
                releaseDate: cached.releaseDate,
            )
        }
        let art = resolvedArtworkURL(for: track)
        return AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: art,
            coverArtId: navidromeCoverArtId(for: track),
            trackCount: nil,
            libraryAddedDate: track.libraryAddedDate,
            genres: track.genres,
            releaseYear: track.releaseYear,
        )
    }

    public func refreshNewTabBrowse() async {
        newTabBrowseLoading = true
        newTabBrowseError = nil

        var catalog: [AcquisitionRelease] = []
        if acquisition.isConfigured, acquisition.capabilities.supportsReleaseCatalog {
            let start = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
            let end = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
            catalog = await acquisition.upcomingAndWanted(since: start, until: end)
            newTabBrowseBackend = .lidarr
        } else {
            newTabBrowseBackend = .server
        }

        let recentlyAdded = recentlyAddedAlbums
        let library = libraryAlbums
        let tasteNames = recentlyPlayedTracks.map(\.artist)
            + scrobbleService.store.completed.map(\.artist)
            + subscriptions.followed.map(\.name)
        let scrobbles = scrobbleService.store.completed
        let favorites = favoriteTrackIds
        let followed = subscriptions.followed
        let indexed = discoveryLibraryTracks
        let recentTracks = recentlyPlayedTracks
        let genres = listeningTopGenres()
        let releaseIndex = libraryAlbumReleaseIndex

        let feed = await Task.detached(priority: .userInitiated) {
            var tracksById: [String: Track] = [:]
            tracksById.reserveCapacity(indexed.count + recentTracks.count)
            for track in indexed { tracksById[track.id] = track }
            for track in recentTracks { tracksById[track.id] = track }
            let serverAlbums = NewTabPersonalizationEngine.serverCandidateAlbums(
                recentlyAdded: recentlyAdded,
                libraryAlbums: library,
                tasteArtistNames: tasteNames
            )
            return NewTabPersonalizationEngine.buildFeed(
                context: NewTabPersonalizationEngine.Context(
                    completedScrobbles: scrobbles,
                    favoriteTrackIds: favorites,
                    followedArtists: followed,
                    trackLookup: { tracksById[$0] },
                    indexedTracks: indexed,
                    ownsAlbum: { artist, title in
                        releaseIndex.firstMatch(artist: artist, albumTitle: title) != nil
                    },
                    ownsTrack: { _, _ in false },
                    topGenres: genres,
                    serverAlbums: serverAlbums,
                    recentlyPlayedTracks: recentTracks,
                    catalogReleases: catalog
                )
            )
        }.value
        applyPersonalizedNewTabFeed(feed)
        newTabBrowseError = feed.isEmpty
            ? "Nothing new right now. Play more music or pull to refresh."
            : nil
        newTabBrowseLoading = false
    }

    /// Maps listening-taste genres (same ranking as the New tab's ``listeningTopGenres()``) onto
    /// server genre rows so Home shelves reflect what the user actually plays.
    private func homeTasteGenrePicks(
        from serverGenres: [LibraryGenreSummary],
        limit: Int = homeGenreShelfCount,
    ) -> [LibraryGenreSummary] {
        let eligible = serverGenres.filter(\.hasAlbums)
        guard !eligible.isEmpty else { return [] }

        var bestByCanonical: [String: LibraryGenreSummary] = [:]
        for genre in eligible {
            let key = GenreCanonicalizer.canonical(for: genre.name).lowercased()
            if let existing = bestByCanonical[key] {
                if (genre.albumCount ?? 0) > (existing.albumCount ?? 0) {
                    bestByCanonical[key] = genre
                }
            } else {
                bestByCanonical[key] = genre
            }
        }

        var picked: [LibraryGenreSummary] = []
        var usedIDs = Set<String>()
        for tasteName in listeningTopGenres() {
            let key = tasteName.lowercased()
            guard let match = bestByCanonical[key], usedIDs.insert(match.id).inserted else { continue }
            picked.append(match)
            if picked.count >= limit { return picked }
        }

        let fallback = eligible.sorted {
            if ($0.albumCount ?? 0) != ($1.albumCount ?? 0) {
                return ($0.albumCount ?? 0) > ($1.albumCount ?? 0)
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for genre in fallback where !usedIDs.contains(genre.id) {
            picked.append(genre)
            usedIDs.insert(genre.id)
            if picked.count >= limit { break }
        }
        return picked
    }

    /// Home → Top Picks + New Releases: taste-ranked **server catalog** not in the magic playlist.
    private func rebuildHomeTopPicksFromMemory() {
        rebuildHomeDiscoveryShelves()
    }

    private func rebuildHomeDiscoveryShelves(
        extraGenreAlbums: [AlbumSummary] = [],
        forceReplace: Bool = false,
    ) {
        applyHomeDiscoveryShelvesRanking(
            from: buildHomeTopPicksCandidatePool(extra: extraGenreAlbums),
            forceReplace: forceReplace,
        )
    }

    private func fetchHomeTopPicksGenreCandidates(
        using lib: MusicLibraryProviding,
        tasteGenres: [LibraryGenreSummary],
    ) async -> [AlbumSummary] {
        let genresForPool: [LibraryGenreSummary]
        if tasteGenres.isEmpty {
            genresForPool = homeTasteGenrePicks(from: (try? await lib.libraryGenres(limit: 100)) ?? [], limit: 3)
        } else {
            genresForPool = Array(tasteGenres.prefix(3))
        }

        var genreAlbums: [AlbumSummary] = []
        for genre in genresForPool {
            genreAlbums.append(contentsOf: (try? await lib.albums(inGenre: genre, limit: 24)) ?? [])
        }
        return genreAlbums
    }

    private func applyHomeDiscoveryShelvesRanking(from pool: [AlbumSummary], forceReplace: Bool = false) {
        guard !pool.isEmpty else {
            if forceReplace || homeTopPickAlbums.isEmpty {
                homeTopPickAlbums = []
                homeNewReleaseAlbums = []
            }
            return
        }

        let recentOrder = Dictionary(uniqueKeysWithValues: recentlyAddedAlbums.enumerated().map { ($1.id, $0) })
        let ranked = NewTabPersonalizationEngine.tasteRankedAlbumSummaries(
            pool,
            context: newTabPersonalizationContext(),
            limit: Self.homeTopPickCount + Self.homeNewReleaseCount,
            recentlyAddedOrder: recentOrder,
        )
        let proposedTop = Array(ranked.prefix(Self.homeTopPickCount))
        let proposedNew = Array(ranked.dropFirst(proposedTop.count).prefix(Self.homeNewReleaseCount))

        if forceReplace || homeTopPickAlbums.isEmpty {
            homeTopPickAlbums = proposedTop
            homeNewReleaseAlbums = proposedNew
        } else {
            homeTopPickAlbums = stabilizeHomeDiscoveryShelf(
                existing: homeTopPickAlbums,
                proposed: proposedTop,
                limit: Self.homeTopPickCount,
            )
            homeNewReleaseAlbums = stabilizeHomeDiscoveryShelf(
                existing: homeNewReleaseAlbums,
                proposed: proposedNew,
                limit: Self.homeNewReleaseCount,
            )
        }
    }

    private func applyPersonalizedNewTabFeed(_ feed: NewTabPersonalizedFeed) {
        newTabIsPersonalized = feed.isPersonalized
        newTabFromYourArtists = feed.fromYourArtists
        newTabArtistHighlights = feed.artistHighlights

        // "New This Week" and "Recent Releases" are two recency slices of one taste-driven
        // pool (releases connected to the user's listening), so they're always distinct.
        let split = Self.splitRecentReleases(feed.recentTasteReleases)
        newTabRecentReleases = split.thisWeek   // New This Week
        newTabDiscoverReleases = split.recent   // Recent Releases
        newTabTopAlbums = feed.isPersonalized ? feed.discoverAlbums : []
        newTabTopTracks = feed.forYouTracks
    }

    private func clearNewTabBrowseGrid() {
        newTabTopTracks = []
        newTabTopAlbums = []
        newTabRecentReleases = []
        newTabFromYourArtists = []
        newTabDiscoverReleases = []
        newTabArtistHighlights = []
        newTabIsPersonalized = false
    }

    // MARK: - Playback helpers

    /// Starts playback and surfaces stream/load failures via the root toast.
    /// Runs `play` now, or holds it behind a confirmation when starting it would throw away
    /// tracks the user explicitly queued via Play Next / Add to Queue. Silent in the common
    /// case — a plain album/playlist queue has nothing hand-curated to lose.
    func playReplacingQueue(_ play: @escaping @MainActor @Sendable () async -> Void) async {
        let queued = player.pendingUserQueuedCount
        guard queued > 0 else {
            await play()
            return
        }
        pendingQueueReplacement = PendingQueueReplacement(queuedCount: queued, play: play)
    }

    /// Confirm handler for ``pendingQueueReplacement`` — runs the held request.
    func confirmPendingQueueReplacement() {
        guard let pending = pendingQueueReplacement else { return }
        pendingQueueReplacement = nil
        Task { await pending.play() }
    }

    func playAlbumOrToast(
        library: MusicLibraryProviding? = nil,
        tracks: [Track],
        startIndex: Int = 0,
        source: PlaybackSource? = nil,
        keepStartTrack: Bool = true
    ) async {
        guard let lib = library ?? activeLibrary else {
            showTransientToast("Sign in to play music.")
            return
        }
        guard !tracks.isEmpty else { return }
        // Kill Mode: drop already-listened songs so each run plays the unheard ones once.
        let (playTracks, playStart) = killModeFilteredPlayback(
            tracks: tracks,
            startIndex: startIndex,
            source: source,
            keepStartTrack: keepStartTrack
        )
        guard !playTracks.isEmpty else {
            showTransientToast(Self.killModeEverythingListenedMessage)
            return
        }
        await playReplacingQueue { [weak self] in
            guard let self else { return }
            do {
                try await self.player.playAlbum(library: lib, tracks: playTracks, startIndex: playStart, source: source)
            } catch {
                self.showTransientToast(error.musicPlaybackToastMessage)
            }
        }
    }

    // MARK: - Acquisition

    /// Issue a request through the active acquisition plugin. Single entry point for all
    /// request UI; surfaces a toast for the outcome.
    @discardableResult
    func requestAcquisition(_ request: AcquisitionRequest) async -> AcquisitionEnqueueResult {
        let result = await acquisition.enqueue(request)
        switch result {
        case .started:
            showTransientToast("Requested “\(request.displayTitle)”")
        case .alreadyActive:
            break
        case .notConfigured:
            showTransientToast("Set up a download plugin in Settings")
        case .failed(let message):
            showTransientToast(message)
        }
        return result
    }

    // MARK: Bulk requests ("Request Missing")

    /// Progress of an in-flight bulk request, for the Stop affordance that replaces the action.
    struct BulkAcquisitionProgress: Equatable {
        var placed: Int
        var total: Int
    }

    /// Non-nil while a bulk request is placing requests. Lives here rather than on the page's
    /// view model **because the run outlives the page**: a 300-release run takes many minutes,
    /// the user will navigate away long before it finishes, and a run that silently died on Back
    /// having placed 40 of 300 requests would be worse than not offering the action at all.
    @Published private(set) var bulkAcquisitionProgress: BulkAcquisitionProgress?
    private var bulkAcquisitionTask: Task<Void, Never>?

    /// Places every request in `requests`, one at a time, and reports the outcome once.
    ///
    /// Deliberately **sequential**. Each Lidarr request costs a catalog lookup, an add, a monitor
    /// write and a search — measured at 10 HTTP calls per new album — so firing 300 together
    /// would be the app deciding to load-test somebody's server. Sequential is also what makes
    /// Stop mean something: the request in flight finishes and nothing after it is sent.
    ///
    /// Goes through ``AcquisitionManager/enqueue(_:)`` rather than ``requestAcquisition(_:)`` for
    /// the same reason ``MusicSubscriptionEngine`` does: the latter toasts once per request, and
    /// for a 300-release run that is 300 toasts. One summary toast is shown at the end instead.
    ///
    /// Non-async so a menu Button can fire it directly. A second call while one is running is
    /// ignored rather than queued.
    func startBulkAcquisition(_ requests: [AcquisitionRequest]) {
        guard bulkAcquisitionTask == nil, !requests.isEmpty else { return }
        bulkAcquisitionProgress = BulkAcquisitionProgress(placed: 0, total: requests.count)
        bulkAcquisitionTask = Task { [weak self] in
            await self?.runBulkAcquisition(requests)
            self?.bulkAcquisitionProgress = nil
            self?.bulkAcquisitionTask = nil
        }
    }

    /// Stops an in-flight bulk request after the one currently being placed.
    func cancelBulkAcquisition() {
        bulkAcquisitionTask?.cancel()
    }

    private func runBulkAcquisition(_ requests: [AcquisitionRequest]) async {
        var placed = 0
        var failed = 0
        var stopped = false
        for request in requests {
            if Task.isCancelled { stopped = true; break }
            switch await acquisition.enqueue(request) {
            case .started, .alreadyActive:
                placed += 1
            case .failed:
                failed += 1
            case .notConfigured:
                showTransientToast("Set up a download plugin in Settings")
                return
            }
            bulkAcquisitionProgress = BulkAcquisitionProgress(placed: placed + failed, total: requests.count)
        }
        showTransientToast(Self.bulkAcquisitionSummary(
            placed: placed, failed: failed, total: requests.count, stopped: stopped
        ))
    }

    /// One sentence covering every way the run can end, rather than a cheerful count that is
    /// wrong when half of it failed.
    static func bulkAcquisitionSummary(placed: Int, failed: Int, total: Int, stopped: Bool) -> String {
        let noun = placed == 1 ? "release" : "releases"
        if stopped {
            return placed == 0 ? "Stopped — nothing requested" : "Stopped after requesting \(placed) \(noun)"
        }
        if failed == 0 { return "Requested \(placed) \(noun)" }
        if placed == 0 { return "Couldn’t request any of the \(total) releases" }
        return "Requested \(placed) of \(total) — \(failed) failed"
    }

    /// Albums on the connected server credited to `name` (normalized-artist match).
    /// The subscription engine's "do I already have this?" check; works with any backend.
    func serverAlbums(forArtistName name: String) async -> [AlbumSummary] {
        guard let lib = activeLibrary else { return [] }
        let target = LibraryTrackMatcher.normalize(name)
        let results = (try? await lib.searchCatalog(query: name, limit: 60)) ?? .empty
        return results.albums.filter { LibraryTrackMatcher.normalize($0.artist) == target }
    }

    // MARK: - Album detail related shelves

    /// Resolves a server artist id for album-detail shelves (discography fetch).
    func resolveLibraryArtistId(forArtistName name: String) async -> String? {
        guard let lib = activeLibrary else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wantExact = LibraryTrackMatcher.normalize(trimmed)
        let wantTokens = LibraryTrackMatcher.normalizedChartArtistTokens(trimmed)

        func matches(_ artistName: String) -> Bool {
            if !wantExact.isEmpty, LibraryTrackMatcher.normalize(artistName) == wantExact { return true }
            guard !wantTokens.isEmpty else { return false }
            let have = LibraryTrackMatcher.normalizedChartArtistTokens(artistName)
            return LibraryTrackMatcher.artistsOverlap(wantTokens, have)
        }

        // Fast path: targeted catalog search (one round trip vs paging all artists).
        let searchHits = (try? await lib.searchCatalog(query: trimmed, limit: 12)) ?? .empty
        if let hit = searchHits.artists.first(where: { matches($0.name) }) {
            return hit.id
        }

        // Rare fallback when search indexing misses the artist.
        let artists = (try? await lib.libraryArtists(limit: 4_000)) ?? []
        return artists.first(where: { matches($0.name) })?.id
    }

    private struct AlbumDetailShelfMemoEntry {
        let otherVersions: [AlbumSummary]
        let moreByArtist: [AlbumSummary]
        let youMightAlsoLike: [AlbumSummary]
    }

    /// Memoized shelf derivations, keyed the same way ``AlbumDetailArtistCatalogCache`` is —
    /// one layer up, over the *derivation* rather than the fetch.
    ///
    /// The rows redo this work on every scroll-into-view, and the derivation (not artwork,
    /// which never runs on this thread) is what stalls the main actor. The key carries
    /// ``albumDetailCacheSessionKey``, so a catalog change bumps `libraryCatalogEpoch` and every
    /// entry is dropped rather than going stale.
    private var albumDetailShelfMemo: [String: AlbumDetailShelfMemoEntry] = [:]
    private var albumDetailYouMightAlsoLikeMemo: [String: [AlbumSummary]] = [:]
    /// The session these memos were built for; a change clears both.
    private var albumDetailShelfMemoSessionKey = ""

    /// Drops both memos when the backend or catalog epoch moves on, so entries cannot outlive
    /// the catalog they were derived from and the dictionaries cannot grow across epochs.
    private func invalidateAlbumDetailShelfMemosIfNeeded(_ sessionKey: String) {
        guard albumDetailShelfMemoSessionKey != sessionKey else { return }
        albumDetailShelfMemoSessionKey = sessionKey
        albumDetailShelfMemo.removeAll()
        albumDetailYouMightAlsoLikeMemo.removeAll()
    }

    /// Instant album-detail shelves from the in-memory catalog page (no network).
    func albumDetailShelvesFromMemory(
        artist: String,
        title: String,
        excludingAlbumId: String?,
    ) -> (otherVersions: [AlbumSummary], moreByArtist: [AlbumSummary], youMightAlsoLike: [AlbumSummary]) {
        let sessionKey = albumDetailCacheSessionKey()
        var memoKey = ""
        if !sessionKey.isEmpty {
            invalidateAlbumDetailShelfMemosIfNeeded(sessionKey)
            memoKey = "\(sessionKey)|\(artist)|\(title)|\(excludingAlbumId ?? "")"
            if let hit = albumDetailShelfMemo[memoKey] {
#if DEBUG
                DebugUIRemote.log("SHELF memo=hit kind=shelves artist=\(artist)")
#endif
                return (hit.otherVersions, hit.moreByArtist, hit.youMightAlsoLike)
            }
        }
#if DEBUG
        DebugUIRemote.log("SHELF memo=miss kind=shelves artist=\(artist) "
            + "keyed=\(memoKey.isEmpty ? "no" : "yes") catalog=\(libraryAlbums.count)")
#endif
        let catalog = libraryAlbums.filter { albumDetailArtistMatches($0.artist, referenceArtist: artist) }
        let versions = albumDetailOtherVersions(
            in: catalog,
            artist: artist,
            title: title,
            excludingAlbumId: excludingAlbumId,
        )
        let versionIDs = Set(versions.map(\.id))
        let more = albumDetailMoreByArtist(
            in: catalog,
            artist: artist,
            excludingAlbumId: excludingAlbumId,
            excludingVersionIDs: versionIDs,
        )
        let ymal = albumDetailYouMightAlsoLike(
            artist: artist,
            excludingAlbumId: excludingAlbumId,
            excludingVersionIDs: versionIDs,
        )
        // Only memoize a derivation that had real inputs AND produced something. Storing an empty
        // result computed before `libraryAlbums` had loaded is what made the shelf vanish for good
        // on an album: the empty went into the memo under this key, and every later visit was a hit
        // returning it. A genuinely empty shelf is recomputed each visit instead — cheap, and
        // correctness beats saving that work.
        let derivedFromLoadedCatalog = !libraryAlbums.isEmpty
        let producedSomething = !versions.isEmpty || !more.isEmpty || !ymal.isEmpty
        if !memoKey.isEmpty, derivedFromLoadedCatalog, producedSomething {
            albumDetailShelfMemo[memoKey] = AlbumDetailShelfMemoEntry(
                otherVersions: versions,
                moreByArtist: more,
                youMightAlsoLike: ymal,
            )
        }
        return (versions, more, ymal)
    }

    /// Start the album-detail shelves as soon as the album view opens, instead of when the shelf
    /// row scrolls into sight.
    ///
    /// **Executor: the main actor, on purpose, and no new thread.** The derivation reads
    /// `libraryAlbums` and the personalization context, both `@Published` state on this
    /// `@MainActor` model, so running it anywhere else would mean snapshotting that state into a
    /// `Sendable` copy — a real refactor with real data-race risk, to buy nothing here. Audio is
    /// unaffected either way: playback renders on `MTAudioProcessingTap`'s real-time thread, which
    /// takes no locks and never touches this actor, so main-actor work cannot stall it.
    ///
    /// **It must not slow the album open**, which is currently fine on device. Two things ensure
    /// that: the wait below lets the push transition finish before any CPU work starts, and the
    /// catalog fetch suspends on the network, so the main thread is free while it is in flight.
    /// The derivation lands in the memo, so the shelf's own pass is a hit.
    func warmAlbumDetailShelves(artist: String, title: String, excludingAlbumId: String?) async {
        // The fetch goes FIRST and with no delay. Waiting 550ms before even starting it lost the
        // race against a fast scroll — still saw the shelf pop in at the bottom. The fetch is
        // network-bound and suspends immediately, so starting it early costs the opening screen
        // nothing, and it is the part that must be finished before the shelf can render at all.
        let started = CFAbsoluteTimeGetCurrent()
        _ = await fetchAlbumDetailArtistCatalog(artist: artist)
        guard !Task.isCancelled else { return }

        // Only the CPU-bound derivation waits, and only for however much of the settle window the
        // fetch did not already use. A cached fetch returns instantly and this still holds the work
        // off the main actor until the push has done its heavy frames; a slow fetch has already
        // covered the window and the derivation runs straight away.
        let settle = 0.35
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if elapsed < settle {
            try? await Task.sleep(for: .milliseconds(Int((settle - elapsed) * 1000)))
        }
        guard !Task.isCancelled else { return }
        _ = albumDetailShelvesFromMemory(
            artist: artist,
            title: title,
            excludingAlbumId: excludingAlbumId,
        )
    }

    /// Full server discography for album-detail carousels — not limited to the cached ``libraryAlbums`` page.
    func fetchAlbumDetailArtistCatalog(artist: String) async -> [AlbumSummary] {
        guard let lib = activeLibrary else { return [] }
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sessionKey = albumDetailCacheSessionKey()
        if let cached = await AlbumDetailArtistCatalogCache.shared.load(artistName: trimmed, sessionKey: sessionKey) {
            return cached
        }

        let memory = libraryAlbums.filter { albumDetailArtistMatches($0.artist, referenceArtist: trimmed) }

        if let artistId = await resolveLibraryArtistId(forArtistName: trimmed) {
            let albums = (try? await lib.albums(forLibraryArtistId: artistId, limit: 400)) ?? []
            if !albums.isEmpty {
                let sorted = sortAlbumDetailRelatedAlbums(albums)
                await AlbumDetailArtistCatalogCache.shared.save(
                    artistName: trimmed,
                    sessionKey: sessionKey,
                    albums: sorted,
                )
                return sorted
            }
        }

        let searchHits = (try? await lib.searchCatalog(query: trimmed, limit: 80)) ?? .empty
        let fromSearch = searchHits.albums.filter { albumDetailArtistMatches($0.artist, referenceArtist: trimmed) }
        if !fromSearch.isEmpty {
            let sorted = sortAlbumDetailRelatedAlbums(dedupeAlbumSummariesById(fromSearch))
            await AlbumDetailArtistCatalogCache.shared.save(
                artistName: trimmed,
                sessionKey: sessionKey,
                albums: sorted,
            )
            return sorted
        }

        let sorted = sortAlbumDetailRelatedAlbums(memory)
        if !sorted.isEmpty {
            await AlbumDetailArtistCatalogCache.shared.save(
                artistName: trimmed,
                sessionKey: sessionKey,
                albums: sorted,
            )
        }
        return sorted
    }

    private func albumDetailCacheSessionKey() -> String {
        guard isSignedIn else { return "" }
        return "\(backendKind.rawValue)|\(libraryCatalogEpoch)"
    }

    /// True when a catalog row's artist line refers to the same performer(s).
    func albumDetailArtistMatches(_ albumArtistLine: String, referenceArtist: String) -> Bool {
        let want = LibraryTrackMatcher.normalizedChartArtistTokens(referenceArtist)
        let have = LibraryTrackMatcher.normalizedChartArtistTokens(albumArtistLine)
        guard !want.isEmpty, !have.isEmpty else { return false }
        return LibraryTrackMatcher.artistsOverlap(want, have)
    }

    /// Alternate editions on the server (single, EP, deluxe, reinvented, etc.).
    func albumDetailOtherVersions(
        in catalog: [AlbumSummary],
        artist: String,
        title: String,
        excludingAlbumId: String?,
    ) -> [AlbumSummary] {
        let baseKey = AlbumSummary.albumVersionBaseKey(title)
        guard baseKey.count >= 3 else { return [] }

        let reference = AlbumSummary(
            id: excludingAlbumId ?? "",
            title: title,
            artist: artist,
            artworkURL: nil,
        )

        let matches = catalog.filter { album in
            guard album.id != excludingAlbumId else { return false }
            guard albumDetailArtistMatches(album.artist, referenceArtist: artist) else { return false }
            return reference.isOtherVersion(of: album)
        }
        return sortAlbumDetailRelatedAlbums(matches)
    }

    /// More albums by the same artist from the server catalog.
    func albumDetailMoreByArtist(
        in catalog: [AlbumSummary],
        artist: String,
        excludingAlbumId: String?,
        excludingVersionIDs: Set<String> = [],
        limit: Int = 15,
    ) -> [AlbumSummary] {
        let matches = catalog.filter { album in
            album.id != excludingAlbumId
                && !excludingVersionIDs.contains(album.id)
                && albumDetailArtistMatches(album.artist, referenceArtist: artist)
        }
        return Array(sortAlbumDetailRelatedAlbums(matches).prefix(limit))
    }

    /// Taste-ranked server albums by other artists (listening signal from scrobbles, favorites, genres).
    func albumDetailYouMightAlsoLike(
        artist: String,
        excludingAlbumId: String?,
        excludingVersionIDs: Set<String> = [],
        limit: Int = 15,
    ) -> [AlbumSummary] {
        // Memoized separately from the shelf tuple because `refreshShelvesFromServer` calls this
        // again on its own after awaiting the catalog. It reads `libraryAlbums` and its inputs are
        // only artist / exclusions / limit — it does *not* depend on the catalog just awaited — so
        // the session key plus those inputs fully determines the result.
        let sessionKey = albumDetailCacheSessionKey()
        var memoKey = ""
        if !sessionKey.isEmpty {
            invalidateAlbumDetailShelfMemosIfNeeded(sessionKey)
            memoKey = "\(sessionKey)|\(artist)|\(excludingAlbumId ?? "")|\(limit)|"
                + excludingVersionIDs.sorted().joined(separator: ",")
            if let hit = albumDetailYouMightAlsoLikeMemo[memoKey] {
#if DEBUG
                DebugUIRemote.log("SHELF memo=hit kind=ymal artist=\(artist)")
#endif
                return hit
            }
        }
#if DEBUG
        DebugUIRemote.log("SHELF memo=miss kind=ymal artist=\(artist) catalog=\(libraryAlbums.count)")
#endif
        let excludeIDs = Set([excludingAlbumId].compactMap { $0 }).union(excludingVersionIDs)
        let candidates = libraryAlbums.filter { album in
            !excludeIDs.contains(album.id)
                && !albumDetailArtistMatches(album.artist, referenceArtist: artist)
        }
        let ranked = NewTabPersonalizationEngine.tasteRankedAlbumSummaries(
            candidates,
            context: newTabPersonalizationContext(),
            limit: limit,
        )
        // Same rule as the shelves memo above: no catalog or no result means no memo entry.
        if !memoKey.isEmpty, !libraryAlbums.isEmpty, !ranked.isEmpty {
            albumDetailYouMightAlsoLikeMemo[memoKey] = ranked
        }
        return ranked
    }

    private func dedupeAlbumSummariesById(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        var seen = Set<String>()
        return albums.filter { seen.insert($0.id).inserted }
    }

    private func sortAlbumDetailRelatedAlbums(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        albums.sorted { lhs, rhs in
            let ly = lhs.releaseYear ?? 0
            let ry = rhs.releaseYear ?? 0
            if ly != ry { return ly > ry }
            if let ld = lhs.releaseDate, let rd = rhs.releaseDate, ld != rd {
                return ld > rd
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Re-run the follow-artist completeness pass (foreground / manual "Check now").
    func refreshSubscriptions() async {
        await subscriptions.checkAll()
    }

    /// Persists a config field for a plugin and nudges observers (gating recomputes).
    func setAcquisitionConfig(_ value: String, for kind: AcquisitionPluginKind, field: String) {
        AcquisitionConfigStore.set(value, kind, field)
        objectWillChange.send()
    }

    /// Clears all stored credentials for a plugin.
    func disconnectAcquisitionPlugin(_ kind: AcquisitionPluginKind) {
        AcquisitionConfigStore.clear(kind, fields: AcquisitionManager.capabilities(for: kind).configFields)
        objectWillChange.send()
    }

    /// Preview track listing for **New tab / browse** flows. Not used for owned library albums in ``ServerPlaylistDetailView``.
    func resolveBrowseAlbumPreviewTracks(source: BrowseAlbumDetailSource) async -> [BrowseAlbumPreviewTrack] {
        switch source {
        case .chartBrowse(let artist, let title, _, let kind, let albumId):
            let tracks = await acquisition.tracks(forBrowseAlbumId: albumId, artist: artist, title: title)
            if !tracks.isEmpty { return tracks }
            if kind.lowercased() == "single" || kind.lowercased() == "ep" {
                return [
                    BrowseAlbumPreviewTrack(
                        id: "chart-single:\(artist):\(title)",
                        position: 1,
                        title: title,
                        duration: nil,
                    ),
                ]
            }
            return []
        }
    }

    // MARK: - Radio (Navidrome + Radio Browser directory)

    @Published private(set) var customRadioStations: [CustomRadioStation] = []
    /// O(1) "is this directory station already saved?" for browse rows.
    @Published private(set) var savedDirectoryStationUUIDs: Set<String> = []

    func reloadCustomRadioStations() {
        applyCustomRadioStations(CustomRadioStationStore.load())
    }

    /// In-memory Your Stations list — one publish for rows + O(1) directory lookups.
    private func applyCustomRadioStations(_ stations: [CustomRadioStation]) {
        customRadioStations = stations
        savedDirectoryStationUUIDs = Set(stations.compactMap(\.directoryStationUUID))
    }

    private func sortedCustomRadioStations(_ stations: [CustomRadioStation]) -> [CustomRadioStation] {
        stations.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func isDirectoryStationSaved(_ uuid: String) -> Bool {
        savedDirectoryStationUUIDs.contains(uuid)
    }

    func toggleSavedDirectoryStation(_ station: RadioDirectoryStation) {
        if savedDirectoryStationUUIDs.contains(station.stationUUID) {
            applyCustomRadioStations(
                customRadioStations.filter { $0.directoryStationUUID != station.stationUUID }
            )
            Task { @MainActor in
                CustomRadioStationStore.removeDirectoryStation(uuid: station.stationUUID)
            }
            Task { @MainActor in
                showTransientToast("Removed from Your Stations")
            }
        } else {
            let custom = station.asCustomRadioStation()
            let snapshot = customRadioStations
            applyCustomRadioStations(sortedCustomRadioStations(customRadioStations + [custom]))
            Task { @MainActor in
                do {
                    _ = try CustomRadioStationStore.add(custom)
                } catch {
                    applyCustomRadioStations(snapshot)
                    errorMessage = error.localizedDescription
                }
            }
            Task { @MainActor in
                showTransientToast(
                    TransientToastContent(
                        title: "Saved to Your Stations",
                        subtitle: station.name,
                        artworkURL: station.faviconURL,
                    )
                )
            }
        }
    }

    func addCustomRadioStation(name: String, streamURL: URL, artworkData: Data?) throws {
        let station = try CustomRadioStationStore.add(
            name: name,
            streamURL: streamURL,
            artworkData: artworkData,
        )
        applyCustomRadioStations(sortedCustomRadioStations(customRadioStations + [station]))
        Task { @MainActor in
            showTransientToast("Station added")
        }
    }

    func removeCustomRadioStation(id: String, notify: Bool = true) {
        guard customRadioStations.contains(where: { $0.id == id }) else { return }
        applyCustomRadioStations(customRadioStations.filter { $0.id != id })
        Task { @MainActor in
            CustomRadioStationStore.remove(id: id)
        }
        if notify {
            Task { @MainActor in
                showTransientToast("Station removed")
            }
        }
    }

    /// Whether the active radio stream is already saved under **Your Stations**.
    func isRadioTrackInYourStations(_ track: Track) -> Bool {
        savedCustomRadioStation(matching: track) != nil
    }

    /// Adds or removes the playing radio stream from **Your Stations**.
    /// Mirrors ``toggleFavoriteTrack(id:)``: flip in-memory state immediately, persist async, no playback side effects.
    func toggleRadioTrackInYourStations(_ track: Track) {
        guard track.isInternetRadioStream, track.streamOverrideURL != nil else { return }
        if let existing = savedCustomRadioStation(matching: track) {
            removeCustomRadioStation(id: existing.id, notify: false)
            return
        }
        guard let streamURL = track.streamOverrideURL else { return }
        let remoteArtwork = track.artworkURL.flatMap { url in
            url.isFileURL ? nil : url
        }
        let station = CustomRadioStation(
            name: track.title,
            streamURL: streamURL,
            remoteArtworkURL: remoteArtwork,
            directoryStationUUID: Self.directoryStationUUID(fromPlayingTrackId: track.id),
            detailLine: "Live stream",
        )
        let snapshot = customRadioStations
        applyCustomRadioStations(sortedCustomRadioStations(customRadioStations + [station]))
        Task { @MainActor in
            do {
                _ = try CustomRadioStationStore.add(station)
            } catch {
                applyCustomRadioStations(snapshot)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func savedCustomRadioStation(matching track: Track) -> CustomRadioStation? {
        if let stationId = Self.customRadioStationId(fromPlayingTrackId: track.id),
           let match = customRadioStations.first(where: { $0.id == stationId }) {
            return match
        }
        if let uuid = Self.directoryStationUUID(fromPlayingTrackId: track.id),
           let match = customRadioStations.first(where: { $0.directoryStationUUID == uuid }) {
            return match
        }
        guard let streamURL = track.streamOverrideURL else { return nil }
        return customRadioStations.first { $0.streamURL == streamURL }
    }

    private static func customRadioStationId(fromPlayingTrackId trackId: String) -> String? {
        let prefix = "vellum-radio-custom-"
        guard trackId.hasPrefix(prefix) else { return nil }
        let id = String(trackId.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Radio Browser directory plays use `internet-radio-<stationuuid>` track ids.
    private static func directoryStationUUID(fromPlayingTrackId trackId: String) -> String? {
        let prefix = "internet-radio-"
        guard trackId.hasPrefix(prefix) else { return nil }
        let suffix = String(trackId.dropFirst(prefix.count))
        guard isRadioBrowserStationUUID(suffix) else { return nil }
        return suffix
    }

    private static func isRadioBrowserStationUUID(_ value: String) -> Bool {
        value.count == 36 && value.filter { $0 == "-" }.count == 4
    }

    private static func customRadioTrackId(stationId: String) -> String {
        "vellum-radio-custom-\(stationId)"
    }

    /// Plays a live stream from the server's internet radio list, the Radio Browser
    /// directory, or a user-added station.
    func playInternetRadioStation(_ station: InternetRadioStation) async {
        let track = Track(
            id: station.isUserAdded ? "vellum-radio-\(station.id)" : "internet-radio-\(station.id)",
            title: station.name,
            albumId: "internet-radio",
            albumTitle: "Live Radio",
            artist: station.name,
            duration: 0,
            discNumber: 1,
            indexNumber: 1,
            artworkURL: station.artworkURL,
            streamOverrideURL: station.streamURL,
        )
        player.shuffleMode = .off
        // Directory popularity only works if clients report plays. Fire-and-forget.
        if let uuid = station.directoryStationUUID, !effectiveOfflineMode {
            Task.detached(priority: .background) {
                await RadioBrowserClient.shared.registerPlay(stationUUID: uuid)
            }
        }
        do {
            try await player.playAlbum(library: activeLibrary, tracks: [track], startIndex: 0)
        } catch {
            guard !Self.isBenignPlaybackInterruption(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func isBenignPlaybackInterruption(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue { return true }
        return false
    }

    /// Updates ``favoriteTrackIds`` immediately (stars, menus, rows); Jellyfin / Navidrome persist in the background with revert on failure.
    func toggleFavoriteTrack(id: String) {
        let targetFavorite = !favoriteTrackIds.contains(id)

        if targetFavorite, favoritesAutoDownload {
            if let track = discoveryTrackById[id] ?? offline.cachedTrack(id: id) {
                offline.enqueueTrack(track)
            }
        }

        if backendKind == .jellyfin, let client = jellyfin {
            let snapshot = favoriteTrackIds
            var next = favoriteTrackIds
            if targetFavorite { next.insert(id) } else { next.remove(id) }
            favoriteTrackIds = next
            Task { @MainActor in
                do {
                    try await client.setFavorite(trackId: id, favorite: targetFavorite)
                } catch {
                    favoriteTrackIds = snapshot
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        if backendKind == .navidrome, let client = navidrome {
            let snapshot = favoriteTrackIds
            var next = favoriteTrackIds
            if targetFavorite { next.insert(id) } else { next.remove(id) }
            favoriteTrackIds = next
            Task { @MainActor in
                do {
                    try await client.setFavorite(trackId: id, favorite: targetFavorite)
                } catch {
                    favoriteTrackIds = snapshot
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        var next = favoriteTrackIds
        if targetFavorite { next.insert(id) } else { next.remove(id) }
        favoriteTrackIds = next
        UserDefaults.standard.set(Array(next), forKey: Self.favoriteTrackIdsKey)
    }

    private func loadFavoriteTrackIdsFromDefaults() {
        favoriteTrackIds = Set(UserDefaults.standard.stringArray(forKey: Self.favoriteTrackIdsKey) ?? [])
        favoriteArtistNames = Set(UserDefaults.standard.stringArray(forKey: Self.favoriteArtistNamesKey) ?? [])
    }

    /// Toggles the favorite state for an artist by name. Stored locally only.
    func toggleFavoriteArtist(name: String) {
        let key = LibraryTrackMatcher.normalize(name)
        guard !key.isEmpty else { return }
        var next = favoriteArtistNames
        if next.contains(key) {
            next.remove(key)
        } else {
            next.insert(key)
        }
        favoriteArtistNames = next
        UserDefaults.standard.set(Array(next), forKey: Self.favoriteArtistNamesKey)
    }

    func isArtistFavorited(name: String) -> Bool {
        let key = LibraryTrackMatcher.normalize(name)
        return !key.isEmpty && favoriteArtistNames.contains(key)
    }

    private func loadRecentlyPlayedEntriesFromDefaults() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.recentlyPlayedEntriesKey),
           let decoded = try? JSONDecoder().decode([RecentPlayedEntry].self, from: data) {
            recentlyPlayedEntries = decoded
            rebuildHomeRecentlyPlayed()
            return
        }
        // Migrate the legacy album-only string array, then drop the old key.
        if let legacy = defaults.stringArray(forKey: Self.recentlyPlayedAlbumIdsKey), !legacy.isEmpty {
            let migrated = legacy.map { RecentPlayedEntry(kind: .album, id: $0) }
            recentlyPlayedEntries = migrated
            saveRecentlyPlayedEntriesToDefaults()
            defaults.removeObject(forKey: Self.recentlyPlayedAlbumIdsKey)
            rebuildHomeRecentlyPlayed()
        }
    }

    private func saveRecentlyPlayedEntriesToDefaults() {
        let defaults = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(recentlyPlayedEntries) else { return }
        defaults.set(data, forKey: Self.recentlyPlayedEntriesKey)
    }

    func playlistLastPlayedDate(forPlaylistId id: String) -> Date? {
        playlistLastPlayedDates[id]
    }

    /// Resolves which playlist Now Playing → Go to Playlist should open for the active track.
    /// User-queued tracks remember the playlist they were inserted from; otherwise falls back to ``PlaybackEngine/playbackSource``.
    func sourcePlaylistForNowPlaying(activeTrack: Track?, playbackSource: PlaybackSource?) -> PlaylistSummary? {
        guard let track = activeTrack else { return nil }
        if let originId = player.originPlaylistId(forTrackId: track.id),
           let match = libraryPlaylists.first(where: { $0.id == originId }) {
            return match
        }
        if case .playlist(let playlist) = playbackSource {
            return libraryPlaylists.first(where: { $0.id == playlist.id }) ?? playlist
        }
        return nil
    }

    private func loadPlaylistLastPlayedDatesFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.playlistLastPlayedDatesKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        playlistLastPlayedDates = decoded
    }

    private func loadPlaylistCreatedDatesFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.playlistCreatedDatesKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        playlistCreatedDates = decoded
    }

    func recordPlaylistCreated(_ id: String) {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        playlistCreatedDates[key] = Date()
        guard let data = try? JSONEncoder().encode(playlistCreatedDates) else { return }
        UserDefaults.standard.set(data, forKey: Self.playlistCreatedDatesKey)
    }

    /// Bumps a playlist to the front of the add-to-playlist sheet's Recents.
    func noteAddedToPlaylist(playlistId: String) {
        var next = recentAddToPlaylistIds.filter { $0 != playlistId }
        next.insert(playlistId, at: 0)
        recentAddToPlaylistIds = Array(next.prefix(Self.recentAddToPlaylistIdsLimit))
        UserDefaults.standard.set(recentAddToPlaylistIds, forKey: Self.recentAddToPlaylistIdsKey)
    }

    private func loadRecentAddToPlaylistIdsFromDefaults() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentAddToPlaylistIdsKey) ?? []
        recentAddToPlaylistIds = Array(stored.prefix(Self.recentAddToPlaylistIdsLimit))
    }

    private func savePlaylistLastPlayedDatesToDefaults() {
        guard let data = try? JSONEncoder().encode(playlistLastPlayedDates) else { return }
        UserDefaults.standard.set(data, forKey: Self.playlistLastPlayedDatesKey)
    }

    /// Records that the user played a track. Plays sourced from a playlist record the playlist;
    /// ad-hoc/album queues fall back to the track's album. Called by `PlaybackEngine` once per
    /// track when scrobble fires (so a brief preview play doesn't pollute the shelf).
    func recordRecentPlay(track: Track, source: PlaybackSource?) {
        let entry: RecentPlayedEntry
        switch source {
        case .playlist(let playlist):
            let id = playlist.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            entry = RecentPlayedEntry(kind: .playlist, id: id)
            playlistLastPlayedDates[id] = Date()
            savePlaylistLastPlayedDatesToDefaults()
        case .none:
            let id = track.albumId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            entry = RecentPlayedEntry(kind: .album, id: id)
        }
        var next = recentlyPlayedEntries.filter { $0 != entry }
        next.insert(entry, at: 0)
        if next.count > Self.recentlyPlayedEntriesLimit {
            next = Array(next.prefix(Self.recentlyPlayedEntriesLimit))
        }
        recentlyPlayedEntries = next
        saveRecentlyPlayedEntriesToDefaults()
        rebuildHomeRecentlyPlayed()
        writeWidgetData()
    }

    public func writeWidgetData() {
        var seen = Set<String>()
        let recent = recentlyPlayedTracks.compactMap { track -> WidgetDataStore.MusicItem? in
            let id = track.albumId.isEmpty ? track.id : track.albumId
            guard seen.insert(id).inserted else { return nil }
            return WidgetDataStore.MusicItem(
                id: id,
                title: track.albumTitle.isEmpty ? track.title : track.albumTitle,
                artist: track.artist,
                artworkURLString: resolvedArtworkURL(for: track)?.absoluteString,
                kind: .album
            )
        }.prefix(6)

        let nowPlaying: WidgetDataStore.MusicItem? = player.activeTrack.map { track in
            WidgetDataStore.MusicItem(
                id: track.albumId.isEmpty ? track.id : track.albumId,
                title: track.albumTitle.isEmpty ? track.title : track.albumTitle,
                artist: track.artist,
                artworkURLString: resolvedArtworkURL(for: track)?.absoluteString,
                kind: .album
            )
        }

        let accentHex = AppAccentPreset.hex(from: AppAccentPreset.current.color)
        let payload = WidgetDataStore.Payload(
            recentlyPlayed: Array(recent),
            nowPlaying: nowPlaying,
            isPlaying: player.isPlaying,
            updatedAt: Date(),
            accentHex: accentHex
        )
        WidgetDataStore.write(payload)
        #if os(iOS)
        // First reload: title/artist/play-state update immediately.
        WidgetCenter.shared.reloadAllTimelines()
        // Second reload: after artwork is fetched and saved to the shared container.
        let allItems = Array(recent) + (nowPlaying.map { [$0] } ?? [])
        Task.detached(priority: .utility) {
            let wrote = await WidgetDataStore.cacheArtwork(items: allItems)
            if wrote {
                await WidgetCenter.shared.reloadAllTimelines()
            }
        }
        #endif
    }

    private func rebuildHomeRecentlyPlayed() {
        let local = localRecentlyPlayed(limit: 24)
        let server = homeRecentlyPlayedServerAlbums.map(RecentPlayedItem.album)
        var seen = Set<String>()
        let merged = (local + server).filter { seen.insert($0.id).inserted }
        homeRecentlyPlayed = Array(merged.prefix(12))
    }

    private func loadRecentlyPlayedTracksFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentlyPlayedTracksKey),
              let decoded = try? JSONDecoder().decode([Track].self, from: data)
        else { return }
        recentlyPlayedTracks = decoded
    }

    /// Persist the history list, encoding off the main actor.
    ///
    /// This is reached from `recordRecentTrackPlay`, which is wired to
    /// `PlaybackEngine.onTrackStarted` — so it fires on every track change, including the
    /// `jumpToQueueItem` that a queue row's own Button calls. Encoding up to 100 `Track` structs
    /// synchronously put a full JSON encode in the same runloop pass as the page-snap animation
    /// that tap had just started.
    ///
    /// The write itself stays on the main actor and is generation-checked, so two saves racing
    /// cannot land out of order and persist an older history than the one in memory.
    private func saveRecentlyPlayedTracksToDefaults() {
        recentlyPlayedSaveGeneration &+= 1
        let generation = recentlyPlayedSaveGeneration
        let snapshot = recentlyPlayedTracks
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.recentlyPlayedSaveGeneration == generation else { return }
                UserDefaults.standard.set(data, forKey: Self.recentlyPlayedTracksKey)
            }
        }
    }

    /// Logs a single track as actually-played. Called by `PlaybackEngine` only when the
    /// scrobble threshold (~50% of the track) is crossed, so skipping past a song does
    /// NOT add it to history.
    func recordRecentTrackPlay(_ track: Track) {
        let trimmedId = track.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        var next = recentlyPlayedTracks.filter { $0.id != trimmedId }
        next.insert(track, at: 0)
        if next.count > Self.recentlyPlayedTracksLimit {
            next = Array(next.prefix(Self.recentlyPlayedTracksLimit))
        }
        recentlyPlayedTracks = next
        saveRecentlyPlayedTracksToDefaults()
    }

    /// Wipes the track-level Now Playing → Queue → History list (Clear button).
    func clearRecentlyPlayedTracks() {
        recentlyPlayedTracks = []
        UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedTracksKey)
    }

    /// Wipes the local recently-played history (Now Playing → Queue → History "Clear" button).
    func clearRecentlyPlayed() {
        recentlyPlayedEntries = []
        UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedEntriesKey)
        rebuildHomeRecentlyPlayed()
    }

    /// Resolves the local recently-played list against the in-memory library / playlist catalogs.
    /// Used as a fallback when the backend's `recentlyPlayed` endpoint returns nothing.
    func localRecentlyPlayed(limit: Int = 12) -> [RecentPlayedItem] {
        let albumsById = libraryAlbumsById
        let playlistsById = Dictionary(uniqueKeysWithValues: libraryPlaylists.map { ($0.id, $0) })
        var out: [RecentPlayedItem] = []
        out.reserveCapacity(limit)
        for entry in recentlyPlayedEntries {
            switch entry.kind {
            case .album:
                if let album = albumsById[entry.id] { out.append(.album(album)) }
            case .playlist:
                if let playlist = playlistsById[entry.id] { out.append(.playlist(playlist)) }
            }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Settings persistence, quality, sync, EQ

    private func loadPersistedSettings() {
        if let raw = UserDefaults.standard.string(forKey: Self.themePreferenceKey),
           let v = AppThemePreference(rawValue: raw) {
            themePreference = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.wifiStreamQualityKey),
           let v = StreamQualityTier(rawValue: raw) {
            wifiStreamQuality = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.cellularStreamQualityKey),
           let v = StreamQualityTier(rawValue: raw) {
            cellularStreamQuality = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.downloadQualityKey),
           let v = DownloadQualityTier(rawValue: raw) {
            downloadQualityTier = v
        }
        migrateLegacyStreamQualityIfNeeded()
        if let v = StreamBitRateOption(rawValue: UserDefaults.standard.integer(forKey: Self.wifiStreamBitRateKey)),
           UserDefaults.standard.object(forKey: Self.wifiStreamBitRateKey) != nil {
            wifiStreamBitRate = v
        }
        if let v = StreamBitRateOption(rawValue: UserDefaults.standard.integer(forKey: Self.cellularStreamBitRateKey)),
           UserDefaults.standard.object(forKey: Self.cellularStreamBitRateKey) != nil {
            cellularStreamBitRate = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.wifiStreamFormatKey),
           let v = StreamFormatOption(rawValue: raw) {
            wifiStreamFormat = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.cellularStreamFormatKey),
           let v = StreamFormatOption(rawValue: raw) {
            cellularStreamFormat = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.downloadFormatKey),
           let v = DownloadFormatOption(rawValue: raw) {
            downloadFormat = v
        }
        if let v = SkipIntervalOption(rawValue: UserDefaults.standard.integer(forKey: Self.skipBackwardIntervalKey)),
           UserDefaults.standard.object(forKey: Self.skipBackwardIntervalKey) != nil {
            skipBackwardInterval = v
        }
        if let v = SkipIntervalOption(rawValue: UserDefaults.standard.integer(forKey: Self.skipForwardIntervalKey)),
           UserDefaults.standard.object(forKey: Self.skipForwardIntervalKey) != nil {
            skipForwardInterval = v
        }
        if UserDefaults.standard.object(forKey: Self.showSkipIntervalButtonsKey) != nil {
            showSkipIntervalButtons = UserDefaults.standard.bool(forKey: Self.showSkipIntervalButtonsKey)
        }
        if UserDefaults.standard.object(forKey: Self.showSleepTimerButtonKey) != nil {
            showSleepTimerButton = UserDefaults.standard.bool(forKey: Self.showSleepTimerButtonKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.remoteControlModeKey),
           let v = RemoteControlMode(rawValue: raw) {
            remoteControlMode = v
        }
        if UserDefaults.standard.object(forKey: Self.playbackRateKey) != nil {
            let rate = UserDefaults.standard.float(forKey: Self.playbackRateKey)
            if let match = PlaybackRateOption(rawValue: rate) {
                defaultPlaybackRate = match
            }
        }
        if let raw = UserDefaults.standard.string(forKey: Self.artistPlayModeKey),
           let mode = ArtistPlayMode(rawValue: raw) {
            artistPlayMode = mode
        }
        if UserDefaults.standard.object(forKey: Self.showHomeMixesInPlaylistsKey) != nil {
            showHomeMixesInPlaylists = UserDefaults.standard.bool(forKey: Self.showHomeMixesInPlaylistsKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.metadataRefreshThresholdKey),
           let v = MetadataRefreshThreshold(rawValue: raw) {
            metadataRefreshThreshold = v
        }
        if let raw = UserDefaults.standard.string(forKey: Self.serverFailoverModeKey),
           let mode = ServerFailoverMode(rawValue: raw) {
            serverFailoverMode = mode
        }
        if let raw = UserDefaults.standard.string(forKey: Self.songListItemSizeKey),
           let v = SongListItemSize(rawValue: raw) {
            songListItemSize = v
        }
        let syncTs = UserDefaults.standard.double(forKey: Self.lastLibrarySyncAtKey)
        if syncTs > 0 {
            lastLibrarySyncAt = Date(timeIntervalSince1970: syncTs)
        }
        if UserDefaults.standard.object(forKey: Self.volumeNormalizationKey) != nil {
            volumeNormalizationEnabled = UserDefaults.standard.bool(forKey: Self.volumeNormalizationKey)
        }
        if UserDefaults.standard.object(forKey: Self.albumBackdropEnabledKey) != nil {
            albumBackdropEnabled = UserDefaults.standard.bool(forKey: Self.albumBackdropEnabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.playlistBackdropEnabledKey) != nil {
            playlistBackdropEnabled = UserDefaults.standard.bool(forKey: Self.playlistBackdropEnabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.playerBackdropEnabledKey) != nil {
            playerBackdropEnabled = UserDefaults.standard.bool(forKey: Self.playerBackdropEnabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.offlineModeKey) != nil {
            offlineMode = UserDefaults.standard.bool(forKey: Self.offlineModeKey)
        }
        if UserDefaults.standard.object(forKey: Self.autoOfflineEnabledKey) != nil {
            autoOfflineEnabled = UserDefaults.standard.bool(forKey: Self.autoOfflineEnabledKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.autoOfflineModeKey),
           let mode = AutoOfflineMode(rawValue: raw) {
            autoOfflineMode = mode
        }
        homeWifiSSIDs = UserDefaults.standard.stringArray(forKey: Self.homeWifiSSIDsKey) ?? []
        if UserDefaults.standard.object(forKey: Self.wifiOnlyDownloadsKey) != nil {
            wifiOnlyDownloads = UserDefaults.standard.bool(forKey: Self.wifiOnlyDownloadsKey)
        }
        if let raw = UserDefaults.standard.object(forKey: Self.maxConcurrentDownloadsKey) as? Int,
           let value = OfflineMaxConcurrentDownloads(rawValue: raw) {
            maxConcurrentDownloads = value
        }
        if let raw = UserDefaults.standard.string(forKey: Self.storageLimitModeKey),
           let mode = OfflineStorageLimitMode(rawValue: raw) {
            offlineStorageLimitMode = mode
        }
        if UserDefaults.standard.object(forKey: Self.maxCacheSizeGBKey) != nil {
            maxCacheSizeGB = UserDefaults.standard.double(forKey: Self.maxCacheSizeGBKey)
        }
        if UserDefaults.standard.object(forKey: Self.favoritesAutoDownloadKey) != nil {
            favoritesAutoDownload = UserDefaults.standard.bool(forKey: Self.favoritesAutoDownloadKey)
        }
    }

    private func wireOfflineDownloadManager() {
        offline.wifiOnlyDownloads = wifiOnlyDownloads
        offline.maxConcurrentDownloads = maxConcurrentDownloads
        offline.storageLimitMode = offlineStorageLimitMode
        offline.maxCacheSizeGB = maxCacheSizeGB
        offline.artworkURLForTrack = { [weak self] track in
            self?.resolvedArtworkURL(for: track)
        }
        offline.configure(
            libraryProvider: { [weak self] in self?.activeLibrary },
            networkPolicy: { [weak self] in
                guard let self else { return (online: true, wifiLike: true) }
                return (online: self.hasInternetPath, wifiLike: self.prefersWifiLikePath)
            },
        )
        offline.recalculateCacheBytes()
        applyEffectiveOfflinePresentation()
    }

    private func applyEffectiveOfflinePresentation() {
        // Offline mode filters what Vellum shows — it is not the same as losing connectivity.
        if hasInternetPath, isSignedIn {
            Task { await refreshServerConnectionHealth() }
        }
    }

    private func evaluateAutoOfflineMode() async {
        guard autoOfflineEnabled else {
            autoOfflineActive = false
            applyEffectiveOfflinePresentation()
            return
        }
        switch autoOfflineMode {
        case .wifiOnly:
            autoOfflineActive = !prefersWifiLikePath || !hasInternetPath
        case .homeWifi:
            if !prefersWifiLikePath || !hasInternetPath {
                autoOfflineActive = true
            } else if homeWifiSSIDs.isEmpty {
                autoOfflineActive = false
            } else {
                await HomePresenceHelper.ensureLocationAccessForHomeDetection()
                if let ssid = await AutoOfflineHelper.fetchCurrentSSID() {
                    autoOfflineActive = !homeWifiSSIDs.contains(ssid)
                } else {
                    autoOfflineActive = false
                }
            }
        }
        applyEffectiveOfflinePresentation()
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let wasOnline = self.hasInternetPath
                // `@Published` has no equality check, and this handler fires on interface
                // reordering and `isExpensive` flips, not just online↔offline — so an
                // unconditional assignment was a full-tree invalidation on events where nothing
                // had actually changed. Every comparable path in this file is guarded already.
                if self.hasInternetPath != online { self.hasInternetPath = online }
                let wifiLike = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                self.prefersWifiLikePath = wifiLike
                if !online {
                    self.serverConnectionHealth = .noNetwork
                } else if !wasOnline, self.isSignedIn {
                    self.prefetchAccountAvatar()
                    Task { await self.refreshServerConnectionHealth() }
                }
                guard online else {
                    await self.evaluateAutoOfflineMode()
                    return
                }
                let cellularNow = !wifiLike
                if cellularNow != self.prefersCellularStreamingQuality {
                    self.prefersCellularStreamingQuality = cellularNow
                    self.pushQualitySettingsToClients()
                }
                self.offline.kickQueueWorker()
                await self.evaluateAutoOfflineMode()
                await self.reconcileLocalNetworkFallbackIfNeeded()
                if online {
                    self.scrobbleService.onNetworkRestored()
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    func pushQualitySettingsToClients() {
        let bitRate = prefersCellularStreamingQuality ? cellularStreamBitRate : wifiStreamBitRate
        let format = prefersCellularStreamingQuality ? cellularStreamFormat : wifiStreamFormat
        jellyfin?.streamingBitrateCapBps = bitRate.jellyfinAudioBitRate
        jellyfin?.offlineBitrateCapBps = downloadQualityTier.jellyfinAudioBitRate
        jellyfin?.streamingFormat = format
        jellyfin?.offlineFormat = downloadFormat
        navidrome?.streamingMaxBitRate = bitRate.navidromeMaxBitRate(for: format)
        navidrome?.streamingFormat = format
        navidrome?.offlineMaxBitRate = downloadQualityTier.navidromeMaxBitRate
        navidrome?.offlineFormat = downloadFormat
    }

    func syncPlaybackPreferencesToEngine() {
        player.skipBackwardInterval = skipBackwardInterval.seconds
        player.skipForwardInterval = skipForwardInterval.seconds
        player.showSkipIntervalButtons = showSkipIntervalButtons
        player.showSleepTimerButton = showSleepTimerButton
        player.remoteControlMode = remoteControlMode
        player.playbackRate = defaultPlaybackRate.rawValue
        syncEqualizerToEngine()
        player.updateRemoteCommands()
    }

    func syncEqualizerToEngine() {
        player.equalizerEnabled = equalizerEnabled
        player.equalizerBypass = equalizerBypass
        player.equalizerBandGains = effectiveEqualizerBandGains(for: player.activeTrack)
        player.applyLiveEqualizerGains()
    }

    func effectiveEqualizerBandGains(for track: Track?) -> [Float] {
        var resolved = EqualizerAutomationEngine(
            profiles: equalizerProfiles,
        ).resolvedGains(
            baseGains: equalizerBandGains,
            track: track,
            routeKey: EqualizerDeviceRoute.currentRouteKey(),
            routeDisplayName: EqualizerDeviceRoute.currentRouteDisplayName(),
            vintageMode: equalizerVintageMode,
            stereoWidth: equalizerStereoWidth,
            hearingOffset: equalizerHearingOffset,
            adaptiveEnabled: equalizerAdaptiveEnabled,
            adaptiveStrength: equalizerAdaptiveStrength,
            headphoneProfileId: equalizerHeadphoneProfileId,
            frequencyToolMode: equalizerFrequencyToolMode,
            frequencyToolBand: equalizerFrequencyToolBand,
        )
        if equalizerBassEnhancement {
            for index in 0 ... min(3, resolved.count - 1) {
                resolved[index] = min(resolved[index] + 4, EqualizerBand.gainRange.upperBound)
            }
        }
        if equalizerVocalEnhancement {
            for index in 4 ... min(6, resolved.count - 1) {
                resolved[index] = min(resolved[index] + 3.5, EqualizerBand.gainRange.upperBound)
            }
        }
        if equalizerLoudnessCompensation {
            #if os(iOS)
            let volume = AVAudioSession.sharedInstance().outputVolume
            if volume < 0.75 {
                let boost = (0.75 - volume) * 10
                resolved = resolved.enumerated().map { index, gain in
                    let weight: Float = index < 4 ? 1.3 : (index < 7 ? 1.0 : 0.7)
                    return min(gain + boost * weight, EqualizerBand.gainRange.upperBound)
                }
            }
            #endif
        }
        return EqualizerPreset.normalizedGains(resolved)
    }

    func applyEqualizerAutomationForTrack(_ track: Track) {
        equalizerUserOverride = false
        guard equalizerEnabled else {
            syncEqualizerToEngine()
            return
        }
        if let gains = automatedBaseGains(for: track),
           gains != equalizerBandGains {
            setEqualizerBandGains(gains, recordHistory: false)
        } else {
            syncEqualizerToEngine()
        }
    }

    func applyEqualizerAutomationForRouteChange() {
        guard equalizerEnabled else { return }
        syncEqualizerToEngine()
    }

    private func automatedBaseGains(for track: Track) -> [Float]? {
        if let album = equalizerProfiles.first(where: { $0.kind == .album && $0.key == track.albumId }) {
            return album.gains
        }
        let artistKey = LibraryTrackMatcher.normalize(track.artist)
        if let artist = equalizerProfiles.first(where: { $0.kind == .artist && $0.key == artistKey }) {
            return artist.gains
        }
        return nil
    }

    func reloadEqualizerProfiles() {
        equalizerProfiles = EqualizerProfileStore.load()
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        equalizerPresetId = preset.id
        setEqualizerBandGains(preset.gains, recordHistory: true)
    }

    func beginEqualizerEditSession() {
        guard equalizerEditSessionBaseline == nil else { return }
        equalizerEditSessionBaseline = EqualizerPreset.normalizedGains(equalizerBandGains)
    }

    func endEqualizerEditSession() {
        guard let baseline = equalizerEditSessionBaseline else { return }
        equalizerEditSessionBaseline = nil
        let current = EqualizerPreset.normalizedGains(equalizerBandGains)
        guard baseline != current else { return }
        var history = equalizerHistory
        history.recordUndo(before: baseline)
        equalizerHistory = history
    }

    func setEqualizerBandGain(index: Int, gain: Float, recordHistory: Bool = false) {
        guard index >= 0, index < EqualizerBand.count else { return }
        var next = equalizerBandGains
        if next.count < EqualizerBand.count {
            next = EqualizerPreset.normalizedGains(next)
        }
        next[index] = min(max(gain, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound)
        equalizerUserOverride = true
        setEqualizerBandGains(next, recordHistory: recordHistory)
        equalizerPresetId = EqualizerPreset.catalog[0].id
    }

    func setEqualizerBandGains(_ gains: [Float], recordHistory: Bool) {
        let normalized = EqualizerPreset.normalizedGains(gains)
        guard normalized != equalizerBandGains else { return }

        if recordHistory, !equalizerHistorySuppressed {
            var history = equalizerHistory
            history.recordUndo(before: equalizerBandGains)
            equalizerHistory = history
        }
        equalizerHistorySuppressed = true
        equalizerBandGains = normalized
        equalizerHistorySuppressed = false
    }

    func undoEqualizerChange() {
        var history = equalizerHistory
        guard let restored = history.undo(current: equalizerBandGains) else { return }
        equalizerHistory = history
        setEqualizerBandGains(restored, recordHistory: false)
        equalizerPresetId = EqualizerPreset.catalog[0].id
        triggerEqualizerUndoRedoHaptic()
    }

    func redoEqualizerChange() {
        var history = equalizerHistory
        guard let restored = history.redo(current: equalizerBandGains) else { return }
        equalizerHistory = history
        setEqualizerBandGains(restored, recordHistory: false)
        equalizerPresetId = EqualizerPreset.catalog[0].id
        triggerEqualizerUndoRedoHaptic()
    }

    private func triggerEqualizerUndoRedoHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    func saveEqualizerProfileForCurrentArtist() {
        guard let track = player.activeTrack else { return }
        let key = LibraryTrackMatcher.normalize(track.artist)
        _ = EqualizerProfileStore.upsert(
            kind: .artist,
            key: key,
            displayName: track.artist,
            gains: equalizerBandGains,
        )
        reloadEqualizerProfiles()
        equalizerUserOverride = false
        showTransientToast("Saved for \(track.artist)")
    }

    func saveEqualizerProfileForCurrentAlbum() {
        guard let track = player.activeTrack else { return }
        _ = EqualizerProfileStore.upsert(
            kind: .album,
            key: track.albumId,
            displayName: track.albumTitle,
            gains: equalizerBandGains,
        )
        reloadEqualizerProfiles()
        equalizerUserOverride = false
        showTransientToast("Saved for \(track.albumTitle)")
    }

    func saveEqualizerProfileForCurrentDevice() {
        guard let key = EqualizerDeviceRoute.currentRouteKey(),
              let name = EqualizerDeviceRoute.currentRouteDisplayName()
        else { return }
        _ = EqualizerProfileStore.upsert(
            kind: .device,
            key: key,
            displayName: name,
            gains: equalizerBandGains,
        )
        reloadEqualizerProfiles()
        showTransientToast("Saved for \(name)")
    }

    func removeEqualizerProfile(id: String) {
        EqualizerProfileStore.remove(id: id)
        reloadEqualizerProfiles()
    }

    func exportEqualizerPreset(named name: String) -> EqualizerPresetExport {
        EqualizerPresetExport(
            name: name,
            gains: equalizerBandGains,
            createdAt: Date(),
        )
    }

    func importEqualizerPreset(_ export: EqualizerPresetExport) {
        setEqualizerBandGains(export.gains, recordHistory: true)
        equalizerPresetId = EqualizerPreset.catalog[0].id
        showTransientToast("Imported \(export.name)")
    }

    func applyHearingTestOffsets(_ offsets: [Float]) {
        equalizerHearingOffset = EqualizerPreset.normalizedGains(offsets)
        showTransientToast("Hearing profile applied")
    }

    /// Apply the best-matching preset for the currently playing track's genre.
    func applyEqualizerSuggestionForCurrentTrack() {
        guard let track = player.activeTrack else { return }
        for genre in track.genres {
            if let presetId = EqualizerGenreMapping.presetId(forGenre: genre),
               let preset = EqualizerPreset.catalog.first(where: { $0.id == presetId })
            {
                applyEqualizerPreset(preset)
                showTransientToast("EQ set to \(preset.name)")
                return
            }
        }
        showTransientToast("No genre match — genres not tagged for \(track.title)")
    }

    func resetPlaybackSettingsToDefaults() {
        wifiStreamBitRate = .none
        cellularStreamBitRate = .kbps320
        wifiStreamFormat = .raw
        cellularStreamFormat = .raw
        downloadQualityTier = .kbps320
        downloadFormat = .mp3
        skipBackwardInterval = .s15
        skipForwardInterval = .s30
        showSkipIntervalButtons = false
        showSleepTimerButton = false
        remoteControlMode = .skipTrack
        defaultPlaybackRate = .normal
        artistPlayMode = .topSongs
        metadataRefreshThreshold = .oneWeek
        pushQualitySettingsToClients()
        syncPlaybackPreferencesToEngine()
    }

    /// Active stream format options for the connected backend.
    var availableStreamFormats: [StreamFormatOption] {
        backendKind == .jellyfin ? StreamFormatOption.jellyfinCases : StreamFormatOption.allCases
    }

    /// Refreshes album track metadata before playback when the cache is stale.
    func refreshAlbumTracksIfNeeded(for track: Track) async -> Track {
        guard !offlineMode, !track.isInternetRadioStream else { return track }
        guard !track.albumId.isEmpty else { return track }
        let albumId = track.albumId
        guard metadataRefreshThreshold != .never else { return track }
        if let cached = albumTracksCache[albumId],
           !metadataRefreshThreshold.isStale(retrievedAt: cached.retrievedAt) {
            return reconcileTrack(track, with: cached.tracks) ?? track
        }
        guard let lib = activeLibrary else { return track }
        do {
            let fresh = try await lib.tracks(forAlbumId: albumId)
            albumTracksCache[albumId] = CachedAlbumTracks(tracks: fresh, retrievedAt: Date())
            return reconcileTrack(track, with: fresh) ?? track
        } catch {
            return track
        }
    }

    private func reconcileTrack(_ track: Track, with albumTracks: [Track]) -> Track? {
        if albumTracks.contains(where: { $0.id == track.id }) { return track }
        if let match = albumTracks.first(where: {
            $0.discNumber == track.discNumber
                && $0.indexNumber == track.indexNumber
                && $0.title.caseInsensitiveCompare(track.title) == .orderedSame
        }) {
            return match
        }
        if let match = albumTracks.first(where: { $0.title.caseInsensitiveCompare(track.title) == .orderedSame }) {
            return match
        }
        return nil
    }

    func normalizedServerURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// True when the configured fallback address is a private LAN URL.
    var secondaryURLIsLocalNetwork: Bool {
        HomePresenceHelper.isLocalNetworkServerURL(normalizedServerURL(from: secondaryURLString))
    }

    /// Local-IP fallback is only usable on a configured home Wi‑Fi network.
    func canUseLocalNetworkFallback() async -> Bool {
        guard secondaryURLIsLocalNetwork else { return true }
        return await HomePresenceHelper.isAtHome(homeSSIDs: homeWifiSSIDs)
    }

    /// Drops back to the primary address when the user leaves home while on a LAN fallback.
    func reconcileLocalNetworkFallbackIfNeeded() async {
        guard isSignedIn,
              activeServerURLRole == .secondary,
              secondaryURLIsLocalNetwork
        else { return }
        if await canUseLocalNetworkFallback() { return }
        await switchActiveServerURL(to: .primary)
        showTransientToast("Left home — using primary address")
    }

    var activeServerURLString: String {
        switch activeServerURLRole {
        case .primary:
            return baseURLString
        case .secondary:
            let secondary = secondaryURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            return secondary.isEmpty ? baseURLString : secondary
        }
    }

    func trustCurrentServerCertificate() {
        guard let host = normalizedServerURL(from: activeServerURLString)?.host else { return }
        TrustedCertificateStore.trustHost(host)
        showTransientToast("Trusted certificate for \(host)")
    }

    func switchActiveServerURL(to role: ActiveServerURLRole) async {
        guard role != activeServerURLRole else { return }
        guard let url = role == .secondary ? normalizedServerURL(from: secondaryURLString) : normalizedServerURL(from: baseURLString) else {
            return
        }
        if role == .secondary, HomePresenceHelper.isLocalNetworkServerURL(url) {
            await HomePresenceHelper.ensureLocationAccessForHomeDetection()
            guard await HomePresenceHelper.isAtHome(homeSSIDs: homeWifiSSIDs) else {
                showTransientToast("Fallback address is only available on your home Wi‑Fi")
                return
            }
        }
        switch backendKind {
        case .jellyfin:
            jellyfin?.updateBaseURL(url)
            if let client = jellyfin {
                await Self.registerMediaAuthHeaders(host: url.host, headers: client.httpHeadersForMediaRequests())
            }
        case .navidrome:
            navidrome?.updateBaseURL(url)
        }
        activeServerURLRole = role
        await refreshServerConnectionHealth()
        showTransientToast(role == .secondary ? "Using fallback address" : "Using primary address")
    }

    func attemptAutomaticFailoverIfNeeded() async -> Bool {
        guard serverFailoverMode == .automatic,
              activeServerURLRole == .primary,
              normalizedServerURL(from: secondaryURLString) != nil,
              serverConnectionHealth != .connected
        else { return false }
        if secondaryURLIsLocalNetwork {
            await HomePresenceHelper.ensureLocationAccessForHomeDetection()
            guard await HomePresenceHelper.isAtHome(homeSSIDs: homeWifiSSIDs) else {
                return false
            }
        }
        await switchActiveServerURL(to: .secondary)
        return serverConnectionHealth == .connected
    }

    /// Reactive stale-id recovery after stream failure — refreshes the album and remaps queue + downloads.
    func recoverStaleSongIDs(for track: Track) async -> StaleSongRecoveryResult? {
        guard !offlineMode, !track.isInternetRadioStream, !track.albumId.isEmpty else { return nil }
        guard let lib = activeLibrary else { return nil }

        let oldTracks: [Track]
        if let cached = albumTracksCache[track.albumId], !cached.tracks.isEmpty {
            oldTracks = cached.tracks
        } else {
            oldTracks = player.queue.filter { $0.albumId == track.albumId }
        }

        do {
            let fresh = try await lib.tracks(forAlbumId: track.albumId)
            albumTracksCache[track.albumId] = CachedAlbumTracks(tracks: fresh, retrievedAt: Date())
            let swaps = StaleSongMatching.buildSwapMap(oldTracks: oldTracks, freshTracks: fresh)
            guard swaps[track.id] != nil else { return nil }

            applyTrackIDSwaps(swaps)
            return StaleSongRecoveryResult(current: swaps[track.id]!, swaps: swaps)
        } catch {
            return nil
        }
    }

    func applyTrackIDSwaps(_ swaps: [String: Track]) {
        guard !swaps.isEmpty else { return }
        let librarySwaps = swaps.filter { librarySongIds.contains($0.key) }
        player.applyTrackSwaps(swaps)
        for (oldId, newTrack) in swaps {
            try? offline.remapDownloadedTrackId(from: oldId, to: newTrack)
            if librarySongIds.contains(oldId) {
                librarySongIds.remove(oldId)
                librarySongIds.insert(newTrack.id)
            }
            if favoriteTrackIds.contains(oldId) {
                favoriteTrackIds.remove(oldId)
                favoriteTrackIds.insert(newTrack.id)
                UserDefaults.standard.set(Array(favoriteTrackIds), forKey: Self.favoriteTrackIdsKey)
            }
        }
        let remappedKillMode = Self.killModeMarksRemapped(
            pending: killModePendingRemovals,
            passed: killModePassedTracks,
            swaps: swaps.mapValues(\.id)
        )
        if remappedKillMode.pending != killModePendingRemovals {
            killModePendingRemovals = remappedKillMode.pending
            KillModeStore.savePending(remappedKillMode.pending)
        }
        if remappedKillMode.passed != killModePassedTracks {
            killModePassedTracks = remappedKillMode.passed
            KillModeStore.savePassed(remappedKillMode.passed)
        }
        invalidateKillModeListenedCache()
        if !librarySwaps.isEmpty {
            Task { await persistTrackIDSwapsToMagicPlaylist(librarySwaps) }
        }
    }

    /// One step of a stale-id swap against the magic playlist.
    ///
    /// The order of these is the whole point, so it is a value rather than control flow: it can be
    /// asserted in a test without a server, which the two `await`s below cannot.
    enum MagicPlaylistSwapStep: Equatable {
        /// Current track ids — the ones the server uses *now*, after a rescan.
        case add([String])
        /// Stale track ids — the ids the server used *before* the rescan. A different set of
        /// values from `.add`, not the same tracks twice.
        case remove(Set<String>)
    }

    /// Add-before-remove, deliberately.
    ///
    /// A swap is two server writes with no transaction around them, so the process can die between
    /// them and something has to be left behind. This chooses *what*. Removing first means a
    /// failure in the gap leaves the tracks gone from the library with nothing holding their ids —
    /// the Subsonic remove is by index and batched, it is not rolled back, and there is no record
    /// left to retry from. Adding first means a failure in the gap leaves the same song listed
    /// twice, under its stale id and its current one, which the next swap or a manual tidy can fix.
    ///
    /// Make before break. Duplicates are recoverable; deletions are not.
    nonisolated static func magicPlaylistSwapSteps(
        for swaps: [String: Track]
    ) -> [MagicPlaylistSwapStep] {
        guard !swaps.isEmpty else { return [] }
        return [
            .add(swaps.values.map(\.id).sorted()),
            .remove(Set(swaps.keys)),
        ]
    }

    private func persistTrackIDSwapsToMagicPlaylist(_ swaps: [String: Track]) async {
        guard let playlistId = libraryMagicPlaylistId else { return }
        do {
            for step in Self.magicPlaylistSwapSteps(for: swaps) {
                switch step {
                case let .add(trackIds):
                    try await addTracksToServerMagicPlaylist(playlistId: playlistId, trackIds: trackIds)
                case let .remove(trackIds):
                    try await removeTracksFromServerMagicPlaylist(playlistId: playlistId, trackIds: trackIds)
                }
            }
            await persistLibraryMembershipPayload()
        } catch {}
    }

    func playMoreLikeThis(track: Track) async {
        guard let lib = activeLibrary else { return }
        do {
            let similar = try await lib.similarTracks(to: track, limit: 25)
            guard !similar.isEmpty else {
                showTransientToast("No similar tracks found")
                return
            }
            try await player.playAlbum(library: lib, tracks: similar, startIndex: 0)
            showTransientToast("Playing similar tracks")
        } catch {
            showTransientToast("Couldn't load similar tracks")
        }
    }

    func queueMoreLikeThis(track: Track) async {
        guard let lib = activeLibrary else { return }
        do {
            let similar = try await lib.similarTracks(to: track, limit: 15)
            guard !similar.isEmpty else {
                showTransientToast("No similar tracks found")
                return
            }
            // A batch the app picked, not a song the user picked: the collection entry point, so
            // Kill Mode's filter still applies to it.
            try await player.addTracksToQueue(library: lib, tracks: similar)
            showTransientToast("Added similar tracks to queue")
        } catch {
            showTransientToast("Couldn't load similar tracks")
        }
    }

    func playArtistMix(for track: Track) async {
        guard let lib = activeLibrary else { return }
        do {
            let genre = track.genres.first
            let random = try await lib.randomTracks(limit: 30, genre: genre)
            let filtered = random.filter { $0.artist.caseInsensitiveCompare(track.artist) == .orderedSame || genre != nil }
            let tracks = filtered.isEmpty ? random : filtered
            guard !tracks.isEmpty else {
                showTransientToast("No mix tracks found")
                return
            }
            try await player.playAlbum(library: lib, tracks: tracks.shuffled(), startIndex: 0)
            showTransientToast("Playing mix")
        } catch {
            showTransientToast("Couldn't load mix")
        }
    }

    func triggerServerLibraryScan() async throws {
        guard let lib = activeLibrary else { throw URLError(.userAuthenticationRequired) }
        try await lib.triggerLibraryScan()
    }

    func fetchNavidromeScanStatus() async throws -> NavidromeScanStatus {
        guard let client = navidrome else { throw URLError(.unsupportedURL) }
        return try await client.fetchScanStatus()
    }

    func fetchNavidromeShares() async throws -> [NavidromeShareEntry] {
        guard let client = navidrome else { throw URLError(.unsupportedURL) }
        return try await client.fetchShares()
    }

    func createNavidromeShare(forItemId id: String, description: String?) async throws -> NavidromeShareEntry {
        guard let client = navidrome else { throw URLError(.unsupportedURL) }
        return try await client.createShare(forItemId: id, description: description)
    }

    /// True when signed into Navidrome and the account has share permission (or metadata not loaded yet).
    var canCreateNavidromeShares: Bool {
        guard backendKind == .navidrome, isSignedIn else { return false }
        guard let meta = navidromeUserMetadata else { return true }
        return meta.shareRole
    }

    /// Creates the share on the server, then hands the URL to the system share sheet.
    ///
    /// The complaint this answers is that creating a link left it on the pasteboard with a
    /// toast and nothing else — you could not send it anywhere from where you were standing,
    /// and a silent clipboard write is invisible if you miss the toast. A declarative
    /// `ShareLink` is not an option at the call sites: they are context-menu buttons, and the
    /// URL does not exist until the server round-trip returns, so the sheet is presented
    /// imperatively once there is something real to share.
    ///
    /// The pasteboard write is kept as the fallback for the case where no presenter can be
    /// found, so the link is never simply lost.
    func createNavidromeShareAndNotify(forItemId id: String, description: String) async {
        do {
            let entry = try await createNavidromeShare(forItemId: id, description: description)
            #if os(iOS)
            if SystemShareSheetPresenter.present(url: entry.url) { return }
            UIPasteboard.general.url = entry.url
            #endif
            showTransientToast("Share link copied")
        } catch {
            showTransientToast("Couldn't create share link")
        }
    }

    func deleteNavidromeShare(id: String) async throws {
        guard let client = navidrome else { throw URLError(.unsupportedURL) }
        try await client.deleteShare(id: id)
    }

    func playbackSettingsSnapshot() -> VellumPlaybackSettingsSnapshot {
        VellumPlaybackSettingsSnapshot(
            wifiStreamBitRate: wifiStreamBitRate.rawValue.description,
            cellularStreamBitRate: cellularStreamBitRate.rawValue.description,
            wifiStreamFormat: wifiStreamFormat.rawValue,
            cellularStreamFormat: cellularStreamFormat.rawValue,
            downloadFormat: downloadFormat.rawValue,
            downloadQualityTier: downloadQualityTier.rawValue,
            skipBackwardInterval: String(skipBackwardInterval.rawValue),
            skipForwardInterval: String(skipForwardInterval.rawValue),
            remoteControlMode: remoteControlMode.rawValue,
            showSkipIntervalButtons: showSkipIntervalButtons,
            showSleepTimerButton: showSleepTimerButton,
            metadataRefreshThreshold: metadataRefreshThreshold.rawValue,
        )
    }

    func applyPlaybackSettingsSnapshot(_ snapshot: VellumPlaybackSettingsSnapshot) -> Bool {
        if let v = StreamBitRateOption(rawValue: Int(snapshot.wifiStreamBitRate) ?? -1) {
            wifiStreamBitRate = v
        }
        if let v = StreamBitRateOption(rawValue: Int(snapshot.cellularStreamBitRate) ?? -1) {
            cellularStreamBitRate = v
        }
        if let v = StreamFormatOption(rawValue: snapshot.wifiStreamFormat) {
            wifiStreamFormat = v
        }
        if let v = StreamFormatOption(rawValue: snapshot.cellularStreamFormat) {
            cellularStreamFormat = v
        }
        if let v = DownloadFormatOption(rawValue: snapshot.downloadFormat) {
            downloadFormat = v
        }
        if let v = DownloadQualityTier(rawValue: snapshot.downloadQualityTier) {
            downloadQualityTier = v
        }
        if let v = SkipIntervalOption(rawValue: Int(snapshot.skipBackwardInterval) ?? -1) {
            skipBackwardInterval = v
        }
        if let v = SkipIntervalOption(rawValue: Int(snapshot.skipForwardInterval) ?? -1) {
            skipForwardInterval = v
        }
        if let v = RemoteControlMode(rawValue: snapshot.remoteControlMode) {
            remoteControlMode = v
        }
        showSkipIntervalButtons = snapshot.showSkipIntervalButtons
        showSleepTimerButton = snapshot.showSleepTimerButton
        if let v = MetadataRefreshThreshold(rawValue: snapshot.metadataRefreshThreshold) {
            metadataRefreshThreshold = v
        }
        syncPlaybackPreferencesToEngine()
        pushQualitySettingsToClients()
        return true
    }

    private func migrateLegacyStreamQualityIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.playbackSettingsMigratedV2Key) else { return }
        if UserDefaults.standard.object(forKey: Self.wifiStreamBitRateKey) == nil,
           let raw = UserDefaults.standard.string(forKey: Self.wifiStreamQualityKey),
           let tier = StreamQualityTier(rawValue: raw) {
            wifiStreamBitRate = tier == .capped320 ? .kbps320 : .none
        }
        if UserDefaults.standard.object(forKey: Self.cellularStreamBitRateKey) == nil,
           let raw = UserDefaults.standard.string(forKey: Self.cellularStreamQualityKey),
           let tier = StreamQualityTier(rawValue: raw) {
            cellularStreamBitRate = tier == .capped320 ? .kbps320 : .none
        }
        UserDefaults.standard.set(true, forKey: Self.playbackSettingsMigratedV2Key)
    }

    private func persistLastLibrarySyncDate(_ date: Date?) {
        lastLibrarySyncAt = date
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastLibrarySyncAtKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastLibrarySyncAtKey)
        }
    }

    private func recordSuccessfulLibrarySync() {
        persistLastLibrarySyncDate(Date())
    }

    func refreshLibraryStatistics() async {
        guard isSignedIn else {
            libraryStatistics = .empty
            return
        }
        if libraryPlaylists.isEmpty {
            await refreshLibraryPlaylists()
        }
        let playlistCount = libraryPlaylists.count
        do {
            switch backendKind {
            case .jellyfin:
                guard let client = jellyfin else { return }
                let remote = try await client.fetchLibraryStatistics()
                libraryStatistics = LibraryStatistics(
                    artistCount: remote.artistCount,
                    albumCount: remote.albumCount,
                    songCount: remote.songCount,
                    playlistCount: playlistCount,
                )
            case .navidrome:
                guard let client = navidrome else { return }
                let remote = try await client.fetchApproximateLibraryStatistics()
                libraryStatistics = LibraryStatistics(
                    artistCount: remote.artistCount,
                    albumCount: remote.albumCount,
                    songCount: remote.songCount,
                    playlistCount: playlistCount,
                    songsMayBeApproximate: remote.songsMayBeApproximate,
                )
            }
        } catch {
            libraryStatistics = LibraryStatistics(
                artistCount: nil,
                albumCount: nil,
                songCount: nil,
                playlistCount: playlistCount,
            )
        }
    }

    func syncLibraryNow() async {
        guard isSignedIn else { return }
        isLibrarySyncing = true
        defer { isLibrarySyncing = false }
        await refreshLibraryAlbums()
        await refreshLibraryPlaylists()
        await refreshLibraryMembership()
        await refreshHome()
        await refreshLibraryStatistics()
        recordSuccessfulLibrarySync()
    }

    private func loadKeychain() {
        if let j = try? KeychainStore.loadJellyfin() {
            backendKind = .jellyfin
            baseURLString = j.base.absoluteString
            secondaryURLString = j.secondaryBase?.absoluteString ?? ""
            username = j.user
            password = j.password
            let client = JellyfinMusicClient(baseURL: j.base)
            let hasToken = !(j.accessToken ?? "").isEmpty && !(j.userId ?? "").isEmpty
            if hasToken, let token = j.accessToken, let uid = j.userId {
                client.applyRestoredSession(accessToken: token, userId: uid)
                jellyfin = client
                navidrome = nil
                isSignedIn = true
                applyLaunchTab()
                updateDeleteCapability()
                prefetchAccountAvatar()
                pushQualitySettingsToClients()
                libraryDiskRestoreTask = Task { [weak self] in
                    await self?.restoreLibraryFromDiskAsync()
                }
                restorePlaybackQueueFromDisk()
                serverConnectionHealth = .unknown
                Task { await Self.registerMediaAuthHeaders(host: j.base.host, headers: client.httpHeadersForMediaRequests()) }
            }
            Task { await reconcileRestoredSession(hasRestoredToken: hasToken) }
        } else if let n = try? KeychainStore.loadNavidrome() {
            backendKind = .navidrome
            baseURLString = n.base.absoluteString
            secondaryURLString = n.secondaryBase?.absoluteString ?? ""
            username = n.user
            password = n.password
            let client = NavidromeClient(baseURL: n.base)
            // Salted-token auth means there's no long-lived bearer token to "restore" — having
            // username+password is enough to make API calls without re-POSTing the password.
            let hasCredentials = !n.user.isEmpty && !n.password.isEmpty
            if hasCredentials {
                client.applyRestoredSession(token: n.subsonicToken ?? "", username: n.user, password: n.password)
                navidrome = client
                jellyfin = nil
                isSignedIn = true
                applyLaunchTab()
                updateDeleteCapability()
                restoreMagicPlaylistAvatarURL()
                prefetchAccountAvatar()
                libraryDiskRestoreTask = Task { [weak self] in
                    await self?.restoreLibraryFromDiskAsync()
                }
                restorePlaybackQueueFromDisk()
                serverConnectionHealth = .unknown
                Task { [weak self, weak client] in
                    guard let client else { return }
                    if let metadata = try? await client.refreshUserMetadata() {
                        await MainActor.run { self?.navidromeUserMetadata = metadata }
                    }
                }
            }
            Task { await reconcileRestoredSession(hasRestoredToken: hasCredentials) }
        }
    }

    /// Registers per-host auth headers so artwork / avatar loaders can authenticate
    /// against Jellyfin without leaking the bearer token into the URL.
    private static func registerMediaAuthHeaders(host: String?, headers: [String: String]) async {
        guard let host = host, !host.isEmpty else { return }
        await MediaAuthHeaderRegistry.shared.register(host: host, headers: headers)
    }

    /// Decides whether to re-authenticate after a Keychain restore.
    ///
    /// Sign-in only runs when:
    ///   (a) no usable session was restored, or
    ///   (b) the server explicitly rejected the restored session (401/403 / Subsonic error 40/41).
    /// On healthy or merely-unreachable probes we do NOT re-POST credentials — preserving the
    /// password's privacy across cold launches on hostile networks.
    private func reconcileRestoredSession(hasRestoredToken: Bool) async {
        // Finish disk restore before any network bootstrap so Library / Home paint from
        // cache instead of racing an empty catalog against `refreshLibraryAlbums`.
        if let restore = libraryDiskRestoreTask {
            await restore.value
            libraryDiskRestoreTask = nil
        } else if isSignedIn {
            await restoreLibraryFromDiskAsync()
        }

        await refreshServerConnectionHealth()
        guard hasRestoredToken else {
            await signIn()
            return
        }
        let probe: ServerReachabilityProbe
        switch backendKind {
        case .jellyfin:
            probe = await jellyfin?.probeAuthStatus() ?? .unreachable
        case .navidrome:
            probe = await navidrome?.probeAuthStatus() ?? .unreachable
        }
        switch probe {
        case .authRejected:
            // Token / credentials rejected — re-authenticate (also covers "user changed password
            // on server" recovery flow).
            await signIn()
        case .ok:
            // Healthy restored session: kick the same bootstrap fresh sign-ins do so the
            // library catalog, home shelves, and ``refreshLibraryMembership`` all reconcile
            // with the server. Without this, cold launches show only what the on-disk
            // snapshot happened to contain.
            scheduleLibraryBootstrap()
        case .unreachable:
            // Transient outage — never re-leak the password on cold launch. The on-disk
            // snapshot is what the user sees until connectivity recovers.
            break
        }
    }
}
