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
    @Published var accentPresetId: String = UserDefaults.standard.string(forKey: "lyraAccentPresetId") ?? AppAccentPreset.defaultId {
        didSet {
            UserDefaults.standard.set(accentPresetId, forKey: "lyraAccentPresetId")
            syncHomeScreenIconForAccentIfNeeded()
        }
    }

    @Published var musicBrainzEnabled: Bool = UserDefaults.standard.object(forKey: "musicBrainzEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(musicBrainzEnabled, forKey: "musicBrainzEnabled") }
    }

    @Published var backendKind: BackendKind = .jellyfin
    @Published var baseURLString: String = ""
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var isSignedIn: Bool = false
    /// True while ``signIn()`` is in flight (manual or keychain restore).
    @Published var isAuthenticating: Bool = false
    @Published var selectedTab: AppTab = .home
    @Published var pendingNavigation: NowPlayingDeepLink? = nil

    /// Scroll signal consumed by an already-visible ``ServerPlaylistDetailView`` so "Go to Playlist"
    /// scrolls to the now-playing track even when the user is already on that playlist.
    @Published var pendingPlaylistScroll: PendingPlaylistScroll? = nil

    /// Same as ``pendingPlaylistScroll`` but for album-mode detail views.
    @Published var pendingAlbumScroll: PendingAlbumScroll? = nil

    /// Brief bottom toast (e.g. "Added to Queue"). Auto-clears after ``showTransientToast``
    /// is called; the ``MusicTransientToastChrome`` view modifier renders it.
    @Published var transientToast: String? = nil
    private var transientToastTask: Task<Void, Never>? = nil

    @Published var errorMessage: String?
    @Published private(set) var hasInternetPath: Bool = true
    @Published private(set) var serverConnectionHealth: ServerConnectionHealth = .unknown

    /// Shared catalog for Listen / Library / Search tabs.
    @Published private(set) var libraryAlbums: [AlbumSummary] = [] {
        didSet {
            rebuildLibraryAlbumIndex()
            rebuildHomeRecentlyPlayed()
        }
    }
    @Published private(set) var recentlyAddedAlbums: [AlbumSummary] = []
    /// Backend-side play history (Jellyfin `DatePlayed`, Subsonic `getAlbumList2?type=recent`).
    /// Stored separately from the local list so the merged Home shelf can update live as either side changes.
    @Published private(set) var homeRecentlyPlayedServerAlbums: [AlbumSummary] = []
    @Published private(set) var homeGenreShelves: [(genre: String, albums: [AlbumSummary])] = []

    /// Live merge of the local play log and the server's recently-played albums.
    @Published private(set) var homeRecentlyPlayed: [RecentPlayedItem] = []
    @Published private(set) var libraryAlbumsLoadError: String?

    /// Normalized track titles → normalized artist strings (for Downtify vs library matching).
    @Published private(set) var libraryTrackTitleIndex: [String: Set<String>] = [:]
    /// Snapshot of tracks used to build ``libraryTrackTitleIndex`` (resolve Downtify rows → `Track`).
    @Published private(set) var discoveryLibraryTracks: [Track] = [] {
        didSet { rebuildDiscoveryTrackIndices() }
    }
    /// O(1) "is this chart row in the user's library?" lookup. Rebuilt with ``libraryTrackTitleIndex``.
    private(set) var libraryChartTrackIndex: LibraryChartTrackIndex = .empty
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

    private var libraryAlbumsById: [String: AlbumSummary] = [:]
    /// O(1) "is this chart album in the user's library?" lookup. Rebuilt alongside ``libraryAlbumsById``.
    private(set) var libraryAlbumReleaseIndex: LibraryAlbumReleaseIndex = .empty
    private var libraryBootstrapTask: Task<Void, Never>?
    private var trackIndexTask: Task<Void, Never>?

    private static let favoriteTrackIdsKey = "LyraMusic.favoriteTrackIds"
    @Published private(set) var favoriteTrackIds: Set<String> = []

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

    // MARK: - Downtify (optional)

    @Published var downtifyBaseURLString: String = DowntifyClient.storedBaseURL ?? ""
    var downtifyConfigured: Bool { DowntifyClient.isConfigured }

    private static let themePreferenceKey = "lyraThemePreference"
    private static let wifiStreamQualityKey = "lyraWifiStreamQuality"
    private static let cellularStreamQualityKey = "lyraCellularStreamQuality"
    private static let downloadQualityKey = "lyraDownloadQuality"
    private static let songListItemSizeKey = "lyraSongListItemSize"
    private static let lastLibrarySyncAtKey = "lyraLastLibrarySyncAt"
    private static let volumeNormalizationKey = "lyraVolumeNormalization"
    private static let eqMasterEnabledKey = "lyraEQMasterEnabled"
    private static let eqBandGainsKey = "lyraEQBandGainsDb"
    private static let eqPresetsKey = "lyraEQPresets"

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

    @Published var downloadQualityTier: DownloadQualityTier = .original {
        didSet {
            UserDefaults.standard.set(downloadQualityTier.rawValue, forKey: Self.downloadQualityKey)
            pushQualitySettingsToClients()
        }
    }

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

    @Published var eqMasterEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(eqMasterEnabled, forKey: Self.eqMasterEnabledKey)
        }
    }

    /// Six EQ band gains in dB (see ``PlaybackEQBandHz``). Reserved for a future equalizer.
    @Published var eqBandGainsDb: [Float] = [0, 0, 0, 0, 0, 0] {
        didSet {
            if eqBandGainsDb.count != 6 {
                eqBandGainsDb = Array((eqBandGainsDb + Array(repeating: 0, count: 6)).prefix(6))
            }
            Self.persistEQGains(eqBandGainsDb)
        }
    }

    @Published var eqPresets: [EQPreset] = [] {
        didSet {
            Self.persistEQPresets(eqPresets)
        }
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
        player.bind(offline: offline)
        // Only mini-player chrome affects most tabs; avoid rebinding Home/Library on every queue tick.
        player.$showsMiniPlayerChrome
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // User-action driven state — re-emit so NowPlayingView's shuffle/repeat row + up-next
        // list react to taps. Low frequency, so no scroll-jank cost.
        player.$shuffleMode
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$repeatMode
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$queue
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$currentIndex
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        offline.$downloadedTrackIds
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        loadPersistedSettings()
        startNetworkMonitor()
        loadKeychain()
        loadFavoriteTrackIdsFromDefaults()
        loadRecentlyPlayedEntriesFromDefaults()
        loadRecentlyPlayedTracksFromDefaults()
        player.onTrackScrobbled = { [weak self] track, source in
            Task { @MainActor in
                self?.recordRecentPlay(track: track, source: source)
            }
        }
        player.onTrackStarted = { [weak self] track in
            Task { @MainActor in
                self?.recordRecentTrackPlay(track)
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

    /// Updates the home screen icon when it does not match the current accent (iOS shows its OK alert on change).
    public func syncHomeScreenIconForAccentIfNeeded() {
        #if canImport(UIKit)
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let target = AppAlternateIconSync.resolvedIconName(forAccentPresetId: accentPresetId)
        guard UIApplication.shared.alternateIconName != target else { return }
        AppAlternateIconSync.apply(accentPresetId: accentPresetId, completion: nil)
        #endif
    }

    public func signIn() async {
        guard !isAuthenticating else { return }
        errorMessage = nil
        guard let base = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Invalid server URL"
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            switch backendKind {
            case .jellyfin:
                let client = JellyfinMusicClient(baseURL: base)
                try await client.signIn(username: username, password: password)
                jellyfin = client
                navidrome = nil
                try KeychainStore.saveJellyfin(
                    base: base,
                    user: username,
                    password: password,
                    accessToken: client.sessionAccessToken,
                    userId: client.sessionUserId,
                )
                await Self.registerMediaAuthHeaders(host: base.host, headers: client.httpHeadersForMediaRequests())
            case .navidrome:
                let client = NavidromeClient(baseURL: base)
                try await client.signIn(username: username, password: password)
                navidrome = client
                jellyfin = nil
                navidromeUserMetadata = client.currentUserMetadata
                try KeychainStore.saveNavidrome(
                    base: base,
                    user: username,
                    password: password,
                    subsonicToken: client.sessionToken,
                )
            }
            // Enter the app immediately after auth — library refresh can take a long time on large servers.
            isSignedIn = true
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
        PlaybackQueueStore.clear()
        hasInternetPath = true
        serverConnectionHealth = .unknown
    }

    /// Prefer on-disk artwork for downloaded content, then server URL.
    func resolvedArtworkURL(for track: Track) -> URL? {
        offline.localArtworkURL(forTrackId: track.id) ?? track.artworkURL
    }

    func resolvedArtworkURL(for album: AlbumSummary) -> URL? {
        offline.localArtworkURL(forAlbumId: album.id) ?? album.artworkURL
    }

    func persistLibrarySnapshot() {
        LibrarySnapshotStore.save(
            LibrarySnapshot(
                albums: libraryAlbums,
                tracks: discoveryLibraryTracks,
                playlists: libraryPlaylists,
                favoriteTrackIds: Array(favoriteTrackIds),
                libraryMagicPlaylistId: libraryMagicPlaylistId,
                librarySongIds: Array(librarySongIds),
                libraryAlbumEntries: libraryAlbumEntries,
                libraryPlaylistEntries: libraryPlaylistEntries,
            ),
        )
    }

    private func restoreLibraryFromDisk() {
        if let snap = LibrarySnapshotStore.load() {
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
        async let played = (try? await lib.recentlyPlayed(limit: 12)) ?? []
        async let genres = (try? await lib.libraryGenres(limit: 20)) ?? []
        let (playedResult, genresResult) = await (played, genres)
        homeRecentlyPlayedServerAlbums = playedResult
        rebuildHomeRecentlyPlayed()
        let pickedGenres = Array(genresResult.shuffled().prefix(4))
        let shelves = await withTaskGroup(of: (genre: String, albums: [AlbumSummary])?.self) { group in
        for g in pickedGenres {
                group.addTask {
            let albums = (try? await lib.albums(inGenre: g, limit: 8)) ?? []
                    guard !albums.isEmpty else { return nil }
                    return (genre: g.name, albums: albums)
                }
            }
            var rows: [(genre: String, albums: [AlbumSummary])] = []
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows
        }
        homeGenreShelves = shelves
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
        await refreshLibraryAlbums()
        recordSuccessfulLibrarySync()
        async let home: Void = refreshHome()
        async let stats: Void = refreshLibraryStatistics()
        async let browse: Void = refreshNewTabBrowse()
        async let membership: Void = refreshLibraryMembership()
        _ = await (home, stats, browse, membership)
    }

    // MARK: - Library membership (magic playlist)

    /// `host` component of the active server URL, lowercased for the membership cache key.
    private var libraryMagicPlaylistHost: String? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
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
    private var libraryMagicPlaylistIdentity: (name: String, host: String?, userKey: String)? {
        guard isSignedIn, let userKey = libraryMagicPlaylistUserKey else { return nil }
        let host = libraryMagicPlaylistHost
        let name = LibraryMembership.magicPlaylistName(backend: backendKind, host: host, userKey: userKey)
        return (name, host, userKey)
    }

    /// Resolves the user's magic playlist (find by deterministic name, create when absent),
    /// then loads its track ids and JSON membership payload into the published state.
    /// Cheap on subsequent runs because the resolved id is cached in `UserDefaults`.
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
            if fetch.name != identity.name {
                // Name drift (user renamed the magic playlist via web UI). Re-resolve from scratch.
                LibraryMembership.clearCachedPlaylistId(backend: backendKind, host: identity.host, userKey: identity.userKey)
                let freshId = try await resolveMagicPlaylistId(identity: identity)
                let freshFetch = try await fetchMagicPlaylistContents(playlistId: freshId)
                applyMagicPlaylistFetch(playlistId: freshId, fetch: freshFetch)
            } else {
                applyMagicPlaylistFetch(playlistId: resolvedId, fetch: fetch)
            }
        } catch {
            // Don't surface this as a global error — library still functions without it,
            // just without the user-curated overlay. Try again on the next bootstrap.
            libraryMagicPlaylistId = nil
        }
    }

    private struct LibraryPlaylistFetchShape {
        let id: String
        let name: String
        let trackIds: [String]
        let comment: String?
    }

    private func resolveMagicPlaylistId(identity: (name: String, host: String?, userKey: String)) async throws -> String {
        if let cached = LibraryMembership.cachedPlaylistId(
            backend: backendKind, host: identity.host, userKey: identity.userKey,
        ) {
            // Trust the cache without a roundtrip; if the fetch later fails, we re-resolve.
            return cached
        }
        let resolved = try await findOrCreateMagicPlaylist(name: identity.name)
        LibraryMembership.cachePlaylistId(
            resolved, backend: backendKind, host: identity.host, userKey: identity.userKey,
        )
        return resolved
    }

    private func findOrCreateMagicPlaylist(name: String) async throws -> String {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { throw URLError(.userAuthenticationRequired) }
            if let existing = try await client.findPlaylistByName(name) { return existing.id }
            return try await client.createEmptyPrivatePlaylist(name: name)
        case .navidrome:
            guard let client = navidrome else { throw URLError(.userAuthenticationRequired) }
            if let existing = try await client.findPlaylistByName(name) { return existing.id }
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
        Task { await backfillMissingLibraryAlbumSummaries() }
        if backendKind == .navidrome {
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
        let missingIds = libraryAlbumEntries.map(\.id).filter { !knownIds.contains($0) }
        guard !missingIds.isEmpty else { return }
        var fetched: [AlbumSummary] = []
        for id in missingIds {
            let summary: AlbumSummary?
            switch backendKind {
            case .jellyfin:
                summary = try? await jellyfin?.albumSummary(forId: id)
            case .navidrome:
                summary = try? await navidrome?.albumSummary(forId: id)
            }
            if let summary { fetched.append(summary) }
        }
        guard !fetched.isEmpty else { return }
        // Merge into the catalog in one assignment so the @Published setter only
        // fires once and `libraryAlbumsById` rebuilds once.
        var merged = libraryAlbums
        let existing = Set(merged.map(\.id))
        for album in fetched where !existing.contains(album.id) {
            merged.append(album)
        }
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
            // Best-effort: a write failure leaves the in-memory state out of sync with the
            // server. Next ``refreshLibraryMembership`` will reconcile.
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

    /// Tracks to show under Library → Downloaded: manifest records first, then library catalog matches.
    func tracksForDownloadedLibrary() -> [Track] {
        let cached = offline.cachedTracks()
        if !cached.isEmpty { return cached }
        let ids = offline.downloadedTrackIds
        guard !ids.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Track] = []
        for track in discoveryLibraryTracks where ids.contains(track.id) {
            guard offline.localFile(for: track.id) != nil else { continue }
            if seen.insert(track.id).inserted { out.append(track) }
        }
        for id in ids where !seen.contains(id) {
            guard offline.localFile(for: id) != nil else { continue }
            if let track = offline.cachedTrack(id: id) {
                out.append(track)
                seen.insert(id)
            }
        }
        return out.sorted {
            let ac = $0.albumTitle.localizedCaseInsensitiveCompare($1.albumTitle)
            if ac != .orderedSame { return ac == .orderedAscending }
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.indexNumber < $1.indexNumber
        }
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
    }

    /// Appends an album to `libraryAlbums` if it isn't already cached, so views that
    /// resolve `libraryAlbumEntries` against the catalog don't drop newly-added albums.
    private func ensureAlbumInCatalog(_ album: AlbumSummary) {
        if libraryAlbumsById[album.id] != nil { return }
        libraryAlbums.append(album)
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
        // If the user has no remaining songs from this album, drop the album entry
        // too so the album disappears from "My Library" instead of lingering as a
        // stub that re-opens the full album view.
        if !track.albumId.isEmpty,
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
        libraryAlbumsById = Dictionary(uniqueKeysWithValues: libraryAlbums.map { ($0.id, $0) })
        libraryAlbumReleaseIndex = LibraryAlbumReleaseIndex(albums: libraryAlbums)
    }

    /// Rebuild both the title-index (used by Downtify match-Bool checks) and the
    /// chart-track index (used by New tab `Track` lookups) when the discovery
    /// snapshot is reassigned. Centralized so no caller can update one and forget
    /// the other.
    private func rebuildDiscoveryTrackIndices() {
        libraryTrackTitleIndex = LibraryTrackMatcher.titleIndex(from: discoveryLibraryTracks)
        libraryChartTrackIndex = LibraryChartTrackIndex(tracks: discoveryLibraryTracks)
    }

    public func refreshLibraryAlbums(limit: Int = AppModel.defaultLibraryAlbumFetchLimit) async {
        guard let lib = activeLibrary else { return }
        libraryAlbumsLoadError = nil
        do {
            async let all = lib.albums(limit: limit)
            async let recent = lib.recentlyAdded(limit: 60)
            libraryAlbums = try await all
            recentlyAddedAlbums = (try? await recent) ?? []
            mergeOfflineCatalog()
            persistLibrarySnapshot()
            scheduleLibraryTrackMatchIndexRefresh()
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

    func fetchPlaylistRows(playlistId: String) async throws -> [PlaylistRowItem] {
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

    func createPlaylist(name: String, initialTracks: [Track] = [], jellyfinVisibleToAll: Bool = false) async throws {
        let ids = initialTracks.map(\.id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist name cannot be empty."])
        }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            _ = try await client.createPlaylist(name: trimmed, trackIds: ids, isPublic: jellyfinVisibleToAll)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            _ = try await client.createPlaylist(name: trimmed, trackIds: ids)
        }
        await refreshLibraryPlaylists()
    }

    func addTracksToPlaylist(playlistId: String, tracks: [Track]) async throws {
        let ids = tracks.map(\.id)
        guard !ids.isEmpty else { return }
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
        await refreshLibraryPlaylists()
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
        await refreshLibraryPlaylists()
    }

    func renamePlaylist(playlistId: String, name: String, jellyfinVisibleToAll: Bool? = nil) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Playlist name cannot be empty."])
        }
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.renamePlaylist(playlistId: playlistId, name: trimmed, isPublic: jellyfinVisibleToAll)
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            try await client.renamePlaylist(playlistId: playlistId, name: trimmed)
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
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { return }
            do {
                favoriteTrackIds = try await client.fetchFavoriteTrackIds(limit: 20_000)
            } catch {}
        case .navidrome:
            guard let client = navidrome else { return }
            do {
                favoriteTrackIds = try await client.fetchFavoriteTrackIds(limit: 20_000)
            } catch {}
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

    /// Loads up to `limit` audio tracks from the server and rebuilds `libraryTrackTitleIndex` for discovery matching.
    public func refreshLibraryTrackMatchIndex(limit: Int = 50_000) async {
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
            let tracks = try await lib.allTracks(limit: limit)
            discoveryLibraryTracks = tracks
            offline.backfillRecordsIfMissing(knownTracks: tracks)
            mergeOfflineCatalog()
            persistLibrarySnapshot()
        } catch {
            libraryTrackIndexLoadError = error.localizedDescription
            offline.backfillRecordsIfMissing(knownTracks: discoveryLibraryTracks)
            mergeOfflineCatalog()
        }
    }

    func albumSummary(for track: Track) -> AlbumSummary {
        if let cached = libraryAlbumsById[track.albumId] {
            var album = cached
            if let local = resolvedArtworkURL(for: cached) {
                album = AlbumSummary(
                    id: album.id,
                    title: album.title,
                    artist: album.artist,
                    artworkURL: local,
                    trackCount: album.trackCount,
                    libraryAddedDate: album.libraryAddedDate,
                    genres: album.genres,
                    releaseYear: album.releaseYear,
                )
            }
            return album
        }
        let art = resolvedArtworkURL(for: track)
        return AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: art,
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

    // MARK: - Downtify

    func saveDowntifyURL() {
        let trimmed = downtifyBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        DowntifyClient.save(baseURL: trimmed)
        downtifyBaseURLString = trimmed
        objectWillChange.send()
    }

    func disconnectDowntify() {
        DowntifyClient.clear()
        downtifyBaseURLString = ""
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
        if UserDefaults.standard.object(forKey: Self.eqMasterEnabledKey) != nil {
            eqMasterEnabled = UserDefaults.standard.bool(forKey: Self.eqMasterEnabledKey)
        }
        if let arr = UserDefaults.standard.array(forKey: Self.eqBandGainsKey) as? [Double], arr.count == 6 {
            eqBandGainsDb = arr.map { Float($0) }
        }
        eqPresets = Self.loadEQPresetsFromDefaults()
    }

    private static func loadEQPresetsFromDefaults() -> [EQPreset] {
        guard let data = UserDefaults.standard.data(forKey: eqPresetsKey) else { return [] }
        return (try? JSONDecoder().decode([EQPreset].self, from: data)) ?? []
    }

    fileprivate static func persistEQGains(_ gains: [Float]) {
        UserDefaults.standard.set(gains.map { Double($0) }, forKey: eqBandGainsKey)
    }

    fileprivate static func persistEQPresets(_ presets: [EQPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: eqPresetsKey)
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let wasOnline = self.hasInternetPath
                self.hasInternetPath = online
                if !online {
                    self.serverConnectionHealth = .noNetwork
                } else if !wasOnline, self.isSignedIn {
                    self.prefetchAccountAvatar()
                    Task { await self.refreshServerConnectionHealth() }
                }
                guard online else { return }
                let wifiLike = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                let cellularNow = !wifiLike
                if cellularNow != self.prefersCellularStreamingQuality {
                    self.prefersCellularStreamingQuality = cellularNow
                    self.pushQualitySettingsToClients()
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    func pushQualitySettingsToClients() {
        let streamTier = prefersCellularStreamingQuality ? cellularStreamQuality : wifiStreamQuality
        jellyfin?.streamingBitrateCapBps = streamTier.jellyfinAudioBitRate
        jellyfin?.offlineBitrateCapBps = downloadQualityTier.jellyfinAudioBitRate
        navidrome?.streamingMaxBitRate = streamTier.navidromeMaxBitRate
        navidrome?.offlineMaxBitRate = downloadQualityTier.navidromeMaxBitRate
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
        scheduleLibraryTrackMatchIndexRefresh()
        await refreshLibraryStatistics()
        recordSuccessfulLibrarySync()
    }

    func saveEQPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        eqPresets.append(EQPreset(name: trimmed, gainsDb: eqBandGainsDb))
    }

    func deleteEQPreset(id: UUID) {
        eqPresets.removeAll { $0.id == id }
    }

    func renameEQPreset(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = eqPresets.firstIndex(where: { $0.id == id }) else { return }
        var preset = eqPresets[idx]
        preset.name = trimmed
        eqPresets[idx] = preset
    }

    func applyEQPreset(_ preset: EQPreset) {
        eqBandGainsDb = preset.gainsDb
        eqMasterEnabled = true
    }

    private func loadKeychain() {
        if let j = try? KeychainStore.loadJellyfin() {
            backendKind = .jellyfin
            baseURLString = j.base.absoluteString
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
