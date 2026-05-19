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

@MainActor
public final class AppModel: ObservableObject {
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
    @Published private(set) var libraryAlbums: [AlbumSummary] = []
    @Published private(set) var recentlyAddedAlbums: [AlbumSummary] = []
    @Published private(set) var homeRecentlyPlayed: [AlbumSummary] = []
    @Published private(set) var homeGenreShelves: [(genre: String, albums: [AlbumSummary])] = []
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

    private static let favoriteTrackIdsKey = "LyraMusic.favoriteTrackIds"
    @Published private(set) var favoriteTrackIds: Set<String> = []

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
        player.$lyrics
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$shuffleMode
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        player.$repeatMode
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        offline.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        loadPersistedSettings()
        startNetworkMonitor()
        loadKeychain()
        loadFavoriteTrackIdsFromDefaults()
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
            Task {
                await refreshLibraryAlbums()
                await refreshHome()
                await refreshLibraryTrackMatchIndex()
                await refreshLibraryStatistics()
                recordSuccessfulLibrarySync()
                await refreshNewTabBrowse()
            }
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
        homeRecentlyPlayed = []
        homeGenreShelves = []
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
        homeRecentlyPlayed = playedResult
        let pickedGenres = Array(genresResult.prefix(4))
        var shelves: [(genre: String, albums: [AlbumSummary])] = []
        for g in pickedGenres {
            let albums = (try? await lib.albums(inGenre: g, limit: 8)) ?? []
            if !albums.isEmpty {
                shelves.append((genre: g.name, albums: albums))
            }
        }
        homeGenreShelves = shelves
    }

    public func refreshLibraryAlbums(limit: Int = 200) async {
        guard let lib = activeLibrary else { return }
        libraryAlbumsLoadError = nil
        do {
            async let all = lib.albums(limit: limit)
            async let recent = lib.recentlyAdded(limit: 60)
            libraryAlbums = try await all
            recentlyAddedAlbums = (try? await recent) ?? []
            mergeOfflineCatalog()
            persistLibrarySnapshot()
            Task { await refreshLibraryTrackMatchIndex() }
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
        switch backendKind {
        case .jellyfin:
            guard let client = jellyfin else {
                throw URLError(.userAuthenticationRequired)
            }
            guard let entry = row.jellyfinEntryId else {
                throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist entry id."])
            }
            try await client.removeTracksFromPlaylist(playlistId: playlistId, entryIds: [entry])
        case .navidrome:
            guard let client = navidrome else {
                throw URLError(.userAuthenticationRequired)
            }
            guard let idx = row.navidromeIndex else {
                throw NSError(domain: "LyraMusic", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing playlist index."])
            }
            try await client.removeTracksFromPlaylist(playlistId: playlistId, indexes: [idx])
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

    /// Loads up to `limit` audio tracks from the server and rebuilds `libraryTrackTitleIndex` for discovery matching.
    public func refreshLibraryTrackMatchIndex(limit: Int = 20_000) async {
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
        if let cached = libraryAlbums.first(where: { $0.id == track.albumId }) {
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
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if let rg = await MusicBrainzTracklistClient.findReleaseGroupId(artist: artist, albumTitle: title) {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
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
        await refreshLibraryTrackMatchIndex()
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
            if let token = j.accessToken, let uid = j.userId, !token.isEmpty, !uid.isEmpty {
                client.applyRestoredSession(accessToken: token, userId: uid)
                jellyfin = client
                navidrome = nil
                isSignedIn = true
                updateDeleteCapability()
                prefetchAccountAvatar()
                pushQualitySettingsToClients()
                restoreLibraryFromDisk()
                serverConnectionHealth = .unknown
            }
            Task {
                await refreshServerConnectionHealth()
                await signIn()
            }
        } else if let n = try? KeychainStore.loadNavidrome() {
            backendKind = .navidrome
            baseURLString = n.base.absoluteString
            username = n.user
            password = n.password
            let client = NavidromeClient(baseURL: n.base)
            if let token = n.subsonicToken, !token.isEmpty {
                client.applyRestoredSession(token: token, username: n.user, password: n.password)
                navidrome = client
                jellyfin = nil
                isSignedIn = true
                updateDeleteCapability()
                prefetchAccountAvatar()
                restoreLibraryFromDisk()
                serverConnectionHealth = .unknown
            }
            Task {
                await refreshServerConnectionHealth()
                await signIn()
            }
        }
    }
}
