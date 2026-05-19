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
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var libraryFilter = LibrarySongLibraryFilter.allSongs
    @State private var sort = LibrarySongSort.dateAdded
    @State private var navigateAlbum: AlbumSummary?

    private var filtered: [Track] {
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
            return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return base.sorted {
                let cmpArtist = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if cmpArtist != .orderedSame { return cmpArtist == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .dateAdded:
            return base.sorted { lhs, rhs in
                let ld = lhs.libraryAddedDate ?? .distantPast
                let rd = rhs.libraryAddedDate ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
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
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "music.note",
                    description: emptyDescription
                )
                .padding(.top, 32)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(filtered, id: \.id) { track in
                    songRow(track)
                        .listRowBackground(MusicDesign.background)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparatorTint(MusicDesign.separator)
                }
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
            AlbumDetailView(album: album)
        }
        .task {
            await load()
        }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
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
            isDisabled: filtered.isEmpty,
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
        defer { isLoading = false }

        if libraryFilter == .downloads {
            tracks = app.offline.cachedTracks()
            if tracks.isEmpty, !app.isSignedIn {
                loadError = "Sign in to browse your library."
            }
            return
        }

        guard let lib = app.activeLibrary else {
            tracks = app.offline.cachedTracks()
            loadError = tracks.isEmpty ? "Sign in to browse your library." : nil
            return
        }
        do {
            tracks = try await lib.allTracks(limit: 50_000)
            app.mergeOfflineCatalogFromDownloads()
        } catch {
            tracks = app.discoveryLibraryTracks
            if tracks.isEmpty {
                tracks = app.offline.cachedTracks()
            }
            loadError = tracks.isEmpty ? error.localizedDescription : nil
        }
    }

    private func playAll() async {
        guard !filtered.isEmpty else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: filtered, startIndex: 0)
    }

    private func shuffleAll() async {
        guard !filtered.isEmpty else { return }
        let shuffled = filtered.shuffled()
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: shuffled, startIndex: 0)
    }

    private func play(track: Track) async {
        guard let idx = filtered.firstIndex(where: { $0.id == track.id }) else { return }
        try? await app.player.playAlbum(library: app.activeLibrary, tracks: filtered, startIndex: idx)
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
    var onDeleteFromLibrary: () -> Void = {}
    var canDeleteFromLibrary: Bool = false
    var onRemoveDownload: (() -> Void)? = nil

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
            && (lhs.onRemoveFromPlaylist != nil) == (rhs.onRemoveFromPlaylist != nil)
    }

    private var offlinePhase: TrackOfflineIndicatorPhase {
        TrackOfflineIndicatorPhase(offlineDownload: offlineDownload, isOfflineCached: isOfflineCached)
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
                        Self.swipeChipIcon("trash")
                    }
                    .tint(.red)
                    .accessibilityLabel("Delete from Library")
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
                    AlbumArtworkView(url: artworkURL ?? track.artworkURL, cornerRadius: 6)
                        .frame(width: itemSize.artworkSide, height: itemSize.artworkSide)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(itemSize.titleFont)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(track.artist)
                            .font(itemSize.subtitleFont)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TrackOfflineDownloadIndicator(
                    phase: offlinePhase,
                    onCancelDownload: offlinePhase.isDownloading ? { onCancelOfflineDownload() } : nil,
                    onTapStartDownload: offlinePhase == .notCached ? { onDownload() } : nil
                )

                Menu {
                    ControlGroup {
                        if let onRemoveDownload, isOfflineCached {
                            Button(action: onRemoveDownload) {
                                Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                            }
                        } else {
                            Button(action: onDownload) {
                                Label("Download", systemImage: "arrow.down.circle")
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
                        Button(role: .destructive, action: onDeleteFromLibrary) {
                            Label("Delete from Library", systemImage: "trash")
                        }
                        .disabled(!canDeleteFromLibrary)
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
            .background(MusicDesign.background)
    }
}

