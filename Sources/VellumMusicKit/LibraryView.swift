import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    @AppStorage(LibraryPinStore.storageKey) private var pinnedStorage: String = "[]"
    @State private var showNewPlaylistSheet = false
    @State private var showEditSections = false
    @State private var showFloatingHeader = true
    @State private var navigationPath = NavigationPath()
    private let pinnedColumns = MusicDesign.libraryHubGridColumns(count: 3)
    private let recentColumns = MusicDesign.libraryHubGridColumns(count: 2)

    private var pinnedItems: [LibraryPinnedItem] {
        LibraryPinStore.resolvedItems(raw: pinnedStorage, app: app)
    }

    private var recentItems: [RecentLibraryItem] {
        // Three date sources, all resolved against the in-memory catalogs:
        //   1. Albums explicitly in the magic-playlist comment → per-user add date.
        //   2. Playlists explicitly in the magic-playlist comment → per-user add date.
        //   3. Owned playlists from `getPlaylists` → server `created` date (since making
        //      a playlist counts as adding it). Deduped against (2) by id; the explicit
        //      entry date wins when both exist.
        // Resolve through AppModel's prebuilt id indexes. Mapping `libraryAlbums` (the whole
        // server catalog) into a dictionary here used to run on every body pass.
        var dated: [(item: RecentLibraryItem, added: Date)] = []

        for entry in app.libraryAlbumEntries {
            if let album = app.catalogAlbum(id: entry.id) {
                dated.append((.album(album), entry.added))
            }
        }

        var seenPlaylistIds: Set<String> = []
        for entry in app.libraryPlaylistEntries {
            if let playlist = app.libraryPlaylist(id: entry.id) {
                dated.append((.playlist(playlist), entry.added))
                seenPlaylistIds.insert(entry.id)
            }
        }
        for playlist in app.libraryPlaylists where !seenPlaylistIds.contains(playlist.id) {
            // Prefer the most recent of the server `created` date and the local "created in
            // this app" stamp, so a freshly-made playlist sorts to the top even before the
            // server reports a date. Falls back to `.distantPast` when neither is known.
            let added = [playlist.libraryAddedDate, app.localPlaylistCreatedDate(playlist.id)]
                .compactMap { $0 }
                .max() ?? .distantPast
            dated.append((.playlist(playlist), added))
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
        NavigationStack(path: $navigationPath) {
            ScrollView {
                libraryScrollMainContent
            }
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: MusicTabFloatingHeaderScrollModifier.defaultSlack,
                showFloatingHeader: $showFloatingHeader
            ))
            .musicTabFloatingHeaderInset(isVisible: showFloatingHeader) {
                libraryHeaderBar
            }
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
#if os(iOS)
                    .presentationDetents([.large])
#endif
            }
            .sheet(isPresented: $showEditSections) {
                EditLibrarySectionsSheet(configRaw: $sectionConfigRaw)
            }
            .deepLinkPush(tab: .library, path: $navigationPath)
        }
        .coverZoomContext()
        .tint(MusicDesign.accent)
        .onAppear {
            LibraryPinStore.migrateLegacyPlaylistPinsIfNeeded(storage: &pinnedStorage)
        }
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
        // Resolved once per pass — `pinnedItems` and `orderedVisibleRows` each decode JSON,
        // and the row list was previously decoded again per row by the divider check.
        let pinned = pinnedItems
        let rows = orderedVisibleRows
        return VStack(alignment: .leading, spacing: 0) {
            if !pinned.isEmpty {
                LazyVGrid(columns: pinnedColumns, spacing: 20) {
                    ForEach(pinned) { item in
                        NavigationLink {
                            pinnedItemDestination(item)
                        } label: {
                            pinnedItemCell(item, zoomId: pinnedItemZoomId(item))
                                .coverZoomSource(
                                    id: pinnedItemZoomId(item),
                                    style: pinnedUsesCustomZoom(item) ? .custom : .system
                                )
                        }
                        .buttonStyle(.plain)
                        .libraryPinnedItemContextMenu(item, pinnedStorage: $pinnedStorage)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                libraryRowLink(row, showsDivider: showsLibraryHubRowDivider(at: index, row: row, in: rows))
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

    /// Inset divider after each hub row; **Downloaded** always gets one before Recently Added.
    private func showsLibraryHubRowDivider(at index: Int, row: LibraryRow, in rows: [LibraryRow]) -> Bool {
        if row == .downloaded { return true }
        return index < rows.count - 1
    }

    @ViewBuilder
    private func libraryRowLink(_ row: LibraryRow, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
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
            }
            .musicChevronRowDivider(.symbolIcon, shows: showsDivider)
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
        let items = recentItems
        if items.isEmpty {
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
                ForEach(items) { item in
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
            NavigationLink { ServerPlaylistDetailView(album: album, librarySource: true) } label: {
                recentCell(item, zoomId: album.id).coverZoomSource(id: album.id, style: .custom)
            }
                .buttonStyle(.plain)
                .libraryAlbumContextMenu(album)
        case .playlist(let playlist):
            NavigationLink { ServerPlaylistDetailView(playlist: playlist) } label: {
                recentCell(item, zoomId: playlist.id).coverZoomSource(id: playlist.id, style: .custom)
            }
                .buttonStyle(.plain)
                .libraryPlaylistContextMenu(playlist)
        }
    }

    private func recentCell(_ item: RecentLibraryItem, zoomId: String) -> some View {
        LibraryHubGridCell(title: item.title, subtitle: item.subtitle) {
            // Same anchor as the 52pt playlist rows, on a much larger square grid cell — the
            // animator derives everything from the measured rect, so no size is baked in.
            AlbumArtworkView(url: resolvedRecentArtworkURL(for: item), cornerRadius: MusicDesign.gridAlbumCorner)
                .coverZoomCellAnchor(id: zoomId, cornerRadius: MusicDesign.gridAlbumCorner)
        }
    }

    private func resolvedRecentArtworkURL(for item: RecentLibraryItem) -> URL? {
        switch item {
        case .album(let album):
            return app.resolvedArtworkURL(for: album)
        case .playlist(let playlist):
            return app.resolvedArtworkURL(for: playlist)
        }
    }

    @ViewBuilder
    private func pinnedItemDestination(_ item: LibraryPinnedItem) -> some View {
        switch item {
        case .album(let album):
            ServerPlaylistDetailView(album: album, librarySource: true)
        case .playlist(let playlist):
            if playlist.id == "__favorite_songs__" {
                FavoritePlaylistView()
            } else {
                ServerPlaylistDetailView(playlist: playlist)
            }
        case .track(let track):
            ServerPlaylistDetailView(
                album: app.albumSummary(for: track),
                librarySource: app.isAlbumInLibrary(track.albumId),
                scrollToTrackId: track.id
            )
        }
    }

    /// Zoom key mirroring ``pinnedItemDestination(_:)`` — track pins open their
    /// owning album, so they zoom on the album id.
    private func pinnedItemZoomId(_ item: LibraryPinnedItem) -> String {
        switch item {
        case .album(let album): return album.id
        case .playlist(let playlist): return playlist.id
        case .track(let track): return app.albumSummary(for: track).id
        }
    }

    private func pinnedItemCell(_ item: LibraryPinnedItem, zoomId: String) -> some View {
        LibraryHubGridCell(title: item.title, style: .pinned) {
            pinnedItemArtwork(item)
                .coverZoomCellAnchor(id: zoomId, cornerRadius: MusicDesign.gridAlbumCorner)
        }
    }

    /// Favorite Songs pushes `FavoritePlaylistView`, whose hero is laid out differently from
    /// `ServerPlaylistDetailView`. The custom animator caches one hero rect globally, so let
    /// that one keep the stock zoom rather than aim at the wrong destination.
    private func pinnedUsesCustomZoom(_ item: LibraryPinnedItem) -> Bool {
        if case .playlist(let playlist) = item, playlist.id == "__favorite_songs__" { return false }
        return true
    }

    @ViewBuilder
    private func pinnedItemArtwork(_ item: LibraryPinnedItem) -> some View {
        switch item {
        case .playlist(let playlist) where playlist.id == "__favorite_songs__":
            FavoriteSongsPlaylistArtwork(cornerRadius: MusicDesign.gridAlbumCorner)
        default:
            AlbumArtworkView(url: resolvedPinnedArtworkURL(for: item), cornerRadius: MusicDesign.gridAlbumCorner)
        }
    }

    private func resolvedPinnedArtworkURL(for item: LibraryPinnedItem) -> URL? {
        switch item {
        case .album(let album):
            return app.resolvedArtworkURL(for: album)
        case .playlist(let playlist):
            return app.resolvedArtworkURL(for: playlist)
        case .track(let track):
            return app.resolvedArtworkURL(for: track)
        }
    }
}

/// Library → **Playlists** (favorite songs as a playlist; Jellyfin favorites sync with the server).
private enum PlaylistFilter: String, CaseIterable, Hashable {
    case all = "All Playlists"
    case favorites = "Favorites"
    case downloads = "Downloads"
}

private enum PlaylistSort: String, CaseIterable, Hashable {
    case title = "Title"
    case dateAdded = "Date Added"
    case lastPlayed = "Last Played"
    case updatedDate = "Updated Date"
    case playlistType = "Playlist Type"
}

private enum PlaylistViewStyle: String {
    case list
    case grid
}

@MainActor
private enum LibraryPlaylistDownloadIndexCache {
    private static var cachedDownloadIds: Set<String> = []
    private static var cachedPlaylistIds: Set<String> = []
    private static var cachedMatchingPlaylistIds: Set<String> = []

    static func invalidate() {
        cachedDownloadIds = []
        cachedPlaylistIds = []
        cachedMatchingPlaylistIds = []
    }

    static func matchingPlaylistIds(
        downloadedTrackIds: Set<String>,
        playlists: [PlaylistSummary],
        fetchRows: @escaping @Sendable (String) async throws -> [PlaylistRowItem]
    ) async -> Set<String> {
        let playlistIds = Set(playlists.map(\.id))
        guard !downloadedTrackIds.isEmpty else {
            invalidate()
            return []
        }
        if downloadedTrackIds == cachedDownloadIds,
           playlistIds == cachedPlaylistIds {
            return cachedMatchingPlaylistIds
        }

        var matching = Set<String>()
        // Bounded fan-out: this can mean one rows fetch per playlist, and slamming
        // the server with 60 concurrent requests stalls everything else (artwork,
        // playback handshakes) on slow links.
        await withTaskGroup(of: String?.self) { group in
            let maxConcurrent = 4
            var iterator = playlists.makeIterator()
            @discardableResult
            func addNext() -> Bool {
                guard let playlist = iterator.next() else { return false }
                let playlistId = playlist.id
                group.addTask {
                    guard let rows = try? await fetchRows(playlistId) else { return nil }
                    return rows.contains(where: { downloadedTrackIds.contains($0.track.id) }) ? playlistId : nil
                }
                return true
            }
            var started = 0
            while started < maxConcurrent, addNext() { started += 1 }
            for await playlistId in group {
                if let playlistId { matching.insert(playlistId) }
                addNext()
            }
        }
        cachedDownloadIds = downloadedTrackIds
        cachedPlaylistIds = playlistIds
        cachedMatchingPlaylistIds = matching
        return matching
    }
}

struct LibraryPlaylistsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager

    init(downloadsOnly: Bool = false) {
        _filter = State(initialValue: downloadsOnly ? .downloads : .all)
    }

    @State private var showNewPlaylistSheet = false
    @State private var filter: PlaylistFilter
    @AppStorage("libraryPlaylistsSort") private var sortRaw: String = PlaylistSort.title.rawValue
    @AppStorage("libraryPlaylistsViewStyle") private var viewStyleRaw: String = PlaylistViewStyle.list.rawValue
    @State private var query = ""
    @AppStorage("favoritedPlaylistIds") private var favoritedRaw: String = ""
    @State private var playlistIdsWithDownloads: Set<String> = []

    private var viewStyle: PlaylistViewStyle {
        PlaylistViewStyle(rawValue: viewStyleRaw) ?? .list
    }

    private var sort: PlaylistSort {
        PlaylistSort(rawValue: sortRaw) ?? .title
    }

    private let gridColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let favoriteSongsId = "__favorite_songs__"

    private var favoritedIds: Set<String> {
        Set(favoritedRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private func toggleFavorite(_ id: String) {
        var ids = favoritedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        favoritedRaw = ids.joined(separator: ",")
    }

    private var favoriteSongCount: Int {
        switch filter {
        case .downloads:
            return app.favoriteTrackIds.filter { app.offline.downloadedTrackIds.contains($0) }.count
        case .all, .favorites:
            return app.favoriteTrackIds.count
        }
    }

    private var favoriteSongsEntry: PlaylistSummary? {
        let count = favoriteSongCount
        guard count > 0 else { return nil }
        return PlaylistSummary(
            id: favoriteSongsId,
            name: "Favorite Songs",
            songCount: count,
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
            server = app.libraryPlaylists.filter { playlistIdsWithDownloads.contains($0.id) }
        }
        let sorted = sortPlaylists(server)
        var result: [PlaylistSummary] = []
        if let favoriteSongsEntry {
            result.append(favoriteSongsEntry)
        }
        if filter == .all, app.showHomeMixesInPlaylists {
            result += app.homeMixes.map { $0.asPlaylistSummary() }
        }
        result += sorted
        return result
    }

    private var searchFilteredPlaylists: [PlaylistSummary] {
        searchFiltered(displayedPlaylists)
    }

    private func searchFiltered(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return playlists }
        return playlists.filter { $0.name.lowercased().contains(q) }
    }

    private func sortPlaylists(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        switch sort {
        case .title:
            return playlists.sorted(by: pinnedFirstThenTitle)
        case .dateAdded:
            // Resolve each date once up front. Calling `playlistDateAdded` from the
            // comparator meant a linear scan of `libraryPlaylistEntries` per comparison.
            var addedById: [String: Date] = [:]
            for entry in app.libraryPlaylistEntries { addedById[entry.id] = entry.added }
            return playlists
                .map { ($0, addedById[$0.id] ?? $0.libraryAddedDate ?? .distantPast) }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
                }
                .map(\.0)
        case .updatedDate:
            return playlists.sorted { lhs, rhs in
                let ld = playlistUpdatedDate(lhs)
                let rd = playlistUpdatedDate(rhs)
                if ld != rd { return ld > rd }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .lastPlayed:
            return playlists.sorted { lhs, rhs in
                let ld = app.playlistLastPlayedDate(forPlaylistId: lhs.id) ?? .distantPast
                let rd = app.playlistLastPlayedDate(forPlaylistId: rhs.id) ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .playlistType:
            return playlists.sorted { lhs, rhs in
                let lp = lhs.isPublic ?? false
                let rp = rhs.isPublic ?? false
                if lp != rp { return lp && !rp }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Vellum library add date when known; otherwise server created.
    private func playlistDateAdded(_ playlist: PlaylistSummary) -> Date {
        if let entry = app.libraryPlaylistEntries.first(where: { $0.id == playlist.id }) {
            return entry.added
        }
        return playlist.libraryAddedDate ?? .distantPast
    }

    private func playlistUpdatedDate(_ playlist: PlaylistSummary) -> Date {
        playlist.serverUpdatedDate ?? playlist.libraryAddedDate ?? .distantPast
    }

    private func pinnedFirstThenTitle(_ lhs: PlaylistSummary, _ rhs: PlaylistSummary) -> Bool {
        let lhsPinned = favoritedIds.contains(lhs.id)
        let rhsPinned = favoritedIds.contains(rhs.id)
        if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// Warm the row cache for the handful of playlists most likely to be tapped
    /// (the top of the current sort/filter) so opening one is instant instead of
    /// paying a cold `fetchPlaylistRows` round-trip on tap. Bounded so the
    /// Playlists screen appearing doesn't fan out a request per playlist;
    /// ``prefetchPlaylistRows`` no-ops for already-cached playlists.
    private func warmTopPlaylistRows() async {
        let ids = searchFilteredPlaylists.prefix(8).map(\.id)
            .filter { $0 != favoriteSongsId && HomeMix.mixId(fromLibraryPlaylistId: $0) == nil }
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await app.prefetchPlaylistRows(playlistId: id) }
            }
        }
    }

    @ViewBuilder
    private func destination(for playlist: PlaylistSummary) -> some View {
        if playlist.id == favoriteSongsId {
            FavoritePlaylistView(downloadsOnly: filter == .downloads)
        } else if let mixId = HomeMix.mixId(fromLibraryPlaylistId: playlist.id) {
            ServerPlaylistDetailView(homeMixId: mixId)
        } else {
            ServerPlaylistDetailView(playlist: playlist)
        }
    }

    var body: some View {
        // Both of these filter and sort the whole playlist library. They were referenced
        // half a dozen times across this body, re-sorting on each reference.
        let all = displayedPlaylists
        let visible = searchFiltered(all)
        return ScrollView {
            // Lazy so a large playlist library only builds the rows on screen —
            // a plain VStack here instantiated every row (artwork, context menu,
            // NavigationLink) up front, which is what made the list lag.
            LazyVStack(spacing: 0) {
                if all.isEmpty {
                    ContentUnavailableView(
                        filter == .favorites ? "No Favorited Playlists"
                            : filter == .downloads ? "No Downloaded Playlists"
                            : "No Playlists",
                        systemImage: filter == .favorites ? "star" : filter == .downloads ? "arrow.down.circle" : "music.note.list",
                        description: Text(
                            filter == .favorites
                                ? "Long-press a playlist to add it to Favorites."
                                : filter == .downloads
                                    ? "Download songs from a playlist to see it here."
                                    : "Create a playlist with the + button, or keep listening to build personalized mixes."
                        )
                    )
                    .padding(.top, 40)
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else if viewStyle == .grid {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(visible) { playlist in
                            NavigationLink { destination(for: playlist) } label: {
                                gridCell(playlist)
                                    .coverZoomSource(id: playlist.id, style: .custom)
                            }
                            .buttonStyle(.plain)
                            .homeMixOrPlaylistContextMenu(playlist, app: app)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, playlist in
                        NavigationLink { destination(for: playlist) } label: {
                            listRow(playlist)
                                .coverZoomSource(id: playlist.id, style: .custom)
                        }
                        .buttonStyle(.plain)
                        .homeMixOrPlaylistContextMenu(playlist, app: app)
                        .musicChevronRowDivider(.playlistArtwork, shows: index < visible.count - 1)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .task(id: visible.map(\.id)) {
            await warmTopPlaylistRows()
        }
        .background(MusicDesign.background)
        .musicLibrarySectionScreen(title: "Playlists")
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                Button {
                    showNewPlaylistSheet = true
                } label: {
                    MusicLibraryToolbarIcon(systemName: "text.badge.plus")
                }
                .accessibilityLabel("New playlist")

                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(PlaylistFilter.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                } label: {
                    MusicLibraryToolbarIcon(systemName: "line.3.horizontal")
                }
                .menuOrder(.fixed)

                Menu {
                    Section("View") {
                        Picker("View", selection: $viewStyleRaw) {
                            Label("List", systemImage: "list.bullet")
                                .tag(PlaylistViewStyle.list.rawValue)
                            Label("Grid", systemImage: "square.grid.2x2")
                                .tag(PlaylistViewStyle.grid.rawValue)
                        }
                        .labelsHidden()
                    }
                    Section("Sort By") {
                        Picker("Sort By", selection: $sortRaw) {
                            ForEach(PlaylistSort.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                    }
                } label: {
                    MusicLibraryToolbarIcon(systemName: "ellipsis")
                }
                .menuOrder(.fixed)
            }
        }
        .musicLibraryToolbarMonochromeControls()
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistNameSheet()
                .environmentObject(app)
#if os(iOS)
                .presentationDetents([.large])
#endif
        }
        .musicNativeSearchable(text: $query, prompt: Text("Playlists"))
        .task(id: filter) {
            await refreshPlaylistDownloadIndexIfNeeded()
        }
        .onChange(of: offline.downloadedTrackIds) { _, _ in
            Task { await refreshPlaylistDownloadIndexIfNeeded() }
        }
        .onChange(of: app.libraryPlaylists.map(\.id)) { _, _ in
            Task { await refreshPlaylistDownloadIndexIfNeeded() }
        }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            if filter == .downloads {
                LibraryPlaylistDownloadIndexCache.invalidate()
                Task { await refreshPlaylistDownloadIndexIfNeeded() }
            }
        }
        .task { await app.refreshLibraryPlaylists() }
        .refreshable {
            await app.refreshLibraryPlaylists()
            app.refreshHomeMixes()
        }
    }

    private func refreshPlaylistDownloadIndexIfNeeded() async {
        guard filter == .downloads else {
            await MainActor.run { playlistIdsWithDownloads = [] }
            return
        }
        let matching = await LibraryPlaylistDownloadIndexCache.matchingPlaylistIds(
            downloadedTrackIds: offline.downloadedTrackIds,
            playlists: app.libraryPlaylists,
            fetchRows: { id in
                // Session/disk cache first — only unopened playlists pay a network fetch.
                if let cached = await app.cachedPlaylistRows(playlistId: id) { return cached }
                return try await app.fetchPlaylistRows(playlistId: id)
            }
        )
        await MainActor.run { playlistIdsWithDownloads = matching }
    }

    private func listRow(_ playlist: PlaylistSummary) -> some View {
        HStack(spacing: 14) {
            // Origin rect for the custom cover-zoom animator, and the copy it hides while the
            // card is in flight so only one cover is ever on screen.
            playlistArtworkFixed(playlist, size: 52, cornerRadius: 8)
                .coverZoomCellAnchor(id: playlist.id, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
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
            MusicNavigationChevron()
        }
        .musicChevronRowPadding()
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func playlistArtworkFixed(_ playlist: PlaylistSummary, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if playlist.id == favoriteSongsId {
            FavoriteSongsPlaylistArtwork(cornerRadius: cornerRadius, size: size)
        } else if let mix = app.homeMix(forLibraryPlaylistId: playlist.id) {
            MixCollageArtworkView(
                urls: mix.artworkURLs,
                fallbackSeed: "homeMix:\(mix.id)",
                cornerRadius: cornerRadius
            )
            .frame(width: size, height: size)
        } else {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: cornerRadius)
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func playlistArtworkFill(_ playlist: PlaylistSummary, cornerRadius: CGFloat) -> some View {
        if playlist.id == favoriteSongsId {
            FavoriteSongsPlaylistArtwork(cornerRadius: cornerRadius)
        } else if let mix = app.homeMix(forLibraryPlaylistId: playlist.id) {
            MixCollageArtworkView(
                urls: mix.artworkURLs,
                fallbackSeed: "homeMix:\(mix.id)",
                cornerRadius: cornerRadius
            )
        } else {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: cornerRadius)
        }
    }

    private func gridCell(_ playlist: PlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            playlistArtworkFill(playlist, cornerRadius: MusicDesign.gridAlbumCorner)
                .coverZoomCellAnchor(id: playlist.id, cornerRadius: MusicDesign.gridAlbumCorner)
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
        if let mix = app.homeMix(forLibraryPlaylistId: playlist.id) {
            return mix.libraryDetailSubtitle
        }
        if let n = playlist.songCount { return n == 1 ? "1 song" : "\(n) songs" }
        return "Playlist"
    }
}

/// Favorite Songs playlist tile — accent star on a neutral background (no square icon).
private struct FavoriteSongsPlaylistArtwork: View {
    var cornerRadius: CGFloat
    var size: CGFloat?

    private var starPointSize: CGFloat {
        if let size { return size * 0.38 }
        return 28
    }

    var body: some View {
        Group {
            if let size {
                artworkBody
                    .frame(width: size, height: size)
            } else {
                artworkBody
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private var artworkBody: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(MusicDesign.tertiarySurfaceFill)
            .overlay {
                Image(systemName: "star.fill")
                    .font(.system(size: starPointSize, weight: .semibold))
                    .foregroundStyle(MusicDesign.accent)
            }
    }
}

/// White hero tile for ``FavoritePlaylistView`` — large accent star, no square framing.
private struct FavoriteSongsHeroArtwork: View {
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white)
            .overlay {
                Image(systemName: "star.fill")
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(MusicDesign.accent)
            }
            .frame(width: side, height: side)
    }
}

/// Tracks starred as favorites (``LibraryPlaylistsView`` → Favorite Songs).
struct FavoritePlaylistView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    private let downloadsOnly: Bool

    init(downloadsOnly: Bool = false) {
        self.downloadsOnly = downloadsOnly
    }

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var isDownloadingAll = false
    private let backdropPalette: ArtworkDynamicGradient.BackdropPalette = .favoriteSongsHero
    @State private var showDownloadedFavoritesActions = false
    @State private var navigateAlbum: AlbumSummary?
    @State private var trackPendingDownloadedDelete: Track?
    @State private var dismissalPhase: CoverZoomTransitionPhase = .idle
    @State private var isBeingDismissed = false

    private var displayTitle: String {
        downloadsOnly ? "Downloaded Favorites" : "Favorite Songs"
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.albumTitle.lowercased().contains(q)
        }
    }

    private var heroSubtitle: String? {
        let count = tracks.count
        guard count > 0 else { return nil }
        var parts = ["\(count) song\(count == 1 ? "" : "s")"]
        if !downloadsOnly {
            parts.append("Synced with \(app.backendKind.title)")
        }
        return parts.joined(separator: " · ")
    }

    private var heroArtSide: CGFloat {
        let w: CGFloat = {
#if os(iOS)
            UIScreen.main.bounds.width
#else
            800
#endif
        }()
        return min(max(w - 52, 260), 320)
    }

    private var allTracksCached: Bool {
        !tracks.isEmpty && tracks.allSatisfy { app.offline.downloadedTrackIds.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AlbumHeroBackdropView(artworkURL: nil, palette: backdropPalette)

            List {
                Section {
                    PlaylistHeroOrPillsHeader(
                        hero: { heroBlock.padding(.top, 8).padding(.bottom, 22) },
                        pills: {
                            AlbumHeroPlayShuffleCluster(
                                palette: backdropPalette,
                                isDisabled: filtered.isEmpty,
                                onPlay: { Task { await playAll() } },
                                onShuffle: { Task { await shuffleAll() } }
                            )
                        }
                    )
                    // Gate the hero only — wrapping the whole screen left scrolling and
                    // every track row dead for ~0.6s after each open.
                    .coverZoomDetailHitTesting(phase: $dismissalPhase, isBeingDismissed: $isBeingDismissed)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 14, trailing: 20))
                }

                trackListRows
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .listRowSpacing(5)
            .modifier(AlbumDetailListContentMargins(isAlbum: true))
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .coverZoomDestination(id: "__favorite_songs__", dismissalPhase: $dismissalPhase)
        .detailDismissTracker(isBeingDismissed: $isBeingDismissed)
        .onAppear {
            isBeingDismissed = false
            if dismissalPhase == .gone { dismissalPhase = .idle }
        }
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicFavoriteSongsNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .musicLibraryToolbarMonochromeControls()
        .musicNativeSearchable(text: $searchText, prompt: Text("Songs"))
        .toolbar { favoriteDetailToolbar }
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
                .onDisappear { navigateAlbum = nil }
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
            tracks = scopedTracks(tracks.filter { newIds.contains($0.id) })
        }
        .onChange(of: app.offline.downloadedTrackIds) { _, _ in
            guard downloadsOnly, !tracks.isEmpty else { return }
            tracks = scopedTracks(tracks)
        }
        .modifier(DownloadedAlbumActionPresentation(
            isPresented: $showDownloadedFavoritesActions,
            onRemoveDownload: { removeAllFavoritesOfflineDownloads() },
            onDeleteFromLibrary: { Task { await removeAllFavoritesFromLibraryAndOffline() } },
        ))
        .downloadedTrackDeleteSheet(
            track: $trackPendingDownloadedDelete,
            app: app,
            offline: offline
        )
        .preferredColorScheme(.light)
    }

    @ToolbarContentBuilder
    private var favoriteDetailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
            Menu {
                if !allTracksCached {
                    ControlGroup {
                        Button {
                            Task { await downloadAllTracks() }
                        } label: {
                            Label("Download All", systemImage: "arrow.down.circle")
                        }
                        .disabled(filtered.isEmpty || isDownloadingAll)
                    }
                    .tint(Color.primary)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
            }
            .menuOrder(.fixed)
            .coverZoomDetailHitTesting(phase: $dismissalPhase, isBeingDismissed: $isBeingDismissed)
        }
    }

    private var heroBlock: some View {
        VStack(spacing: 18) {
            FavoriteSongsHeroArtwork(side: heroArtSide, cornerRadius: 14)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 6) {
                Text(displayTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                if let heroSubtitle {
                    Text(heroSubtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(backdropPalette.heroChromeSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }

            actionButtonTriplet
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionButtonTriplet: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Button {
                Task { await shuffleAll() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backdropPalette.heroGlassIcon)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(backdropPalette.heroGlassCircleFill))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)

            Button {
                Task { await playAll() }
            } label: {
                HStack(spacing: MusicDesign.libraryPlayShuffleLabelSpacing) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(backdropPalette.heroPlayCapsuleForeground)
                .frame(width: MusicDesign.albumHeroPrimaryCapsuleWidth, height: 54)
                .background(Capsule().fill(backdropPalette.heroPlayCapsuleBackground))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)

            primaryActionButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if allTracksCached {
            Button {
                showDownloadedFavoritesActions = true
            } label: {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backdropPalette.heroGlassIcon)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(backdropPalette.heroGlassCircleFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage downloads")
        } else {
            Button {
                Task { await downloadAllTracks() }
            } label: {
                Group {
                    if isDownloadingAll {
                        ProgressView()
                            .tint(backdropPalette.heroGlassIcon)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(
                                tracks.isEmpty ? backdropPalette.heroGlassIcon.opacity(0.35) : backdropPalette.heroGlassIcon
                            )
                    }
                }
                .frame(width: 54, height: 54)
                .background(Circle().fill(backdropPalette.heroGlassCircleFill))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty || isDownloadingAll)
            .accessibilityLabel("Download")
        }
    }

    @ViewBuilder
    private var trackListRows: some View {
        if isLoading, tracks.isEmpty {
            ProgressView()
                .tint(backdropPalette.heroAccent)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if let loadError, tracks.isEmpty {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(backdropPalette.heroChromeSecondary)
                .padding(.horizontal, 22)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if filtered.isEmpty {
            if isSearching, !tracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .padding(.top, 32)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Text(emptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(backdropPalette.heroChromeSecondary.opacity(0.9))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, track in
                songRow(track, showsBottomDivider: index < filtered.count - 1)
                    .favoriteSongsListRowStyle()
            }
        }
    }

    private var emptyStateMessage: String {
        if downloadsOnly {
            return "Favorite songs you have saved for offline playback will appear here."
        }
        return "Star songs from the ··· menu or Now Playing. Favorites sync with \(app.backendKind.title)."
    }

    private func songRow(_ track: Track, showsBottomDivider: Bool) -> some View {
        TrackDownloadProgressReader(progress: offline.progressModel, trackId: track.id) { downloadState in
            songRowContent(track, downloadState: downloadState, showsBottomDivider: showsBottomDivider)
        }
    }

    private func songRowContent(_ track: Track, downloadState: OfflineDownloadUIState?, showsBottomDivider: Bool) -> some View {
        LibrarySongRow(
            track: track,
            artworkURL: app.resolvedArtworkURL(for: track),
            itemSize: app.songListItemSize,
            isFavorite: app.favoriteTrackIds.contains(track.id),
            isNowPlaying: app.nowPlayingTrackId == track.id,
            offlineDownload: downloadState,
            isOfflineCached: app.offline.downloadedTrackIds.contains(track.id),
            onPlay: { Task { await play(track: track) } },
            onDownload: { Task { await cacheOffline(track: track) } },
            onCancelOfflineDownload: { app.offline.cancelDownload(trackId: track.id) },
            onFavorite: { app.toggleFavoriteTrack(id: track.id) },
            onPlayNext: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playNext(library: lib, track: track)
                    await MainActor.run { app.showTransientToast("Playing Next") }
                }
            },
            onAddToQueue: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.addToQueue(library: lib, track: track)
                    await MainActor.run { app.showTransientToast("Added to Queue") }
                }
            },
            hasActiveQueue: app.hasActivePlaybackQueue,
            onGoToAlbum: { openFavoriteSongAlbumDetail(for: track) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { Task { await app.removeSongFromLibrary(track) } } : nil,
            onDeleteFromLibrary: { app.beginLibraryTrackDeletion(track) },
            canDeleteFromLibrary: app.canDeleteFromLibrary,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                ? { try? app.offline.remove(trackId: track.id) } : nil,
            rowBackgroundFill: .white,
            showsBottomDivider: showsBottomDivider,
            rowLabelPalette: backdropPalette,
            onPresentDownloadedDeleteSheet: {
                trackPendingDownloadedDelete = track
            }
        )
        .equatable()
    }

    private func cacheOffline(track: Track) async {
        app.enqueueOfflineTrack(track)
    }

    private func scopedTracks(_ loaded: [Track]) -> [Track] {
        guard downloadsOnly else { return loaded }
        return loaded.filter { app.offline.downloadedTrackIds.contains($0.id) }
    }

    private func openFavoriteSongAlbumDetail(for track: Track) {
        let album = app.albumSummary(for: track)
        if navigateAlbum?.id == album.id {
            navigateAlbum = nil
            DispatchQueue.main.async {
                navigateAlbum = album
            }
        } else {
            navigateAlbum = album
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
            let loaded = try await app.favoritePlaylistTracks()
            tracks = scopedTracks(loaded)
        } catch {
            loadError = error.localizedDescription
            tracks = []
        }
    }

    private func removeAllFavoritesOfflineDownloads() {
        app.removeOfflineCachedItem(itemId: OfflineDownloadQueueItem.favoritesItemId)
    }

    private func removeAllFavoritesFromLibraryAndOffline() async {
        app.removeOfflineCachedItem(itemId: OfflineDownloadQueueItem.favoritesItemId)
        for track in tracks where app.isSongInLibrary(track.id) {
            await app.removeSongFromLibrary(track)
        }
    }

    private func downloadAllTracks() async {
        guard app.activeLibrary != nil, !filtered.isEmpty else { return }
        isDownloadingAll = true
        defer { isDownloadingAll = false }
        app.enqueueOfflineFavorites(tracks: filtered)
        app.showTransientToast("Added to download queue")
    }

    private func playAll() async {
        guard let lib = app.activeLibrary, !filtered.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: filtered, startIndex: 0)
    }

    private func shuffleAll() async {
        guard let lib = app.activeLibrary, !filtered.isEmpty else { return }
        try? await app.player.playAlbumShuffled(library: lib, tracks: filtered)
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

private enum DownloadedLibrarySection: String, CaseIterable, Identifiable {
    case playlists
    case artists
    case albums
    case songs
    case genres

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .genres: return "Genres"
        }
    }

    var symbol: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "mic"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        case .genres: return "paintbrush.pointed.fill"
        }
    }
}

/// Library → **Downloaded** hub: category rows + Recently Downloaded grid.
struct LibraryDownloadedView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @State private var backfillDebounceTask: Task<Void, Never>?
    @State private var recentlyDownloadedAlbums: [AlbumSummary] = []
    @State private var isRefreshingRecents = false

    private let recentColumns = MusicDesign.libraryHubGridColumns(count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(DownloadedLibrarySection.allCases.enumerated()), id: \.element.id) { index, section in
                    downloadedSectionLink(
                        section,
                        showsDivider: showsDownloadedHubRowDivider(at: index, section: section)
                    )
                }

                Text("Recently Downloaded")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 14)

                recentlyDownloadedBody
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(MusicDesign.background)
        .musicLibrarySectionScreen(title: "Downloaded")
        .task {
            await refreshDownloadedContent()
        }
        .onChange(of: offline.downloadedTrackIds) { _, _ in
            scheduleDownloadedBackfill()
        }
    }

    /// Inset divider between category rows; **Genres** always gets one before Recently Downloaded.
    private func showsDownloadedHubRowDivider(at index: Int, section: DownloadedLibrarySection) -> Bool {
        if section == .genres { return true }
        return index < DownloadedLibrarySection.allCases.count - 1
    }

    @ViewBuilder
    private func downloadedSectionLink(_ section: DownloadedLibrarySection, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
            switch section {
            case .playlists:
                NavigationLink {
                    LibraryPlaylistsView(downloadsOnly: true)
                } label: {
                    downloadedSectionLabel(section)
                }
                .buttonStyle(.plain)
            case .artists:
                NavigationLink {
                    LibraryArtistsView(downloadsOnly: true)
                } label: {
                    downloadedSectionLabel(section)
                }
                .buttonStyle(.plain)
            case .albums:
                NavigationLink {
                    AlbumsGridView(scope: .downloads)
                } label: {
                    downloadedSectionLabel(section)
                }
                .buttonStyle(.plain)
            case .songs:
                NavigationLink {
                    LibrarySongsView(downloadsOnly: true)
                } label: {
                    downloadedSectionLabel(section)
                }
                .buttonStyle(.plain)
            case .genres:
                NavigationLink {
                    LibraryGenresView(downloadsOnly: true)
                } label: {
                    downloadedSectionLabel(section)
                }
                .buttonStyle(.plain)
            }
            }
            .musicChevronRowDivider(.symbolIcon, shows: showsDivider)
        }
    }

    private func downloadedSectionLabel(_ section: DownloadedLibrarySection) -> some View {
        HStack(spacing: 16) {
            Image(systemName: section.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.accent)
                .frame(width: 28, alignment: .center)
            Text(section.title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            MusicNavigationChevron()
        }
        .musicChevronRowPadding()
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var recentlyDownloadedBody: some View {
        if isRefreshingRecents, recentlyDownloadedAlbums.isEmpty, !offline.downloadedTrackIds.isEmpty {
            ProgressView()
                .tint(MusicDesign.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else if recentlyDownloadedAlbums.isEmpty {
            recentlyDownloadedEmptyState
        } else {
            LazyVGrid(columns: recentColumns, spacing: 20) {
                ForEach(recentlyDownloadedAlbums) { album in
                    NavigationLink {
                        ServerPlaylistDetailView(album: album, librarySource: true)
                    } label: {
                        recentlyDownloadedCell(album)
                            .coverZoomSource(id: album.id)
                    }
                    .buttonStyle(.plain)
                    .libraryAlbumContextMenu(album)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var recentlyDownloadedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .padding(.bottom, 4)
            Text(offline.downloadedTrackIds.isEmpty ? "No Downloads Yet" : "Nothing to Show")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(
                offline.downloadedTrackIds.isEmpty
                    ? "Swipe a library song right-to-left and tap Download to save it for offline playback."
                    : "Open the app once while online to refresh download metadata."
            )
            .font(.subheadline)
            .foregroundStyle(MusicDesign.secondaryLabel)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func recentlyDownloadedCell(_ album: AlbumSummary) -> some View {
        LibraryHubGridCell(title: album.title, subtitle: album.artist) {
            AlbumArtworkView(url: app.resolvedArtworkURL(for: album), cornerRadius: MusicDesign.gridAlbumCorner)
        }
    }

    private func scheduleDownloadedBackfill() {
        backfillDebounceTask?.cancel()
        backfillDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await refreshDownloadedContent()
        }
    }

    @MainActor
    private func refreshDownloadedContent() async {
        isRefreshingRecents = true
        defer { isRefreshingRecents = false }
        let ids = app.offline.downloadedTrackIds
        if !ids.isEmpty {
            let known = ids.compactMap { app.discoveryTrackById[$0] }
            app.offline.backfillRecordsIfMissing(knownTracks: known)
            app.offline.reloadDownloadedTrackIdsFromManifest()
            await app.offline.enrichCachedArtworkIfNeeded()
        }
        recentlyDownloadedAlbums = offline.recentlyDownloadedAlbums(limit: 60)
    }
}

struct LibraryPlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(MusicDesign.accent)
            Text("\(title) isn’t available yet in Vellum Music.")
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

enum AlbumsGridScope {
    case library
    case downloads
}

private enum LibraryAlbumLibraryFilter: String, CaseIterable {
    case allAlbums
    case downloads
}

private enum LibraryAlbumSort: String {
    case title
    case dateAdded
    case artist
}

/// Full album grid (Music-style square art + two-line captions).
struct AlbumsGridView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    private let scope: AlbumsGridScope
    @State private var showLoadError = false
    @State private var query = ""
    @State private var scrubberSelectedLetter: String?
    @State private var lastScrubbedLetter: String?
    @State private var libraryFilter: LibraryAlbumLibraryFilter
    @State private var sort = LibraryAlbumSort.title
    @State private var displayedSearchAlbums: [AlbumSummary] = []
    @State private var displayedAlbumSections: [LibraryAlbumGridSection] = []
    @State private var displayedScrubberLetters: [String] = []
    @State private var displayedBaseAlbumCount = 0
    @State private var showsDisplayedAlbumSections = true
    @State private var albumDisplayDebounceTask: Task<Void, Never>?

    init(scope: AlbumsGridScope = .library) {
        self.scope = scope
        _libraryFilter = State(initialValue: scope == .downloads ? .downloads : .allAlbums)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    /// Albums the user has added to their Vellum library, resolved against the cached
    /// catalog. Newest-added first (per the magic playlist's per-album timestamps).
    private var libraryAlbums: [AlbumSummary] {
        app.libraryAlbumEntries
            .compactMap { entry in app.catalogAlbum(id: entry.id).map { ($0, entry.added) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var downloadedAlbums: [AlbumSummary] {
        offline.cachedAlbums()
    }

    private var baseAlbums: [AlbumSummary] {
        switch scope {
        case .downloads:
            return downloadedAlbums
        case .library:
            switch libraryFilter {
            case .allAlbums:
                return libraryAlbums
            case .downloads:
                let downloadedIds = Set(downloadedAlbums.map(\.id))
                return libraryAlbums.filter { downloadedIds.contains($0.id) }
            }
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func recomputeAlbumDisplay() {
        // `baseAlbums` resolves the whole personal library against the catalog — evaluate it
        // once and hand it to the body rather than also computing it for the log details.
        let base = baseAlbums
        PerfLog.measure("LibraryView.recomputeAlbumDisplay", details: "base=\(base.count) sort=\(sort) q=\(query.count)c") {
            recomputeAlbumDisplayBody(base: base)
        }
    }

    private func scheduleRecomputeAlbumDisplay() {
        albumDisplayDebounceTask?.cancel()
        albumDisplayDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            recomputeAlbumDisplay()
        }
    }

    private func recomputeAlbumDisplayBody(base: [AlbumSummary]) {
        displayedBaseAlbumCount = base.count

        let sorted: [AlbumSummary]
        switch sort {
        case .title:
            sorted = base.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .dateAdded:
            let entriesById = Dictionary(uniqueKeysWithValues: app.libraryAlbumEntries.map { ($0.id, $0.added) })
            sorted = base.sorted { lhs, rhs in
                (entriesById[lhs.id] ?? .distantPast) > (entriesById[rhs.id] ?? .distantPast)
            }
        case .artist:
            sorted = base.sorted { lhs, rhs in
                let cmpArtist = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
                if cmpArtist != .orderedSame { return cmpArtist == .orderedAscending }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            displayedSearchAlbums = sorted
        } else {
            displayedSearchAlbums = sorted.filter {
                $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
            }
        }

        let sectioned = !isSearching && (sort == .title || sort == .artist)
        showsDisplayedAlbumSections = sectioned
        guard sectioned else {
            displayedAlbumSections = []
            displayedScrubberLetters = []
            return
        }

        let sectionLetter: (AlbumSummary) -> String = { album in
            switch sort {
            case .title:
                return LibraryAlphabetIndex.sectionLetter(for: album.title)
            case .artist:
                return LibraryAlphabetIndex.sectionLetter(for: album.artist)
            case .dateAdded:
                return LibraryAlphabetIndex.sectionLetter(for: album.title)
            }
        }
        displayedAlbumSections = LibraryAlphabetIndex.groupedSections(sorted, letter: sectionLetter)
            .map { LibraryAlbumGridSection(id: $0.id, albums: $0.items) }
        displayedScrubberLetters = displayedAlbumSections.map(\.id)
    }

    private var emptyTitle: String {
        if scope == .downloads || libraryFilter == .downloads {
            return "No Downloaded Albums"
        }
        return "No Albums in Library"
    }

    private var emptyDescription: String {
        if scope == .downloads || libraryFilter == .downloads {
            return "Albums with offline downloads will appear here."
        }
        return "Long-press an album and tap Add to Library to start your collection."
    }

    private func scrollToSection(_ letter: String, proxy: ScrollViewProxy) {
        guard displayedScrubberLetters.contains(letter) else { return }
        guard letter != lastScrubbedLetter else { return }
        lastScrubbedLetter = letter
        var highlight = Transaction()
        highlight.disablesAnimations = true
        withTransaction(highlight) {
            scrubberSelectedLetter = letter
        }
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        var scroll = Transaction()
        scroll.disablesAnimations = true
        withTransaction(scroll) {
            proxy.scrollTo(LibraryAlphabetIndex.albumScrollSectionID(letter), anchor: .top)
        }
    }

    private func endScrubbing() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lastScrubbedLetter = nil
            scrubberSelectedLetter = nil
        }
    }

    private var playShuffleRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: displayedSearchAlbums.isEmpty,
            onPlay: { Task { await playAll() } },
            onShuffle: { Task { await shuffleAll() } }
        )
    }

    private func tracksForPlayback(from albums: [AlbumSummary]) -> [Track] {
        guard !albums.isEmpty else { return [] }

        if scope == .downloads || libraryFilter == .downloads {
            let albumIds = Set(albums.map(\.id))
            let tracks = app.tracksForDownloadedLibrary().filter { albumIds.contains($0.albumId) }
            return tracksGroupedByAlbumOrder(albums: albums, tracks: tracks)
        }

        let albumIds = Set(albums.map(\.id))
        var tracks = app.discoveryLibraryTracks.filter {
            albumIds.contains($0.albumId) && app.librarySongIds.contains($0.id)
        }
        var seen = Set(tracks.map(\.id))
        for track in app.offline.cachedTracks() where albumIds.contains(track.albumId)
            && app.librarySongIds.contains(track.id)
            && seen.insert(track.id).inserted {
            tracks.append(track)
        }
        return tracksGroupedByAlbumOrder(albums: albums, tracks: tracks)
    }

    private func tracksGroupedByAlbumOrder(albums: [AlbumSummary], tracks: [Track]) -> [Track] {
        let byAlbum = Dictionary(grouping: tracks, by: \.albumId)
        var result: [Track] = []
        result.reserveCapacity(tracks.count)
        for album in albums {
            let albumTracks = (byAlbum[album.id] ?? []).sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.indexNumber < $1.indexNumber
            }
            result.append(contentsOf: albumTracks)
        }
        return result
    }

    private func resolveTracksForPlayback() async -> [Track] {
        let albums = displayedSearchAlbums
        let cached = tracksForPlayback(from: albums)
        if !cached.isEmpty { return cached }
        guard let lib = app.activeLibrary else { return [] }

        var result: [Track] = []
        for album in albums {
            guard let fetched = try? await lib.tracks(forAlbumId: album.id) else { continue }
            let candidates: [Track]
            if scope == .downloads || libraryFilter == .downloads {
                candidates = fetched.filter { app.offline.downloadedTrackIds.contains($0.id) }
            } else {
                candidates = fetched.filter { app.librarySongIds.contains($0.id) }
            }
            result.append(contentsOf: candidates.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.indexNumber < $1.indexNumber
            })
        }
        return result
    }

    private func playAll() async {
        let tracks = await resolveTracksForPlayback()
        guard let lib = app.activeLibrary, !tracks.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracks, startIndex: 0)
    }

    private func shuffleAll() async {
        let tracks = await resolveTracksForPlayback()
        guard let lib = app.activeLibrary, !tracks.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracks.shuffled(), startIndex: 0)
    }

    @ViewBuilder
    private var albumsScrollContent: some View {
        if scope == .library,
           displayedBaseAlbumCount == 0,
           app.libraryAlbumsLoadError == nil,
           !app.libraryAlbumEntries.isEmpty {
            ProgressView()
                .tint(MusicDesign.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if displayedBaseAlbumCount == 0 {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "square.stack",
                description: Text(emptyDescription)
            )
            .padding(.top, 60)
        } else if displayedSearchAlbums.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 60)
        } else if isSearching || !showsDisplayedAlbumSections {
            albumsFlatGrid(displayedSearchAlbums)
                .padding(.vertical, 12)
        } else {
            albumsSectionedGrid
        }
    }

    private var albumsSectionedGrid: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            ForEach(displayedAlbumSections) { section in
                Text(section.id)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    .id(LibraryAlphabetIndex.albumScrollSectionID(section.id))

                albumsFlatGrid(section.albums)
            }
        }
        .padding(.vertical, 12)
    }

    private func albumsFlatGrid(_ albums: [AlbumSummary]) -> some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(albums) { album in
                NavigationLink {
                    ServerPlaylistDetailView(album: album, librarySource: true)
                } label: {
                    AlbumGridCell(album: album)
                        .coverZoomSource(id: album.id)
                }
                .buttonStyle(.plain)
                .libraryAlbumContextMenu(album)
            }
        }
        .padding(.horizontal, 16)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        playShuffleRow
                            .padding(.top, 8)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)

                        albumsScrollContent
                    }
                }
                .scrollIndicators(.hidden)

                if showsDisplayedAlbumSections, !displayedAlbumSections.isEmpty, !displayedScrubberLetters.isEmpty {
                    LibraryAlphabetScrubberHost(
                        letters: displayedScrubberLetters,
                        selectedLetter: scrubberSelectedLetter,
                        onSelect: { letter in
                            scrollToSection(letter, proxy: scrollProxy)
                        },
                        onScrubEnd: endScrubbing
                    )
                }
            }
        }
        .background(MusicDesign.background)
        .musicLibrarySectionScreen(title: "Albums")
        .musicNativeSearchable(text: $query, prompt: Text("Albums"))
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                if scope == .library {
                    Menu {
                        filterMenuContent
                    } label: {
                        MusicLibraryToolbarIcon(systemName: "line.3.horizontal")
                    }
                    .menuOrder(.fixed)
                }

                Menu {
                    sortMenuContent
                } label: {
                    MusicLibraryToolbarIcon(systemName: "ellipsis")
                }
                .menuOrder(.fixed)
            }
        }
        .musicLibraryToolbarMonochromeControls()
        .alert("Could not load", isPresented: $showLoadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.libraryAlbumsLoadError ?? "")
        }
        .onChange(of: app.libraryAlbumsLoadError) { _, new in
            if scope == .library {
                showLoadError = new != nil && app.libraryAlbums.isEmpty
            }
        }
        .onChange(of: query) { _, _ in
            recomputeAlbumDisplay()
            if isSearching {
                endScrubbing()
            }
        }
        .onChange(of: sort) { _, _ in
            recomputeAlbumDisplay()
            endScrubbing()
        }
        .onChange(of: libraryFilter) { _, _ in
            recomputeAlbumDisplay()
            endScrubbing()
        }
        .onChange(of: app.libraryAlbumEntries) { _, _ in recomputeAlbumDisplay() }
        .onChange(of: app.libraryAlbums.count) { _, _ in recomputeAlbumDisplay() }
        .onChange(of: offline.downloadedTrackIds) { _, _ in scheduleRecomputeAlbumDisplay() }
        .onAppear { recomputeAlbumDisplay() }
        .refreshable {
            if scope == .library {
                await app.refreshLibraryAlbums()
            }
        }
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Button {
            libraryFilter = .allAlbums
        } label: {
            HStack {
                Label("All Albums", systemImage: "square.stack")
                Spacer(minLength: 16)
                if libraryFilter == .allAlbums {
                    Image(systemName: "checkmark")
                }
            }
        }
        Button {
            libraryFilter = .downloads
        } label: {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                Spacer(minLength: 16)
                if libraryFilter == .downloads {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    @ViewBuilder
    private var sortMenuContent: some View {
        Button {
            sort = .title
        } label: {
            HStack {
                Text("Title")
                Spacer(minLength: 16)
                if sort == .title {
                    Image(systemName: "checkmark")
                }
            }
        }
        Button {
            sort = .dateAdded
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Date Added")
                    Text("Newest First")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if sort == .dateAdded {
                    Image(systemName: "checkmark")
                }
            }
        }
        Button {
            sort = .artist
        } label: {
            HStack {
                Text("Artist")
                Spacer(minLength: 16)
                if sort == .artist {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

private struct AlbumGridCell: View {
    @EnvironmentObject private var app: AppModel
    let album: AlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: app.resolvedArtworkURL(for: album), cornerRadius: MusicDesign.albumCorner)
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

    /// Cached so the whole server catalog isn't filtered and sorted on every ``AppModel``
    /// publish while this screen is open.
    @State private var albums: [AlbumSummary] = []

    private func recomputeAlbums() {
        let key = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            albums = []
            return
        }
        albums = app.libraryAlbums
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
                                .coverZoomSource(id: album.id)
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
        .musicInlineNavigationTitleScreen()
        .musicNavigationBarVisibleWhenPushed()
        .onAppear { recomputeAlbums() }
        .onChange(of: app.libraryAlbums.count) { _, _ in recomputeAlbums() }
        .onChange(of: artistName) { _, _ in recomputeAlbums() }
    }
}
