import Combine
import Network
import SwiftUI
#if os(iOS)
import UIKit
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
    case musicBrainz
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

@MainActor
public final class AppModel: ObservableObject {
    /// Default album fetch size for library grid / sync (raised for large Jellyfin / Navidrome libraries).
    public static let defaultLibraryAlbumFetchLimit = 500
    @Published var accentPresetId: String = UserDefaults.standard.string(forKey: AppAccentPreset.accentPresetIdKey) ?? AppAccentPreset.defaultId {
        didSet {
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

    @Published var musicBrainzEnabled: Bool = UserDefaults.standard.object(forKey: "musicBrainzEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(musicBrainzEnabled, forKey: "musicBrainzEnabled") }
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
    @Published var selectedTab: AppTab = .home
    /// "Go to Album / Playlist / Artist" deep link pushed onto the user's current tab after the
    /// Now Playing player dismisses. Set together with ``deepLinkTab`` so only the tab that was
    /// active at trigger time consumes the push (tab bar stays visible during the destination).
    @Published var presentedDeepLink: NowPlayingDeepLink? = nil
    @Published var deepLinkTab: AppTab? = nil

    /// Scroll signal consumed by an already-visible ``ServerPlaylistDetailView`` so "Go to Playlist"
    /// scrolls to the now-playing track even when the user is already on that playlist.
    @Published var pendingPlaylistScroll: PendingPlaylistScroll? = nil

    /// Same as ``pendingPlaylistScroll`` but for album-mode detail views.
    @Published var pendingAlbumScroll: PendingAlbumScroll? = nil

    /// Set by ``ServerPlaylistDetailView`` while it's mounted so Now Playing → Go to Playlist
    /// can detect "destination already visible behind player" and skip a redundant push.
    @Published var currentlyVisiblePlaylistId: String? = nil
    /// Album equivalent of ``currentlyVisiblePlaylistId``.
    @Published var currentlyVisibleAlbumId: String? = nil

    /// Brief bottom toast (e.g. "Added to Queue"). Auto-clears after ``showTransientToast``
    /// is called; the ``MusicTransientToastChrome`` view modifier renders it.
    @Published var transientToast: String? = nil
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
    /// Sticky per-session random pick of which genres get a shelf on Home. Locked in on the
    /// first successful ``refreshHome()`` of the session; subsequent refreshes reuse it so the
    /// Home layout doesn't reshuffle on every tab visit or pull-to-refresh. Cleared on sign-out
    /// and server-identity changes (alongside ``homeGenreShelves``), and reset by cold launch.
    private var homeSelectedGenres: [LibraryGenreSummary]?

    /// Live merge of the local play log and the server's recently-played albums.
    @Published private(set) var homeRecentlyPlayed: [RecentPlayedItem] = []
    /// On-device personalized mixes for the Home → Tuned In shelf.
    @Published private(set) var homeMixes: [HomeMix] = []
    @Published private(set) var libraryAlbumsLoadError: String?

    /// Normalized track titles → normalized artist strings (for Downtify vs library matching).
    @Published private(set) var libraryTrackTitleIndex: [String: Set<String>] = [:]
    /// Snapshot of tracks used to build ``libraryTrackTitleIndex`` (resolve Downtify rows → `Track`).
    @Published private(set) var discoveryLibraryTracks: [Track] = [] {
        didSet { rebuildDiscoveryTrackIndices() }
    }
    /// O(1) "is this chart row in the user's library?" lookup. Rebuilt with ``libraryTrackTitleIndex``.
    private(set) var libraryChartTrackIndex: LibraryChartTrackIndex = .empty
    /// O(1) track lookup for downloaded-library resolution (rebuilt with ``discoveryLibraryTracks``).
    private(set) var discoveryTrackById: [String: Track] = [:]
    @Published private(set) var isIndexingLibraryTracks = false
    @Published private(set) var libraryTrackIndexLoadError: String?

    /// MusicBrainz / external browse shelves for the New tab.
    @Published private(set) var newTabTopTracks: [ChartTrack] = []
    @Published private(set) var newTabTopAlbums: [ChartAlbum] = []
    @Published private(set) var newTabRecentReleases: [ChartAlbum] = []
    @Published private(set) var newTabBrowseLoading = false
    /// Set when MusicBrainz browse fails so the New tab can show a concrete reason instead of an empty shelf.
    @Published private(set) var newTabBrowseError: String?
    /// Which catalog populated the **New** tab on the last successful refresh (drives labels like “MusicBrainz”).
    @Published private(set) var newTabBrowseBackend: NewTabBrowseBackend = .none

    let player = PlaybackEngine()
    let offline = OfflineDownloadManager()
    let acquisition = AcquisitionManager()

    /// Follow-artist / discography-completeness automation (the Lidarr-style "brain"),
    /// backed by the always-available MusicBrainz floor so it works regardless of which
    /// acquisition/library plugins are configured. Assigned in `init`.
    private(set) var subscriptions: MusicSubscriptionEngine!

    private var libraryAlbumsById: [String: AlbumSummary] = [:]
    /// O(1) "is this chart album in the user's library?" lookup. Rebuilt alongside ``libraryAlbumsById``.
    private(set) var libraryAlbumReleaseIndex: LibraryAlbumReleaseIndex = .empty
    private var libraryBootstrapTask: Task<Void, Never>?
    /// Polls the server magic playlist so personal-library changes from other devices land here.
    private var libraryMembershipSyncTask: Task<Void, Never>?
    private var lastLibraryMembershipRefresh = Date.distantPast
    private var trackIndexTask: Task<Void, Never>?
    /// In-memory playlist tracklists for instant detail hydration (Go to Playlist, revisit).
    private var playlistRowsCache: [String: [PlaylistRowItem]] = [:]

    private static let favoriteTrackIdsKey = "LyraMusic.favoriteTrackIds"
    @Published private(set) var favoriteTrackIds: Set<String> = []

    /// Per-playlist "Kill Mode" toggle. When a playlist id is in this set, any user-initiated
    /// `skipNext` while playing FROM that playlist appends the outgoing track to the playlist's
    /// pending-removal set. Disabling Kill Mode does NOT clear the pending list.
    @Published private(set) var killModeEnabledPlaylistIds: Set<String> = []

    /// playlistId → ordered list of track ids queued for removal by Kill Mode, newest first.
    /// Order matters: the kill list view renders most-recent skips at the top. Reviewed and
    /// committed by the user via the kill list view (per-row swipe or "Remove All").
    @Published private(set) var killModePendingRemovals: [String: [String]] = [:]

    /// Set of artists the user has manually favorited from ``ArtistPageView``.
    /// Stored as `LibraryTrackMatcher.normalize`d names so the same artist hits the
    /// same key regardless of source (server artist row vs Last.fm row vs typed search).
    /// Local-only — neither Jellyfin nor Subsonic has a "favorite artist" concept
    /// universally enough to sync against.
    private static let favoriteArtistNamesKey = "LyraMusic.favoriteArtistNames"
    @Published private(set) var favoriteArtistNames: Set<String> = []

    /// Local "recently played" history (mix of playlist + album entries) so Home can show a
    /// Recently Played shelf even when the backend doesn't expose play history. Newest first.
    /// Persisted in UserDefaults as JSON.
    private static let recentlyPlayedEntriesKey = "LyraMusic.recentlyPlayedEntries"
    /// Legacy key (album ids only) — read once on launch and migrated into ``recentlyPlayedEntries``.
    private static let recentlyPlayedAlbumIdsKey = "LyraMusic.recentlyPlayedAlbumIds"
    private static let recentlyPlayedEntriesLimit = 50
    @Published private(set) var recentlyPlayedEntries: [RecentPlayedEntry] = []

    /// Track-level play history for Now Playing → Queue → History. Only songs that
    /// crossed the scrobble threshold (~50% played) are appended, so skipping doesn't
    /// pollute the list. Survives queue changes since it lives on `AppModel`, not on
    /// the player's transient queue. Newest first.
    private static let recentlyPlayedTracksKey = "LyraMusic.recentlyPlayedTracks"
    private static let recentlyPlayedTracksLimit = 100
    @Published private(set) var recentlyPlayedTracks: [Track] = []

    /// Playlist id → last time the user meaningfully played from that playlist (scrobble threshold).
    private static let playlistLastPlayedDatesKey = "LyraMusic.playlistLastPlayedDates"
    @Published private(set) var playlistLastPlayedDates: [String: Date] = [:]

    /// Jellyfin / Navidrome playlists (excludes in-app “Favorite Songs”).
    @Published private(set) var libraryPlaylists: [PlaylistSummary] = []

    // MARK: - Lyra "My Library" magic playlist
    //
    // One private playlist per (backend, user) acts as the canonical store of what the
    // user has personally added to *their* library, server-side. The playlist's track
    // list is the song-membership set; the playlist's `comment` / `Overview` field
    // carries a JSON ``LibraryMembershipPayload`` covering album + playlist membership.
    // Filtered out of every user-facing playlist surface by id and by name prefix.

    /// Server-side id of the resolved magic playlist for the active session. `nil` until
    /// ``refreshLibraryMembership()`` succeeds at least once after sign-in.
    @Published private(set) var libraryMagicPlaylistId: String?
    /// Song IDs the user has added to their library (mirrors magic playlist tracks).
    @Published private(set) var librarySongIds: Set<String> = []
    /// Album IDs in the user's library, with per-album add date (from the magic
    /// playlist's JSON comment payload).
    @Published private(set) var libraryAlbumEntries: [LibraryMembershipPayload.Entry] = []
    /// Playlist IDs the user has added to their library (separate from the magic
    /// playlist itself; the magic playlist is never listed here).
    @Published private(set) var libraryPlaylistEntries: [LibraryMembershipPayload.Entry] = []
    /// `true` while ``refreshLibraryMembership()`` is in flight. Used by Add/Remove
    /// buttons to guard against double-tap reentrancy.
    @Published private(set) var isResolvingLibraryMembership = false

    /// When non-nil, ``MainShellView`` presents ``AddToPlaylistSheet``.
    @Published var playlistPickerPayload: PlaylistPickerPayload?

    /// When non-nil, ``MainShellView`` asks for confirmation before ``deleteTrackFromLibrary(_:)``.
    @Published var libraryTrackPendingDeletion: Track?

    /// Incremented after destructive library edits so screens reload cached track lists.
    @Published private(set) var libraryCatalogEpoch: UInt = 0

    // MARK: - Acquisition plugins (optional)

    /// True when the active acquisition plugin has the credentials it needs.
    var acquisitionConfigured: Bool { acquisition.isConfigured }
    /// Capabilities of the active plugin, for gating request UI.
    var acquisitionCapabilities: AcquisitionCapabilities { acquisition.capabilities }

    private static let themePreferenceKey = "lyraThemePreference"
    private static let wifiStreamQualityKey = "lyraWifiStreamQuality"
    private static let cellularStreamQualityKey = "lyraCellularStreamQuality"
    private static let downloadQualityKey = "lyraDownloadQuality"
    private static let wifiStreamBitRateKey = "lyraWifiStreamBitRate"
    private static let cellularStreamBitRateKey = "lyraCellularStreamBitRate"
    private static let wifiStreamFormatKey = "lyraWifiStreamFormat"
    private static let cellularStreamFormatKey = "lyraCellularStreamFormat"
    private static let downloadFormatKey = "lyraDownloadFormat"
    private static let skipBackwardIntervalKey = "lyraSkipBackwardInterval"
    private static let skipForwardIntervalKey = "lyraSkipForwardInterval"
    private static let showSkipIntervalButtonsKey = "lyraShowSkipIntervalButtons"
    private static let showSleepTimerButtonKey = "lyraShowSleepTimerButton"
    private static let remoteControlModeKey = "lyraRemoteControlMode"
    private static let playbackRateKey = "lyraPlaybackRate"
    private static let artistPlayModeKey = "lyraArtistPlayMode"
    private static let showHomeMixesInPlaylistsKey = "lyraShowHomeMixesInPlaylists"
    private static let metadataRefreshThresholdKey = "lyraMetadataRefreshThreshold"
    private static let serverFailoverModeKey = "lyraServerFailoverMode"
    private static let playbackSettingsMigratedV2Key = "lyraPlaybackSettingsMigratedV2"
    private static let songListItemSizeKey = "lyraSongListItemSize"
    private static let lastLibrarySyncAtKey = "lyraLastLibrarySyncAt"
    private static let volumeNormalizationKey = "lyraVolumeNormalization"
    private static let albumBackdropEnabledKey = "lyraAlbumBackdropEnabled"
    private static let playlistBackdropEnabledKey = "lyraPlaylistBackdropEnabled"
    private static let playerBackdropEnabledKey = "lyraPlayerBackdropEnabled"
    private static let offlineModeKey = "lyraOfflineMode"
    private static let autoOfflineEnabledKey = "lyraAutoOfflineEnabled"
    private static let autoOfflineModeKey = "lyraAutoOfflineMode"
    private static let homeWifiSSIDsKey = "lyraHomeWifiSSIDs"
    private static let wifiOnlyDownloadsKey = "lyraWifiOnlyDownloads"
    private static let maxConcurrentDownloadsKey = "lyraMaxConcurrentDownloads"
    private static let storageLimitModeKey = "lyraStorageLimitMode"
    private static let maxCacheSizeGBKey = "lyraMaxCacheSizeGB"
    private static let favoritesAutoDownloadKey = "lyraFavoritesAutoDownload"

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

    /// When on, personalized Tuned In mixes also appear in Library → Playlists (All).
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
    private let networkMonitorQueue = DispatchQueue(label: "LyraMusic.networkPath")

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

    /// `getCoverArt` URL for the Lyra magic playlist when Navidrome reports a user-uploaded /
    /// external image on it (i.e. *not* the auto-generated mosaic). Used to override the
    /// account avatar so users can manage their PFP by setting the magic playlist's cover.
    @Published private(set) var navidromeMagicPlaylistAvatarURL: URL?

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
        player.bind(offline: offline, resolveArtwork: { [weak self] track in
            self?.resolvedArtworkURL(for: track)
        })
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
            .sink { [weak self] trackId in self?.nowPlayingTrackId = trackId }
            .store(in: &cancellables)
        offline.$downloadedTrackIds
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        offline.$downloadQueue
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        acquisition.onJobFinished = { [weak self] job in
            guard let self else { return }
            Task { await self.handleAcquisitionJobFinished(job) }
        }
        acquisition.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
            }
        ))
        subscriptions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        loadPersistedSettings()
        wireOfflineDownloadManager()
        startNetworkMonitor()
        loadKeychain()
        loadFavoriteTrackIdsFromDefaults()
        loadRecentlyPlayedEntriesFromDefaults()
        loadRecentlyPlayedTracksFromDefaults()
        loadPlaylistLastPlayedDatesFromDefaults()
        killModeEnabledPlaylistIds = KillModeStore.loadEnabled()
        killModePendingRemovals = KillModeStore.loadPending()
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
            }
        }
        player.onTrackSkipped = { [weak self] track, source in
            Task { @MainActor in
                self?.handleKillModeSkip(track: track, source: source)
            }
        }
        installPlaybackQueueAutosave()
    }

    /// Saves the playback queue snapshot ~1s after the queue, current track, or transport modes
    /// change. Position is captured on-demand from the live AVPlayer at save time. Scene-phase
    /// transitions in `LyraMusicHostApp` flush a snapshot immediately via ``persistPlaybackQueue()``.
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
        libraryAlbums = []
        recentlyAddedAlbums = []
        homeRecentlyPlayedServerAlbums = []
        homeGenreShelves = []
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
        canDeleteFromLibrary = false
        favoriteTrackIds = []
        libraryPlaylists = []
        playlistPickerPayload = nil
        libraryTrackPendingDeletion = nil
        libraryCatalogEpoch = 0
        libraryStatistics = .empty
        lastLibrarySyncAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastLibrarySyncAtKey)
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
        guard !track.isInternetRadioStream else { return nil }
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
        await MediaAuthHeaderRegistry.shared.clear()
    }

    private func clearMediaArtworkCachesSync() {
        ArtworkURLCache.clearAll()
        DecodedArtworkCache.clearAll()
        Task { await MediaAuthHeaderRegistry.shared.clear() }
    }

    /// Drops in-memory library media when the active server identity changes without an explicit sign-out.
    private func clearLibraryMediaCatalog() {
        libraryAlbums = []
        recentlyAddedAlbums = []
        homeRecentlyPlayedServerAlbums = []
        homeGenreShelves = []
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
        playlistRowsCache.removeAll()
        LibrarySnapshotStore.clear()
        PlaylistRowsCacheStore.clear()
    }

    func persistLibrarySnapshot() {
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

    /// Kicks the disk-snapshot restore off the main thread. The JSON decode for a
    /// multi-MB library would otherwise block sign-in / cold launch; the small
    /// window of "empty state" before the snapshot lands is much better than a hang.
    private func restoreLibraryFromDisk() {
        Task { [weak self] in
            guard let self else { return }
            let snap = await LibrarySnapshotStore.loadAsync()
            self.applyRestoredSnapshot(snap)
            let rowsCache = await PlaylistRowsCacheStore.loadAsync()
            self.applyRestoredPlaylistRowsCache(rowsCache)
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

    private func applyRestoredSnapshot(_ snap: LibrarySnapshot?) {
        PerfLog.measure("applyRestoredSnapshot", details: snap.map { "albums=\($0.albums.count) tracks=\($0.tracks.count) playlists=\($0.playlists.count) songIds=\($0.librarySongIds.count)" } ?? "nil") {
            applyRestoredSnapshotBody(snap)
        }
    }

    private func applyRestoredSnapshotBody(_ snap: LibrarySnapshot?) {
        if let snap {
            if !snap.albums.isEmpty { libraryAlbums = snap.albums }
            if !snap.tracks.isEmpty {
                discoveryLibraryTracks = snap.tracks
            }
            if !snap.playlists.isEmpty { libraryPlaylists = snap.playlists }
            if !snap.favoriteTrackIds.isEmpty {
                favoriteTrackIds = Set(snap.favoriteTrackIds)
            }
            // Restore library-membership state so Library → Songs/Albums/Recently Added
            // render the user's curated set on cold launch without waiting for the
            // server round-trip in ``refreshLibraryMembership``.
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
            offline.backfillRecordsIfMissing(knownTracks: snap.tracks)
        } else {
            offline.backfillRecordsIfMissing(knownTracks: [])
        }
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
            guard !offlineTracks.isEmpty else { return }

            var trackById = Dictionary(uniqueKeysWithValues: discoveryLibraryTracks.map { ($0.id, $0) })
            for t in offlineTracks {
                trackById[t.id] = t
            }
            discoveryLibraryTracks = Array(trackById.values)

            var albumById = Dictionary(uniqueKeysWithValues: libraryAlbums.map { ($0.id, $0) })
            for album in offline.cachedAlbums() {
                albumById[album.id] = album
            }
            libraryAlbums = albumById.values.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            libraryCatalogEpoch &+= 1
        }
    }

    func beginLibraryTrackDeletion(_ track: Track) {
        guard canDeleteFromLibrary else { return }
        libraryTrackPendingDeletion = track
    }

    func cancelLibraryTrackDeletion() {
        libraryTrackPendingDeletion = nil
    }

    func confirmLibraryTrackDeletion() async {
        guard let track = libraryTrackPendingDeletion else { return }
        libraryTrackPendingDeletion = nil
        await deleteTrackFromLibrary(track)
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

    public func refreshHome() async {
        guard let lib = activeLibrary else { return }
        let needsGenrePick = homeSelectedGenres == nil
        async let played = (try? await lib.recentlyPlayed(limit: 12)) ?? []
        async let genres: [LibraryGenreSummary] = {
            guard needsGenrePick else { return [] }
            return (try? await lib.libraryGenres(limit: 20)) ?? []
        }()
        let (playedResult, genresResult) = await (played, genres)
        homeRecentlyPlayedServerAlbums = playedResult
        rebuildHomeRecentlyPlayed()
        let pickedGenres: [LibraryGenreSummary]
        if let locked = homeSelectedGenres {
            pickedGenres = locked
        } else {
            pickedGenres = Array(genresResult.shuffled().prefix(4))
            if !pickedGenres.isEmpty {
                homeSelectedGenres = pickedGenres
            }
        }
        let indexed = await withTaskGroup(of: (Int, (genre: String, albums: [AlbumSummary]))?.self) { group in
            for (idx, g) in pickedGenres.enumerated() {
                group.addTask {
                    let albums = (try? await lib.albums(inGenre: g, limit: 8)) ?? []
                    guard !albums.isEmpty else { return nil }
                    return (idx, (genre: g.name, albums: albums))
                }
            }
            var rows: [(Int, (genre: String, albums: [AlbumSummary]))] = []
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows
        }
        homeGenreShelves = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
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
    public func scheduleLibraryBootstrap() {
        guard isSignedIn else { return }
        if let libraryBootstrapTask, !libraryBootstrapTask.isCancelled { return }
        libraryBootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.runLibraryBootstrap()
            self.libraryBootstrapTask = nil
        }
    }

    private func runLibraryBootstrap() async {
        await PerfLog.measureAsync("runLibraryBootstrap", context: .network) {
            await refreshLibraryAlbums()
            recordSuccessfulLibrarySync()
            // Only the surfaces visible at launch (Home shelves + personal-library
            // membership) run during bootstrap. Statistics (Settings) and the New tab's
            // MusicBrainz browse are pulled when their views first appear — they were
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
        isResolvingLibraryMembership = true
        defer { isResolvingLibraryMembership = false }
        do {
            let resolvedId = try await resolveMagicPlaylistId(identity: identity)
            let fetch = try await fetchMagicPlaylistContents(playlistId: resolvedId)
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
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stopLibraryMembershipAutoSync() {
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
        let payload = LibraryMembershipPayload.decode(fetch.comment)
        libraryMagicPlaylistId = playlistId
        librarySongIds = Set(fetch.trackIds)
        libraryAlbumEntries = payload.albums
        libraryPlaylistEntries = payload.playlists
        invalidatePlaylistRowsCache(playlistId: playlistId)
        Task { await backfillMissingLibraryAlbumSummaries() }
        if backendKind == .navidrome {
            Task { await refreshMagicPlaylistAvatar(playlistId: playlistId) }
        }
        persistLibrarySnapshot()
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
        let hasCustom = (try? await client.playlistHasCustomCover(playlistId: playlistId)) ?? false
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

    /// Sets the user's Lyra profile picture by uploading `imageData` as the cover art of
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
        var merged = libraryAlbums
        var byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        for album in fetched {
            byId[album.id] = album
        }
        merged = Array(byId.values)
        libraryAlbums = merged
        persistLibrarySnapshot()
    }

    /// Re-encodes the current album/playlist membership and writes it back to the magic
    /// playlist's comment field. Safe to call after every mutation; idempotent.
    private func persistLibraryMembershipPayload() async {
        guard let playlistId = libraryMagicPlaylistId else { return }
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

    /// `true` when the album appears in the user's library (any track present, or
    /// the album was added as a unit via ``addAlbumToLibrary``).
    func isAlbumInLibrary(_ id: String) -> Bool {
        libraryAlbumEntries.contains(where: { $0.id == id })
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
    }

    func clearDownloadedMusic() {
        offline.clearAllDownloads()
    }

    func clearMetadataCache() {
        LibrarySnapshotStore.clear()
        PlaylistRowsCacheStore.clear()
        StreamingMediaDiskCache.shared.clear()
        clearInMemoryPlaylistRowsCache()
    }

    func clearAllLocalCaches() async {
        clearDownloadedMusic()
        clearMetadataCache()
        await clearImageCaches()
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

        // Kick off the server-side scan immediately so it can race the retry loop.
        Task { try? await lib.triggerLibraryScan() }

        let probe = DowntifySong(songId: job.id, name: title,
                                 artists: artist.isEmpty ? [] : [artist],
                                 albumName: "", url: job.id, coverURL: nil, year: nil, explicit: false)
        // ~60s total budget: 20 attempts × 3s. The early attempts catch fast scans
        // (Navidrome typically), the later ones catch slow ones (Jellyfin libraries
        // with many items). First check fires immediately in case the file was
        // already scanned by a prior pass.
        for attempt in 0..<20 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            let results = (try? await lib.searchCatalog(query: "\(artist) \(title)", limit: 30)) ?? .empty
            if let match = LibraryTrackMatcher.firstLibraryTrack(matching: probe, in: results.songs) {
                await addSongToLibrary(match)
                showTransientToast("Added “\(match.title)”")
                return
            }
        }
        // Downloaded but the backend hasn't surfaced it within the budget. The
        // file is on disk; the next scheduled scan will pick it up.
        showTransientToast("Downloaded “\(title)”")
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
    }

    /// Appends an album to `libraryAlbums` if it isn't already cached, so views that
    /// resolve `libraryAlbumEntries` against the catalog don't drop newly-added albums.
    private func ensureAlbumInCatalog(_ album: AlbumSummary) {
        if libraryAlbumsById[album.id] != nil { return }
        libraryAlbums.append(album)
    }

    /// Ensures a pinned album can render in the Library hub grid before the next catalog refresh.
    func retainAlbumForLibraryPin(_ album: AlbumSummary) {
        ensureAlbumInCatalog(album)
    }

    /// Ensures a pinned song can render in the Library hub grid before the track index finishes loading.
    func retainTrackForLibraryPin(_ track: Track) {
        if discoveryTrackById[track.id] != nil { return }
        discoveryLibraryTracks.append(trackWithResolvedArtwork(track))
        rebuildDiscoveryTrackIndices()
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
        libraryAlbums.append(synthesized)
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
    }

    /// Registers a server playlist in the user's Lyra library. The playlist itself is
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
        PerfLog.measure("rebuildLibraryAlbumIndex", details: "albums=\(libraryAlbums.count)") {
            libraryAlbumsById = Dictionary(uniqueKeysWithValues: libraryAlbums.map { ($0.id, $0) })
            libraryAlbumReleaseIndex = LibraryAlbumReleaseIndex(albums: libraryAlbums)
        }
    }

    /// Set while ``refreshLibraryTrackMatchIndex`` is doing the index work off-main
    /// and the resulting structures will be written directly. Suppresses the on-main
    /// rebuild that would otherwise duplicate the work in `didSet`.
    private var skipDiscoveryIndexRebuild = false

    /// Rebuild both the title-index (used by Downtify match-Bool checks) and the
    /// chart-track index (used by New tab `Track` lookups) when the discovery
    /// snapshot is reassigned. Centralized so no caller can update one and forget
    /// the other.
    private func rebuildDiscoveryTrackIndices() {
        guard !skipDiscoveryIndexRebuild else { return }
        PerfLog.measure("rebuildDiscoveryTrackIndices", details: "tracks=\(discoveryLibraryTracks.count)") {
            discoveryTrackById = Dictionary(uniqueKeysWithValues: discoveryLibraryTracks.map { ($0.id, $0) })
            libraryTrackTitleIndex = LibraryTrackMatcher.titleIndex(from: discoveryLibraryTracks)
            libraryChartTrackIndex = LibraryChartTrackIndex(tracks: discoveryLibraryTracks)
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
            libraryAlbums = fetched
            recentlyAddedAlbums = (try? await recent) ?? []
            mergeOfflineCatalog()
            persistLibrarySnapshot()
            // Discovery / Downtify-match index is deferred — building it for tens of
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
        playlistPickerPayload = nil
    }

    func presentAddToPlaylist(tracks: [Track]) {
        guard !tracks.isEmpty, isSignedIn else { return }
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks)
    }

    /// Shows a brief bottom toast (~1.8s) and fires a soft impact haptic. Replaces any
    /// in-flight toast so rapid actions don't pile up.
    func showTransientToast(_ message: String) {
        transientToast = message
        transientToastTask?.cancel()
        transientToastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if self.transientToast == message { self.transientToast = nil }
            }
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }

    /// Refreshes ``libraryPlaylists`` from the active server (Jellyfin / Navidrome).
    /// Filters out the Lyra magic playlist by both id and `__lyra_` name prefix so it
    /// never appears in user-facing playlist surfaces.
    func refreshLibraryPlaylists() async {
        let fetched: [PlaylistSummary]
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { libraryPlaylists = []; return }
            fetched = (try? await client.fetchPlaylistSummaries()) ?? []
        case .navidrome:
            guard let client = navidrome else { libraryPlaylists = []; return }
            fetched = (try? await client.fetchPlaylistSummaries()) ?? []
        }
        libraryPlaylists = filterOutMagicPlaylist(fetched)
        rebuildHomeRecentlyPlayed()
    }

    /// Strips the Lyra magic playlist from any list of server playlists. Belt-and-braces:
    /// matches by cached id when known *and* by `__lyra_` name prefix as a safety net.
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

    func fetchPlaylistRows(playlistId: String) async throws -> [PlaylistRowItem] {
        let rows: [PlaylistRowItem]
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            rows = try await client.fetchPlaylistRows(playlistId: playlistId)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            rows = try await client.fetchPlaylistRows(playlistId: playlistId)
        }
        playlistRowsCache[playlistId] = rows
        persistPlaylistRowsCache()
        return rows
    }

    @discardableResult
    func createPlaylist(name: String, initialTracks: [Track] = [], isPublic: Bool = false) async throws -> PlaylistSummary {
        let ids = initialTracks.map(\.id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist name cannot be empty."])
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

    func removePlaylistRows(playlistId: String, rows: [PlaylistRowItem]) async throws {
        guard !rows.isEmpty else { return }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            let entries = rows.compactMap(\.jellyfinEntryId)
            guard entries.count == rows.count else {
                throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist entry id."])
            }
            try await client.removeTracksFromPlaylist(playlistId: playlistId, entryIds: entries)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            let indexes = rows.compactMap(\.navidromeIndex)
            guard indexes.count == rows.count else {
                throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist index."])
            }
            try await client.removeTracksFromPlaylist(playlistId: playlistId, indexes: indexes)
        }
        stripKillModePending(playlistId: playlistId, trackIds: Set(rows.map(\.track.id)))
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
        try await removePlaylistRows(playlistId: playlistId, rows: rows)
    }

    /// Callback hook from `PlaybackEngine.onTrackSkipped`. Marks the outgoing track when:
    /// (1) playback is sourced from a playlist, (2) Kill Mode is on for that playlist, and
    /// (3) the track wasn't inserted via Play Next / Add to Queue.
    private func handleKillModeSkip(track: Track, source: PlaybackSource?) {
        guard case let .playlist(p)? = source,
              killModeEnabledPlaylistIds.contains(p.id),
              !player.userQueuedTrackIds.contains(track.id) else { return }
        var current = killModePendingRemovals[p.id] ?? []
        // Dedupe-then-prepend so a re-skipped track moves back to the top of the list.
        current.removeAll { $0 == track.id }
        current.insert(track.id, at: 0)
        killModePendingRemovals[p.id] = current
        KillModeStore.savePending(killModePendingRemovals)
    }

    /// Removes the given track ids from the pending list for a playlist and persists. Called
    /// after any successful playlist deletion path so the pending list never references tracks
    /// that are no longer in the playlist. Preserves the relative order of remaining entries.
    private func stripKillModePending(playlistId: String, trackIds: Set<String>) {
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
                domain: "LyraMusic",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Sign in to change playlist artwork."],
            )
        }
        guard !imageData.isEmpty else {
            throw NSError(
                domain: "LyraMusic",
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
            throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist name cannot be empty."])
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
                    let byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
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
        defer { newTabBrowseLoading = false }

        guard musicBrainzEnabled else {
            clearNewTabBrowseGrid()
            newTabBrowseBackend = .none
            return
        }
        newTabBrowseError = nil
        do {
            let mb = try await MusicBrainzNewReleasesClient.fetchRecentAlbums(limit: 50)
            applyNewTabGrid(fromAlbums: mb, backend: .musicBrainz)
            newTabBrowseError = mb.isEmpty ? "No recent albums from MusicBrainz in the last few months." : nil
        } catch {
            clearNewTabBrowseGrid()
            newTabBrowseBackend = .none
            newTabBrowseError = error.localizedDescription
        }
    }

    private func applyNewTabGrid(fromAlbums albums: [ChartAlbum], backend: NewTabBrowseBackend) {
        newTabRecentReleases = albums
        newTabTopTracks = Array(albums.prefix(20)).map {
            ChartTrack(id: $0.id, name: $0.name, artistName: $0.artistName,
                       imageURL: $0.imageURL, playcount: 0, browseKind: "Album")
        }
        newTabTopAlbums = []
        newTabBrowseBackend = backend
    }

    private func clearNewTabBrowseGrid() {
        newTabTopTracks = []
        newTabTopAlbums = []
        newTabRecentReleases = []
    }

    // MARK: - Playback helpers

    /// Starts playback and surfaces stream/load failures via the root toast.
    func playAlbumOrToast(
        library: MusicLibraryProviding? = nil,
        tracks: [Track],
        startIndex: Int = 0,
        source: PlaybackSource? = nil
    ) async {
        guard let lib = library ?? activeLibrary else {
            showTransientToast("Sign in to play music.")
            return
        }
        guard !tracks.isEmpty else { return }
        do {
            try await player.playAlbum(library: lib, tracks: tracks, startIndex: startIndex, source: source)
        } catch {
            showTransientToast(error.musicPlaybackToastMessage)
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

    /// Albums on the connected server credited to `name` (normalized-artist match).
    /// The subscription engine's "do I already have this?" check; works with any backend.
    func serverAlbums(forArtistName name: String) async -> [AlbumSummary] {
        guard let lib = activeLibrary else { return [] }
        let target = LibraryTrackMatcher.normalize(name)
        let results = (try? await lib.searchCatalog(query: name, limit: 60)) ?? .empty
        return results.albums.filter { LibraryTrackMatcher.normalize($0.artist) == target }
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

    /// Preview track listing for **New tab / browse** flows (MusicBrainz → release → recordings). Not used for ``AlbumDetailView``.
    func resolveBrowseAlbumPreviewTracks(source: BrowseAlbumDetailSource) async -> [BrowseAlbumPreviewTrack] {
        switch source {
        case .chartBrowse(let artist, let title, _, let kind):
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let rg = await MusicBrainzTracklistClient.findReleaseGroupId(artist: artist, albumTitle: title) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                let mbTracks = await MusicBrainzTracklistClient.tracksForReleaseGroup(rg)
                if !mbTracks.isEmpty { return mbTracks }
            }
            if kind.lowercased() == "single" {
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

    // MARK: - Radio (Navidrome)

    /// Plays a live stream from the server's internet radio list (`getInternetRadioStations`).
    func playInternetRadioStation(_ station: InternetRadioStation) async {
        guard let client = navidrome else {
            errorMessage = "Internet radio requires a Navidrome connection."
            return
        }
        let track = Track(
            id: "internet-radio-\(station.id)",
            title: station.name,
            albumId: "internet-radio",
            albumTitle: "Live Radio",
            artist: station.name,
            duration: 0,
            discNumber: 1,
            indexNumber: 1,
            artworkURL: nil,
            streamOverrideURL: station.streamURL,
        )
        player.shuffleMode = .off
        do {
            try await player.playAlbum(library: client, tracks: [track], startIndex: 0)
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

    private func saveRecentlyPlayedTracksToDefaults() {
        guard let data = try? JSONEncoder().encode(recentlyPlayedTracks) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentlyPlayedTracksKey)
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
        // Offline mode filters what Lyra shows — it is not the same as losing connectivity.
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
            } else if let ssid = await AutoOfflineHelper.fetchCurrentSSID() {
                autoOfflineActive = !homeWifiSSIDs.contains(ssid)
            } else {
                autoOfflineActive = false
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
                self.hasInternetPath = online
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
        player.equalizerBandGains = equalizerBandGains
        player.applyLiveEqualizerGains()
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset) {
        equalizerPresetId = preset.id
        equalizerBandGains = preset.gains
    }

    func setEqualizerBandGain(index: Int, gain: Float) {
        guard index >= 0, index < EqualizerBand.count else { return }
        var next = equalizerBandGains
        if next.count < EqualizerBand.count {
            next = EqualizerPreset.normalizedGains(next)
        }
        next[index] = min(max(gain, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound)
        equalizerBandGains = next
        equalizerPresetId = EqualizerPreset.catalog[0].id
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
        showTransientToast(role == .secondary ? "Using secondary server" : "Using primary server")
    }

    func attemptAutomaticFailoverIfNeeded() async -> Bool {
        guard serverFailoverMode == .automatic,
              activeServerURLRole == .primary,
              normalizedServerURL(from: secondaryURLString) != nil,
              serverConnectionHealth != .connected
        else { return false }
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
        if !librarySwaps.isEmpty {
            Task { await persistTrackIDSwapsToMagicPlaylist(librarySwaps) }
        }
    }

    private func persistTrackIDSwapsToMagicPlaylist(_ swaps: [String: Track]) async {
        guard let playlistId = libraryMagicPlaylistId else { return }
        do {
            try await removeTracksFromServerMagicPlaylist(playlistId: playlistId, trackIds: Set(swaps.keys))
            try await addTracksToServerMagicPlaylist(
                playlistId: playlistId,
                trackIds: swaps.values.map(\.id)
            )
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
            for item in similar {
                try await player.addToQueue(library: lib, track: item)
            }
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

    func createNavidromeShareAndNotify(forItemId id: String, description: String) async {
        do {
            let entry = try await createNavidromeShare(forItemId: id, description: description)
            #if os(iOS)
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

    func playbackSettingsSnapshot() -> LyraPlaybackSettingsSnapshot {
        LyraPlaybackSettingsSnapshot(
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

    func applyPlaybackSettingsSnapshot(_ snapshot: LyraPlaybackSettingsSnapshot) -> Bool {
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
                updateDeleteCapability()
                prefetchAccountAvatar()
                pushQualitySettingsToClients()
                restoreLibraryFromDisk()
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
                updateDeleteCapability()
                prefetchAccountAvatar()
                restoreLibraryFromDisk()
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
