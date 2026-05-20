import Combine
import Network
import SwiftUI

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
    case lastFm
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
    @Published var selectedTab: Int = 0
    @Published var errorMessage: String?
    @Published private(set) var hasInternetPath: Bool = true
    @Published private(set) var serverConnectionHealth: ServerConnectionHealth = .unknown

    /// Shared catalog for Listen / Library / Search tabs.
    @Published private(set) var libraryAlbums: [AlbumSummary] = [] {
        didSet { rebuildLibraryAlbumIndex() }
    }
    @Published private(set) var recentlyAddedAlbums: [AlbumSummary] = []
    /// Backend-side play history (Jellyfin `DatePlayed`, Subsonic `getAlbumList2?type=recent`).
    /// Stored separately from the local list so the merged Home shelf can update live as either side changes.
    @Published private(set) var homeRecentlyPlayedServerAlbums: [AlbumSummary] = []
    @Published private(set) var homeGenreShelves: [(genre: String, albums: [AlbumSummary])] = []

    /// Live merge of the local play log and the server's recently-played albums. Recomputed every
    /// SwiftUI evaluation, so the Home shelf reflects new scrobbles or a late-arriving playlist sync
    /// without waiting for the next `refreshHome()` pass.
    var homeRecentlyPlayed: [RecentPlayedItem] {
        let local = localRecentlyPlayed(limit: 24)
        let server = homeRecentlyPlayedServerAlbums.map(RecentPlayedItem.album)
        var seen = Set<String>()
        let merged = (local + server).filter { seen.insert($0.id).inserted }
        return Array(merged.prefix(12))
    }
    @Published private(set) var libraryAlbumsLoadError: String?

    /// Normalized track titles → normalized artist strings (for Downtify vs library matching).
    @Published private(set) var libraryTrackTitleIndex: [String: Set<String>] = [:]
    /// Snapshot of tracks used to build ``libraryTrackTitleIndex`` (resolve Downtify rows → `Track`).
    @Published private(set) var discoveryLibraryTracks: [Track] = []
    @Published private(set) var isIndexingLibraryTracks = false
    @Published private(set) var libraryTrackIndexLoadError: String?

    /// Last.fm chart feeds + tag-based “recent releases” shelf for the New tab.
    @Published private(set) var lfmTopTracks: [LFMTrack] = []
    @Published private(set) var lfmTopAlbums: [LFMAlbum] = []
    @Published private(set) var lfmRecentReleases: [LFMAlbum] = []
    @Published private(set) var newTabBrowseLoading = false
    /// Set when Last.fm / MusicBrainz browse fails so the New tab can show a concrete reason instead of an empty shelf.
    @Published private(set) var newTabBrowseError: String?
    /// Which catalog populated the **New** tab on the last successful refresh (drives labels like “MusicBrainz”).
    @Published private(set) var newTabBrowseBackend: NewTabBrowseBackend = .none

    let player = PlaybackEngine()
    let offline = OfflineDownloadManager()
    let lastFm = LastFmScrobbler()

    private var libraryAlbumsById: [String: AlbumSummary] = [:]
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
            return AccountAvatarCache.identity(backend: .navidrome, baseURL: base, userKey: user.lowercased())
        }
    }

    /// Remote URL for the signed-in user's profile image (Jellyfin primary image or Navidrome getAvatar).
    var accountAvatarURL: URL? {
        switch backendKind {
        case .jellyfin:
            return jellyfin?.accountPrimaryImageURL(maxWidth: 256)
        case .navidrome:
            return navidrome?.accountAvatarURL(username: username)
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
        player.bind(lastFm: lastFm, offline: offline)
        player.$queue
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$currentIndex
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$showsMiniPlayerChrome
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$lyrics
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$shuffleMode
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$repeatMode
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
            lastFm.restoreSession()
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
        lfmTopTracks = []
        lfmTopAlbums = []
        lfmRecentReleases = []
        newTabBrowseError = nil
        newTabBrowseBackend = .none
        libraryTrackTitleIndex = [:]
        discoveryLibraryTracks = []
        libraryTrackIndexLoadError = nil
        isIndexingLibraryTracks = false
        KeychainStore.clear()
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
            ),
        )
    }

    private func restoreLibraryFromDisk() {
        if let snap = LibrarySnapshotStore.load() {
            if !snap.albums.isEmpty { libraryAlbums = snap.albums }
            if !snap.tracks.isEmpty {
                discoveryLibraryTracks = snap.tracks
                libraryTrackTitleIndex = LibraryTrackMatcher.titleIndex(from: snap.tracks)
            }
            if !snap.playlists.isEmpty { libraryPlaylists = snap.playlists }
            if !snap.favoriteTrackIds.isEmpty {
                favoriteTrackIds = Set(snap.favoriteTrackIds)
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
        libraryTrackTitleIndex = LibraryTrackMatcher.titleIndex(from: discoveryLibraryTracks)

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
        let pickedGenres = Array(genresResult.prefix(4))
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
        _ = await (home, stats, browse)
    }

    private func rebuildLibraryAlbumIndex() {
        libraryAlbumsById = Dictionary(uniqueKeysWithValues: libraryAlbums.map { ($0.id, $0) })
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

    /// Refreshes ``libraryPlaylists`` from the active server (Jellyfin / Navidrome).
    func refreshLibraryPlaylists() async {
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else { libraryPlaylists = []; return }
            do {
                libraryPlaylists = try await client.fetchPlaylistSummaries()
            } catch {
                libraryPlaylists = []
            }
        case .navidrome:
            guard let client = navidrome else { libraryPlaylists = []; return }
            do {
                libraryPlaylists = try await client.fetchPlaylistSummaries()
            } catch {
                libraryPlaylists = []
            }
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
            libraryTrackTitleIndex = LibraryTrackMatcher.titleIndex(from: tracks)
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
        let lastFmOn = LastFmChartsClient.storedApiKey != nil

        newTabBrowseLoading = true
        defer { newTabBrowseLoading = false }

        if lastFmOn {
            newTabBrowseError = nil
            let pack = await LastFmChartsClient.fetchAll()
            lfmTopTracks = pack.tracks
            lfmTopAlbums = pack.albums
            lfmRecentReleases = pack.recentAlbums
            newTabBrowseBackend = .lastFm
            return
        }

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

    private func applyNewTabGrid(fromAlbums albums: [LFMAlbum], backend: NewTabBrowseBackend) {
        lfmRecentReleases = albums
        lfmTopTracks = Array(albums.prefix(20)).map {
            LFMTrack(id: $0.id, name: $0.name, artistName: $0.artistName,
                     imageURL: $0.imageURL, playcount: 0, browseKind: "Album")
        }
        lfmTopAlbums = []
        newTabBrowseBackend = backend
    }

    private func clearNewTabBrowseGrid() {
        lfmTopTracks = []
        lfmTopAlbums = []
        lfmRecentReleases = []
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
        case .lfm(let artist, let title, _, let kind):
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let rg = await MusicBrainzTracklistClient.findReleaseGroupId(artist: artist, albumTitle: title) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                let mbTracks = await MusicBrainzTracklistClient.tracksForReleaseGroup(rg)
                if !mbTracks.isEmpty { return mbTracks }
            }
            if kind.lowercased() == "single" {
                return [
                    BrowseAlbumPreviewTrack(
                        id: "lfm-single:\(artist):\(title)",
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

    /// Starts a shuffled queue of random library tracks, optionally filtered by genre (`getRandomSongs`).
    func playNavidromeGenreRadio(genreName: String?) async {
        guard let client = navidrome else {
            errorMessage = "Radio stations require a Navidrome connection."
            return
        }
        do {
            let tracks = try await client.fetchRandomSongs(limit: 80, genre: genreName)
            guard !tracks.isEmpty else {
                let label = genreName ?? "your library"
                errorMessage = "No songs found for \(label)."
                return
            }
            player.shuffleMode = .on
            try await player.playAlbum(
                library: client,
                tracks: tracks.shuffled(),
                startIndex: 0,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
            errorMessage = error.localizedDescription
        }
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
            return
        }
        // Migrate the legacy album-only string array, then drop the old key.
        if let legacy = defaults.stringArray(forKey: Self.recentlyPlayedAlbumIdsKey), !legacy.isEmpty {
            let migrated = legacy.map { RecentPlayedEntry(kind: .album, id: $0) }
            recentlyPlayedEntries = migrated
            saveRecentlyPlayedEntriesToDefaults()
            defaults.removeObject(forKey: Self.recentlyPlayedAlbumIdsKey)
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
        case .ok, .unreachable:
            // Healthy session OR transient outage — never re-leak the password on cold launch.
            break
        }
    }
}
