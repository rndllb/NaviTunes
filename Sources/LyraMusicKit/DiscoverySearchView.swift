import SwiftUI

enum SearchScope: String, CaseIterable {
    case discover = "Discover"
    case library = "Library"
}

/// Layout constants for the Search tab (`Tab(role: .search)`).
enum DiscoverySearchLayout {
    /// Reserved height for the pinned Discover / Library pill (`SearchLibraryView` overlay).
    static let scopeBarClearance: CGFloat = 56
}

/// Unified navigation target so every Button-based row in Discovery search can
/// route through one `.navigationDestination(item:)` modifier — multiple
/// stacked modifiers conflict.
enum SearchNavTarget: Hashable {
    case song(Track)
    case album(AlbumSummary)
    case playlist(PlaylistSummary)
    case artist(LibraryArtistSummary)
    case genre(LibraryGenreSummary)
    case downtify(DowntifySong)
}

/// Reads `@Environment(\.isSearching)` (set by an ancestor `.searchable`) and
/// hands the boolean to a builder closure. SwiftUI exposes `isSearching` only
/// to descendants of the view that owns the `.searchable` modifier — wrapping
/// content in this reader is the documented way to inspect the search session
/// state from inside the modified view's body.
private struct SearchSessionReader<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    @ViewBuilder var content: (_ isSearchActive: Bool) -> Content
    var body: some View { content(isSearching) }
}

/// Apple-Music-style genre tile used in the search idle state. Renders the
/// genre name on a deterministic gradient (hash → palette) so colors stay
/// stable across launches without relying on artwork the server rarely
/// provides for genres. Pure label view — taps are owned by the outer
/// `NavigationLink` / `Button` wrapper.
private struct SearchGenreTile: View {
    let title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: SearchGenrePalette.gradient(for: title),
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
            Text(title)
                .font(.headline.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

private enum SearchGenrePalette {
    /// Hand-tuned, mostly-saturated gradient pairs that read well over the
    /// dark `MusicDesign.background`. Selection is deterministic per genre
    /// name so the grid doesn't shuffle on each appearance.
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

/// One row in the Downtify hybrid feed — either a server-catalog hit (Add) or a
/// Downtify download candidate (Download). Server hits already in the user's
/// personal library are filtered out upstream (they live in the Library tab).
private enum HybridRow: Identifiable {
    case serverSong(Track)
    case serverAlbum(AlbumSummary)
    case downtify(DowntifySong)

    var id: String {
        switch self {
        case .serverSong(let t): return "srv-song-\(t.id)"
        case .serverAlbum(let a): return "srv-album-\(a.id)"
        case .downtify(let s): return "dt-\(s.songId)"
        }
    }
}

struct DiscoverySearchView: View {
    @EnvironmentObject private var app: AppModel
    @Binding var searchText: String
    @Binding var scope: SearchScope
    @Binding var navigationPath: NavigationPath
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
    @State private var downtifyResults: [DowntifySong] = []
    @State private var isFetching = false
    @State private var searchError: String?
    @State private var hybridSearchTask: Task<Void, Never>?

    // Idle-state genre tiles (Discover tab).
    @State private var serverGenres: [LibraryGenreSummary] = []
    @State private var isLoadingGenres = false
    @State private var genresLoadError: String?

    // Per-row interaction state.
    @State private var downloadingIds: Set<String> = []
    @State private var downtifyDownloadFraction: [String: Double] = [:]
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
    /// Tight vertical padding so rows don't feel airy. `libraryVerticalPadding`
    /// (10pt at medium) was visibly too generous in search lists.
    private var entityVerticalPadding: CGFloat { 2 }
    private var songVerticalPadding: CGFloat { 2 }
    /// Discover rows sit flush on the page background (no card tint).
    private var discoverRowBackground: Color { MusicDesign.background }
    /// Library search rows keep a subtle card tint for separation.
    private var libraryRowBackground: Color { MusicDesign.tertiarySurfaceFill.opacity(0.55) }

    private var searchArtworkDividerKind: MusicChevronRowDivider.Kind {
        .custom(leading: MusicChevronRowMetrics.artworkDividerLeading(side: rowArtworkSide, spacing: 12))
    }

    private var personalResults: PersonalLibrarySearchResults {
        app.searchPersonalLibrary(query: trimmedQuery)
    }

    /// Unified, relevance-sorted hybrid feed. Both the server catalog and
    /// Downtify return their own internal relevance order; we score every row
    /// against the query and merge-sort so the strongest match wins regardless
    /// of source instead of always surfacing Navidrome/Jellyfin first.
    private var hybridRows: [HybridRow] {
        let personalAlbumIds = Set(app.libraryAlbumEntries.map(\.id))
        let personalSongIds = app.librarySongIds
        let albumIdsInFeed = Set(serverResults.albums.map(\.id))
        let serverTracks = serverResults.songs
        let q = trimmedQuery

        var scored: [(row: HybridRow, score: Double, kindPriority: Int)] = []

        for album in serverResults.albums where !personalAlbumIds.contains(album.id) {
            let s = Self.relevanceScore(title: album.title, artist: album.artist, query: q)
            // Slight bump for albums so when score ties with a single track,
            // the album surfaces first (matches Apple Music's Top Results bias).
            scored.append((.serverAlbum(album), s + 0.05, 0))
        }

        for song in serverResults.songs
            where !personalSongIds.contains(song.id) && !albumIdsInFeed.contains(song.albumId)
        {
            let s = Self.relevanceScore(title: song.title, artist: song.artist, query: q)
            scored.append((.serverSong(song), s, 1))
        }

        for ds in downtifyResults {
            // Suppress Downtify rows already covered by a server hit (the server
            // row already lets the user acquire the track) or by the user's
            // personal library.
            if LibraryTrackMatcher.firstLibraryTrack(matching: ds, in: serverTracks) != nil { continue }
            if LibraryTrackMatcher.matchesLibrary(ds, titleIndex: app.libraryTrackTitleIndex) { continue }
            let artist = ds.artists.joined(separator: ", ")
            let s = Self.relevanceScore(title: ds.name, artist: artist, query: q)
            scored.append((.downtify(ds), s, 2))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Equal score → preserve a stable order (album > song > downtify).
                return lhs.kindPriority < rhs.kindPriority
            }
            .map(\.row)
    }

    /// 0–1 relevance score for a candidate against `query`. Uses
    /// `LibraryTrackMatcher.normalize` so it's diacritic- and punctuation-
    /// insensitive. Title matches outweigh artist matches; exact > prefix > contains.
    private static func relevanceScore(title: String, artist: String, query: String) -> Double {
        let q = LibraryTrackMatcher.normalize(query)
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
            .searchable(
                text: $searchText,
                prompt: scope == .discover
                    ? "Server catalog & Downtify"
                    : "Your library",
            )
            .onSubmit(of: .search) { submitSearch() }
            .onChange(of: scope) { _, newScope in
            if newScope == .discover {
                scheduleHybridSearch()
            } else {
                hybridSearchTask?.cancel()
            }
        }
        .onChange(of: searchText) { _, _ in
            if scope == .discover { scheduleHybridSearch() }
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
            if app.homeGenreShelves.isEmpty {
                await app.refreshHome()
            }
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
        SearchSessionReader { isSearchActive in
            // Three-state body matching Apple Music's search:
            //   * idle (search not focused, no query) → genre-tile grid
            //   * focused, no query → Recently Searched
            //   * has query → live hybrid results
            if !isSearchActive && trimmedQuery.isEmpty {
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
                if !app.downtifyConfigured {
                    Text("Add your Downtify server URL in Settings to enable downloads. Server search still works.")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .padding(.horizontal, 16)
                }

                // Tile grid: the colorful Apple-Music-style top-of-search browse.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Browse Categories")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)

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

                // Per-genre album shelves: mirrors Apple's "Oldies → Pet Sounds…"
                // deeper browse. Source is `homeGenreShelves`, populated by
                // `refreshHome` (4 genres × ~8 albums).
                if !app.homeGenreShelves.isEmpty {
                    ForEach(app.homeGenreShelves, id: \.genre) { shelf in
                        discoverGenreShelf(title: shelf.genre, albums: shelf.albums)
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func discoverGenreShelf(title: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
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
                            shelfAlbumCard(album)
                        }
                        .buttonStyle(.plain)
                        .libraryAlbumContextMenu(album)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func shelfAlbumCard(_ album: AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 8)
                .frame(width: 140, height: 140)
            Text(album.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
    }

    private var hybridRecentlySearchedList: some View {
        List {
            Section {
                recentHeader
                if recent.isEmpty {
                    Text("Search your server, or grab something new with Downtify.")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        Button {
                            tapRecent(item)
                        } label: {
                            recentEntityRow(item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(discoverRowBackground)
                        .musicChevronRowDivider(searchArtworkDividerKind, shows: index < recent.count - 1)
                    }
                }
            }
            if !app.downtifyConfigured {
                Section {
                    Text("Add your Downtify server URL in Settings to enable downloads. Server search still works.")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .musicDiscoverySearchListStyle(discoverRows: true)
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
        .musicDiscoverySearchListStyle(discoverRows: true)
    }

    private func loadServerGenresIfNeeded() async {
        guard let lib = app.activeLibrary else {
            serverGenres = []
            genresLoadError = nil
            isLoadingGenres = false
            return
        }

        isLoadingGenres = true
        genresLoadError = nil
        defer { isLoadingGenres = false }

        do {
            // Cap chosen to fill 4-6 vertical screens of tiles on iPhone.
            serverGenres = try await lib.libraryGenres(limit: 60)
        } catch is CancellationError {
            return
        } catch {
            genresLoadError = error.localizedDescription
            serverGenres = []
        }
    }

    @ViewBuilder
    private func hybridRowView(_ row: HybridRow) -> some View {
        switch row {
        case .serverAlbum(let album):
            serverAlbumRow(album)
        case .serverSong(let track):
            serverSongRow(track)
        case .downtify(let song):
            downtifyRow(song)
        }
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
                Spacer(minLength: 0)
                navChevron
            }
            .padding(.vertical, entityVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(discoverRowBackground)
        .libraryAlbumContextMenu(album)
    }

    /// Trailing ">" chevron used on rows that navigate to a bigger detail view.
    private var navChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MusicDesign.secondaryLabel.opacity(0.7))
    }

    // MARK: - Hybrid: server-song row (Add pill, tap = play)

    private func serverSongRow(_ track: Track) -> some View {
        Button {
            recordRecent(.init(
                kind: .song,
                primaryId: track.id,
                secondaryId: track.albumId,
                title: track.title,
                subtitle: track.artist,
                artworkURL: track.artworkURL,
            ))
            navigationPath.append(SearchNavTarget.song(track))
        } label: {
            HStack(spacing: 12) {
                AlbumArtworkView(url: track.artworkURL)
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
                Spacer(minLength: 0)
                navChevron
            }
            .padding(.vertical, songVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(discoverRowBackground)
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
                navigationPath.append(SearchNavTarget.song(track))
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
    }

    // MARK: - Hybrid: Downtify row (Download pill + tappable detail)

    private func downtifyRow(_ song: DowntifySong) -> some View {
        // Whole-row tap → Downtify detail view. The Download pill stays as a
        // secondary action so users can kick off a download without first
        // opening the detail.
        HStack(spacing: 12) {
            Button {
                recordRecent(.init(
                    kind: .song,
                    primaryId: "downtify:\(song.songId)",
                    title: song.name,
                    subtitle: song.artists.joined(separator: ", "),
                    artworkURL: song.coverURL,
                ))
                navigationPath.append(SearchNavTarget.downtify(song))
            } label: {
                HStack {
                    downtifyRowArtworkAndTitles(song)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if downloadingIds.contains(song.songId) {
                VStack(alignment: .trailing, spacing: 3) {
                    if let fr = downtifyDownloadFraction[song.songId] {
                        ProgressView(value: min(1, fr))
                            .tint(MusicDesign.accent)
                            .frame(width: 56)
                        Text("\(Int((min(1, fr) * 100).rounded()))%")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    } else {
                        ProgressView()
                            .tint(MusicDesign.accent)
                    }
                }
                .frame(width: 56, alignment: .trailing)
            } else {
                statePillButton(
                    label: "Download",
                    systemImage: "arrow.down",
                    busy: false,
                    disabled: !app.downtifyConfigured,
                ) {
                    Task { await downloadSong(song) }
                }
            }
        }
        .padding(.vertical, songVerticalPadding)
        .listRowBackground(discoverRowBackground)
    }

    @ViewBuilder
    private func downtifyRowArtworkAndTitles(_ song: DowntifySong) -> some View {
        HStack(spacing: 12) {
            Group {
                if let art = song.coverURL {
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
                    Text(song.name)
                        .font(songTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if song.explicit == true {
                        Image(systemName: "e.square.fill")
                            .font(.caption2)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
                }
                Text("Song · \(song.artists.joined(separator: ", "))")
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

    // MARK: - Library (personal)

    private var libraryContent: some View {
        SearchSessionReader { isSearchActive in
            // Apple Music's Library search tab idle shows a sparse prompt + recent
            // searches rather than category tiles; results appear once the field
            // is focused. Mirror that: skip the genre grid here.
            if !isSearchActive && trimmedQuery.isEmpty {
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
                Text("Search Your Library")
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
        if app.librarySongIds.isEmpty
            && app.libraryAlbumEntries.isEmpty
            && app.libraryPlaylistEntries.isEmpty
        {
            return "Your library is empty. Add songs, albums, and playlists from Discover to search them here."
        }
        return "Find songs, albums, playlists, and artists you've added to your library."
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
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(libraryRowBackground)
                        .musicChevronRowDivider(searchArtworkDividerKind, shows: index < recent.count - 1)
                    }
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    private var libraryResultsList: some View {
        let results = personalResults
        return List {
            if results.isEmpty {
                Section {
                    Text("Nothing in your library matches \"\(trimmedQuery)\".")
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
                                    artworkURL: track.artworkURL,
                                ))
                                navigationPath.append(SearchNavTarget.song(track))
                            } label: {
                                HStack {
                                    personalSongRow(track)
                                    Spacer(minLength: 0)
                                    navChevron
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
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
                                HStack {
                                    albumRow(album)
                                    Spacer(minLength: 0)
                                    navChevron
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
                            .libraryAlbumContextMenu(album)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < results.albums.count - 1)
                        }
                    }
                }
                if !results.playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(Array(results.playlists.enumerated()), id: \.element.id) { index, playlist in
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
                                HStack {
                                    playlistRow(playlist)
                                    Spacer(minLength: 0)
                                    navChevron
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
                            .libraryPlaylistContextMenu(playlist)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < results.playlists.count - 1)
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
                                    Spacer(minLength: 0)
                                    navChevron
                                }
                                .padding(.vertical, entityVerticalPadding)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(libraryRowBackground)
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
            AlbumArtworkView(url: track.artworkURL)
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
            Spacer(minLength: 0)
            navChevron
        }
        .padding(.vertical, entityVerticalPadding)
        .contentShape(Rectangle())
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
        if scope == .discover { scheduleHybridSearch(debounce: false) }
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

    /// Debounced fan-out to server-catalog search + Downtify. Cancels prior in-flight
    /// task on each call so rapid typing collapses to the last query.
    private func scheduleHybridSearch(debounce: Bool = true) {
        hybridSearchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            serverResults = .empty
            downtifyResults = []
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
        let lib = app.activeLibrary
        let downtifyOK = app.downtifyConfigured

        let server: CatalogSearchResults
        if let lib {
            server = (try? await lib.searchCatalog(query: query, limit: 30)) ?? .empty
        } else {
            server = .empty
        }
        if Task.isCancelled || trimmedQuery != query { return }
        serverResults = server

        let downtify: [DowntifySong]
        if downtifyOK {
            downtify = (try? await DowntifyClient.search(query: query)) ?? []
        } else {
            downtify = []
        }
        if Task.isCancelled || trimmedQuery != query { return }
        downtifyResults = downtify
        isFetching = false
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

    private func downloadSong(_ song: DowntifySong) async {
        guard !downloadingIds.contains(song.songId) else { return }
        guard !LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) else {
            flashToast("Already in your library")
            return
        }
        downloadingIds.insert(song.songId)
        downtifyDownloadFraction[song.songId] = 0
        defer {
            downloadingIds.remove(song.songId)
            downtifyDownloadFraction.removeValue(forKey: song.songId)
        }
        do {
            let name = try await DowntifyClient.downloadSong(song) { p in
                Task { @MainActor in
                    downtifyDownloadFraction[song.songId] = p
                }
            }
            flashToast("Downloading \"\(name)\"")
        } catch {
            flashToast(error.localizedDescription)
        }
    }

    private func flashToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            toast = nil
        }
    }
}

// MARK: - Discover / Library scope pill (pinned in `SearchLibraryView`)

/// Floating liquid-glass Discover / Library control; overlay is outside `isSearching` layout shifts.
struct DiscoverLibraryScopeBar: View {
    @Binding var scope: SearchScope

    var body: some View {
        Picker("Scope", selection: $scope) {
            ForEach(SearchScope.allCases, id: \.self) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding(6)
        .musicGlassCapsuleInteractiveChrome()
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Downtify song detail

/// Pushed when a Downtify result is tapped. Apple-Music-style preview with a
/// large artwork, song metadata, and a primary Download action. Polls the
/// shared download progress dictionary indirectly through its own state since
/// the parent view's `downloadingIds`/`downtifyDownloadFraction` aren't
/// reachable across a navigation push.
struct DowntifySongDetailView: View {
    @EnvironmentObject private var app: AppModel
    let song: DowntifySong

    @State private var isDownloading = false
    @State private var downloadFraction: Double = 0
    @State private var statusMessage: String?

    private var artistsLine: String { song.artists.joined(separator: ", ") }

    private var alreadyInLibrary: Bool {
        LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                artwork
                    .padding(.top, 12)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(song.name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        if song.explicit {
                            Image(systemName: "e.square.fill")
                                .font(.caption)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                        }
                    }
                    Text(artistsLine)
                        .font(.headline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .multilineTextAlignment(.center)
                    if !song.albumName.isEmpty || song.year != nil {
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
        .navigationTitle(song.name)
        .musicNavigationBarTitleDisplayMode(.inline)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if !song.albumName.isEmpty { parts.append(song.albumName) }
        if let y = song.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let url = song.coverURL {
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
        } else if isDownloading {
            VStack(spacing: 6) {
                ProgressView(value: min(1, downloadFraction))
                    .tint(MusicDesign.accent)
                    .frame(width: 220)
                Text("\(Int((min(1, downloadFraction) * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
        } else {
            Button {
                Task { await runDownload() }
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(MusicDesign.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!app.downtifyConfigured)
            .opacity(app.downtifyConfigured ? 1 : 0.5)
        }
    }

    private func runDownload() async {
        isDownloading = true
        downloadFraction = 0
        statusMessage = nil
        defer { isDownloading = false }
        do {
            let name = try await DowntifyClient.downloadSong(song) { p in
                Task { @MainActor in downloadFraction = p }
            }
            statusMessage = "Downloading \"\(name)\""
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
