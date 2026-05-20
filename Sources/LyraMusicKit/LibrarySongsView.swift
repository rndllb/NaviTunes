import SwiftUI

private enum LibrarySongLibraryFilter: String, CaseIterable {
    case allSongs
    case favorites
    case downloads
}

private enum LibrarySongSort: String {
    case title
    case dateAdded
    case artist
}

/// Apple Music–style flat song list for **Library → Songs**.
struct LibrarySongsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var reachedEnd = false
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var libraryFilter = LibrarySongLibraryFilter.allSongs
    @State private var sort = LibrarySongSort.dateAdded
    @State private var navigateAlbum: AlbumSummary?
    @State private var lastPaginationOffset: Int?
    /// Cached projection of `tracks` → filter → search → sort. Recomputed only when an input
    /// changes, so scroll redraws don't re-sort 10k+ items on every body call.
    @State private var displayed: [Track] = []

    private static let initialPageLimit = 300
    private static let jellyfinNextPageLimit = 500
    private static let navidromeNextPageLimit = 180
    private static let paginationPrefetchDistance = 40

    private var nextPageLimit: Int {
        app.backendKind == .navidrome ? Self.navidromeNextPageLimit : Self.jellyfinNextPageLimit
    }

    private var paginationTriggerTrackId: String? {
        guard !displayed.isEmpty, !reachedEnd, !isLoading, !isLoadingMore else { return nil }
        let triggerIndex = max(0, displayed.count - Self.paginationPrefetchDistance)
        return displayed[triggerIndex].id
    }

    private func recomputeDisplayed() {
        let byLibrary: [Track]
        switch libraryFilter {
        case .allSongs:
            byLibrary = tracks
        case .favorites:
            byLibrary = tracks.filter { app.favoriteTrackIds.contains($0.id) }
        case .downloads:
            byLibrary = tracks.filter { app.offline.downloadedTrackIds.contains($0.id) }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Track]
        if q.isEmpty {
            base = byLibrary
        } else {
            base = byLibrary.filter {
                $0.title.lowercased().contains(q)
                    || $0.artist.lowercased().contains(q)
                    || $0.albumTitle.lowercased().contains(q)
            }
        }
        switch sort {
        case .title:
            displayed = base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            displayed = base.sorted {
                let cmpArtist = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if cmpArtist != .orderedSame { return cmpArtist == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .dateAdded:
            displayed = base.sorted { lhs, rhs in
                let ld = lhs.libraryAddedDate ?? .distantPast
                let rd = rhs.libraryAddedDate ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private var trackListRows: some View {
        let triggerTrackId = paginationTriggerTrackId
        ForEach(displayed) { track in
            songRow(track)
                .listRowBackground(MusicDesign.background)
                .listRowInsets(EdgeInsets())
                .listRowSeparatorTint(MusicDesign.separator)
                .onAppear {
                    if track.id == triggerTrackId {
                        Task { await loadMoreIfNeeded(triggeredBy: track.id) }
                    }
                }
        }
        if isLoadingMore, !reachedEnd {
            ProgressView()
                .tint(MusicDesign.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var emptyTitle: String {
        switch libraryFilter {
        case .allSongs: return "No songs"
        case .favorites: return "No favorite songs"
        case .downloads: return "No downloads"
        }
    }

    private var emptyDescription: Text {
        switch libraryFilter {
        case .allSongs:
            return Text(searchText.isEmpty ? "Your library has no songs yet." : "Nothing matches your search.")
        case .favorites:
            return Text(
                searchText.isEmpty
                    ? "Use Favorite in the ··· menu or on Now Playing. Stars sync with \(app.backendKind.title)."
                    : "Nothing matches your search."
            )
        case .downloads:
            return Text(searchText.isEmpty ? "Save tracks offline from an album page." : "Nothing matches your search.")
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
            } else if displayed.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "music.note",
                    description: emptyDescription
                )
                .padding(.top, 32)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                trackListRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .navigationTitle("Songs")
        .musicNavigationBarTitleDisplayMode(.large)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                Menu {
                    filterMenuContent
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.primary)
                }
                .menuOrder(.fixed)

                Menu {
                    sortMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                }
                .menuOrder(.fixed)
            }
        }
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
        }
        .task {
            await load()
        }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .onChange(of: tracks) { _, _ in recomputeDisplayed() }
        .onChange(of: searchText) { _, _ in recomputeDisplayed() }
        .onChange(of: libraryFilter) { _, _ in recomputeDisplayed() }
        .onChange(of: sort) { _, _ in recomputeDisplayed() }
        .onChange(of: app.favoriteTrackIds) { _, _ in
            if libraryFilter == .favorites { recomputeDisplayed() }
        }
        .onChange(of: app.offline.downloadedTrackIds) { _, _ in
            if libraryFilter == .downloads { recomputeDisplayed() }
        }
        .onChange(of: app.librarySongIds) { _, _ in
            tracks = libraryTracksFromCatalog()
        }
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Button {
            libraryFilter = .allSongs
        } label: {
            HStack {
                Label("All Songs", systemImage: "music.note")
                Spacer(minLength: 16)
                if libraryFilter == .allSongs {
                    Image(systemName: "checkmark")
                }
            }
        }
        Button {
            libraryFilter = .favorites
        } label: {
            HStack {
                Label("Favorites", systemImage: "star")
                Spacer(minLength: 16)
                if libraryFilter == .favorites {
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

    private var searchSection: some View {
        LibrarySearchPill(prompt: "Search", text: $searchText)
    }

    private var playShuffleRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: displayed.isEmpty,
            onPlay: { Task { await playAll() } },
            onShuffle: { Task { await shuffleAll() } },
        )
    }

    private func songRow(_ track: Track) -> some View {
        LibrarySongRow(
            track: track,
            artworkURL: app.resolvedArtworkURL(for: track),
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
            onAddToQueue: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.addToQueue(library: lib, track: track)
                }
            },
            hasActiveQueue: !app.player.queue.isEmpty,
            onGoToAlbum: { navigateAlbum = albumSummary(for: track) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { Task { await app.removeSongFromLibrary(track) } } : nil,
            onDeleteFromLibrary: { app.beginLibraryTrackDeletion(track) },
            canDeleteFromLibrary: app.canDeleteFromLibrary,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                ? { try? app.offline.remove(trackId: track.id) } : nil
        )
        .equatable()
    }

    private func cacheOffline(track: Track) async {
        guard let lib = app.activeLibrary else { return }
        do {
            let url = try lib.offlineDownloadURL(for: track)
            try await app.offline.cache(track: track, remote: url, headers: lib.httpHeadersForMediaRequests())
        } catch {}
    }

    private func albumSummary(for track: Track) -> AlbumSummary {
        if let cached = app.libraryAlbums.first(where: { $0.id == track.albumId }) {
            return cached
        }
        return AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? "Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: track.artworkURL,
            trackCount: nil,
            libraryAddedDate: nil,
            genres: track.genres,
            releaseYear: track.releaseYear,
        )
    }

    private func load() async {
        isLoading = true
        loadError = nil
        reachedEnd = true   // Library is a fixed user-curated set; never paginates from the server.
        lastPaginationOffset = nil
        defer { isLoading = false }

        if libraryFilter == .downloads {
            tracks = app.offline.cachedTracks()
            if tracks.isEmpty, !app.isSignedIn {
                loadError = "Sign in to browse your library."
            }
            return
        }

        guard app.activeLibrary != nil else {
            tracks = app.offline.cachedTracks()
            loadError = tracks.isEmpty ? "Sign in to browse your library." : nil
            return
        }
        // Source of truth = the magic-playlist song set. Resolve IDs against the in-memory
        // catalog (built by ``AppModel.refreshLibraryTrackMatchIndex``). Anything not yet
        // indexed will fill in on the next library refresh.
        tracks = libraryTracksFromCatalog()
    }

    private func libraryTracksFromCatalog() -> [Track] {
        let ids = app.librarySongIds
        guard !ids.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Track] = []
        out.reserveCapacity(ids.count)
        for track in app.discoveryLibraryTracks where ids.contains(track.id) {
            if seen.insert(track.id).inserted {
                out.append(track)
            }
        }
        // Pick up any cached-offline tracks that haven't been merged into discoveryLibraryTracks yet.
        for track in app.offline.cachedTracks() where ids.contains(track.id) {
            if seen.insert(track.id).inserted {
                out.append(track)
            }
        }
        return out
    }

    private func loadMoreIfNeeded(triggeredBy triggerTrackId: String?) async {
        guard !reachedEnd, !isLoadingMore, !isLoading else { return }
        guard libraryFilter != .downloads else { return }
        guard let lib = app.activeLibrary else { return }
        guard triggerTrackId == paginationTriggerTrackId else { return }
        let offset = tracks.count
        guard lastPaginationOffset != offset else { return }
        let pageLimit = nextPageLimit
        lastPaginationOffset = offset
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await lib.tracksPage(offset: offset, limit: pageLimit)
            if page.isEmpty {
                reachedEnd = true
                return
            }
            // Dedupe in case the backend's pagination overlaps (Subsonic search3 has no stable order guarantee).
            let existing = Set(tracks.map(\.id))
            let fresh = page.filter { !existing.contains($0.id) }
            if fresh.isEmpty {
                reachedEnd = true
                return
            }
            tracks.append(contentsOf: fresh)
            if page.count < pageLimit { reachedEnd = true }
        } catch {
            // Stop trying to paginate on error so we don't hammer a failing endpoint.
            reachedEnd = true
        }
    }

    private func playAll() async {
        guard !displayed.isEmpty else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: displayed, startIndex: 0)
    }

    private func shuffleAll() async {
        guard !displayed.isEmpty else { return }
        let shuffled = displayed.shuffled()
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: shuffled, startIndex: 0)
    }

    private func play(track: Track) async {
        guard let idx = displayed.firstIndex(where: { $0.id == track.id }) else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: displayed, startIndex: idx)
    }
}

struct LibrarySongRow: View, Equatable {
    let track: Track
    var artworkURL: URL? = nil
    var itemSize: SongListItemSize = .medium
    let isFavorite: Bool
    var offlineDownload: OfflineDownloadUIState? = nil
    var isOfflineCached: Bool = false
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onCancelOfflineDownload: () -> Void
    let onFavorite: () -> Void
    let onPlayNext: () -> Void
    var onAddToQueue: (() -> Void)? = nil
    var hasActiveQueue: Bool = false
    let onGoToAlbum: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    /// User-level remove from Lyra library (drops the song from the magic playlist).
    /// When `nil` the menu item is hidden — useful in non-library surfaces.
    var onRemoveFromLibrary: (() -> Void)? = nil
    var onDeleteFromLibrary: () -> Void = {}
    var canDeleteFromLibrary: Bool = false
    var onRemoveDownload: (() -> Void)? = nil
    /// Adds the song to the user's Lyra library (magic playlist). When supplied AND the
    /// song isn't currently in library, the 3-dot menu's leading item switches from
    /// "Download" to "Add to Library."
    var onAddToLibrary: (() -> Void)? = nil
    /// `true` when the song is part of the user's Lyra library. Used to pick the right
    /// leading menu item (Download vs Add to Library) and the matching inline chip state.
    var isInLibrary: Bool = true
    /// Hide the inline trailing "+" chip when the song isn't in library. The 3-dot menu's
    /// "Add to Library" item is unaffected. Used in playlist rows where the inline plus
    /// is redundant with the menu and visually noisy alongside other playlist chrome.
    var hidesAddToLibraryChip: Bool = false
    /// Hide the leading square artwork (album-detail rows; every row would have the
    /// same cover, which is redundant).
    var showsArtwork: Bool = true
    /// Hide the artist subtitle (album-detail rows — artist already shown in the hero).
    var showsArtist: Bool = true
    /// Solid background the row renders behind its content. Defaults to the standard
    /// list surface; album-detail rows pass `.clear` so the dynamic backdrop palette
    /// shows through the List.
    var rowBackgroundFill: Color = MusicDesign.background

    private static let rowArtworkDecodePixels: CGFloat = 192

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.track.id == rhs.track.id
            && lhs.artworkURL == rhs.artworkURL
            && lhs.track.artworkURL == rhs.track.artworkURL
            && lhs.itemSize == rhs.itemSize
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isOfflineCached == rhs.isOfflineCached
            && lhs.canDeleteFromLibrary == rhs.canDeleteFromLibrary
            && lhs.offlineDownload == rhs.offlineDownload
            && lhs.hasActiveQueue == rhs.hasActiveQueue
            && lhs.showsArtwork == rhs.showsArtwork
            && lhs.showsArtist == rhs.showsArtist
            && lhs.hidesAddToLibraryChip == rhs.hidesAddToLibraryChip
            && (lhs.onRemoveFromPlaylist != nil) == (rhs.onRemoveFromPlaylist != nil)
            && (lhs.onRemoveFromLibrary != nil) == (rhs.onRemoveFromLibrary != nil)
    }

    private var offlinePhase: TrackOfflineIndicatorPhase {
        TrackOfflineIndicatorPhase(
            offlineDownload: offlineDownload,
            isOfflineCached: isOfflineCached,
            isInLibrary: isInLibrary,
        )
    }

    var body: some View {
        // Wrapping the icon over a transparent sizing rectangle gives the Button a
        // hard intrinsic size — the swipe drawer reads that and the chip background
        // becomes a horizontal capsule (because chip corner radius = height/2, and
        // width > height).
        // The first button in the closure is the outermost on screen AND the one the
        // full-swipe gesture commits — when a queue exists that's "Add to Queue".
        rowContent
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if hasActiveQueue, let onAddToQueue {
                    Button(action: onAddToQueue) {
                        Self.swipeChipIcon("text.badge.plus")
                    }
                    .tint(Self.addToQueueTint)
                    .accessibilityLabel("Add to Queue")
                }
                Button(action: onPlayNext) {
                    Self.swipeChipIcon("text.line.first.and.arrowtriangle.forward")
                }
                .tint(MusicDesign.accent)
                .accessibilityLabel("Play Next")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let onRemoveFromPlaylist {
                    Button(role: .destructive, action: onRemoveFromPlaylist) {
                        Self.swipeChipIcon("trash")
                    }
                    .tint(.red)
                    .accessibilityLabel("Remove from Playlist")
                } else if canDeleteFromLibrary {
                    Button(role: .destructive, action: onDeleteFromLibrary) {
                        Self.swipeChipIcon("xmark.bin")
                    }
                    .tint(.red)
                    .accessibilityLabel("Delete File from Server")
                }
            }
    }

    private static let swipeChipWidth: CGFloat = 96
    private static let swipeChipHeight: CGFloat = 34
    private static let addToQueueTint = Color(red: 0.97, green: 0.62, blue: 0.36)

    @ViewBuilder
    private static func swipeChipIcon(_ systemName: String) -> some View {
        ZStack {
            Color.clear.frame(width: swipeChipWidth, height: swipeChipHeight)
            Image(systemName: systemName)
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onPlay) {
                HStack(alignment: .center, spacing: 14) {
                    if showsArtwork {
                        AlbumArtworkView(
                            url: artworkURL ?? track.artworkURL,
                            cornerRadius: 6,
                            maxDecodePixels: Self.rowArtworkDecodePixels,
                        )
                            .frame(width: itemSize.artworkSide, height: itemSize.artworkSide)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(itemSize.titleFont)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if showsArtist {
                            Text(track.artist)
                                .font(itemSize.subtitleFont)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !(hidesAddToLibraryChip && offlinePhase == .addToLibrary) {
                TrackOfflineDownloadIndicator(
                    phase: offlinePhase,
                    onCancelDownload: offlinePhase.isDownloading ? { onCancelOfflineDownload() } : nil,
                    onTapStartDownload: offlinePhase == .notCached ? { onDownload() } : nil,
                    onAddToLibrary: offlinePhase == .addToLibrary ? onAddToLibrary : nil,
                )
            }

                Menu {
                    ControlGroup {
                        if !isInLibrary, let onAddToLibrary {
                            // Out-of-library context (e.g. browse album detail) — the
                            // first menu action gets the user to add it before letting
                            // them download it.
                            Button(action: onAddToLibrary) {
                                Label("Add to Library", systemImage: "plus")
                            }
                        } else if let onRemoveDownload, isOfflineCached {
                            Button(action: onRemoveDownload) {
                                Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                            }
                        } else {
                            Button(action: onDownload) {
                                Label("Download", systemImage: "arrow.down")
                            }
                            .disabled(isOfflineCached)
                        }
                        Button(action: onFavorite) {
                            Label(
                                isFavorite ? "Unfavorite" : "Favorite",
                                systemImage: isFavorite ? "star.fill" : "star"
                            )
                        }
                        ShareLink(item: "\(track.title) — \(track.artist)") {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .tint(Color.primary)

                    Section {
                        Button {} label: { Label("Pin Song", systemImage: "pin") }
                        if let onAddToPlaylist {
                            Button(action: onAddToPlaylist) {
                                Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
                            }
                        } else {
                            Button {} label: { Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus") }
                        }
                    }
                    .tint(Color.primary)

                    Section {
                        Button(action: onPlayNext) {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {} label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
                    }
                    .tint(Color.primary)

                    Section {
                        Button(action: onGoToAlbum) {
                            Label("Go to Album", systemImage: "music.note.square")
                        }
                        Button {} label: { Label("View Credits", systemImage: "info.circle") }
                    }
                    .tint(Color.primary)

                    Section {
                        Button {} label: { Label("Suggest Less", systemImage: "hand.thumbsdown") }
                    }
                    .tint(Color.primary)

                    Section {
                        if let onRemoveFromLibrary {
                            // User-level (magic playlist) — always available when the
                            // host view supplied the callback. Album entry is left alone;
                            // the album stays in library with one fewer track.
                            Button(role: .destructive, action: onRemoveFromLibrary) {
                                Label("Delete from Library", systemImage: "trash")
                            }
                        }
                        // Admin-only: removes the file from the server entirely.
                        if canDeleteFromLibrary {
                            Button(role: .destructive, action: onDeleteFromLibrary) {
                                Label("Delete File from Server", systemImage: "xmark.bin")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, itemSize.libraryVerticalPadding)
            .background(rowBackgroundFill)
    }
}
