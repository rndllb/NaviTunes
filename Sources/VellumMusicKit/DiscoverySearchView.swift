import SwiftUI

enum SearchScope: String, CaseIterable {
    case discover = "Discover"
    case library = "Library"
}

/// Unified navigation target so every Button-based row in Discovery search can
/// route through one `.navigationDestination(item:)` modifier — multiple
/// stacked modifiers conflict.
enum SearchNavTarget: Hashable {
    case song(Track)
    case album(AlbumSummary)
    case playlist(PlaylistSummary)
    case artist(LibraryArtistSummary)
    /// An artist by name only (not in the server library) — resolved via iTunes on
    /// the artist page so the user can browse and request their discography.
    case namedArtist(String)
    case genre(LibraryGenreSummary)
    case acquire(AcquisitionResult)
}

/// Colorful genre tile for the Discover idle grid (no heading — tiles only).
private struct SearchGenreTile: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: SearchGenrePalette.gradient(for: title),
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 8.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            MusicDesign.artworkSubtleBorderOverlay(cornerRadius: 10, colorScheme: colorScheme)
        }
        .contentShape(Rectangle())
    }
}

private enum SearchGenrePalette {
    private static let pairs: [(Color, Color)] = [
        (.init(red: 0.93, green: 0.27, blue: 0.45), .init(red: 0.58, green: 0.13, blue: 0.42)),
        (.init(red: 0.98, green: 0.62, blue: 0.22), .init(red: 0.74, green: 0.31, blue: 0.10)),
        (.init(red: 0.16, green: 0.69, blue: 0.55), .init(red: 0.06, green: 0.36, blue: 0.40)),
        (.init(red: 0.28, green: 0.49, blue: 0.91), .init(red: 0.13, green: 0.20, blue: 0.55)),
        (.init(red: 0.69, green: 0.32, blue: 0.87), .init(red: 0.35, green: 0.13, blue: 0.55)),
        (.init(red: 0.93, green: 0.41, blue: 0.36), .init(red: 0.50, green: 0.14, blue: 0.18)),
        (.init(red: 0.42, green: 0.72, blue: 0.29), .init(red: 0.16, green: 0.39, blue: 0.18)),
        (.init(red: 0.95, green: 0.78, blue: 0.27), .init(red: 0.62, green: 0.42, blue: 0.05)),
        (.init(red: 0.18, green: 0.55, blue: 0.79), .init(red: 0.08, green: 0.27, blue: 0.45)),
        (.init(red: 0.86, green: 0.30, blue: 0.65), .init(red: 0.48, green: 0.10, blue: 0.40)),
        (.init(red: 0.49, green: 0.36, blue: 0.84), .init(red: 0.22, green: 0.15, blue: 0.51)),
        (.init(red: 0.21, green: 0.66, blue: 0.78), .init(red: 0.06, green: 0.30, blue: 0.42)),
    ]

    static func gradient(for key: String) -> [Color] {
        let normalized = key.lowercased()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let pair = pairs[Int(hash % UInt64(pairs.count))]
        return [pair.0, pair.1]
    }
}

/// Apple-Music-style Recently Searched: each row is a discrete *entity* the
/// user previously navigated to from a search result, **not** a raw query
/// string. Tap navigates straight to the entity instead of re-running the
/// query.
private enum RecentEntityKind: String, Codable {
    case song
    case album
    case artist
    case playlist
}

private struct RecentSearchEntity: Codable, Identifiable, Equatable {
    var kind: RecentEntityKind
    /// Primary backend id (track id for songs, album id for albums, etc.).
    var primaryId: String
    /// Secondary id when we need a parent — track entries carry their albumId
    /// here so we can navigate to the album view with `scrollToTrackId:`.
    var secondaryId: String?
    var title: String
    var subtitle: String?
    var artworkURL: URL?

    var id: String { "\(kind.rawValue):\(primaryId)" }

    var dedupeKey: String { id }

    /// Subtitle prefix used to disambiguate kinds in the recent list (e.g. "Song · …").
    var displaySubtitle: String {
        let prefix: String
        switch kind {
        case .song: prefix = "Song"
        case .album: prefix = "Album"
        case .artist: prefix = "Artist"
        case .playlist: prefix = "Playlist"
        }
        if let subtitle, !subtitle.isEmpty { return "\(prefix) · \(subtitle)" }
        return prefix
    }
}

private enum RecentSearchEntityStore {
    /// One list per search scope so the Discover and Library tabs each show
    /// only the entities the user navigated to *from that tab* — searches
    /// don't bleed across scopes. v3 schema; v2 (text queries) is intentionally
    /// not migrated because those entries had no artwork/entity references.
    private static let maxCount = 24

    private static func key(for scope: SearchScope) -> String {
        "discovery_recent_entities_v3.\(scope.rawValue.lowercased())"
    }

    static func load(for scope: SearchScope) -> [RecentSearchEntity] {
        guard let data = UserDefaults.standard.data(forKey: key(for: scope)),
              let decoded = try? JSONDecoder().decode([RecentSearchEntity].self, from: data)
        else { return [] }
        return decoded
    }

    static func append(_ entity: RecentSearchEntity, for scope: SearchScope) {
        var items = load(for: scope)
        items.removeAll { $0.dedupeKey == entity.dedupeKey }
        items.insert(entity, at: 0)
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key(for: scope))
    }

    static func clear(for scope: SearchScope) {
        UserDefaults.standard.removeObject(forKey: key(for: scope))
    }
}

/// An artist found via iTunes that isn't in the server library — surfaced as a
/// normal artist result row so missing artists flow into the artist page like server ones.
private struct NamedArtistMatch: Identifiable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
}

/// One row in the hybrid Discover feed — either a server-catalog hit, an iTunes artist,
/// or an acquisition request candidate. Server hits already in the user's personal library
/// are filtered out upstream (they live in the Library tab).

private enum HybridRow: Identifiable {
    case serverArtist(LibraryArtistSummary)
    case namedArtist(NamedArtistMatch)
    case serverSong(Track)
    case serverAlbum(AlbumSummary)
    case acquire(AcquisitionResult)

    var id: String {
        switch self {
        case .serverArtist(let a): return "srv-artist-\(a.id)"
        case .namedArtist(let a): return "itunes-artist-\(a.id)"
        case .serverSong(let t): return "srv-song-\(t.id)"
        case .serverAlbum(let a): return "srv-album-\(a.id)"
        case .acquire(let r): return "acq-\(r.id)"
        }
    }
}

struct DiscoverySearchView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var acquisition: AcquisitionManager
    @Binding var searchText: String
    @Binding var scope: SearchScope
    @Binding var navigationPath: NavigationPath
    /// True when the pinned search field is focused or has a non-empty query.
    let isSearchSessionActive: Bool
    @State private var recentDiscover: [RecentSearchEntity] = RecentSearchEntityStore.load(for: .discover)
    @State private var recentLibrary: [RecentSearchEntity] = RecentSearchEntityStore.load(for: .library)

    /// Recently-Searched entries for the currently-selected tab.
    private var recent: [RecentSearchEntity] {
        switch scope {
        case .discover: return recentDiscover
        case .library: return recentLibrary
        }
    }

    // Hybrid Discover-tab state.
    @State private var serverResults: CatalogSearchResults = .empty
    @State private var acquireResults: [AcquisitionResult] = []
    @State private var namedArtistMatches: [NamedArtistMatch] = []
    @State private var isFetching = false
    @State private var searchError: String?
    @State private var hybridSearchTask: Task<Void, Never>?

    // Idle-state genre tiles (Discover tab).
    @State private var serverGenres: [LibraryGenreSummary] = []
    @State private var isLoadingGenres = false
    @State private var genresLoadError: String?
    @State private var genresLoadedForKey: String?

    // Library-tab server catalog search.
    @State private var libraryServerResults: CatalogSearchResults = .empty
    @State private var isLibraryFetching = false
    @State private var librarySearchError: String?
    @State private var librarySearchTask: Task<Void, Never>?

    // Per-row interaction state.
    @State private var addingAlbumIds: Set<String> = []
    @State private var toast: String?

    /// Single state-driven navigation target shared by every Button-based row
    /// (server song, library song, library artist, Recently-Searched rows).
    /// Stacking multiple `.navigationDestination(item:)` modifiers on one view
    /// breaks them in practice — one combined modifier off a single binding
    /// avoids the issue entirely.
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Re-run genre fetch when sign-in completes or the active server client is replaced.
    private var genreLoadTaskKey: String {
        let clientKey = app.activeLibrary.map { "\(ObjectIdentifier($0))" } ?? "none"
        return "\(app.isSignedIn)-\(app.backendKind)-\(clientKey)"
    }

    // Single source of truth for row metrics across every Discovery search row
    // (Top Results, Library results, Recently Searched, per-genre shelves).
    // Tracks the global `Song list items` preference in Settings. We use the
    // "library / song" typography (titleFont/subtitleFont) for **every** row
    // so Library and Discover read at the same scale — the previous split
    // between album-typography (subheadline) and song-typography (body)
    // made Discover items look smaller.
    private var itemSize: SongListItemSize { app.songListItemSize }
    private var rowArtworkSide: CGFloat { itemSize.artworkSide }
    private var entityTitleFont: Font { itemSize.titleFont }
    private var entitySubtitleFont: Font { itemSize.subtitleFont }
    private var songTitleFont: Font { itemSize.titleFont }
    private var songSubtitleFont: Font { itemSize.subtitleFont }
    /// Match album-track row breathing room; scales with Settings → Song list items.
    private var entityVerticalPadding: CGFloat { itemSize.albumVerticalPadding }
    private var songVerticalPadding: CGFloat { itemSize.albumVerticalPadding }
    /// Discover rows sit flush on the page background (no card tint).
    private var discoverRowBackground: Color { MusicDesign.background }
    /// Library search rows keep a subtle card tint for separation.
    private var libraryRowBackground: Color { MusicDesign.tertiarySurfaceFill.opacity(0.55) }

    private var searchArtworkDividerKind: MusicChevronRowDivider.Kind {
        .custom(leading: MusicChevronRowMetrics.artworkDividerLeading(side: rowArtworkSide, spacing: 12))
    }

    /// User playlists on the server matching the Library-tab query (magic playlists excluded upstream).
    private var libraryPlaylistMatches: [PlaylistSummary] {
        let tokens = Self.librarySearchTokens(trimmedQuery)
        guard !tokens.isEmpty else { return [] }
        return app.libraryPlaylists.filter { matchesLibrarySearchTokens(tokens, in: $0.name) }
    }

    /// Unified, relevance-sorted hybrid feed. Server catalog, iTunes, and acquisition
    /// plugin hits are scored against the query and merge-sorted so the strongest match
    /// wins regardless of source.
    private var hybridRows: [HybridRow] {
        let personalAlbumIds = Set(app.libraryAlbumEntries.map(\.id))
        let personalSongIds = app.librarySongIds
        let albumIdsInFeed = Set(serverResults.albums.map(\.id))
        let serverTracks = serverResults.songs
        let q = LibraryTrackMatcher.normalize(trimmedQuery)

        var scored: [(row: HybridRow, score: Double, kindPriority: Int)] = []

        // Artists pinned to the top of Top Results. Each artist gets a large
        // score bump so any matching artist surfaces above albums/songs/the request backend
        // — Apple Music does the same: tapping search for "Deftones" returns
        // the artist row first, then their albums, then their songs.
        for artist in serverResults.artists {
            let s = Self.relevanceScore(title: artist.name, artist: artist.name, normalizedQuery: q)
            scored.append((.serverArtist(artist), s + 1.0, -1))
        }

        // Artists not on the server (iTunes matches) get the same artist-row treatment
        // and priority, so a missing artist surfaces alongside server artists.
        for match in namedArtistMatches {
            let s = Self.relevanceScore(title: match.name, artist: match.name, normalizedQuery: q)
            scored.append((.namedArtist(match), s + 1.0, -1))
        }

        for album in serverResults.albums where !personalAlbumIds.contains(album.id) {
            let s = Self.relevanceScore(title: album.title, artist: album.artist, normalizedQuery: q)
            // Slight bump for albums so when score ties with a single track,
            // the album surfaces first (matches Apple Music's Top Results bias).
            scored.append((.serverAlbum(album), s + 0.05, 0))
        }

        for song in serverResults.songs
            where !personalSongIds.contains(song.id) && !albumIdsInFeed.contains(song.albumId)
        {
            let s = Self.relevanceScore(title: song.title, artist: song.artist, normalizedQuery: q)
            scored.append((.serverSong(song), s, 1))
        }

        for result in acquireResults {
            // Suppress acquisition rows already covered by a server hit (the server
            // row already lets the user acquire the track) or by the user's
            // personal library.
            if LibraryTrackMatcher.firstLibraryTrack(matching: result, in: serverTracks) != nil { continue }
            if LibraryTrackMatcher.matchesLibrary(result, titleIndex: app.libraryTrackTitleIndex) { continue }
            let artist = result.artistLine
            let s = Self.relevanceScore(title: result.title, artist: artist, normalizedQuery: q)
            scored.append((.acquire(result), s, 2))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Equal score → preserve a stable order (artist > album > song > request backend).
                return lhs.kindPriority < rhs.kindPriority
            }
            .map(\.row)
    }

    /// 0–1 relevance score for a candidate against `query`. Uses
    /// `LibraryTrackMatcher.normalize` so it's diacritic- and punctuation-
    /// insensitive. Title matches outweigh artist matches; exact > prefix > contains.
    /// Takes a pre-normalized query so a scoring pass over N candidates doesn't re-normalize
    /// the same query string N times (``LibraryTrackMatcher/normalize`` is allocation-heavy).
    private static func relevanceScore(title: String, artist: String, normalizedQuery q: String) -> Double {
        guard !q.isEmpty else { return 0 }
        let t = LibraryTrackMatcher.normalize(title)
        let a = LibraryTrackMatcher.normalize(artist)

        var score: Double = 0
        if t == q {
            score = max(score, 1.0)
        } else if t.hasPrefix(q) {
            score = max(score, 0.85)
        } else if t.contains(q) {
            score = max(score, 0.7)
        }

        if a == q {
            score = max(score, 0.6)
        } else if a.hasPrefix(q) {
            score = max(score, 0.5)
        } else if a.contains(q) {
            score = max(score, 0.35)
        }

        return score
    }

    var body: some View {
        listContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(MusicDesign.background)
            .onChange(of: scope) { _, newScope in
            if newScope == .discover {
                scheduleHybridSearch()
            } else {
                hybridSearchTask?.cancel()
                scheduleLibrarySearch()
            }
        }
        .onChange(of: searchText) { _, _ in
            if scope == .discover {
                scheduleHybridSearch()
            } else {
                scheduleLibrarySearch()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(MusicDesign.chromeCapsuleFill))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task(id: scope) {
            guard scope == .discover, app.isSignedIn else { return }
            app.scheduleDiscoveryTrackIndexRefreshIfNeeded()
        }
        .task(id: genreLoadTaskKey) {
            await loadServerGenresIfNeeded()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var listContent: some View {
        if scope == .discover {
            hybridContent
        } else {
            libraryContent
        }
    }

    // MARK: - Discover (hybrid)

    private var hybridContent: some View {
        Group {
            // Three-state body matching Apple Music's search:
            //   * idle (search not focused, no query) → genre-tile grid
            //   * focused, no query → Recently Searched
            //   * has query → live hybrid results
            if !isSearchSessionActive && trimmedQuery.isEmpty {
                discoverIdleGrid
            } else if trimmedQuery.isEmpty {
                hybridRecentlySearchedList
            } else {
                hybridResultsList
            }
        }
    }

    private var discoverIdleGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !app.acquisitionConfigured {
                    Text("Set up a download plugin in Settings to enable requests. Server search still works.")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 16) {
                    if isLoadingGenres {
                        HStack {
                            ProgressView().tint(MusicDesign.accent)
                            Text("Loading categories…")
                                .font(.subheadline)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                        }
                        .padding(.horizontal, 16)
                    } else if let genresLoadError {
                        Text(genresLoadError)
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.horizontal, 16)
                    } else if serverGenres.isEmpty {
                        Text("No genres returned from your server.")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.horizontal, 16)
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                            ],
                            spacing: 12,
                        ) {
                            ForEach(serverGenres) { genre in
                                Button {
                                    navigationPath.append(SearchNavTarget.genre(genre))
                                } label: {
                                    SearchGenreTile(title: genre.name)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hybridRecentlySearchedList: some View {
        List {
            Section {
                recentHeader
                if recent.isEmpty {
                    Text("Search your server or Apple Music for songs, albums, and artists.")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        Button {
                            tapRecent(item)
                        } label: {
                            recentEntityRow(item)
                                .coverZoomSource(id: recentZoomId(item))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(discoverRowBackground)
                        .discoverySearchListRowChrome()
                        .musicChevronRowDivider(searchArtworkDividerKind, shows: index < recent.count - 1)
                    }
                }
            }
            if !app.acquisitionConfigured {
                Section {
                    Text("Set up a download plugin in Settings to enable requests. Server search still works.")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    private var hybridResultsList: some View {
        let rows = hybridRows
        return List {
            if isFetching && rows.isEmpty {
                Section {
                    HStack {
                        ProgressView().tint(MusicDesign.accent)
                        Text("Searching…")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.leading, 8)
                    }
                    .listRowBackground(Color.clear)
                }
            } else if let err = searchError, rows.isEmpty {
                Section {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            } else if rows.isEmpty {
                Section {
                    Text("No results for \"\(trimmedQuery)\".")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section("Top Results") {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        hybridRowView(row)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < rows.count - 1)
                    }
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    private func loadServerGenresIfNeeded() async {
        let key = genreLoadTaskKey
        if genresLoadedForKey == key, !serverGenres.isEmpty {
            return
        }

        guard !app.effectiveOfflineMode else {
            serverGenres = []
            genresLoadError = nil
            isLoadingGenres = false
            genresLoadedForKey = nil
            return
        }
        guard let lib = app.activeLibrary else {
            serverGenres = []
            genresLoadError = nil
            isLoadingGenres = false
            genresLoadedForKey = nil
            return
        }

        isLoadingGenres = true
        genresLoadError = nil
        defer { isLoadingGenres = false }

        do {
            serverGenres = try await lib.browseGenreCategories(limit: 60)
            genresLoadedForKey = key
        } catch is CancellationError {
            return
        } catch {
            genresLoadError = error.localizedDescription
            serverGenres = []
            genresLoadedForKey = nil
        }
    }

    @ViewBuilder
    private func hybridRowView(_ row: HybridRow) -> some View {
        switch row {
        case .serverArtist(let artist):
            serverArtistRow(artist)
        case .namedArtist(let match):
            namedArtistRow(match)
        case .serverAlbum(let album):
            serverAlbumRow(album)
        case .serverSong(let track):
            serverSongRow(track)
        case .acquire(let result):
            acquireRow(result)
        }
    }

    /// Top-Results artist row — circular avatar + name, navigates to the new
    /// ``ArtistPageView``. Mirrors the library search-results artist row visually
    /// so the two surfaces feel consistent.
    private func serverArtistRow(_ artist: LibraryArtistSummary) -> some View {
        Button {
            recordRecent(.init(
                kind: .artist,
                primaryId: artist.id,
                title: artist.name,
                artworkURL: artist.artworkURL,
            ))
            navigationPath.append(SearchNavTarget.artist(artist))
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkView(url: artist.artworkURL, cornerRadius: rowArtworkSide / 2)
                    .frame(width: rowArtworkSide, height: rowArtworkSide)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(entityTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Artist")
                        .font(entitySubtitleFont)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                Spacer(minLength: 8)
                MusicNavigationChevron()
            }
            .musicChevronRowPadding()
            .padding(.vertical, entityVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(discoverRowBackground)
        .discoverySearchListRowChrome()
    }

    /// Artist not on the server (Lidarr / DroppedNeedle match). Visually identical
    /// to ``serverArtistRow`` and navigates to the same artist page (resolved by name).
    private func namedArtistRow(_ match: NamedArtistMatch) -> some View {
        Button {
            recordRecent(.init(
                kind: .artist,
                primaryId: "itunes:\(match.id)",
                title: match.name,
                artworkURL: match.artworkURL,
            ))
            navigationPath.append(SearchNavTarget.namedArtist(match.name))
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkView(url: match.artworkURL, cornerRadius: rowArtworkSide / 2)
                    .frame(width: rowArtworkSide, height: rowArtworkSide)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.name)
                        .font(entityTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Artist")
                        .font(entitySubtitleFont)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                Spacer(minLength: 8)
                MusicNavigationChevron()
            }
            .musicChevronRowPadding()
            .padding(.vertical, entityVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(discoverRowBackground)
        .discoverySearchListRowChrome()
    }

    // MARK: - Hybrid: server-album row (Add pill)

    private func serverAlbumRow(_ album: AlbumSummary) -> some View {
        // Button + state-driven nav (same pattern as serverSongRow). Prior
        // attempt to use NavigationLink + simultaneousGesture failed because
        // the gesture absorbs the tap and the NavigationLink stops firing.
        Button {
            recordRecent(.init(
                kind: .album,
                primaryId: album.id,
                title: album.title,
                subtitle: album.artist,
                artworkURL: album.artworkURL,
            ))
            navigationPath.append(SearchNavTarget.album(album))
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkView(url: album.artworkURL)
                    .frame(width: rowArtworkSide, height: rowArtworkSide)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(entityTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Album · \(album.artist)")
                        .font(entitySubtitleFont)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                MusicNavigationChevron()
            }
            .musicChevronRowPadding()
            .padding(.vertical, entityVerticalPadding)
            .contentShape(Rectangle())
            .coverZoomSource(id: album.id)
        }
        .buttonStyle(.plain)
        .listRowBackground(discoverRowBackground)
        .libraryAlbumContextMenu(album)
        .discoverySearchListRowChrome()
    }


    // MARK: - Hybrid: server-song row (Add pill, tap = play)

    private func serverSongRow(_ track: Track) -> some View {
        let artworkURL = app.resolvedArtworkURL(for: track)
        return Button {
            recordRecent(.init(
                kind: .song,
                primaryId: track.id,
                secondaryId: track.albumId,
                title: track.title,
                subtitle: track.artist,
                artworkURL: artworkURL,
            ))
            // Tapping a song in search goes to the song's album page (Apple Music
            // behavior). The 3-dot menu still has Play / Play Next for direct playback.
            navigationPath.append(SearchNavTarget.album(app.albumSummary(for: track)))
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkView(url: artworkURL)
                    .frame(width: rowArtworkSide, height: rowArtworkSide)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(songTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Song · \(track.artist)")
                        .font(songSubtitleFont)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                MusicNavigationChevron()
            }
            .coverZoomSource(id: track.albumId)
            .musicChevronRowPadding()
            .padding(.vertical, songVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(discoverRowBackground)
        .discoverySearchListRowChrome()
        .contextMenu {
            serverSongContextMenu(track)
        }
    }

    /// Apple-Music-style long-press menu for a server-catalog song row. Mirrors
    /// the actions in ``libraryAlbumContextMenu`` but scoped to a single song
    /// (Add Song / Add Album / Play / Play Next / Go to Album).
    @ViewBuilder
    private func serverSongContextMenu(_ track: Track) -> some View {
        Section {
            Button {
                Task { @MainActor in
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playAlbum(library: lib, tracks: [track], startIndex: 0)
                }
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                Task { @MainActor in
                    try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [track])
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
        Section {
            if app.isSongInLibrary(track.id) {
                Button(role: .destructive) {
                    app.toggleFavoriteTrack(id: track.id)
                } label: {
                    Label("Remove from Library", systemImage: "minus.circle")
                }
            } else {
                Button {
                    Task { await addTrack(track) }
                } label: {
                    Label("Add Song to Library", systemImage: "plus")
                }
            }
            Button {
                Task {
                    let album = app.albumSummary(for: track)
                    await addAlbum(album)
                }
            } label: {
                Label("Add Album to Library", systemImage: "rectangle.stack.badge.plus")
            }
            Button {
                app.presentAddToPlaylist(tracks: [track])
            } label: {
                Label("Add to a Playlist", systemImage: "music.note.list")
            }
        }
        Section {
            Button {
                navigationPath.append(SearchNavTarget.album(app.albumSummary(for: track)))
            } label: {
                Label("Go to Album", systemImage: "music.note.square")
            }
            ShareLink(item: "\(track.title) — \(track.artist)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        NavidromeShareMenuSection(
            itemId: track.id,
            description: "\(track.title) — \(track.artist)"
        )
    }

    // MARK: - Hybrid: acquisition row (Request pill + tappable detail)

    private func acquireRow(_ result: AcquisitionResult) -> some View {
        // Whole-row tap → acquisition detail view. The Request pill stays as a
        // secondary action so users can kick off a request without first
        // opening the detail.
        let job = acquisition.job(forKey: result.request.requestKey)
        return HStack(spacing: 12) {
            Button {
                recordRecent(.init(
                    kind: .song,
                    primaryId: "acquire:\(result.id)",
                    title: result.title,
                    subtitle: result.artistLine,
                    artworkURL: result.coverURL,
                ))
                navigationPath.append(SearchNavTarget.acquire(result))
            } label: {
                HStack {
                    acquireRowArtworkAndTitles(result)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let job, !job.status.isTerminal {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: min(1, job.progress))
                        .tint(MusicDesign.accent)
                        .frame(width: 56)
                    Text("\(Int((min(1, job.progress) * 100).rounded()))%")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                .frame(width: 56, alignment: .trailing)
            } else if let job, job.status == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 56, alignment: .trailing)
            } else {
                statePillButton(
                    label: "Request",
                    systemImage: "arrow.down.circle",
                    busy: false,
                    disabled: !app.acquisitionConfigured || acquisition.isActive(key: result.request.requestKey),
                ) {
                    Task { await requestResult(result) }
                }
            }
        }
        .musicChevronRowPadding()
        .padding(.vertical, songVerticalPadding)
        .listRowBackground(discoverRowBackground)
        .discoverySearchListRowChrome()
    }

    @ViewBuilder
    private func acquireRowArtworkAndTitles(_ result: AcquisitionResult) -> some View {
        HStack(spacing: 12) {
            Group {
                if let art = result.coverURL {
                    RemoteArtworkScaledFill(url: art, maxPixelSize: 180) {
                        artPlaceholder
                    }
                } else {
                    artPlaceholder
                }
            }
            .frame(width: rowArtworkSide, height: rowArtworkSide)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(result.title)
                        .font(songTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if result.explicit {
                        Image(systemName: "e.square.fill")
                            .font(.caption2)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
                }
                Text(result.subtitle ?? "Song · \(result.artistLine)")
                    .font(songSubtitleFont)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
        }
    }

    private var artPlaceholder: some View {
        ZStack {
            MusicDesign.chromeCapsuleFill
            Image(systemName: "music.note")
                .font(.body)
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
    }

    // MARK: - Hybrid: shared "state pill" button

    @ViewBuilder
    private func statePillButton(
        label: String,
        systemImage: String,
        busy: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().tint(MusicDesign.accent)
                } else {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(disabled ? MusicDesign.secondaryLabel : MusicDesign.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(MusicDesign.chromeCapsuleFill))
        }
        .buttonStyle(.plain)
        .disabled(busy || disabled)
    }

    // MARK: - Library (server catalog)

    private var libraryContent: some View {
        Group {
            // Apple Music's Library search tab idle shows a sparse prompt + recent
            // searches rather than category tiles; results appear once the field
            // is focused. Mirror that: skip the genre grid here.
            if !isSearchSessionActive && trimmedQuery.isEmpty {
                libraryIdleContent
            } else if trimmedQuery.isEmpty {
                libraryRecentlySearchedList
            } else {
                libraryResultsList
            }
        }
    }

    private var libraryIdleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Search Server Library")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                Text(libraryIdlePromptText)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var libraryIdlePromptText: String {
        if !app.isSignedIn {
            return "Sign in to search everything on your music server."
        }
        return "Find any song, album, playlist, or artist on your server."
    }

    private var libraryRecentlySearchedList: some View {
        List {
            Section {
                recentHeader
                if recent.isEmpty {
                    Text(libraryIdlePromptText)
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        Button {
                            tapRecent(item)
                        } label: {
                            recentEntityRow(item)
                                .coverZoomSource(id: recentZoomId(item))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(libraryRowBackground)
                        .discoverySearchListRowChrome()
                        .musicChevronRowDivider(searchArtworkDividerKind, shows: index < recent.count - 1)
                    }
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    private var libraryResultsList: some View {
        let results = libraryServerResults
        let playlists = libraryPlaylistMatches
        let hasResults = !results.isEmpty || !playlists.isEmpty
        return List {
            if isLibraryFetching && !hasResults {
                Section {
                    HStack {
                        ProgressView().tint(MusicDesign.accent)
                        Text("Searching…")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.leading, 8)
                    }
                    .listRowBackground(Color.clear)
                }
            } else if let err = librarySearchError, !hasResults {
                Section {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            } else if !hasResults {
                Section {
                    Text("Nothing on your server matches \"\(trimmedQuery)\".")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            } else {
                if !results.songs.isEmpty {
                    Section("Songs") {
                        ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, track in
                            Button {
                                recordRecent(.init(
                                    kind: .song,
                                    primaryId: track.id,
                                    secondaryId: track.albumId,
                                    title: track.title,
                                    subtitle: track.artist,
                                    artworkURL: app.resolvedArtworkURL(for: track),
                                ))
                                navigationPath.append(SearchNavTarget.album(app.albumSummary(for: track)))
                            } label: {
                                HStack(spacing: 0) {
                                    personalSongRow(track)
                                    Spacer(minLength: 8)
                                    MusicNavigationChevron()
                                }
                                .musicChevronRowPadding()
                                .contentShape(Rectangle())
                                .coverZoomSource(id: track.albumId)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
                            .discoverySearchListRowChrome()
                            .contextMenu { serverSongContextMenu(track) }
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < results.songs.count - 1)
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(Array(results.albums.enumerated()), id: \.element.id) { index, album in
                            Button {
                                recordRecent(.init(
                                    kind: .album,
                                    primaryId: album.id,
                                    title: album.title,
                                    subtitle: album.artist,
                                    artworkURL: album.artworkURL,
                                ))
                                navigationPath.append(SearchNavTarget.album(album))
                            } label: {
                                HStack(spacing: 0) {
                                    albumRow(album)
                                    Spacer(minLength: 8)
                                    MusicNavigationChevron()
                                }
                                .musicChevronRowPadding()
                                .contentShape(Rectangle())
                                .coverZoomSource(id: album.id)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
                            .discoverySearchListRowChrome()
                            .libraryAlbumContextMenu(album)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < results.albums.count - 1)
                        }
                    }
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                            Button {
                                recordRecent(.init(
                                    kind: .playlist,
                                    primaryId: playlist.id,
                                    title: playlist.name,
                                    subtitle: playlist.songCount.map { $0 == 1 ? "1 song" : "\($0) songs" },
                                    artworkURL: playlist.artworkURL,
                                ))
                                navigationPath.append(SearchNavTarget.playlist(playlist))
                            } label: {
                                HStack(spacing: 0) {
                                    playlistRow(playlist)
                                    Spacer(minLength: 8)
                                    MusicNavigationChevron()
                                }
                                .musicChevronRowPadding()
                                .contentShape(Rectangle())
                                .coverZoomSource(id: playlist.id)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
                            .discoverySearchListRowChrome()
                            .libraryPlaylistContextMenu(playlist)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < playlists.count - 1)
                        }
                    }
                }
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(Array(results.artists.enumerated()), id: \.element.id) { index, artist in
                            Button {
                                recordRecent(.init(
                                    kind: .artist,
                                    primaryId: artist.id,
                                    title: artist.name,
                                    artworkURL: artist.artworkURL,
                                ))
                                navigationPath.append(SearchNavTarget.artist(artist))
                            } label: {
                                HStack(spacing: 12) {
                                    AlbumArtworkView(url: artist.artworkURL, cornerRadius: 6)
                                        .frame(width: rowArtworkSide, height: rowArtworkSide)
                                    Text(artist.name)
                                        .font(entityTitleFont)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    MusicNavigationChevron()
                                }
                                .musicChevronRowPadding()
                                .padding(.vertical, entityVerticalPadding)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
                            .discoverySearchListRowChrome()
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < results.artists.count - 1)
                        }
                    }
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    private var recentHeader: some View {
        HStack {
            Text("Recently Searched")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if !recent.isEmpty {
                Button("Clear") {
                    RecentSearchEntityStore.clear(for: scope)
                    switch scope {
                    case .discover: recentDiscover = []
                    case .library: recentLibrary = []
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MusicDesign.accent)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
        .listRowBackground(Color.clear)
    }

    // Library-tab row builders share the same itemSize-driven metrics as the
    // Discover-tab server-* rows so the two tabs read at the same size and
    // both respond to the `Song list items` Settings preference.
    private func albumRow(_ album: AlbumSummary) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: album.artworkURL)
                .frame(width: rowArtworkSide, height: rowArtworkSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(entityTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Album · \(album.artist)")
                    .font(entitySubtitleFont)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, entityVerticalPadding)
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: playlist.artworkURL)
                .frame(width: rowArtworkSide, height: rowArtworkSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(entityTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(playlistSubtitle(for: playlist))
                    .font(entitySubtitleFont)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, entityVerticalPadding)
    }

    private func playlistSubtitle(for playlist: PlaylistSummary) -> String {
        guard let n = playlist.songCount else { return "Playlist" }
        return "Playlist · " + (n == 1 ? "1 song" : "\(n) songs")
    }

    private func personalSongRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: app.resolvedArtworkURL(for: track))
                .frame(width: rowArtworkSide, height: rowArtworkSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(songTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Song · \(track.artist)")
                    .font(songSubtitleFont)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, songVerticalPadding)
    }

    // MARK: - Actions

    // MARK: - Recently Searched

    private func recentEntityRow(_ entity: RecentSearchEntity) -> some View {
        // Driven by the same itemSize as result rows so Recently Searched and
        // search-results read at identical scale.
        HStack(spacing: 12) {
            AlbumArtworkView(url: entity.artworkURL, cornerRadius: 6)
                .frame(width: rowArtworkSide, height: rowArtworkSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.title)
                    .font(entityTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entity.displaySubtitle)
                    .font(entitySubtitleFont)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            MusicNavigationChevron()
        }
        .musicChevronRowPadding()
        .padding(.vertical, entityVerticalPadding)
        .contentShape(Rectangle())
    }

    /// Zoom key mirroring ``tapRecent(_:)`` — songs route to their album
    /// detail, so they zoom on the album id; artist rows never match a
    /// detail destination, so their key is inert.
    private func recentZoomId(_ entity: RecentSearchEntity) -> String {
        switch entity.kind {
        case .song: return entity.secondaryId ?? ""
        case .album, .playlist: return entity.primaryId
        case .artist: return "recent-artist-no-zoom"
        }
    }

    /// Routes a Recently-Searched tap to the right navigation destination.
    /// Synthesizes stub models from stored fields so downstream views can
    /// refetch real data via the id.
    private func tapRecent(_ entity: RecentSearchEntity) {
        switch entity.kind {
        case .song:
            let albumId = entity.secondaryId ?? ""
            // Stub Track is enough for `ServerPlaylistDetailView` to load the
            // album and scroll to the original row by id.
            navigationPath.append(SearchNavTarget.song(Track(
                id: entity.primaryId,
                title: entity.title,
                albumId: albumId,
                albumTitle: "",
                artist: entity.subtitle ?? "",
                duration: 0,
                discNumber: 1,
                indexNumber: 0,
                artworkURL: entity.artworkURL,
            )))
        case .album:
            navigationPath.append(SearchNavTarget.album(AlbumSummary(
                id: entity.primaryId,
                title: entity.title,
                artist: entity.subtitle ?? "",
                artworkURL: entity.artworkURL,
            )))
        case .playlist:
            navigationPath.append(SearchNavTarget.playlist(PlaylistSummary(
                id: entity.primaryId,
                name: entity.title,
                artworkURL: entity.artworkURL,
            )))
        case .artist:
            navigationPath.append(SearchNavTarget.artist(LibraryArtistSummary(
                id: entity.primaryId,
                name: entity.title,
                artworkURL: entity.artworkURL,
            )))
        }
    }

    private func submitSearch() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        if scope == .discover {
            scheduleHybridSearch(debounce: false)
        } else {
            scheduleLibrarySearch(debounce: false)
        }
    }

    /// Records a navigation-target entity into Recently Searched. Called from
    /// result-row taps in both tabs (and the hybrid `play` paths). Reload from
    /// disk afterwards to mirror what would be shown on a fresh launch.
    private func recordRecent(_ entity: RecentSearchEntity) {
        RecentSearchEntityStore.append(entity, for: scope)
        let reloaded = RecentSearchEntityStore.load(for: scope)
        switch scope {
        case .discover: recentDiscover = reloaded
        case .library: recentLibrary = reloaded
        }
    }

    /// Debounced fan-out to server-catalog search + iTunes + optional acquisition plugin.
    private func scheduleHybridSearch(debounce: Bool = true) {
        hybridSearchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            serverResults = .empty
            acquireResults = []
            namedArtistMatches = []
            searchError = nil
            isFetching = false
            return
        }
        isFetching = true
        searchError = nil
        hybridSearchTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            await runHybridSearch(query: q)
        }
    }

    private func runHybridSearch(query: String) async {
        if app.effectiveOfflineMode {
            let offline = app.searchOfflineCatalog(query: query, limit: 30)
            if Task.isCancelled || trimmedQuery != query { return }
            serverResults = offline
            acquireResults = []
            namedArtistMatches = []
            isFetching = false
            return
        }

        let lib = app.activeLibrary
        let acquireOK = app.acquisitionConfigured
            && app.acquisitionCapabilities.supportsTrackSearch
            && !app.effectiveOfflineMode

        let server: CatalogSearchResults
        if let lib {
            server = (try? await lib.searchCatalog(query: query, limit: 30)) ?? .empty
        } else {
            server = .empty
        }
        if Task.isCancelled || trimmedQuery != query { return }
        serverResults = server

        let pluginAcquire: [AcquisitionResult]
        if acquireOK {
            pluginAcquire = await acquisition.search(query: query)
        } else {
            pluginAcquire = []
        }
        let pluginArtists: [AcquisitionArtist]
        if app.acquisitionConfigured, !app.effectiveOfflineMode {
            pluginArtists = await acquisition.searchArtists(query: query)
        } else {
            pluginArtists = []
        }
        if Task.isCancelled || trimmedQuery != query { return }

        var seenAcquireKeys = Set<String>()
        var mergedAcquire: [AcquisitionResult] = []
        for row in pluginAcquire where seenAcquireKeys.insert(row.request.requestKey).inserted {
            mergedAcquire.append(row)
        }
        acquireResults = mergedAcquire

        let serverArtistNames = Set(server.artists.map { LibraryTrackMatcher.normalize($0.name) })
        var seenNames = Set<String>()
        let matches = pluginArtists.compactMap { artist -> NamedArtistMatch? in
            let norm = LibraryTrackMatcher.normalize(artist.name)
            guard !serverArtistNames.contains(norm), seenNames.insert(norm).inserted else { return nil }
            return NamedArtistMatch(id: artist.id, name: artist.name, artworkURL: artist.artworkURL)
        }
        if Task.isCancelled || trimmedQuery != query { return }
        namedArtistMatches = Array(matches.prefix(3))
        isFetching = false
    }

    private func scheduleLibrarySearch(debounce: Bool = true) {
        librarySearchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            libraryServerResults = .empty
            librarySearchError = nil
            isLibraryFetching = false
            return
        }
        isLibraryFetching = true
        librarySearchError = nil
        librarySearchTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            await runLibrarySearch(query: q)
        }
    }

    private func runLibrarySearch(query: String) async {
        if app.effectiveOfflineMode {
            let offline = app.searchOfflineCatalog(query: query, limit: 40)
            if Task.isCancelled || trimmedQuery != query { return }
            libraryServerResults = offline
            librarySearchError = nil
            isLibraryFetching = false
            return
        }

        guard let lib = app.activeLibrary else {
            if Task.isCancelled || trimmedQuery != query { return }
            libraryServerResults = .empty
            isLibraryFetching = false
            return
        }

        do {
            let results = try await lib.searchCatalog(query: query, limit: 40)
            if Task.isCancelled || trimmedQuery != query { return }
            libraryServerResults = results
            librarySearchError = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled || trimmedQuery != query { return }
            librarySearchError = error.localizedDescription
            libraryServerResults = .empty
        }
        isLibraryFetching = false
    }

    private static func librarySearchTokens(_ raw: String) -> [String] {
        raw.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func matchesLibrarySearchTokens(_ tokens: [String], in haystack: String) -> Bool {
        let normalized = haystack.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        for t in tokens where !normalized.contains(t) { return false }
        return true
    }

    private func addAlbum(_ album: AlbumSummary) async {
        guard !addingAlbumIds.contains(album.id) else { return }
        addingAlbumIds.insert(album.id)
        defer { addingAlbumIds.remove(album.id) }
        await app.addAlbumToLibrary(album)
        flashToast("Added \"\(album.title)\" to library")
    }

    private func addTrack(_ track: Track) async {
        let albumId = track.albumId
        guard !addingAlbumIds.contains(albumId) else { return }
        addingAlbumIds.insert(albumId)
        defer { addingAlbumIds.remove(albumId) }
        await app.addSongToLibrary(track)
        flashToast("Added \"\(track.title)\" to library")
    }

    private func requestResult(_ result: AcquisitionResult) async {
        guard !LibraryTrackMatcher.matchesLibrary(result, titleIndex: app.libraryTrackTitleIndex) else {
            flashToast("Already in your library")
            return
        }
        guard app.acquisitionConfigured else {
            flashToast("Set up a download plugin in Settings first.")
            return
        }
        await app.requestAcquisition(result.request)
    }

    private func flashToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            toast = nil
        }
    }
}

// MARK: - Acquisition result detail

/// Pushed when an acquisition search result is tapped. Apple-Music-style preview with a
/// large artwork, metadata, and a primary Request action. Download state comes from the
/// shared `AcquisitionManager`, so progress survives the navigation push and matches the
/// search row.
struct AcquireResultDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var acquisition: AcquisitionManager
    let result: AcquisitionResult

    @State private var statusMessage: String?

    private var artistsLine: String { result.artistLine }

    private var alreadyInLibrary: Bool {
        LibraryTrackMatcher.matchesLibrary(result, titleIndex: app.libraryTrackTitleIndex)
    }

    private var job: AcquisitionJob? { acquisition.job(forKey: result.request.requestKey) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                artwork
                    .padding(.top, 12)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(result.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        if result.explicit {
                            Image(systemName: "e.square.fill")
                                .font(.caption)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                        }
                    }
                    Text(artistsLine)
                        .font(.headline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .multilineTextAlignment(.center)
                    if !metadataLine.isEmpty {
                        Text(metadataLine)
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)

                primaryActionButton

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(MusicDesign.background)
        .navigationTitle(result.title)
        .musicNavigationBarTitleDisplayMode(.inline)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let sub = result.subtitle, !sub.isEmpty { parts.append(sub) }
        if !result.albumName.isEmpty { parts.append(result.albumName) }
        if let y = result.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let url = result.coverURL {
                RemoteArtworkScaledFill(url: url, maxPixelSize: 900) {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 260, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            MusicDesign.chromeCapsuleFill
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if alreadyInLibrary {
            Label("Already in your library", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Capsule().fill(MusicDesign.chromeCapsuleFill))
        } else if let job, !job.status.isTerminal {
            VStack(spacing: 6) {
                ProgressView(value: min(1, job.progress))
                    .tint(MusicDesign.accent)
                    .frame(width: 220)
                Text("\(Int((min(1, job.progress) * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
        } else if let job, job.status == .failed {
            Label("Request failed", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Capsule().fill(MusicDesign.chromeCapsuleFill))
        } else {
            Button {
                Task { await runRequest() }
            } label: {
                RequestActionLabel(font: .headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(MusicDesign.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!app.acquisitionConfigured)
            .opacity(app.acquisitionConfigured ? 1 : 0.5)
        }
    }

    private func runRequest() async {
        guard app.acquisitionConfigured else {
            statusMessage = "Set up a download plugin in Settings first."
            return
        }
        await app.requestAcquisition(result.request)
        statusMessage = "Requested “\(result.title)”"
    }
}

private extension View {
    /// Zero list insets so ``musicChevronRowPadding()`` + ``musicChevronRowDivider`` align with text and chevron.
    func discoverySearchListRowChrome() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}
