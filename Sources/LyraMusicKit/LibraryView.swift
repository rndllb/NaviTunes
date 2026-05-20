import SwiftUI

// MARK: - Recent item

private enum RecentLibraryItem: Identifiable {
    case album(AlbumSummary)
    case playlist(PlaylistSummary)

    var id: String {
        switch self {
        case .album(let a): return "album-\(a.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        }
    }

    var artworkURL: URL? {
        switch self {
        case .album(let a): return a.artworkURL
        case .playlist(let p): return p.artworkURL
        }
    }

    var title: String {
        switch self {
        case .album(let a): return a.title
        case .playlist(let p): return p.name
        }
    }

    var subtitle: String {
        switch self {
        case .album(let a): return a.artist
        case .playlist(let p):
            if let n = p.songCount { return n == 1 ? "1 song" : "\(n) songs" }
            return "Playlist"
        }
    }

    var libraryAddedDate: Date? {
        switch self {
        case .album(let a): return a.libraryAddedDate
        case .playlist(let p): return p.libraryAddedDate
        }
    }
}

// MARK: - Section config

struct LibrarySectionItem: Codable, Identifiable, Equatable {
    var id: String
    var isVisible: Bool
}

private let librarySectionDefaultOrder: [LibrarySectionItem] = [
    .init(id: "playlists",  isVisible: true),
    .init(id: "artists",    isVisible: true),
    .init(id: "albums",     isVisible: true),
    .init(id: "songs",      isVisible: true),
    .init(id: "genres",     isVisible: true),
    .init(id: "downloaded", isVisible: true),
]

private func decodeSections(_ raw: String) -> [LibrarySectionItem] {
    guard let data = raw.data(using: .utf8),
          let items = try? JSONDecoder().decode([LibrarySectionItem].self, from: data),
          !items.isEmpty else { return librarySectionDefaultOrder }
    return items
}

private func encodeSections(_ items: [LibrarySectionItem]) -> String {
    (try? String(data: JSONEncoder().encode(items), encoding: .utf8)) ?? ""
}

// MARK: - Row enum

private enum LibraryRow: String, CaseIterable, Identifiable {
    case playlists
    case artists
    case albums
    case songs
    case genres
    case downloaded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .genres: return "Genres"
        case .downloaded: return "Downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "mic"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        case .genres: return "paintbrush.pointed.fill"
        case .downloaded: return "arrow.down.circle.fill"
        }
    }
}

/// Apple Music **Library** tab: category rows + Recently Added grid.
struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage("library_section_config") private var sectionConfigRaw: String = ""
    @AppStorage("favoritedPlaylistIds") private var favoritedRaw: String = ""
    @State private var showNewPlaylistSheet = false
    @State private var showEditSections = false
    @State private var showFloatingHeader = true

    private let pinnedColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private let recentColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var pinnedPlaylistIds: Set<String> {
        Set(favoritedRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var pinnedPlaylists: [PlaylistSummary] {
        app.libraryPlaylists.filter { pinnedPlaylistIds.contains($0.id) }
    }

    private var recentItems: [RecentLibraryItem] {
        // Three date sources, all resolved against the in-memory catalogs:
        //   1. Albums explicitly in the magic-playlist comment → per-user add date.
        //   2. Playlists explicitly in the magic-playlist comment → per-user add date.
        //   3. Owned playlists from `getPlaylists` → server `created` date (since making
        //      a playlist counts as adding it). Deduped against (2) by id; the explicit
        //      entry date wins when both exist.
        let albumsById = Dictionary(uniqueKeysWithValues: app.libraryAlbums.map { ($0.id, $0) })
        let playlistsById = Dictionary(uniqueKeysWithValues: app.libraryPlaylists.map { ($0.id, $0) })

        var dated: [(item: RecentLibraryItem, added: Date)] = []

        for entry in app.libraryAlbumEntries {
            if let album = albumsById[entry.id] {
                dated.append((.album(album), entry.added))
            }
        }

        var seenPlaylistIds: Set<String> = []
        for entry in app.libraryPlaylistEntries {
            if let playlist = playlistsById[entry.id] {
                dated.append((.playlist(playlist), entry.added))
                seenPlaylistIds.insert(entry.id)
            }
        }
        for playlist in app.libraryPlaylists where !seenPlaylistIds.contains(playlist.id) {
            // Use `.distantPast` when the server didn't return a `created` date so the
            // playlist still appears in Recently Added (just sorted to the bottom).
            dated.append((.playlist(playlist), playlist.libraryAddedDate ?? .distantPast))
        }

        return dated
            .sorted { $0.added > $1.added }
            .prefix(60)
            .map(\.item)
    }

    private var orderedVisibleRows: [LibraryRow] {
        decodeSections(sectionConfigRaw)
            .filter(\.isVisible)
            .compactMap { LibraryRow(rawValue: $0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                libraryScrollMainContent
            }
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: 72,
                showFloatingHeader: $showFloatingHeader
            ))
            .safeAreaInset(edge: .top, spacing: 0) {
                if showFloatingHeader {
                    libraryHeaderBar
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showFloatingHeader)
            .background(MusicDesign.background)
            .musicNewTabNavigationChrome()
            .musicNewTabRootHidesNavigationBar()
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .refreshable {
                await app.refreshLibraryAlbums()
            }
            .sheet(isPresented: $showNewPlaylistSheet) {
                NewPlaylistNameSheet()
                    .environmentObject(app)
            }
            .sheet(isPresented: $showEditSections) {
                EditLibrarySectionsSheet(configRaw: $sectionConfigRaw)
            }
        }
        .tint(MusicDesign.accent)
    }

    private var libraryHeaderBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Library")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button {
                    showNewPlaylistSheet = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("New playlist")

                Menu {
                    Button("Edit Sections") {
                        showEditSections = true
                    }
                    Button("Refresh library") {
                        Task { await app.refreshLibraryAlbums() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More library actions")
            }
            .musicGlassCapsuleInteractiveChrome()

            MusicToolbarSettingsAvatarLink(diameter: 45)
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.bottom, 10)
    }

    private var libraryScrollMainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pinnedPlaylists.isEmpty {
                LazyVGrid(columns: pinnedColumns, spacing: 20) {
                    ForEach(pinnedPlaylists) { playlist in
                        NavigationLink {
                            ServerPlaylistDetailView(playlist: playlist)
                        } label: {
                            pinnedPlaylistCell(playlist)
                        }
                        .buttonStyle(.plain)
                        .libraryPlaylistContextMenu(playlist)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }

            ForEach(orderedVisibleRows) { row in
                libraryRowLink(row)
            }

            Text("Recently Added")
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 14)

            recentlyAddedSectionBody
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func libraryRowLink(_ row: LibraryRow) -> some View {
        VStack(spacing: 0) {
            switch row {
            case .albums:
                NavigationLink {
                    AlbumsGridView()
                } label: {
                    libraryRowLabel(row)
                }
                .buttonStyle(.plain)
            case .songs:
                NavigationLink {
                    LibrarySongsView()
                } label: {
                    libraryRowLabel(row)
                }
                .buttonStyle(.plain)
            case .playlists:
                NavigationLink {
                    LibraryPlaylistsView()
                } label: {
                    libraryRowLabel(row)
                }
                .buttonStyle(.plain)
            case .artists:
                NavigationLink {
                    LibraryArtistsView()
                } label: {
                    libraryRowLabel(row)
                }
                .buttonStyle(.plain)
            case .genres:
                NavigationLink {
                    LibraryGenresView()
                } label: {
                    libraryRowLabel(row)
                }
                .buttonStyle(.plain)
            case .downloaded:
                NavigationLink {
                    LibraryDownloadedView()
                } label: {
                    libraryRowLabel(row)
                }
                .buttonStyle(.plain)
            }
            Divider()
                .background(MusicDesign.separator)
                .padding(.leading, 56)
        }
    }

    private func libraryRowLabel(_ row: LibraryRow) -> some View {
        HStack(spacing: 16) {
            Image(systemName: row.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.accent)
                .frame(width: 28, alignment: .center)
            Text(row.title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// Three-way state for the Recently Added grid: still resolving membership → spinner,
    /// resolved but the user hasn't added anything → empty CTA, populated → grid.
    @ViewBuilder
    private var recentlyAddedSectionBody: some View {
        if recentItems.isEmpty {
            if app.isResolvingLibraryMembership || app.libraryMagicPlaylistId == nil {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else {
                recentlyAddedEmptyState
            }
        } else {
            LazyVGrid(columns: recentColumns, spacing: 20) {
                ForEach(recentItems) { item in
                    recentItemLink(item)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var recentlyAddedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.square.on.square")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .padding(.bottom, 4)
            Text("Nothing Added Yet")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Long-press an album or playlist and tap **Add to Library** to see it here.")
                .font(.subheadline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    @ViewBuilder
    private func recentItemLink(_ item: RecentLibraryItem) -> some View {
        switch item {
        case .album(let album):
            NavigationLink { ServerPlaylistDetailView(album: album, librarySource: true) } label: { recentCell(item) }
                .buttonStyle(.plain)
                .libraryAlbumContextMenu(album)
        case .playlist(let playlist):
            NavigationLink { ServerPlaylistDetailView(playlist: playlist) } label: { recentCell(item) }
                .buttonStyle(.plain)
                .libraryPlaylistContextMenu(playlist)
        }
    }

    private func recentCell(_ item: RecentLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: item.artworkURL, cornerRadius: MusicDesign.gridAlbumCorner)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
        }
    }

    private func pinnedPlaylistCell(_ playlist: PlaylistSummary) -> some View {
        VStack(spacing: 8) {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: MusicDesign.gridAlbumCorner)
                .aspectRatio(1, contentMode: .fit)
            Text(playlist.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
    }
}

/// Library → **Playlists** (favorite songs as a playlist; Jellyfin favorites sync with the server).
private enum PlaylistFilter: String, CaseIterable {
    case all = "All Playlists"
    case favorites = "Favorites"
    case downloads = "Downloads"
}

private enum PlaylistSort: String, CaseIterable {
    case title = "Title"
    case dateAdded = "Date Added"
    case lastPlayed = "Last Played"
    case updatedDate = "Updated Date"
    case playlistType = "Playlist Type"
}

private enum PlaylistViewStyle { case list, grid }

struct LibraryPlaylistsView: View {
    @EnvironmentObject private var app: AppModel

    @State private var showNewPlaylistSheet = false
    @State private var filter: PlaylistFilter = .all
    @State private var sort: PlaylistSort = .title
    @State private var viewStyle: PlaylistViewStyle = .list
    @AppStorage("favoritedPlaylistIds") private var favoritedRaw: String = ""

    private let gridColumns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    private let favoriteSongsId = "__favorite_songs__"

    private var favoritedIds: Set<String> {
        Set(favoritedRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private func toggleFavorite(_ id: String) {
        var ids = favoritedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        favoritedRaw = ids.joined(separator: ",")
    }

    private var favoriteSongsEntry: PlaylistSummary {
        let count = app.favoriteTrackIds.count
        return PlaylistSummary(
            id: favoriteSongsId,
            name: "Favorite Songs",
            songCount: count > 0 ? count : nil,
            artworkURL: nil
        )
    }

    private var displayedPlaylists: [PlaylistSummary] {
        let server: [PlaylistSummary]
        switch filter {
        case .all:
            server = app.libraryPlaylists
        case .favorites:
            server = app.libraryPlaylists.filter { favoritedIds.contains($0.id) }
        case .downloads:
            let cached = app.offline.downloadedTrackIds
            server = app.libraryPlaylists.filter { playlist in
                app.discoveryLibraryTracks.contains { cached.contains($0.id) && $0.albumId == playlist.id }
            }
        }
        let sorted: [PlaylistSummary]
        switch sort {
        case .title:
            sorted = server.sorted(by: pinnedFirstThenTitle)
        case .playlistType:
            sorted = server.sorted { lhs, rhs in
                let lhsPinned = favoritedIds.contains(lhs.id)
                let rhsPinned = favoritedIds.contains(rhs.id)
                if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
                let lp = lhs.isPublic ?? false
                let rp = rhs.isPublic ?? false
                if lp != rp { return lp && !rp }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        default:
            sorted = server.enumerated().sorted { lhs, rhs in
                let lhsPinned = favoritedIds.contains(lhs.element.id)
                let rhsPinned = favoritedIds.contains(rhs.element.id)
                if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        return [favoriteSongsEntry] + sorted
    }

    private func pinnedFirstThenTitle(_ lhs: PlaylistSummary, _ rhs: PlaylistSummary) -> Bool {
        let lhsPinned = favoritedIds.contains(lhs.id)
        let rhsPinned = favoritedIds.contains(rhs.id)
        if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    @ViewBuilder
    private func destination(for playlist: PlaylistSummary) -> some View {
        if playlist.id == favoriteSongsId {
            FavoritePlaylistView()
        } else {
            ServerPlaylistDetailView(playlist: playlist)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if displayedPlaylists.isEmpty {
                    ContentUnavailableView(
                        filter == .favorites ? "No Favorited Playlists" : "No Downloaded Playlists",
                        systemImage: filter == .favorites ? "star" : "arrow.down.circle",
                        description: Text(filter == .favorites
                            ? "Long-press a playlist to add it to Favorites."
                            : "Download songs from a playlist to see it here.")
                    )
                    .padding(.top, 40)
                } else if viewStyle == .grid {
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(displayedPlaylists) { playlist in
                            NavigationLink { destination(for: playlist) } label: {
                                gridCell(playlist)
                            }
                            .buttonStyle(.plain)
                            .libraryPlaylistContextMenu(playlist)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                } else {
                    ForEach(displayedPlaylists) { playlist in
                        VStack(spacing: 0) {
                            NavigationLink { destination(for: playlist) } label: {
                                listRow(playlist)
                            }
                            .buttonStyle(.plain)
                            .libraryPlaylistContextMenu(playlist)

                            Divider()
                                .background(MusicDesign.separator)
                                .padding(.leading, 88)
                        }
                    }
                }
            }
        }
        .background(MusicDesign.background)
        .navigationTitle("Playlists")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                Button {
                    showNewPlaylistSheet = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("New playlist")

                Menu {
                    ForEach(PlaylistFilter.allCases, id: \.self) { f in
                        Button {
                            filter = f
                        } label: {
                            HStack {
                                Text(f.rawValue)
                                Spacer(minLength: 16)
                                if filter == f { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.primary)
                }
                .menuOrder(.fixed)

                Menu {
                    Section("View") {
                        Button {
                            viewStyle = .list
                        } label: {
                            HStack {
                                Label("List", systemImage: "list.bullet")
                                Spacer(minLength: 16)
                                if viewStyle == .list { Image(systemName: "checkmark") }
                            }
                        }
                        Button {
                            viewStyle = .grid
                        } label: {
                            HStack {
                                Label("Grid", systemImage: "square.grid.2x2")
                                Spacer(minLength: 16)
                                if viewStyle == .grid { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Section("Sort By") {
                        ForEach(PlaylistSort.allCases, id: \.self) { s in
                            Button {
                                sort = s
                            } label: {
                                HStack {
                                    Text(s.rawValue)
                                    Spacer(minLength: 16)
                                    if sort == s { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                }
                .menuOrder(.fixed)
            }
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistNameSheet().environmentObject(app)
        }
        .task { await app.refreshLibraryPlaylists() }
        .refreshable { await app.refreshLibraryPlaylists() }
    }

    private func listRow(_ playlist: PlaylistSummary) -> some View {
        HStack(spacing: 16) {
            playlistArtworkFixed(playlist, size: 52, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitleText(playlist))
                    .font(.caption)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
            Spacer(minLength: 8)
            if favoritedIds.contains(playlist.id) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(MusicDesign.accent)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func playlistArtworkFixed(_ playlist: PlaylistSummary, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if playlist.id == favoriteSongsId {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MusicDesign.accent.opacity(0.18))
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(MusicDesign.accent)
            }
            .frame(width: size, height: size)
        } else {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: cornerRadius)
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func playlistArtworkFill(_ playlist: PlaylistSummary, cornerRadius: CGFloat) -> some View {
        if playlist.id == favoriteSongsId {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MusicDesign.accent.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)
                Image(systemName: "star.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(MusicDesign.accent)
            }
        } else {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: cornerRadius)
        }
    }

    private func gridCell(_ playlist: PlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            playlistArtworkFill(playlist, cornerRadius: MusicDesign.gridAlbumCorner)
            Text(playlist.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(subtitleText(playlist))
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
        }
    }

    private func subtitleText(_ playlist: PlaylistSummary) -> String {
        if let n = playlist.songCount { return n == 1 ? "1 song" : "\(n) songs" }
        return "Playlist"
    }
}

/// Tracks starred as favorites (``LibraryPlaylistsView`` → Favorite Songs).
struct FavoritePlaylistView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var navigateAlbum: AlbumSummary?
    @State private var trackPendingDownloadedDelete: Track?

    private var filtered: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.albumTitle.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            Section {
                searchSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 14, trailing: 20))

                playShuffleRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
            }

            if isLoading, tracks.isEmpty {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if let loadError, tracks.isEmpty {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .padding(.horizontal, 20)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No favorite songs",
                    systemImage: "star",
                    description: Text(
                        searchText.isEmpty
                            ? "For Navidrome this matches Favourites (starred songs and albums). Jellyfin uses audio favorites."
                            : "Nothing matches your search."
                    )
                )
                .padding(.top, 32)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, track in
                    songRow(track, showsBottomDivider: index < filtered.count - 1)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .navigationTitle("Favorite Songs")
        .musicNavigationBarTitleDisplayMode(.large)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
        }
        .task { await load() }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .onChange(of: app.favoriteTrackIds) { _, newIds in
            guard !tracks.isEmpty else { return }
            // Empty ID snapshots happen when server refresh fails silently; reloading avoids wiping a good list.
            if newIds.isEmpty {
                Task { await load() }
                return
            }
            tracks = tracks.filter { newIds.contains($0.id) }
        }
        .downloadedTrackDeleteSheet(
            track: $trackPendingDownloadedDelete,
            app: app,
            offline: offline
        )
    }

    private var searchSection: some View {
        LibrarySearchPill(prompt: "Search", text: $searchText)
    }

    private var playShuffleRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: filtered.isEmpty,
            onPlay: { Task { await playAll() } },
            onShuffle: { Task { await shuffleAll() } },
        )
    }

    private func songRow(_ track: Track, showsBottomDivider: Bool) -> some View {
        LibrarySongRow(
            track: track,
            itemSize: app.songListItemSize,
            isFavorite: app.favoriteTrackIds.contains(track.id),
            offlineDownload: offline.activeDownloads[track.id],
            isOfflineCached: app.offline.downloadedTrackIds.contains(track.id),
            onPlay: { Task { await play(track: track) } },
            onDownload: { Task { await cacheOffline(track: track) } },
            onCancelOfflineDownload: { app.offline.cancelDownload(trackId: track.id) },
            onFavorite: { app.toggleFavoriteTrack(id: track.id) },
            onPlayNext: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playNext(library: lib, track: track)
                }
            },
            onGoToAlbum: { navigateAlbum = app.albumSummary(for: track) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { Task { await app.removeSongFromLibrary(track) } } : nil,
            onDeleteFromLibrary: { app.beginLibraryTrackDeletion(track) },
            canDeleteFromLibrary: app.canDeleteFromLibrary,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                ? { try? app.offline.remove(trackId: track.id) } : nil,
            showsBottomDivider: showsBottomDivider,
            onPresentDownloadedDeleteSheet: {
                trackPendingDownloadedDelete = track
            }
        )
        .equatable()
        .librarySongListRowStyle()
    }

    private func cacheOffline(track: Track) async {
        guard let lib = app.activeLibrary else { return }
        do {
            let url = try lib.offlineDownloadURL(for: track)
            try await app.offline.cache(track: track, remote: url, headers: lib.httpHeadersForMediaRequests())
        } catch is CancellationError {
            return
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func load() async {
        guard app.isSignedIn else {
            loadError = "Sign in to see favorites."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            tracks = try await app.favoritePlaylistTracks()
        } catch {
            loadError = error.localizedDescription
            tracks = []
        }
    }

    private func playAll() async {
        guard let lib = app.activeLibrary, !filtered.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: filtered, startIndex: 0)
    }

    private func shuffleAll() async {
        guard let lib = app.activeLibrary, !filtered.isEmpty else { return }
        let shuffled = filtered.shuffled()
        try? await app.player.playAlbum(library: lib, tracks: shuffled, startIndex: 0)
    }

    private func play(track: Track) async {
        guard let lib = app.activeLibrary else { return }
        guard let idx = filtered.firstIndex(where: { $0.id == track.id }) else { return }
        try? await app.player.playAlbum(library: lib, tracks: filtered, startIndex: idx)
    }
}



// MARK: - Edit Sections Sheet

private struct EditLibrarySectionsSheet: View {
    @Binding var configRaw: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [LibrarySectionItem] = []

    private func row(for item: LibrarySectionItem) -> LibraryRow? {
        LibraryRow(rawValue: item.id)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($items) { $item in
                    HStack(spacing: 16) {
                        Button {
                            item.isVisible.toggle()
                        } label: {
                            Image(systemName: item.isVisible ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(item.isVisible ? Color.primary : MusicDesign.secondaryLabel, MusicDesign.accent)
                        }
                        .buttonStyle(.plain)

                        if let r = row(for: item) {
                            Image(systemName: r.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(MusicDesign.accent)
                                .frame(width: 28, alignment: .center)
                            Text(r.title)
                                .font(.body)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    items.move(fromOffsets: from, toOffset: to)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Library")
            .musicNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: MusicToolbar.trailingItemPlacement) {
                    Button {
                        configRaw = encodeSections(items)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .onAppear {
            items = decodeSections(configRaw)
        }
    }
}

// MARK: - Downloaded

struct LibraryDownloadedView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @State private var searchText = ""
    @State private var navigateAlbum: AlbumSummary?
    @State private var navigateAlbumScrollToTrackId: String?
    @State private var trackPendingDownloadedDelete: Track?

    private let albumColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var downloadedTracks: [Track] {
        app.tracksForDownloadedLibrary()
    }

    private var filtered: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return downloadedTracks }
        return downloadedTracks.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.albumTitle.lowercased().contains(q)
        }
    }

    private var downloadedAlbums: [AlbumSummary] {
        var seen = Set<String>()
        var albums: [AlbumSummary] = []
        for track in filtered {
            if !seen.contains(track.albumId) {
                seen.insert(track.albumId)
                albums.append(resolvedAlbumSummary(for: track))
            }
        }
        return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if downloadedTracks.isEmpty {
                ContentUnavailableView(
                    app.offline.downloadedTrackIds.isEmpty ? "No Downloads" : "Loading Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        app.offline.downloadedTrackIds.isEmpty
                            ? "Swipe a library song right-to-left and tap Download to save it for offline playback."
                            : "Open the app once while online to refresh download metadata, or sync your library."
                    )
                )
                .padding(.top, 48)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    searchBar
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 14, trailing: 20))

                    playShuffleRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
                }

                if !downloadedAlbums.isEmpty {
                    Section {
                        LazyVGrid(columns: albumColumns, spacing: 16) {
                            ForEach(downloadedAlbums) { album in
                                Button {
                                    openDownloadedAlbum(album)
                                } label: {
                                    albumCell(album)
                                }
                                .buttonStyle(.plain)
                                .libraryAlbumContextMenu(album)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 24, trailing: 20))
                    } header: {
                        sectionLabel("Albums")
                    }
                }

                if filtered.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                        .padding(.top, 32)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, track in
                            songRow(track, showsBottomDivider: index < filtered.count - 1)
                        }
                    } header: {
                        sectionLabel("Songs")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .navigationTitle("Downloaded")
        .musicNavigationBarTitleDisplayMode(.large)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(
                album: album,
                librarySource: true,
                scrollToTrackId: navigateAlbumScrollToTrackId
            )
        }
        .onChange(of: navigateAlbum?.id) { _, albumId in
            if albumId == nil {
                navigateAlbumScrollToTrackId = nil
            }
        }
        .onAppear {
            app.offline.backfillRecordsIfMissing(knownTracks: app.discoveryLibraryTracks)
            app.offline.reloadDownloadedTrackIdsFromManifest()
        }
        .onChange(of: offline.downloadedTrackIds) { _, _ in
            app.offline.backfillRecordsIfMissing(knownTracks: app.discoveryLibraryTracks)
        }
        .downloadedTrackDeleteSheet(
            track: $trackPendingDownloadedDelete,
            app: app,
            offline: offline
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.bottom, 4)
    }

    private var searchBar: some View {
        LibrarySearchPill(prompt: "Search downloads", text: $searchText, showsMic: false)
    }

    private var playShuffleRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: filtered.isEmpty,
            onPlay: { Task { await playAll() } },
            onShuffle: { Task { await shuffleAll() } },
        )
    }

    private func openDownloadedAlbum(_ album: AlbumSummary, scrollToTrackId: String? = nil) {
        navigateAlbumScrollToTrackId = scrollToTrackId
        navigateAlbum = album
    }

    private func isTrackOfflineOnDevice(_ track: Track) -> Bool {
        app.offline.downloadedTrackIds.contains(track.id)
            && app.offline.localFile(for: track.id) != nil
    }

    private func albumCell(_ album: AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: app.resolvedArtworkURL(for: album), cornerRadius: MusicDesign.gridAlbumCorner)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
        }
    }

    private func songRow(_ track: Track, showsBottomDivider: Bool) -> some View {
        LibrarySongRow(
            track: track,
            artworkURL: app.resolvedArtworkURL(for: track),
            itemSize: app.songListItemSize,
            isFavorite: app.favoriteTrackIds.contains(track.id),
            offlineDownload: offline.activeDownloads[track.id],
            isOfflineCached: isTrackOfflineOnDevice(track),
            onPlay: { Task { await play(track: track) } },
            onDownload: {},
            onCancelOfflineDownload: {},
            onFavorite: { app.toggleFavoriteTrack(id: track.id) },
            onPlayNext: {
                Task {
                    try? await app.player.playNext(library: app.activeLibrary, track: track)
                }
            },
            onGoToAlbum: {
                openDownloadedAlbum(resolvedAlbumSummary(for: track), scrollToTrackId: track.id)
            },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { Task { await app.removeSongFromLibrary(track) } } : nil,
            onDeleteFromLibrary: { app.beginLibraryTrackDeletion(track) },
            canDeleteFromLibrary: app.canDeleteFromLibrary,
            onRemoveDownload: { try? app.offline.remove(trackId: track.id) },
            isInLibrary: app.isSongInLibrary(track.id),
            showsBottomDivider: showsBottomDivider,
            onPresentDownloadedDeleteSheet: {
                trackPendingDownloadedDelete = track
            }
        )
        .equatable()
        .librarySongListRowStyle()
    }

    private func resolvedAlbumSummary(for track: Track) -> AlbumSummary {
        if let cached = app.libraryAlbums.first(where: { $0.id == track.albumId }) {
            var album = cached
            if let art = app.resolvedArtworkURL(for: cached) {
                album = AlbumSummary(
                    id: album.id,
                    title: album.title,
                    artist: album.artist,
                    artworkURL: art,
                    trackCount: album.trackCount,
                    libraryAddedDate: album.libraryAddedDate,
                    genres: album.genres,
                    releaseYear: album.releaseYear,
                )
            }
            return album
        }
        return AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: app.resolvedArtworkURL(for: track),
            trackCount: nil,
            libraryAddedDate: nil,
            genres: track.genres,
            releaseYear: track.releaseYear
        )
    }

    private func play(track: Track) async {
        guard let idx = filtered.firstIndex(where: { $0.id == track.id }) else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: filtered, startIndex: idx)
    }

    private func playAll() async {
        guard !filtered.isEmpty else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: filtered, startIndex: 0)
    }

    private func shuffleAll() async {
        guard !filtered.isEmpty else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: filtered.shuffled(), startIndex: 0)
    }
}

struct LibraryPlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(MusicDesign.accent)
            Text("\(title) isn’t available yet in Lyra Music.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MusicDesign.background)
        .navigationTitle(title)
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
    }
}

/// Full album grid (Music-style square art + two-line captions).
struct AlbumsGridView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showLoadError = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    /// Albums the user has added to their Lyra library, resolved against the cached
    /// catalog. Newest-added first (per the magic playlist's per-album timestamps).
    private var libraryAlbums: [AlbumSummary] {
        let entriesById = Dictionary(uniqueKeysWithValues: app.libraryAlbumEntries.map { ($0.id, $0.added) })
        let albumsById = Dictionary(uniqueKeysWithValues: app.libraryAlbums.map { ($0.id, $0) })
        return app.libraryAlbumEntries
            .compactMap { entry in albumsById[entry.id] }
            .sorted { lhs, rhs in
                (entriesById[lhs.id] ?? .distantPast) > (entriesById[rhs.id] ?? .distantPast)
            }
    }

    var body: some View {
        ScrollView {
            if libraryAlbums.isEmpty, app.libraryAlbumsLoadError == nil, !app.libraryAlbumEntries.isEmpty {
                // Catalog hasn't caught up to membership yet — wait for the bootstrap merge.
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if libraryAlbums.isEmpty {
                ContentUnavailableView(
                    "No Albums in Library",
                    systemImage: "square.stack",
                    description: Text("Long-press an album and tap Add to Library to start your collection.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(libraryAlbums) { album in
                        NavigationLink {
                            ServerPlaylistDetailView(album: album, librarySource: true)
                        } label: {
                            AlbumGridCell(album: album)
                        }
                        .buttonStyle(.plain)
                        .libraryAlbumContextMenu(album)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(MusicDesign.background)
        .navigationTitle("Albums")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await app.refreshLibraryAlbums() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.primary)
                }
            }
        }
        .alert("Could not load", isPresented: $showLoadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.libraryAlbumsLoadError ?? "")
        }
        .onChange(of: app.libraryAlbumsLoadError) { _, new in
            showLoadError = new != nil && app.libraryAlbums.isEmpty
        }
        .refreshable {
            await app.refreshLibraryAlbums()
        }
    }
}

private struct AlbumGridCell: View {
    let album: AlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: MusicDesign.albumCorner)
            Text(album.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
        }
    }
}

/// Albums in the cached library whose artist string matches (case-insensitive). Pushed from Now Playing → artist name.
struct ArtistAlbumsView: View {
    @EnvironmentObject private var app: AppModel
    let artistName: String

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    private var albums: [AlbumSummary] {
        let key = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        return app.libraryAlbums
            .filter {
                $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(key) == .orderedSame
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            if albums.isEmpty {
                ContentUnavailableView(
                    "No albums here",
                    systemImage: "music.note.list",
                    description: Text("No albums by this artist appear in your library cache yet.")
                )
                .padding(.top, 48)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink {
                            ServerPlaylistDetailView(album: album, librarySource: true)
                        } label: {
                            AlbumGridCell(album: album)
                        }
                        .buttonStyle(.plain)
                        .libraryAlbumContextMenu(album)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(MusicDesign.background)
        .navigationTitle(artistName)
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
    }
}
