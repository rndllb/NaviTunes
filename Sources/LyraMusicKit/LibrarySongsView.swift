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

    init(downloadsOnly: Bool = false) {
        _libraryFilter = State(initialValue: downloadsOnly ? .downloads : .allSongs)
    }

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var libraryFilter: LibrarySongLibraryFilter
    @State private var sort = LibrarySongSort.dateAdded
    @State private var navigateAlbum: AlbumSummary?
    @State private var trackPendingDownloadedDelete: Track?
    /// Cached projection of `tracks` → filter → search → sort. Recomputed only when an input
    /// changes, so scroll redraws don't re-sort 10k+ items on every body call.
    @State private var displayed: [Track] = []

    private func recomputeDisplayed() {
        // Runs on every searchText keystroke. For very large libraries (50K+ tracks)
        // this filter+sort dominates main-thread time per keystroke — PerfLog will
        // surface the hitch in Console.app and as `recomputeDisplayed` signposts.
        PerfLog.measure("LibrarySongsView.recomputeDisplayed", details: "tracks=\(tracks.count) q=\(searchText.count)c filter=\(libraryFilter) sort=\(sort)") {
            recomputeDisplayedBody()
        }
    }

    private func recomputeDisplayedBody() {
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
        ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
            songRow(track, showsBottomDivider: index < displayed.count - 1)
        }
    }

    private var emptyTitle: String {
        switch libraryFilter {
        case .allSongs: return "No songs"
        case .favorites: return "No favorite songs"
        case .downloads: return "No downloads"
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyDescription: Text {
        switch libraryFilter {
        case .allSongs:
            return Text("Your library has no songs yet.")
        case .favorites:
            return Text(
                "Use Favorite in the ··· menu or on Now Playing. Stars sync with \(app.backendKind.title)."
            )
        case .downloads:
            return Text("Save tracks offline from an album page.")
        }
    }

    var body: some View {
        songsListRoot
            .modifier(LibrarySongsLifecycleModifier(
                load: { await load() },
                recomputeDisplayed: recomputeDisplayed,
                libraryFilter: libraryFilter
            ))
            .downloadedTrackDeleteSheet(
                track: $trackPendingDownloadedDelete,
                app: app,
                offline: offline
            )
    }

    private var songsListRoot: some View {
        List {
            Section {
                playShuffleRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
            }

            songsListBody
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicLibrarySectionScreen(title: "Songs")
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                Menu {
                    filterMenuContent
                } label: {
                    MusicLibraryToolbarIcon(systemName: "line.3.horizontal")
                }
                .menuOrder(.fixed)

                Menu {
                    sortMenuContent
                } label: {
                    MusicLibraryToolbarIcon(systemName: "ellipsis")
                }
                .menuOrder(.fixed)
            }
        }
        .musicLibraryToolbarMonochromeControls()
        .musicNativeSearchable(text: $searchText, prompt: Text("Songs"))
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
                .onDisappear { navigateAlbum = nil }
        }
        .onChange(of: tracks) { _, _ in recomputeDisplayed() }
        .onChange(of: searchText) { _, _ in recomputeDisplayed() }
        .onChange(of: sort) { _, _ in recomputeDisplayed() }
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

    private var playShuffleRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: displayed.isEmpty,
            onPlay: { Task { await playAll() } },
            onShuffle: { Task { await shuffleAll() } },
        )
    }

    @ViewBuilder
    private var songsListBody: some View {
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

    private func songRow(_ track: Track, showsBottomDivider: Bool) -> some View {
        TrackDownloadProgressReader(progress: offline.progressModel, trackId: track.id) { downloadState in
            songRowContent(track, downloadState: downloadState, showsBottomDivider: showsBottomDivider)
        }
        .librarySongListRowStyle()
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
            onGoToAlbum: { openAlbumDetail(for: track) },
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
    }

    private func cacheOffline(track: Track) async {
        app.enqueueOfflineTrack(track)
    }

    private func openAlbumDetail(for track: Track) {
        let album = albumSummary(for: track)
        if navigateAlbum?.id == album.id {
            navigateAlbum = nil
            DispatchQueue.main.async {
                navigateAlbum = album
            }
        } else {
            navigateAlbum = album
        }
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
            tracks = app.tracksForDownloadedLibrary()
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

        if app.libraryMagicPlaylistId == nil, app.librarySongIds.isEmpty {
            await app.refreshLibraryMembership()
        }

        tracks = await app.tracksForPersonalLibrary()
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

/// Subscribes to download progress at the row level so a progress tick re-renders
/// only the affected row, never the hosting list body. Required because
/// ``OfflineDownloadManager`` no longer publishes ``activeDownloads`` through its
/// own `objectWillChange` (see ``OfflineDownloadProgressModel``) — reading
/// `offline.activeDownloads` from a list body would render stale progress.
struct TrackDownloadProgressReader<Content: View>: View {
    @ObservedObject var progress: OfflineDownloadProgressModel
    let trackId: String
    @ViewBuilder let content: (OfflineDownloadUIState?) -> Content

    var body: some View {
        content(progress.activeDownloads[trackId])
    }
}

struct LibrarySongRow: View, Equatable {
    @EnvironmentObject private var app: AppModel
    @AppStorage(LibraryPinStore.storageKey) private var pinnedStorage: String = "[]"
    let track: Track
    var artworkURL: URL? = nil
    var itemSize: SongListItemSize = .medium
    let isFavorite: Bool
    var isNowPlaying: Bool = false
    var offlineDownload: OfflineDownloadUIState? = nil
    var isOfflineCached: Bool = false
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onCancelOfflineDownload: () -> Void
    let onFavorite: () -> Void
    let onPlayNext: () -> Void
    /// When set AND `hasActiveQueue` is true, becomes the outermost leading swipe action.
    var onAddToQueue: (() -> Void)? = nil
    /// Drives whether ``onAddToQueue`` is surfaced as the full-swipe leading action.
    var hasActiveQueue: Bool = false
    var onGoToAlbum: (() -> Void)? = nil
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
    /// Indigo/blue pill swipe actions and compact row metrics on album detail.
    var usesAlbumSwipeChrome: Bool = false
    /// Hairline under the row (inside the cell so it stays put while swiping).
    var showsBottomDivider: Bool = false
    /// Album-detail divider tint; ignored unless ``usesAlbumSwipeChrome``.
    var dividerPalette: ArtworkDynamicGradient.BackdropPalette? = nil
    /// Fixed light-surface label colors (e.g. ``FavoritePlaylistView``) — not accent-tinted.
    var rowLabelPalette: ArtworkDynamicGradient.BackdropPalette? = nil
    /// 1-based track # on album detail rows.
    var trackDisplayIndex: Int? = nil
    /// Reserved ★ slot on library song lists (star shown when favorited).
    var showsLeadingFavoriteStar: Bool = true
    /// Swipe trash on a downloaded library track — host presents ``downloadedTrackDeleteSheet``.
    var onPresentDownloadedDeleteSheet: (() -> Void)? = nil

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
            && lhs.showsArtwork == rhs.showsArtwork
            && lhs.showsArtist == rhs.showsArtist
            && lhs.hidesAddToLibraryChip == rhs.hidesAddToLibraryChip
            && lhs.usesAlbumSwipeChrome == rhs.usesAlbumSwipeChrome
            && lhs.trackDisplayIndex == rhs.trackDisplayIndex
            && lhs.showsLeadingFavoriteStar == rhs.showsLeadingFavoriteStar
            && (lhs.onRemoveFromPlaylist != nil) == (rhs.onRemoveFromPlaylist != nil)
            && (lhs.onRemoveFromLibrary != nil) == (rhs.onRemoveFromLibrary != nil)
            && lhs.isNowPlaying == rhs.isNowPlaying
            && lhs.hasActiveQueue == rhs.hasActiveQueue
            && lhs.showsBottomDivider == rhs.showsBottomDivider
            && lhs.dividerPalette?.prefersDarkHeroChrome == rhs.dividerPalette?.prefersDarkHeroChrome
            && lhs.rowLabelPalette?.prefersDarkHeroChrome == rhs.rowLabelPalette?.prefersDarkHeroChrome
            && LibraryPinStore.contains(
                LibraryPinnedRef(kind: .track, itemId: lhs.track.id),
                in: lhs.pinnedStorage
            ) == LibraryPinStore.contains(
                LibraryPinnedRef(kind: .track, itemId: rhs.track.id),
                in: rhs.pinnedStorage
            )
    }

    private var offlinePhase: TrackOfflineIndicatorPhase {
        TrackOfflineIndicatorPhase(
            offlineDownload: offlineDownload,
            isOfflineCached: isOfflineCached,
            isInLibrary: isInLibrary,
        )
    }

    /// In-library songs that are not on device yet — no cloud glyph; use swipe-to-download instead.
    private var showsTrailingOfflineGlyph: Bool {
        offlinePhase != .notCached
    }

    fileprivate var showsDownloadSwipeAction: Bool {
        !isOfflineCached && offlineDownload == nil
    }

    /// On device — trailing trash opens the downloaded-delete sheet (library or downloads-only).
    private var confirmsDownloadedDelete: Bool {
        isOfflineCached && onPresentDownloadedDeleteSheet != nil
    }

    fileprivate var trailingDeleteSwipeAction: (() -> Void)? {
        if confirmsDownloadedDelete, let onPresentDownloadedDeleteSheet {
            return onPresentDownloadedDeleteSheet
        }
        guard let onRemoveFromLibrary else { return nil }
        return onRemoveFromLibrary
    }

    private var hasArtistSubtitle: Bool {
        showsArtist && !track.artist.isEmpty
    }

    /// ★ before artwork on library lists when the track is favorited (Apple Music).
    private var showsLibraryFavoriteStar: Bool {
        !usesAlbumSwipeChrome && showsArtwork && showsLeadingFavoriteStar && isFavorite
    }

    private var showsLeadingIndicators: Bool {
        if usesAlbumSwipeChrome { return true }
        if showsArtwork { return false }
        return showsLeadingFavoriteStar
    }

    private var trackPinRef: LibraryPinnedRef {
        LibraryPinnedRef(kind: .track, itemId: track.id)
    }

    private var isPinnedToLibrary: Bool {
        LibraryPinStore.contains(trackPinRef, in: pinnedStorage)
    }

    private var titleForeground: Color {
        if usesAlbumSwipeChrome, let dividerPalette {
            return dividerPalette.heroChromePrimary
        }
        if let rowLabelPalette {
            return rowLabelPalette.heroChromePrimary
        }
        if isNowPlaying && !showsArtwork {
            return .accentColor
        }
        return .primary
    }

    private var subtitleForeground: Color {
        if usesAlbumSwipeChrome, let dividerPalette {
            return dividerPalette.heroChromeSecondary
        }
        if let rowLabelPalette {
            return rowLabelPalette.heroChromeSecondary
        }
        return MusicDesign.secondaryLabel
    }

    private var rowMenuGlyphColor: Color {
        if usesAlbumSwipeChrome, let dividerPalette {
            return dividerPalette.heroChromeSecondary
        }
        if let rowLabelPalette {
            return rowLabelPalette.heroChromeSecondary
        }
        return MusicDesign.secondaryLabel
    }

    private var rowDividerColor: Color {
        if usesAlbumSwipeChrome, let dividerPalette {
            return dividerPalette.heroTracklistSeparator
        }
        if let rowLabelPalette {
            return rowLabelPalette.heroTracklistSeparator
        }
        return MusicDesign.separator
    }

    /// Leading edge of the title/subtitle column (divider aligns with text, not artwork).
    private var libraryTitleLeadingInset: CGFloat {
        if usesAlbumSwipeChrome {
            return AlbumTrackRowLayout.librarySongTitleLeadingFromScreenEdge
        }
        let horizontalPadding: CGFloat = 20
        let titleGapAfterArtwork: CGFloat = 14
        if showsArtwork {
            return horizontalPadding + itemSize.artworkSide + titleGapAfterArtwork
        }
        if showsLeadingFavoriteStar {
            return horizontalPadding + AlbumTrackIndexColumn.starSlotWidth + 8
        }
        return horizontalPadding
    }

    private var libraryDividerLeadingInset: CGFloat {
        libraryTitleLeadingInset
    }

    /// Sits in the leading margin (left of artwork) without shifting row layout.
    @ViewBuilder
    private var libraryFavoriteStarInGutter: some View {
        if showsLibraryFavoriteStar {
            Image(systemName: "star.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(rowLabelPalette?.heroChromePrimary ?? MusicDesign.accent)
                .offset(x: -(MusicChevronRowMetrics.leadingPadding - 5))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        rowContent
            .librarySongSwipeActions(
                showsDownload: showsDownloadSwipeAction,
                onPlayNext: onPlayNext,
                onAddToQueue: (hasActiveQueue ? onAddToQueue : nil),
                onDownload: onDownload,
                onRemoveFromPlaylist: onRemoveFromPlaylist,
                onRemoveFromLibrary: trailingDeleteSwipeAction,
                onDeleteFromLibrary: canDeleteFromLibrary ? onDeleteFromLibrary : nil,
                trailingLibraryDeleteIsDestructive: !confirmsDownloadedDelete,
                chipMetrics: usesAlbumSwipeChrome ? .albumTrack : nil
            )
    }

    fileprivate var rowContent: some View {
        rowBody
            .frame(minHeight: usesAlbumSwipeChrome ? AlbumTrackRowLayout.rowMinHeight : nil)
            .overlay(alignment: .bottom) {
                if showsBottomDivider {
                    if usesAlbumSwipeChrome, let dividerPalette {
                        AppleMusicAlbumTrackDivider(
                            palette: dividerPalette,
                            titleLeadingInset: AlbumTrackRowLayout.librarySongTitleLeadingFromScreenEdge
                        )
                        .allowsHitTesting(false)
                    } else {
                        LibrarySongRowDivider(
                            leadingInset: libraryDividerLeadingInset,
                            color: rowDividerColor
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
    }

    private var rowBody: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onPlay) {
                HStack(alignment: .center, spacing: usesAlbumSwipeChrome ? AlbumTrackRowLayout.indexToTitleSpacing : 14) {
                    if showsLeadingIndicators {
                        SongRowLeadingIndicators(
                            trackIndex: usesAlbumSwipeChrome ? trackDisplayIndex : nil,
                            isFavorite: isFavorite,
                            backdropPalette: usesAlbumSwipeChrome ? dividerPalette : nil,
                            isNowPlaying: isNowPlaying
                        )
                    }
                    if showsArtwork {
                        AlbumArtworkView(
                            url: artworkURL ?? track.artworkURL,
                            cornerRadius: 6,
                            maxDecodePixels: Self.rowArtworkDecodePixels,
                        )
                        .frame(width: itemSize.artworkSide, height: itemSize.artworkSide)
                        .overlay(alignment: .leading) {
                            libraryFavoriteStarInGutter
                        }
                        .overlay(alignment: .center) {
                            if isNowPlaying {
                                ZStack {
                                    Color.black.opacity(0.45)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    NowPlayingBarsIndicator(player: app.player, color: .white)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: usesAlbumSwipeChrome ? AlbumTrackRowLayout.titleSubtitleSpacing : 4) {
                        Text(track.title)
                            .font(usesAlbumSwipeChrome ? .subheadline.weight(.semibold) : itemSize.titleFont)
                            .foregroundStyle(titleForeground)
                            .lineLimit(usesAlbumSwipeChrome ? 1 : 2)
                            .multilineTextAlignment(.leading)
                        if hasArtistSubtitle {
                            Text(track.artist)
                                .font(itemSize.subtitleFont)
                                .foregroundStyle(subtitleForeground)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(rowLabelPalette?.heroChromePrimary)

            if showsTrailingOfflineGlyph, !(hidesAddToLibraryChip && offlinePhase == .addToLibrary) {
                TrackOfflineDownloadIndicator(
                    phase: offlinePhase,
                    onCancelDownload: offlinePhase.isDownloading ? { onCancelOfflineDownload() } : nil,
                    onTapStartDownload: usesAlbumSwipeChrome ? nil : (offlinePhase == .notCached ? { onDownload() } : nil),
                    onAddToLibrary: offlinePhase == .addToLibrary ? onAddToLibrary : nil,
                    backdropPalette: usesAlbumSwipeChrome ? dividerPalette : rowLabelPalette
                )
            }

                Menu {
                    ControlGroup {
                        if !isInLibrary, let onAddToLibrary {
                            Button(action: onAddToLibrary) {
                                Label("Add to Library", systemImage: "plus")
                            }
                        } else if isInLibrary, !isOfflineCached {
                            Button(action: onDownload) {
                                Label("Download", systemImage: "arrow.down")
                            }
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
                        Button {
                            if !isPinnedToLibrary {
                                app.retainTrackForLibraryPin(track)
                            }
                            LibraryPinStore.toggle(trackPinRef, storage: &pinnedStorage)
                        } label: {
                            Label(
                                LibraryPinStore.menuLabel(kind: .track, isPinned: isPinnedToLibrary),
                                systemImage: isPinnedToLibrary ? "pin.slash" : "pin"
                            )
                        }
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
                    }
                    .tint(Color.primary)

                    if let onGoToAlbum {
                        Section {
                            Button(action: onGoToAlbum) {
                                Label("Go to Album", systemImage: "music.note.square")
                            }
                        }
                        .tint(Color.primary)
                    }

                    NavidromeShareMenuSection(
                        itemId: track.id,
                        description: "\(track.title) — \(track.artist)"
                    )

                    if isOfflineCached {
                        Section {
                            // Informational "this song is on device" row — disabled so it
                            // reads as a status indicator, not an action.
                            Button {} label: {
                                Label("Downloaded", systemImage: "checkmark.circle.fill")
                            }
                            .disabled(true)
                            if let onRemoveDownload {
                                Button(action: onRemoveDownload) {
                                    Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                                }
                            }
                        }
                        .tint(Color.primary)
                    }

                    if onRemoveFromLibrary != nil || canDeleteFromLibrary {
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
                        .tint(MusicDesign.destructiveAction)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(usesAlbumSwipeChrome ? .caption.weight(.semibold) : .body.weight(.semibold))
                        .foregroundStyle(rowMenuGlyphColor)
                        .frame(
                            width: usesAlbumSwipeChrome ? 22 : 32,
                            height: usesAlbumSwipeChrome ? 22 : 36
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, usesAlbumSwipeChrome ? AlbumTrackRowLayout.horizontalPadding : 20)
            .padding(.vertical, usesAlbumSwipeChrome ? AlbumTrackRowLayout.verticalRowPadding : itemSize.libraryVerticalPadding)
            .background(rowBackgroundFill)
    }
}

/// Hairline between library song rows — aligns past artwork when shown.
struct LibrarySongRowDivider: View {
    var leadingInset: CGFloat
    var trailingInset: CGFloat = 20
    var color: Color = MusicDesign.separator

    var body: some View {
        MusicInsetHairlineDivider(
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            color: color,
        )
    }
}

/// Compact tracklist placeholder — sits directly under hero / divider (fixed height, no List stretch).
struct AlbumTracklistLoadingRow: View {
    var palette: ArtworkDynamicGradient.BackdropPalette?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.9)
                .tint(palette?.heroAccent ?? MusicDesign.accent)
            Text("Loading tracks…")
                .font(.subheadline)
                .foregroundStyle(palette?.heroChromeSecondary ?? MusicDesign.secondaryLabel)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AlbumTracklistLoadingRowChrome: ViewModifier {
    let isAlbum: Bool
    let palette: ArtworkDynamicGradient.BackdropPalette

    func body(content: Content) -> some View {
        if isAlbum {
            content.albumTrackListRowStyle()
        } else {
            content
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }
}

/// Zero vertical content margins on album detail lists only.
struct AlbumDetailListContentMargins: ViewModifier {
    let isAlbum: Bool

    func body(content: Content) -> some View {
        if isAlbum {
            content.contentMargins(.vertical, 0, for: .scrollContent)
        } else {
            content
        }
    }
}

struct SwipeActionChipMetrics {
    let width: CGFloat
    let height: CGFloat
    let iconFont: Font
    let playNextTint: Color
    let downloadTint: Color
    let deleteTint: Color
    let addToQueueTint: Color

    static let addToQueueColor = Color(red: 0.97, green: 0.62, blue: 0.36)

    static let albumTrack = SwipeActionChipMetrics(
        width: AlbumTrackSwipeChipMetrics.width,
        height: AlbumTrackSwipeChipMetrics.height,
        iconFont: AlbumTrackSwipeChipMetrics.iconFont,
        playNextTint: AlbumTrackSwipeChipMetrics.playNextTint,
        downloadTint: AlbumTrackSwipeChipMetrics.downloadTint,
        deleteTint: AlbumTrackSwipeChipMetrics.deleteTint,
        addToQueueTint: addToQueueColor
    )
}

extension View {
    /// Leading Play Next and trailing Download / delete (icon-only) — requires a parent `List`.
    /// When `onAddToQueue` is provided, it becomes the outermost (full-swipe) leading action
    /// — caller decides when (e.g. only when an active queue exists).
    func librarySongSwipeActions(
        showsDownload: Bool,
        onPlayNext: @escaping () -> Void,
        onAddToQueue: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        onRemoveFromPlaylist: (() -> Void)? = nil,
        onRemoveFromLibrary: (() -> Void)? = nil,
        onDeleteFromLibrary: (() -> Void)? = nil,
        /// When false, trailing trash only presents a confirmation sheet — avoid `List` row-delete animation.
        trailingLibraryDeleteIsDestructive: Bool = true,
        chipMetrics: SwipeActionChipMetrics? = nil
    ) -> some View {
        swipeActions(edge: .leading, allowsFullSwipe: true) {
            // First button is the outermost on screen AND the full-swipe target — when
            // a queue exists, that's "Add to Queue" so the gesture matches the user's
            // intent to append to the end.
            if let onAddToQueue {
                Button(action: onAddToQueue) {
                    swipeActionIcon("text.append", metrics: chipMetrics)
                }
                .tint(chipMetrics?.addToQueueTint ?? SwipeActionChipMetrics.addToQueueColor)
                .accessibilityLabel("Add to Queue")
            }
            Button(action: onPlayNext) {
                swipeActionIcon("text.line.first.and.arrowtriangle.forward", metrics: chipMetrics)
            }
            .tint(chipMetrics?.playNextTint ?? MusicDesign.accent)
            .accessibilityLabel("Play Next")
        }
        // Full swipe on the trailing edge commits Remove-from-Playlist in playlist
        // context (the only button shown there); disabled elsewhere so a wide swipe
        // can't accidentally trigger a Download/Delete on a library song.
        .swipeActions(edge: .trailing, allowsFullSwipe: onRemoveFromPlaylist != nil) {
            if showsDownload, onRemoveFromPlaylist == nil, let onDownload {
                Button(action: onDownload) {
                    swipeActionIcon("arrow.down", metrics: chipMetrics)
                }
                .tint(chipMetrics?.downloadTint ?? MusicDesign.accent)
                .accessibilityLabel("Download")
            }
            if let onRemoveFromPlaylist {
                Button(action: onRemoveFromPlaylist) {
                    swipeActionIcon("trash", metrics: chipMetrics)
                }
                .tint(chipMetrics?.deleteTint ?? MusicDesign.destructiveAction)
                .accessibilityLabel("Remove")
            } else if let onRemoveFromLibrary {
                Group {
                    if trailingLibraryDeleteIsDestructive {
                        Button(role: .destructive, action: onRemoveFromLibrary) {
                            swipeActionIcon("trash", metrics: chipMetrics)
                        }
                    } else {
                        Button(action: onRemoveFromLibrary) {
                            swipeActionIcon("trash", metrics: chipMetrics)
                        }
                    }
                }
                .tint(chipMetrics?.deleteTint ?? MusicDesign.destructiveAction)
                .accessibilityLabel("Delete from Library")
            } else if let onDeleteFromLibrary {
                Button(role: .destructive, action: onDeleteFromLibrary) {
                    swipeActionIcon("trash", metrics: chipMetrics)
                }
                .tint(chipMetrics?.deleteTint ?? MusicDesign.destructiveAction)
                .accessibilityLabel("Delete")
            }
        }
    }

    @ViewBuilder
    private func swipeActionIcon(_ systemName: String, metrics: SwipeActionChipMetrics?) -> some View {
        if let metrics {
            ZStack {
                Color.clear
                    .frame(width: metrics.width, height: metrics.height)
                Image(systemName: systemName)
                    .font(metrics.iconFont)
            }
        } else {
            Image(systemName: systemName)
        }
    }

    /// Library-style song rows over a dynamic hero backdrop (playlists on ``AlbumHeroBackdropView``).
    func heroBackdropSongListRowStyle(highlightOpacity: Double = 0) -> some View {
        listRowBackground(
            ZStack {
                Color.clear
                Color.accentColor.opacity(highlightOpacity)
            }
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    /// Plain list row chrome for ``LibrarySongRow`` (requires a parent `List` for swipe actions).
    /// `highlightOpacity` drives a brief accent flash used by deep-link scroll targets.
    func librarySongListRowStyle(highlightOpacity: Double = 0) -> some View {
        listRowBackground(
            ZStack {
                MusicDesign.background
                Color.accentColor.opacity(highlightOpacity)
            }
        )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }

    /// ``FavoritePlaylistView`` — artwork rows on the fixed white hero wash (not ``MusicDesign.background``).
    func favoriteSongsListRowStyle(highlightOpacity: Double = 0) -> some View {
        listRowBackground(
            ZStack {
                Color.white
                Color.accentColor.opacity(highlightOpacity)
            }
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    /// Album hero track rows — clear cells over ``AlbumHeroBackdropView``, inset narrower than hero.
    /// `highlightOpacity` drives a brief accent flash used by deep-link scroll targets.
    func albumTrackListRowStyle(highlightOpacity: Double = 0) -> some View {
        let inset = AlbumTrackRowLayout.listHorizontalInset
        return environment(\.defaultMinListRowHeight, 0)
            .listRowBackground(
                ZStack {
                    Color.clear
                    Color.accentColor.opacity(highlightOpacity)
                }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
            .listRowSeparator(.hidden)
    }

}

private struct LibrarySongsLifecycleModifier: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let load: () async -> Void
    let recomputeDisplayed: () -> Void
    let libraryFilter: LibrarySongLibraryFilter

    func body(content: Content) -> some View {
        content
            .task { await load() }
            .onChange(of: app.libraryCatalogEpoch) { _, _ in
                Task { await load() }
            }
            .onChange(of: libraryFilter) { _, _ in
                Task { await load() }
            }
            .onChange(of: app.favoriteTrackIds) { _, _ in
                if libraryFilter == .favorites { recomputeDisplayed() }
            }
            .onChange(of: app.offline.downloadedTrackIds) { _, _ in
                switch libraryFilter {
                case .downloads, .allSongs:
                    Task { await load() }
                case .favorites:
                    break
                }
            }
            .onChange(of: app.librarySongIds) { _, _ in
                Task { await load() }
            }
            .onChange(of: app.libraryMagicPlaylistId) { _, _ in
                Task { await load() }
            }
    }
}
