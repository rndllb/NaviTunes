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
    /// An artist by name only (not in the server library). The artist page resolves the name
    /// against MusicBrainz on arrival, which costs one search request.
    case namedArtist(String)
    /// An artist opened from a MusicBrainz search hit, carrying the hit itself.
    ///
    /// Distinct from ``namedArtist`` because the payload is the point: the search response
    /// already holds the header facts, so a page opened this way renders them without a
    /// request. Passing a bare name here instead would throw that away and make the artist
    /// page search again for a row we are already holding.
    case musicBrainzArtist(MusicBrainzArtist)
    /// An artist known only by MBID and name — the shape a request-candidate row can offer,
    /// since it carries the id but not the artist's own metadata.
    case musicBrainzArtistId(id: String, name: String)
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
    /// MusicBrainz artist id, for an artist row that came from MusicBrainz rather than the
    /// server.
    ///
    /// Kept because the id is the expensive part. Without it, re-opening a niche artist from
    /// Recently Searched had to resolve the name against MusicBrainz again — one rate-limited
    /// request to rediscover an answer the app was already holding when the row was written —
    /// and could resolve to a *different* artist of the same name than the one the user tapped.
    ///
    /// Optional so entries already on disk decode unchanged.
    var musicBrainzId: String?

    var id: String { "\(kind.rawValue):\(primaryId)" }

    var dedupeKey: String { id }

    /// Prefix once used for request rows stored into Recently Searched.
    static let acquireIdPrefix = "acquire:"

    /// Prefix once used for off-server artist rows, from when they came from iTunes.
    ///
    /// Those rows stored `"itunes:<id>"` in ``primaryId`` and were then navigated to as though
    /// the string were a *server* artist id, which no server has ever issued. Entries already on
    /// disk are still routed — by MBID where the prefix hides one, by name otherwise — rather
    /// than being hidden, since the row itself is fine and only the id was wrong.
    static let legacyOffServerArtistPrefix = "itunes:"

    /// The MusicBrainz id a legacy `itunes:`-prefixed artist entry is carrying, if any.
    ///
    /// After the iTunes path was removed these ids were MBIDs stored under the old prefix, so
    /// the value is usually recoverable. Validated by shape — an MBID is a 36-character UUID —
    /// so an actual iTunes numeric id from an older install is not mistaken for one.
    var recoveredMusicBrainzId: String? {
        if let musicBrainzId, !musicBrainzId.isEmpty { return musicBrainzId }
        guard kind == .artist, primaryId.hasPrefix(Self.legacyOffServerArtistPrefix) else { return nil }
        let candidate = String(primaryId.dropFirst(Self.legacyOffServerArtistPrefix.count))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    /// True when this artist row cannot be trusted as a server artist id.
    var isOffServerArtist: Bool {
        kind == .artist && (musicBrainzId != nil || primaryId.hasPrefix(Self.legacyOffServerArtistPrefix))
    }

    /// An entry that cannot be navigated to, because it never described a library entity.
    ///
    /// Request rows used to be recorded here with `primaryId: "acquire:<id>"` and no album id.
    /// Tapping one built a stub `Track` with `albumId: ""`, which `ServerPlaylistDetailView`
    /// rendered as a page literally titled "Album" with no artwork, the words "Album not found",
    /// and a Play button that looked live and did nothing.
    ///
    /// New ones are no longer written. This catches the ones already sitting in people's stores,
    /// which would otherwise keep that dead route reachable for ever.
    var isUnnavigable: Bool {
        primaryId.hasPrefix(Self.acquireIdPrefix)
            || primaryId.trimmingCharacters(in: .whitespaces).isEmpty
            || (kind == .song && (secondaryId ?? "").isEmpty)
    }

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

/// An artist not in the server library — surfaced as a normal artist result row so missing
/// artists flow into the artist page like server ones.
///
/// `musicBrainz` is the search payload the row came from, when it came from MusicBrainz. It
/// travels with the row so that opening it costs nothing: the artist page renders its header
/// straight from this. Rows sourced from the acquisition plugin leave it nil and the page
/// resolves the name itself.
private struct NamedArtistMatch: Identifiable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
    var disambiguation: String?
    var musicBrainz: MusicBrainzArtist?

    /// Where tapping this row should land.
    var navTarget: SearchNavTarget {
        if let musicBrainz { return .musicBrainzArtist(musicBrainz) }
        return .namedArtist(name)
    }
}

/// One row in the hybrid Discover feed — either a server-catalog hit, an iTunes artist,
/// or an acquisition request candidate. Server hits already in the user's personal library
/// are filtered out upstream (they live in the Library tab).

private enum HybridRow: Identifiable {
    case serverArtist(LibraryArtistSummary)
    case namedArtist(NamedArtistMatch)
    case serverSong(Track)
    case serverAlbum(AlbumSummary)
    /// An album MusicBrainz knows about that the connected server does not.
    case musicBrainzAlbum(MusicBrainzReleaseGroup)
    /// A song MusicBrainz knows about that the connected server does not.
    case musicBrainzSong(MusicBrainzSongRow)
    case acquire(AcquisitionResult)

    var id: String {
        switch self {
        case .serverArtist(let a): return "srv-artist-\(a.id)"
        case .namedArtist(let a): return "mb-artist-\(a.id)"
        case .serverSong(let t): return "srv-song-\(t.id)"
        case .serverAlbum(let a): return "srv-album-\(a.id)"
        case .musicBrainzAlbum(let g): return "mb-album-\(g.id)"
        case .musicBrainzSong(let s): return "mb-song-\(s.id)"
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
    ///
    /// Filtered, not just trimmed at the point of writing: stores already on people's devices hold
    /// request rows that navigate to a dead album page. See ``RecentSearchEntity/isUnnavigable``.
    private var recent: [RecentSearchEntity] {
        switch scope {
        case .discover: return recentDiscover.filter { !$0.isUnnavigable }
        case .library: return recentLibrary.filter { !$0.isUnnavigable }
        }
    }

    // Hybrid Discover-tab state.
    @State private var serverResults: CatalogSearchResults = .empty
    @State private var acquireResults: [AcquisitionResult] = []
    @State private var isFetching = false
    @State private var searchError: String?
    @State private var hybridSearchTask: Task<Void, Never>?

    /// The MusicBrainz side of Discover: artists, albums and songs, each independently
    /// paginated. Replaces the old three-artist-row lookup entirely.
    @StateObject private var musicBrainz = MusicBrainzSearchFeed()
    /// Which entity tab is showing. `All` merges MusicBrainz with the server catalog and does
    /// not paginate; the other three are single-entity infinite-scrolling lists.
    @State private var entity: MusicBrainzSearchEntity = .all
    /// Separate from ``hybridSearchTask`` so the MusicBrainz fan-out can run on its own longer
    /// debounce without holding up the server-catalog results.
    @State private var musicBrainzTask: Task<Void, Never>?

    /// MusicBrainz artist rows as the feed's artist hits, minus anything the server already
    /// answered for (those belong to the server rows, which are playable).
    ///
    /// Ranked by MusicBrainz's own relevance rather than re-sorted locally. That ordering is the
    /// entire reason for querying MusicBrainz: it is what surfaces a hit found through an alias
    /// or a corrected misspelling, neither of which a local name comparison can see.
    private var namedArtistMatches: [NamedArtistMatch] {
        // Suppressed by MBID, never by name.
        //
        // Artist names are not identities and are not even close to unique: MusicBrainz holds 17
        // distinct artists named exactly "Rocket" in the first page of results alone — a Russian
        // rapper, a UK grime artist, an LA indie band, an 80s electro-funk act. Dropping every
        // MusicBrainz artist whose name matches a server artist therefore does not remove a
        // duplicate, it removes sixteen different musicians because the user happens to own a
        // record by the seventeenth.
        //
        // An MBID does identify an artist, so a server artist that reports one suppresses exactly
        // its own row and nothing else. A server artist without an MBID suppresses nothing: the
        // cost of that is one repeated row, against the cost of silently hiding everyone who
        // shares a name.
        let serverArtistMBIDs = Set(serverResults.artists.compactMap(\.musicBrainzArtistId))
        var seen = Set<String>()
        return musicBrainz.artists.compactMap { artist -> NamedArtistMatch? in
            guard !artist.name.isEmpty else { return nil }
            guard !serverArtistMBIDs.contains(artist.id), seen.insert(artist.id).inserted else {
                return nil
            }
            return NamedArtistMatch(
                id: artist.id,
                name: artist.name,
                artworkURL: nil,
                disambiguation: artist.searchRowDescriptor,
                musicBrainz: artist
            )
        }
    }

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

        var scored: [(row: HybridRow, score: Double, kindPriority: Int, coverage: Double, tieBreak: String)] = []

        // One row per release, across every source that can produce one.
        //
        // Server albums, plugin release rows, and the server album list *itself* all feed this
        // list, and nothing compared them to each other — so the same record could appear twice
        // (Navidrome will happily return two editions of one album, or one album scanned twice).
        // Keyed on normalized title + artist and never on id, because two sources agreeing on a
        // release is precisely the case where the ids differ.
        var seenReleaseKeys = Set<String>()

        // Artists lead Top Results when the query actually names one — see `artistRowScore` for
        // why the lift is graded rather than the flat `+1.0` this used to add to every artist.
        for artist in serverResults.artists {
            let s = Self.artistRowScore(name: artist.name, normalizedQuery: q)
            scored.append((.serverArtist(artist), s, -1, Self.matchCoverage(of: artist.name, queryLength: q.count), artist.name))
        }

        // Artists not on the server (MusicBrainz matches) get the same artist-row treatment
        // and priority, so a missing artist surfaces alongside server artists.
        for match in namedArtistMatches {
            let s = Self.musicBrainzArtistRowScore(
                name: match.name,
                musicBrainzScore: match.musicBrainz?.score,
                normalizedQuery: q
            )
            scored.append((.namedArtist(match), s, -1, Self.matchCoverage(of: match.name, queryLength: q.count), match.name))
        }

        for album in serverResults.albums {
            // The key is recorded even when the row itself is not emitted: an album already in the
            // personal library is deliberately absent from this feed, but a plugin row offering to
            // *acquire* that same album still has to be suppressed.
            let isFirstOfItsRelease = seenReleaseKeys
                .insert(Self.releaseIdentityKey(title: album.title, artist: album.artist))
                .inserted
            guard isFirstOfItsRelease, !personalAlbumIds.contains(album.id) else { continue }
            let s = Self.relevanceScore(title: album.title, artist: album.artist, normalizedQuery: q)
            // Slight bump for albums so when score ties with a single track,
            // the album surfaces first (matches Apple Music's Top Results bias).
            scored.append((.serverAlbum(album), s + 0.05, 0, Self.matchCoverage(of: album.title, queryLength: q.count), album.title))
        }

        for song in serverResults.songs
            where !personalSongIds.contains(song.id) && !albumIdsInFeed.contains(song.albumId)
        {
            let s = Self.relevanceScore(title: song.title, artist: song.artist, normalizedQuery: q)
            scored.append((.serverSong(song), s, 1, Self.matchCoverage(of: song.title, queryLength: q.count), song.title))
        }

        // MusicBrainz albums, for the `All` tab. Suppressed when the same release already
        // arrived from the server, since the server row is playable and this one is only
        // requestable — `seenReleaseKeys` is the same gate the plugin rows go through.
        for group in musicBrainz.albums.prefix(Self.allTabMusicBrainzLimit) {
            let artist = group.searchRowArtist
            guard seenReleaseKeys
                .insert(Self.releaseIdentityKey(title: group.title, artist: artist))
                .inserted
            else { continue }
            let s = Self.musicBrainzRowScore(
                title: group.title,
                artist: artist,
                musicBrainzScore: group.score,
                normalizedQuery: q
            )
            scored.append((
                .musicBrainzAlbum(group), s + 0.05, 0,
                Self.matchCoverage(of: group.title, queryLength: q.count), group.title
            ))
        }

        // MusicBrainz songs, for the `All` tab. Checked against the server's own track hits by
        // title + artist so a song you already have does not appear twice, once playable and
        // once as a request.
        let serverSongKeys = Set(serverTracks.map { Self.releaseIdentityKey(title: $0.title, artist: $0.artist) })
        for song in musicBrainz.songs.prefix(Self.allTabMusicBrainzLimit) {
            let key = Self.releaseIdentityKey(title: song.title, artist: song.artist)
            guard !serverSongKeys.contains(key) else { continue }
            guard !LibraryTrackMatcher.matchesLibrary(
                song.asAcquisitionResult,
                titleIndex: app.libraryTrackTitleIndex
            ) else { continue }
            let s = Self.musicBrainzRowScore(
                title: song.title,
                artist: song.artist,
                musicBrainzScore: song.recording.score,
                normalizedQuery: q
            )
            scored.append((
                .musicBrainzSong(song), s, 1,
                Self.matchCoverage(of: song.title, queryLength: q.count), song.title
            ))
        }

        for result in acquireResults {
            // Suppress acquisition rows already covered by a server hit (the server
            // row already lets the user acquire the track) or by the user's
            // personal library.
            if LibraryTrackMatcher.firstLibraryTrack(matching: result, in: serverTracks) != nil { continue }
            if LibraryTrackMatcher.matchesLibrary(result, titleIndex: app.libraryTrackTitleIndex) { continue }
            let artist = result.artistLine
            guard seenReleaseKeys
                .insert(Self.releaseIdentityKey(title: result.title, artist: result.artists.first ?? artist))
                .inserted
            else { continue }
            let s = Self.relevanceScore(title: result.title, artist: artist, normalizedQuery: q)
            scored.append((.acquire(result), s, 2, Self.matchCoverage(of: result.title, queryLength: q.count), result.title))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Equal score → preserve a stable order (artist > album > song > request backend).
                if lhs.kindPriority != rhs.kindPriority { return lhs.kindPriority < rhs.kindPriority }
                // Same score and same kind: the tighter match wins — see `matchCoverage`.
                if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
                // Still tied: `sorted(by:)` is not a stable sort, so without a final key two
                // equal rows could swap places between passes — and this whole property is
                // recomputed on every body evaluation. Decorated rather than read off `row.id`,
                // so the comparator does no work per comparison.
                return lhs.tieBreak < rhs.tieBreak
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
            score = max(score, artistExactScore)
        } else if a.hasPrefix(q) {
            score = max(score, artistPrefixScore)
        } else if a.contains(q) {
            score = max(score, artistContainsScore)
        }

        return score
    }

    /// Artist-name match tiers, shared by ``relevanceScore(title:artist:normalizedQuery:)``,
    /// where the artist is a row's *secondary* field, and ``artistRowScore(name:normalizedQuery:)``,
    /// where it is the row.
    private static let artistExactScore = 0.6
    private static let artistPrefixScore = 0.5
    private static let artistContainsScore = 0.35

    /// How far an artist row is lifted above everything else. See ``artistRowScore``.
    private static let artistExactBump = 1.0
    private static let artistPrefixBump = 0.25

    /// Score for an artist row: how well the name matches the query, plus a lift sized by how
    /// completely the query names that artist.
    ///
    /// Two things changed here in T069, and they only work as a pair.
    ///
    /// **The name is scored on the artist scale, not the title scale.** This used to call
    /// `relevanceScore(title: name, artist: name, …)`, which takes the max of both scales — so an
    /// artist row collected a *title*-tier score (0.85 for a prefix) for what is an artist match,
    /// and then took the lift on top of that.
    ///
    /// **The lift is no longer flat.** It was an unconditional `+1.0`, which put every artist above
    /// everything else however weak the match. Searching `japanese de` returned the artist
    /// "DJ.Deplorer" — relevance 0, lifted to 1.0 — above "Japanese Denim", the exact thing being
    /// searched for, which scored 0.85. Three artists sat above it. Now:
    ///
    /// - **exact** name (`deftones` → Deftones): the full lift. This is the Apple Music behaviour
    ///   the flat bump was reaching for, and it still wins against an album of the same name.
    /// - **prefix** (`deft` → Deftones): a small lift — enough to hold the artist above their own
    ///   albums and songs, which reach at most 0.6 (+0.05) from the artist side, and deliberately
    ///   *not* enough to beat a strong title match elsewhere. That is what finally lets
    ///   "Japanese Denim" (title prefix, 0.85) outrank "Japanese Deejay" (0.5 + 0.25).
    /// - **substring, or no match at all**: no lift. A loose name collision is not a reason to lead
    ///   the results.
    ///
    /// The trade-off is deliberate and worth stating: for a *partial* query an eponymous album can
    /// now edge out its own artist (`deft` → the album "Deftones" at 0.90 over the artist at 0.75).
    /// Widening the prefix lift to cover that is exactly what would put "Japanese Deejay" back on
    /// top of "Japanese Denim", so the reported bug wins.
    private static func artistRowScore(name: String, normalizedQuery q: String) -> Double {
        guard !q.isEmpty else { return 0 }
        let n = LibraryTrackMatcher.normalize(name)
        if n == q { return artistExactScore + artistExactBump }
        if n.hasPrefix(q) { return artistPrefixScore + artistPrefixBump }
        if n.contains(q) { return artistContainsScore }
        return 0
    }

    /// How many MusicBrainz rows of each kind the merged `All` tab draws from.
    ///
    /// `All` is a "best answer" view, not a catalogue — the dedicated tabs are where a full
    /// result set is browsed, and those paginate. Taking the whole hundred-row page here would
    /// bury the server's own playable results under request candidates.
    private static let allTabMusicBrainzLimit = 12

    /// MusicBrainz's own relevance, mapped into this feed's score scale.
    ///
    /// MusicBrainz returns 0–100 and it is the only signal that can see *why* a row matched.
    /// A hit found through an alias or a corrected misspelling — `crosses` → `†††`, `yeezy` →
    /// `Ye`, `blak sabath` → `Black Sabbath` — has a name that does not contain the query at
    /// all, so every local comparison scores it zero and sinks it below every other row. That
    /// is the exact class of result this app queries MusicBrainz to obtain, and discarding the
    /// score threw all of it away.
    ///
    /// Mapped to a maximum of ``artistPrefixScore`` rather than higher: a perfect MusicBrainz
    /// match should reach the band where it is plainly visible, but must not outrank a row whose
    /// name the user literally typed.
    private static func musicBrainzScoreTier(_ score: Int?) -> Double {
        guard let score, score > 0 else { return 0 }
        return artistPrefixScore * min(Double(score), 100) / 100
    }

    /// Score for a MusicBrainz artist row: the better of the local name match and MusicBrainz's
    /// own relevance.
    ///
    /// `max`, not a replacement. The local scale still has to win where it applies, because an
    /// exact typed name earns ``artistExactBump`` and MusicBrainz has no equivalent notion of
    /// "this is the row you meant" beyond a 100 it also hands to several near-misses.
    private static func musicBrainzArtistRowScore(
        name: String,
        musicBrainzScore: Int?,
        normalizedQuery q: String
    ) -> Double {
        max(artistRowScore(name: name, normalizedQuery: q), musicBrainzScoreTier(musicBrainzScore))
    }

    /// Score for a MusicBrainz album or song row: the better of the local title/artist match and
    /// MusicBrainz's own relevance. Same reasoning as ``musicBrainzArtistRowScore``.
    private static func musicBrainzRowScore(
        title: String,
        artist: String,
        musicBrainzScore: Int?,
        normalizedQuery q: String
    ) -> Double {
        max(
            relevanceScore(title: title, artist: artist, normalizedQuery: q),
            musicBrainzScoreTier(musicBrainzScore)
        )
    }

    /// How much of a candidate's name the query accounts for, 0–1.
    ///
    /// Used **only as a tiebreak**, never as part of the score, so it cannot move a row across a
    /// match tier. For `japanese de` the observed feed had "Japanese Death Machine" and "Japanese
    /// Denim" both scoring 0.85 — each is exactly a title prefix, and nothing else separated them,
    /// so the wanted row landed second behind an EP nobody asked for. The query covers 11 of
    /// "Japanese Denim"'s 14 characters and 11 of "Japanese Death Machine"'s 22: the tighter match
    /// is the better answer.
    ///
    /// Uses raw lengths rather than normalized ones to avoid a second `normalize` per row on a
    /// path that runs in a body. Punctuation makes it slightly generous, which a tiebreak can afford.
    private static func matchCoverage(of name: String, queryLength: Int) -> Double {
        guard queryLength > 0 else { return 0 }
        return Double(queryLength) / Double(max(queryLength, name.count))
    }

    /// Normalized `title|artist`, the identity used to collapse the same release arriving from
    /// more than one source. Same normalization as every other match in this file, so punctuation
    /// and diacritics can't split one release into two rows.
    private static func releaseIdentityKey(title: String, artist: String) -> String {
        "\(LibraryTrackMatcher.normalize(title))|\(LibraryTrackMatcher.normalize(artist))"
    }

    var body: some View {
        listContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(MusicDesign.background)
            .onChange(of: scope) { _, newScope in
            if newScope == .discover {
                scheduleHybridSearch()
                scheduleMusicBrainzSearch()
            } else {
                hybridSearchTask?.cancel()
                musicBrainzTask?.cancel()
                scheduleLibrarySearch()
            }
        }
        .onChange(of: searchText) { _, _ in
            if scope == .discover {
                scheduleHybridSearch()
                scheduleMusicBrainzSearch()
            } else {
                scheduleLibrarySearch()
            }
        }
        // Switching tabs never re-runs the query. The feed keeps a cursor per entity, so a tab
        // whose first page is already in hand renders instantly and costs no request — which
        // matters at one request per second.
        .onChange(of: entity) { _, _ in
            guard scope == .discover else { return }
            loadMusicBrainzTab()
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
                                .coverZoomSource(id: recentZoomId(item), style: .custom)
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

    /// The Discover results area: entity tabs above one list.
    ///
    /// The tabs exist so the three MusicBrainz entities can each paginate. `All` is the merged,
    /// locally-ranked view and does not paginate — see ``MusicBrainzSearchEntity``.
    private var hybridResultsList: some View {
        VStack(spacing: 0) {
            MusicGlassSegmentPillBar(
                options: Array(MusicBrainzSearchEntity.allCases),
                selection: $entity,
                title: { $0.title }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            switch entity {
            case .all: allResultsList
            case .artists: artistsResultsList
            case .albums: albumsResultsList
            case .songs: songsResultsList
            }
        }
    }

    /// Merged view: server catalog, MusicBrainz and plugin candidates, ranked together.
    private var allResultsList: some View {
        let rows = hybridRows
        return List {
            if rows.isEmpty {
                Section { musicBrainzStatusRow(hasRows: false) }
            } else {
                Section("Top Results") {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        hybridRowView(row)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < rows.count - 1)
                    }
                }
                // A MusicBrainz failure has to be visible even when server rows filled the list,
                // because the missing half is exactly the half that finds music you don't have.
                if musicBrainz.errorMessage != nil || musicBrainz.isLoading {
                    Section { musicBrainzStatusRow(hasRows: true) }
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    private var artistsResultsList: some View {
        musicBrainzPaginatedList(namedArtistMatches) { match in
            namedArtistRow(match)
        }
    }

    private var albumsResultsList: some View {
        musicBrainzPaginatedList(musicBrainz.albums) { group in
            musicBrainzAlbumRow(group)
        }
    }

    private var songsResultsList: some View {
        musicBrainzPaginatedList(musicBrainz.songs) { song in
            musicBrainzSongRow(song)
        }
    }

    /// One paginated single-entity list.
    ///
    /// The trailing-row `onAppear` is the paging trigger. It fires a few rows early rather than
    /// exactly at the last row so the next page is usually in hand before the user reaches the
    /// bottom — at one request per second, triggering on the final row guarantees a visible stall.
    /// ``MusicBrainzSearchFeed/loadMore(entity:)`` is itself re-entrancy-guarded, so a fast
    /// scroll firing this repeatedly cannot stack requests.
    private func musicBrainzPaginatedList<Row: Identifiable, Content: View>(
        _ rows: [Row],
        @ViewBuilder row content: @escaping (Row) -> Content
    ) -> some View {
        List {
            if rows.isEmpty {
                Section { musicBrainzStatusRow(hasRows: false) }
            } else {
                Section(entity.title) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        content(item)
                            .musicChevronRowDivider(searchArtworkDividerKind, shows: index < rows.count - 1)
                            .onAppear {
                                guard index >= rows.count - Self.pagingTriggerLookahead else { return }
                                Task { await musicBrainz.loadMore(entity: entity) }
                            }
                    }
                }
                if musicBrainz.isLoadingMore {
                    Section {
                        HStack {
                            ProgressView().tint(MusicDesign.accent)
                            Text("Loading more…")
                                .font(.subheadline)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                                .padding(.leading, 8)
                        }
                        .listRowBackground(Color.clear)
                    }
                } else if musicBrainz.errorMessage != nil {
                    Section { musicBrainzStatusRow(hasRows: true) }
                }
            }
        }
        .musicDiscoverySearchListStyle()
    }

    /// How many rows from the bottom the next page starts loading.
    private static let pagingTriggerLookahead = 5

    /// The one place Discover explains why it has nothing, or nothing more, to show.
    ///
    /// Four outcomes that used to be one. Before this, a rate-limit refusal, a transport failure
    /// and a genuine no-such-artist all rendered as the same "No results" — so the app told users
    /// an artist did not exist whenever MusicBrainz happened to be busy, which it often is.
    @ViewBuilder
    private func musicBrainzStatusRow(hasRows: Bool) -> some View {
        if musicBrainz.isLoading || (isFetching && !hasRows) {
            HStack {
                ProgressView().tint(MusicDesign.accent)
                Text("Searching…")
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .padding(.leading, 8)
            }
            .listRowBackground(Color.clear)
        } else if musicBrainz.isRateLimited {
            Button {
                Task { await musicBrainz.retry(entity: entity) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MusicBrainz is busy right now.")
                            .font(.subheadline.weight(.medium))
                        Text("Tap to try again.")
                            .font(.caption)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        } else if let message = musicBrainz.errorMessage ?? searchError {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .listRowBackground(Color.clear)
        } else if !hasRows {
            Text("No results for \"\(trimmedQuery)\".")
                .font(.subheadline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .listRowBackground(Color.clear)
        }
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
        case .musicBrainzAlbum(let group):
            musicBrainzAlbumRow(group)
        case .musicBrainzSong(let song):
            musicBrainzSongRow(song)
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
            .coverZoomSource(
                id: ArtistPageInput.coverZoomPageId(forName: artist.name),
                style: .custom,
                cellCornerRadius: rowArtworkSide / 2,
            )
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
                primaryId: match.id,
                title: match.name,
                artworkURL: match.artworkURL,
                musicBrainzId: match.id,
            ))
            navigationPath.append(match.navTarget)
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
                    // MusicBrainz's disambiguation is what separates same-named artists
                    // ("Michigan/Ohio emo band"), which is exactly the ambiguity an artist
                    // row has to resolve for the user before they tap it.
                    Text(match.disambiguation.map { "Artist · \($0)" } ?? "Artist")
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
            .coverZoomSource(id: album.id, style: .custom)
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
            .coverZoomSource(id: track.albumId, style: .custom)
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

    /// Long-press menu for a server-catalog song row — the shared
    /// ``StandardSongMenuContent``, so a song offers the same actions here as it does in a
    /// playlist, on the artist page, or in the Now Playing queue.
    ///
    /// The two actions this surface had that the template did not — **Play** and **Add Album to
    /// Library** — are now optional callbacks on the template rather than a reason to keep a
    /// separate menu. Nothing was dropped in the convergence.
    @ViewBuilder
    private func serverSongContextMenu(_ track: Track) -> some View {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        StandardSongMenuContent(
            track: track,
            onPlay: {
                Task { @MainActor in
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playAlbum(library: lib, tracks: [track], startIndex: 0)
                }
            },
            onPlayNext: {
                Task { @MainActor in
                    try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [track])
                }
            },
            onAddToQueue: {
                Task { @MainActor in
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.addToQueue(library: lib, track: track, sourcePlaylistId: nil)
                }
            },
            onAddAlbumToLibrary: {
                Task { await addAlbum(app.albumSummary(for: track)) }
            },
            onFavorite: { app.toggleFavoriteTrack(id: track.id) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
            onAddToLibrary: app.isSongInLibrary(track.id)
                ? nil
                : { Task { await addTrack(track) } },
            onGoToAlbum: {
                navigationPath.append(SearchNavTarget.album(app.albumSummary(for: track)))
            },
            onGoToArtist: ArtistNavigation.isTappable(artist)
                ? { navigationPath.append(SearchNavTarget.namedArtist(track.artist)) }
                : nil,
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { Task { await app.removeSongFromLibrary(track) } }
                : nil
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
                // Deliberately NOT recorded into Recently Searched. An un-acquired release is not
                // a library entity, and storing it produced a recent row that navigated to an
                // album page titled with the literal placeholder "Album", no artwork, "Album not
                // found", and a Play button that did nothing.
                navigationPath.append(SearchNavTarget.acquire(result))
            } label: {
                HStack {
                    acquireRowArtworkAndTitles(result)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            acquireRowAccessory(result: result, job: job)
        }
        .musicChevronRowPadding()
        .padding(.vertical, songVerticalPadding)
        .listRowBackground(discoverRowBackground)
        .discoverySearchListRowChrome()
    }

    // MARK: - Hybrid: MusicBrainz album / song rows

    /// A MusicBrainz album row.
    ///
    /// Renders as a **server** album row when the connected server turns out to have the
    /// release, and as a request row otherwise. That substitution is the point: in the dedicated
    /// Albums tab every row comes from MusicBrainz, so without it an album already sitting on
    /// the user's own server would be offered as something to go and download.
    ///
    /// The request form reuses ``acquireRow`` rather than reimplementing it, by mapping the
    /// release group onto the same ``AcquisitionResult`` a plugin row carries. An album found by
    /// searching MusicBrainz is not a different kind of thing from an album found by searching
    /// the plugin — it needs the same Request pill, the same job state and the same detail view.
    @ViewBuilder
    private func musicBrainzAlbumRow(_ group: MusicBrainzReleaseGroup) -> some View {
        if let owned = serverAlbumsByReleaseKey[
            Self.releaseIdentityKey(title: group.title, artist: group.searchRowArtist)
        ] {
            serverAlbumRow(owned)
        } else {
            acquireRow(group.asSearchAcquisitionRelease.asSearchResult)
        }
    }

    /// A MusicBrainz song row, with the same server-substitution rule as
    /// ``musicBrainzAlbumRow(_:)``.
    @ViewBuilder
    private func musicBrainzSongRow(_ song: MusicBrainzSongRow) -> some View {
        if let owned = serverSongsByReleaseKey[
            Self.releaseIdentityKey(title: song.title, artist: song.artist)
        ] {
            serverSongRow(owned)
        } else {
            acquireRow(song.asAcquisitionResult)
        }
    }

    /// Server album hits indexed by release identity, so a MusicBrainz row can tell in O(1)
    /// whether the user already has the release.
    ///
    /// Built from ``serverResults`` — this search's own server hits — and never from
    /// `app.libraryAlbums`, which is the entire server catalogue and must not be scanned from a
    /// body (`Rules/swiftui-body-cost.md`). That is also the correct source: if the release is on
    /// the server, the server search found it.
    private var serverAlbumsByReleaseKey: [String: AlbumSummary] {
        var map: [String: AlbumSummary] = [:]
        for album in serverResults.albums {
            map[Self.releaseIdentityKey(title: album.title, artist: album.artist)] = album
        }
        return map
    }

    /// Server track hits indexed by title + artist, for the same substitution.
    private var serverSongsByReleaseKey: [String: Track] {
        var map: [String: Track] = [:]
        for song in serverResults.songs {
            map[Self.releaseIdentityKey(title: song.title, artist: song.artist)] = song
        }
        return map
    }

    /// The trailing control on a request row: what the backend says, or the way to ask.
    ///
    /// Every branch here is driven by a state the server reported. Note there is no
    /// percentage unless `hasDeterminateProgress` is set — a backend can say "downloading"
    /// without saying how far, and drawing a precise bar in that case would be the app making
    /// a number up, which is the whole complaint this pass exists to answer.
    @ViewBuilder
    private func acquireRowAccessory(result: AcquisitionResult, job: AcquisitionJob?) -> some View {
        if let job, job.status == .stalled {
            // Not a spinner and not a number. The backend says nothing is happening, so the row
            // says nothing is happening — that is the whole point of this pass.
            VStack(alignment: .trailing, spacing: 4) {
                Text("Nothing\nhappening")
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                Button("Try Again") {
                    Task { await requestResult(result) }
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(MusicDesign.accent)
            }
            .frame(width: 84, alignment: .trailing)
        } else if let job, !job.status.isTerminal {
            VStack(alignment: .trailing, spacing: 3) {
                // A bar and a percentage exist only when Lidarr supplied a fraction. Otherwise the
                // row shows the phase word alone — no bar, because there is nothing to fill it in
                // with that anyone measured.
                if let fraction = job.progress {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(MusicDesign.accent)
                        .frame(width: 56)
                    Text("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(MusicDesign.secondaryLabel)
                } else {
                    Text(job.status.displayTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
            }
            .frame(width: 72, alignment: .trailing)
        } else if let job, job.status == .notFound || job.status == .failed {
            // Terminal and unhappy. This is the state the app simply did not have before: a
            // search that came back empty looked identical to one still running, for ever.
            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    job.status == .notFound ? "Not found" : "Failed",
                    systemImage: job.status == .notFound ? "magnifyingglass" : "exclamationmark.circle.fill",
                )
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(job.status == .notFound ? MusicDesign.secondaryLabel : Color.red)
                Button("Try Again") {
                    Task { await requestResult(result) }
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(MusicDesign.accent)
            }
            .frame(width: 84, alignment: .trailing)
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
                acquireRowSubtitle(result)
            }
        }
    }

    /// Second line of a request row, with the **artist as its own tap target**.
    ///
    /// It used to be one baked string ("Single · Daniel Caesar"), so tapping the artist did
    /// nothing — the whole row just opened the request detail. The kind and the artist are now
    /// laid out separately and the artist routes to the artist page, the same as everywhere else
    /// in the app. A plugin-supplied `subtitle` (a quality or source hint) is still rendered
    /// verbatim, because that is not an artist and must not pretend to be tappable.
    @ViewBuilder
    private func acquireRowSubtitle(_ result: AcquisitionResult) -> some View {
        let artist = result.artists.first ?? result.artistLine
        if let subtitle = result.subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(songSubtitleFont)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Text("\(result.kindLabel ?? "Song") ·")
                    .font(songSubtitleFont)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                ArtistNameButton(
                    name: artist,
                    font: songSubtitleFont,
                    foreground: MusicDesign.secondaryLabel,
                ) {
                    navigationPath.append(SearchNavTarget.namedArtist(artist))
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
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
                                .coverZoomSource(id: recentZoomId(item), style: .custom)
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
                                .coverZoomSource(id: track.albumId, style: .custom)
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
                                .coverZoomSource(id: album.id, style: .custom)
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
                                .coverZoomSource(id: playlist.id, style: .custom)
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
                                .coverZoomSource(
                                    id: ArtistPageInput.coverZoomPageId(forName: artist.name),
                                    style: .custom,
                                )
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

    /// Zoom key mirroring ``tapRecent(_:)`` — songs route to their album detail, so they zoom
    /// on the album id; artists route to the artist page and take its name-derived key.
    private func recentZoomId(_ entity: RecentSearchEntity) -> String {
        switch entity.kind {
        case .song: return entity.secondaryId ?? ""
        case .album, .playlist: return entity.primaryId
        case .artist: return ArtistPageInput.coverZoomPageId(forName: entity.title)
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
            // An off-server artist must never be routed as a server artist id. Doing that is
            // what turned a saved MusicBrainz row into a page that queried the server for an id
            // it had never issued, and threw away the MBID the row was holding.
            if let mbid = entity.recoveredMusicBrainzId {
                navigationPath.append(SearchNavTarget.musicBrainzArtistId(id: mbid, name: entity.title))
            } else if entity.isOffServerArtist {
                navigationPath.append(SearchNavTarget.namedArtist(entity.title))
            } else {
                navigationPath.append(SearchNavTarget.artist(LibraryArtistSummary(
                    id: entity.primaryId,
                    name: entity.title,
                    artworkURL: entity.artworkURL,
                )))
            }
        }
    }

    private func submitSearch() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        if scope == .discover {
            scheduleHybridSearch(debounce: false)
            // An explicit submit is the user saying they are done typing, so the debounce has
            // nothing left to protect against. The one-second floor still applies in the queue.
            scheduleMusicBrainzSearch(debounce: false)
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

    /// Debounced fan-out to server-catalog search plus the optional acquisition plugin.
    ///
    /// The MusicBrainz side runs separately (``scheduleMusicBrainzSearch``) on a longer debounce,
    /// because it is rate-limited to one request per second and must not gate the server results.
    private func scheduleHybridSearch(debounce: Bool = true) {
        hybridSearchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            serverResults = .empty
            acquireResults = []
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
            isFetching = false
            return
        }

        let lib = app.activeLibrary
        let pluginOK = app.acquisitionConfigured && !app.effectiveOfflineMode
        let acquireOK = pluginOK && app.acquisitionCapabilities.supportsTrackSearch
        // An album-granularity plugin (Lidarr) has no track search, so a song-title query used to
        // reach nothing but `searchArtists` — which is why searching a single by its title returned
        // three artists and no way to request the song. Ask the plugin's album catalog too: a
        // single is a release, so the title resolves there.
        let albumAcquireOK = pluginOK && app.acquisitionCapabilities.granularity == .album

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
        // Artist rows no longer come from the plugin. A plugin answers from its own library or
        // its own fuzzy catalog lookup, which is a narrower and less reliable index of who
        // exists than MusicBrainz — and it has no notion of disambiguation, so two artists
        // sharing a name arrive indistinguishable. That search runs on its own longer debounce
        // (``scheduleMusicBrainzSearch``) because MusicBrainz is rate limited to one
        // request per second and must not be asked on every keystroke.
        let pluginAlbums: [AcquisitionRelease] = albumAcquireOK
            ? await acquisition.searchAlbums(query: query)
            : []
        if Task.isCancelled || trimmedQuery != query { return }

        var seenAcquireKeys = Set<String>()
        var mergedAcquire: [AcquisitionResult] = []
        for row in pluginAcquire where seenAcquireKeys.insert(row.request.requestKey).inserted {
            mergedAcquire.append(row)
        }
        // Releases already on the server used to be dropped here as well. That rule now lives in
        // `hybridRows` alongside the rest of the per-row suppression (T069), because it has to
        // cover releases arriving from *any* source, not just the plugin — including the server
        // album list disagreeing with itself.
        //
        // What stays here is the relevance floor, which is about this fetch rather than the feed:
        // `album/lookup` is a fuzzy catalog search and returns loosely related releases, and
        // anything matching neither the title nor the artist is noise at the foot of Top Results.
        let normalizedQuery = LibraryTrackMatcher.normalize(query)
        for release in pluginAlbums {
            guard Self.relevanceScore(
                title: release.title,
                artist: release.artist,
                normalizedQuery: normalizedQuery,
            ) > 0 else { continue }
            let row = release.asSearchResult
            guard seenAcquireKeys.insert(row.request.requestKey).inserted else { continue }
            mergedAcquire.append(row)
        }
        acquireResults = mergedAcquire
        if Task.isCancelled || trimmedQuery != query { return }
        isFetching = false
    }

    /// MusicBrainz artist search, on a deliberately long debounce.
    ///
    /// One second of no typing, matching the one-request-per-second budget: a shorter delay
    /// would queue a request per keystroke and every one of them would have to wait its turn
    /// behind the last, so the answer would arrive later, not sooner. The server-catalog search
    /// keeps its own 300 ms debounce and is unaffected — only this row set waits.
    private func scheduleMusicBrainzSearch(debounce: Bool = true) {
        musicBrainzTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty, !app.effectiveOfflineMode else {
            musicBrainz.clear()
            return
        }
        musicBrainzTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: UInt64(Self.musicBrainzDebounceSeconds * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await musicBrainz.start(query: q, entity: entity)
        }
    }

    /// Debounce before a MusicBrainz fan-out.
    ///
    /// Shorter than the second this used to wait, because cancelling a search now actually
    /// cancels the request (see ``MusicBrainzRequestQueue/perform(path:query:policy:)``). While
    /// abandoned requests still went out, a short debounce spent the whole one-per-second budget
    /// on prefixes nobody would see and the real answer arrived *later*. With cancellation
    /// honoured, an abandoned keystroke costs nothing and the wait only has to cover typing.
    private static let musicBrainzDebounceSeconds: Double = 0.6

    /// Loads the entity tab the user just switched to, if its first page is not already held.
    private func loadMusicBrainzTab() {
        musicBrainzTask?.cancel()
        guard !trimmedQuery.isEmpty, !app.effectiveOfflineMode else { return }
        musicBrainzTask = Task { @MainActor in
            await musicBrainz.ensureLoaded(entity: entity)
        }
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
    @State private var artistTarget: SearchNavTarget?

    private var artistsLine: String { result.artistLine }

    /// Where tapping the artist name should go.
    ///
    /// The MBID is preferred whenever the row carries one: it names exactly one artist, whereas
    /// a name has to be looked up and can land on a different act sharing it. The name is the
    /// fallback for rows that have no id at all.
    ///
    /// `nil` means the name is not navigable — an empty credit, or a compilation credited to
    /// "Various Artists", where a single artist page is not a meaningful destination. Those keep
    /// rendering as plain text, which is what the tappability gate has always been protecting.
    private var artistNavTarget: SearchNavTarget? {
        // Only navigate on a single credited artist. A multi-artist release has no one page to
        // land on, and picking the first would be a guess presented as a fact.
        guard result.artists.count == 1, let name = result.artists.first,
              ArtistNavigation.isTappable(name)
        else { return nil }
        if let mbid = result.request.artistMBID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mbid.isEmpty {
            return .musicBrainzArtistId(id: mbid, name: name)
        }
        return .namedArtist(name)
    }

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
                    // Reaching an album from search and finding no way through to its artist is
                    // exactly the moment the link is most wanted, since search is where you land
                    // when the artist did not come up on their own.
                    if let artistTargetValue = artistNavTarget {
                        Button {
                            artistTarget = artistTargetValue
                        } label: {
                            Text(artistsLine)
                                .font(.headline)
                                .foregroundStyle(MusicDesign.accent)
                                .multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the artist page")
                    } else {
                        Text(artistsLine)
                            .font(.headline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .multilineTextAlignment(.center)
                    }
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
        // Programmatic push rather than a NavigationLink around the label — the same pattern the
        // other detail screens use, and the one that does not fight the enclosing scroll view.
        .navigationDestination(item: $artistTarget) { target in
            switch target {
            case .musicBrainzArtistId(let id, let name):
                ArtistPageView(input: .musicBrainzArtistId(id: id, name: name))
            case .namedArtist(let name):
                ArtistPageView(input: .named(name))
            default:
                EmptyView()
            }
        }
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
                // Same rule as the row: a bar only when the backend gave a fraction.
                if let fraction = job.progress {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(MusicDesign.accent)
                        .frame(width: 220)
                    Text("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(MusicDesign.secondaryLabel)
                } else {
                    Text(job.status.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                if let message = job.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
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
