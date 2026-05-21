import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Playlist visibility (Jellyfin + Navidrome)

private struct PlaylistVisibilityFields: View {
    @Binding var isPublic: Bool

    var body: some View {
        Toggle("Visible to all", isOn: $isPublic)
        Text("When off, only you can see this playlist. When on, other users on the server can see it.")
            .font(.caption)
            .foregroundStyle(MusicDesign.secondaryLabel)
    }
}

// MARK: - Add to playlist (global sheet)

struct AddToPlaylistSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let tracks: [Track]

    @State private var newPlaylistName = ""
    @State private var isPublic = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("New playlist") {
                    TextField("Playlist name", text: $newPlaylistName)
                        .musicTextInputAutocapitalization(.words)
                    PlaylistVisibilityFields(isPublic: $isPublic)
                    Button {
                        Task { await createNewAndAdd() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Create and add")
                        }
                    }
                    .disabled(isWorking || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Your playlists") {
                    if app.libraryPlaylists.isEmpty {
                        Text("No playlists yet. Create one above.")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    } else {
                        ForEach(app.libraryPlaylists) { pl in
                            Button(pl.name) {
                                Task { await addToExisting(pl.id) }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MusicDesign.background)
            .navigationTitle("Add to playlist")
            .musicNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        app.dismissPlaylistPicker()
                        dismiss()
                    }
                }
            }
            .musicNavigationChrome()
        }
        .task {
            await app.refreshLibraryPlaylists()
        }
    }

    private func createNewAndAdd() async {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.createPlaylist(
                name: name,
                initialTracks: tracks,
                isPublic: isPublic,
            )
            app.dismissPlaylistPicker()
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func addToExisting(_ playlistId: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.addTracksToPlaylist(playlistId: playlistId, tracks: tracks)
            app.dismissPlaylistPicker()
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Create empty playlist

struct NewPlaylistNameSheet: View {
    var body: some View {
        PlaylistEditSheet(mode: .create)
    }
}

// MARK: - New folder sheet

struct NewFolderNameSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isPublic = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $name)
                #if os(iOS)
                    .musicTextInputAutocapitalization(.words)
                #endif
                PlaylistVisibilityFields(isPublic: $isPublic)
                Text("A folder groups playlists together. It will appear in your library once created.")
                    .font(.caption)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
            .scrollContentBackground(.hidden)
            .background(MusicDesign.background)
            .navigationTitle("New Folder")
            .musicNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
            .musicNavigationChrome()
        }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.createPlaylist(name: trimmed, initialTracks: [], isPublic: isPublic)
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Server playlist detail

private enum PlaylistTrackSortOrder: String, CaseIterable, Identifiable {
    case playlistOrder = "Playlist Order"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case dateAdded = "Date Added"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .playlistOrder: return "list.number"
        case .title: return "textformat"
        case .artist: return "music.mic"
        case .album: return "square.stack"
        case .dateAdded: return "calendar"
        }
    }
}

/// Tagged source for ``ServerPlaylistDetailView``. The detail view renders both album
/// and playlist contents through one List-based layout; the source enum drives the
/// branch points (hero subtitle, track-row type, overflow menu, etc.).
enum LibraryDetailSource {
    case playlist(PlaylistSummary)
    case album(AlbumSummary, librarySource: Bool)

    var isAlbum: Bool {
        if case .album = self { return true }
        return false
    }

    var albumOrNil: AlbumSummary? {
        if case .album(let album, _) = self { return album }
        return nil
    }

    var playlistOrNil: PlaylistSummary? {
        if case .playlist(let p) = self { return p }
        return nil
    }

    var librarySource: Bool {
        if case .album(_, let ls) = self { return ls }
        return false
    }

    var artworkURL: URL? {
        switch self {
        case .album(let a, _): return a.artworkURL
        case .playlist(let p): return p.artworkURL
        }
    }

    var displayName: String {
        switch self {
        case .album(let a, _): return a.title
        case .playlist(let p): return p.name
        }
    }

    var sourceId: String {
        switch self {
        case .album(let a, _): return "album-\(a.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        }
    }
}

struct ServerPlaylistDetailView: View {
    let source: LibraryDetailSource
    /// Album-mode deep-link: when set, scrolls the tracklist to this id after load.
    var scrollToTrackId: String? = nil

    init(playlist: PlaylistSummary, scrollToTrackId: String? = nil) {
        self.source = .playlist(playlist)
        self.scrollToTrackId = scrollToTrackId
    }

    init(album: AlbumSummary, librarySource: Bool = false, scrollToTrackId: String? = nil) {
        self.source = .album(album, librarySource: librarySource)
        self.scrollToTrackId = scrollToTrackId
    }

    /// Legacy accessor — the playlist-mode payload. Force-unwrap is safe at every
    /// call site originally written for ``init(playlist:)``; album-mode call sites
    /// short-circuit via ``isAlbum`` before touching this.
    private var playlist: PlaylistSummary {
        source.playlistOrNil ?? PlaylistSummary(
            id: "__album__",
            name: source.displayName,
            songCount: nil,
            artworkURL: source.artworkURL,
        )
    }

    private var isAlbum: Bool { source.isAlbum }
    private var albumOrNil: AlbumSummary? { source.albumOrNil }
    private var librarySource: Bool { source.librarySource }

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [PlaylistRowItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var navigateAlbum: AlbumSummary?
    @State private var showPlaylistEditor = false
    @State private var showDeleteConfirm = false
    @State private var rowPendingRemoval: PlaylistRowItem?
    @State private var navigationTitleText = ""
    @State private var isDownloadingAll = false
    @State private var sortOrder: PlaylistTrackSortOrder = .playlistOrder
    @AppStorage("favoritedPlaylistIds") private var favoritedRaw: String = ""

    // Album-mode-only state (kept here so the View remains a single type with the
    // playlist case; ignored when ``source`` is a playlist).
    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback
    @State private var showCompleteAlbum: Bool = false
    @State private var showDownloadedAlbumActions = false
    @State private var trackPendingDownloadedDelete: Track?
    @State private var didScrollToFocusTrack = false
    @State private var highlightedRowId: String? = nil
    /// Live scroll target that can be re-driven by ``AppModel/pendingPlaylistScroll``
    /// after the initial ``scrollToTrackId`` (from the init) has been consumed.
    @State private var activeScrollTrackId: String? = nil

    private var filtered: [PlaylistRowItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [PlaylistRowItem]
        if q.isEmpty {
            base = rows
        } else {
            base = rows.filter {
            $0.track.title.lowercased().contains(q)
                || $0.track.artist.lowercased().contains(q)
                || $0.track.albumTitle.lowercased().contains(q)
            }
        }
        return sortedRows(base)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isAlbum {
                AlbumHeroBackdropView(artworkURL: source.artworkURL, palette: backdropPalette)
            }

            ScrollViewReader { proxy in
                List {
                    Section {
                        PlaylistHeroOrPillsHeader(
                            hero: { heroBlock.padding(.top, 8).padding(.bottom, 22) },
                            pills: {
                                LibraryPlayShuffleRow(
                                    isDisabled: filtered.isEmpty,
                                    onPlay: { Task { await playAll() } },
                                    onShuffle: { Task { await shuffleAll() } }
                                )
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                                .padding(.bottom, 14)
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }

                    trackRows
                }
                .listStyle(.plain)
                .listSectionSpacing(0)
                .listRowSpacing(isAlbum ? 5 : 0)
                .modifier(AlbumDetailListContentMargins(isAlbum: isAlbum))
                .scrollContentBackground(.hidden)
                .background(isAlbum ? Color.clear : MusicDesign.background)
                .environment(\.defaultMinListRowHeight, isAlbum ? 0 : 44)
                .onChange(of: rows.map(\.track.id)) { _, _ in
                    scrollToFocusedTrackIfNeeded(proxy: proxy)
                }
                .modifier(DetailScrollSignalObserver(
                    playlistId: source.playlistOrNil?.id,
                    albumId: source.albumOrNil?.id,
                    onScrollRequested: { trackId in
                        activeScrollTrackId = trackId
                        didScrollToFocusTrack = false
                        scrollToFocusedTrackIfNeeded(proxy: proxy)
                    }
                ))
            }
        }
        .playlistTrackSearchable(enabled: !isAlbum, text: $searchText)
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .modifier(DetailNavigationChrome(isAlbum: isAlbum, palette: backdropPalette))
        .musicNavigationBarVisibleWhenPushed()
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
        }
        .onAppear {
            if navigationTitleText.isEmpty {
                navigationTitleText = source.displayName
            }
        }
        .modifier(LibraryAlbumDismissObserver(
            isAlbum: isAlbum,
            librarySource: librarySource,
            albumId: albumOrNil?.id,
            dismiss: { dismiss() }
        ))
        .task { await load() }
        .task(id: source.artworkURL?.absoluteString ?? "") {
            // Album-mode dynamic backdrop palette derivation. No-op for playlists since
            // the palette state is ignored in that branch.
            guard isAlbum else { return }
            let p = await ArtworkDynamicGradient.analyzeBackdrop(from: source.artworkURL)
            await MainActor.run { backdropPalette = p }
        }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .alert(
            "Remove from Playlist?",
            isPresented: Binding(
                get: { rowPendingRemoval != nil },
                set: { if !$0 { rowPendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                rowPendingRemoval = nil
            }
            Button("Remove", role: .destructive) {
                guard let row = rowPendingRemoval else { return }
                rowPendingRemoval = nil
                Task { await removeRow(row) }
            }
        } message: {
            Text("Would you like to remove this song from this playlist?")
        }
        .toolbar { detailToolbarContent }
        .sheet(isPresented: $showPlaylistEditor) {
            // Edit sheet is playlist-only — guarded by ``beginRename`` so it never
            // opens in album mode anyway.
            if let p = source.playlistOrNil {
                PlaylistEditSheet(
                    playlist: app.libraryPlaylists.first(where: { $0.id == p.id }) ?? p,
                    rows: rows,
                    onSaved: { newName in
                        if let newName {
                            navigationTitleText = newName
                        }
                        Task { await load() }
                    }
                )
                .environmentObject(app)
#if os(iOS)
                .presentationDetents([.large])
#endif
            }
        }
        .confirmationDialog(
            "Delete “\(navigationTitleText.isEmpty ? source.displayName : navigationTitleText)”?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
        ) {
            Button("Delete", role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .modifier(DownloadedAlbumActionPresentation(
            isPresented: $showDownloadedAlbumActions,
            onRemoveDownload: { removeAllAlbumOfflineDownloads() },
            onDeleteFromLibrary: { Task { await deleteAlbumFromLibraryAndOffline() } },
        ))
        .downloadedTrackDeleteSheet(
            track: $trackPendingDownloadedDelete,
            app: app,
            offline: offline
        )
    }

    /// Branched rows for the List: empty / loading states + the track ForEach +
    /// (album-mode only) Show-Complete-Album toggle and metadata footer.
    @ViewBuilder
    private var trackRows: some View {
        let visible = filtered
        if isLoading, rows.isEmpty {
            ProgressView()
                .tint(MusicDesign.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if let loadError, rows.isEmpty {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .padding(.horizontal, 20)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if visible.isEmpty {
            ContentUnavailableView(
                "No songs",
                systemImage: "music.note.list",
                description: Text(emptyDescription)
            )
            .padding(.top, 32)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(Array(visible.enumerated()), id: \.element.rowId) { index, row in
                let showsBottomDivider = index < visible.count - 1
                let highlightOpacity: Double = row.rowId == highlightedRowId ? 0.28 : 0
                if isAlbum {
                    songRow(row, displayIndex: index + 1, showsBottomDivider: showsBottomDivider)
                        .albumTrackListRowStyle(highlightOpacity: highlightOpacity)
                } else {
                    songRow(row, displayIndex: index + 1, showsBottomDivider: showsBottomDivider)
                        .librarySongListRowStyle(highlightOpacity: highlightOpacity)
                }
            }
            if isAlbum {
                showCompleteAlbumToggle
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                albumFooterBlock
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    /// Toolbar content branches: playlist mode shows the rename/delete/sort overflow
    /// menu; album mode shows a share-artwork link plus a compact overflow with
    /// download-all and library actions.
    @ToolbarContentBuilder
    private var detailToolbarContent: some ToolbarContent {
        if isAlbum {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                if let url = source.artworkURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(backdropPalette.heroChromePrimary)
                    }
                }
                Menu {
                    albumOverflowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(backdropPalette.heroChromePrimary)
                }
                .menuOrder(.fixed)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    playlistOverflowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                }
                .menuOrder(.fixed)
            }
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Nothing matches your search." }
        if isAlbum { return "No tracks returned for this album." }
        return "Add tracks from your library. Changes sync with \(app.backendKind.title)."
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

    private var heroSubtitle: String? {
        switch source {
        case .album(let album, _):
            // Album hero subtitle: artist name + composed metadata (genre · year · etc).
            // Falls back to just the artist when no album metadata is known yet.
            let tracks = rows.map(\.track)
            let detail = AlbumHeroMetadataLine.compose(album: album, tracks: tracks)
            if detail.isEmpty {
                return album.artist.isEmpty ? nil : album.artist
            }
            if album.artist.isEmpty { return detail }
            return "\(album.artist) · \(detail)"
        case .playlist(let p):
            var parts: [String] = []
            let count = p.songCount ?? rows.count
            if count > 0 {
                parts.append("\(count) song\(count == 1 ? "" : "s")")
            }
            if let date = p.libraryAddedDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                parts.append("Updated \(formatter.localizedString(for: date, relativeTo: Date()))")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// Full album tracklist (not the library-filtered subset).
    private var allOrderedTracks: [Track] {
        rows.map(\.track).sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.indexNumber < $1.indexNumber
        }
    }

    private var allTracksCached: Bool {
        let tracks = allOrderedTracks
        return !tracks.isEmpty && tracks.allSatisfy { app.offline.downloadedTrackIds.contains($0.id) }
    }

    private var showsDownloadedAlbumCheckmark: Bool {
        guard isAlbum, let album = albumOrNil else { return false }
        return app.isAlbumInLibrary(album.id) && allTracksCached
    }

    private var allTracksFavorited: Bool {
        !rows.isEmpty && rows.allSatisfy { app.favoriteTrackIds.contains($0.track.id) }
    }

    private var favoritedPlaylistIds: Set<String> {
        Set(favoritedRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var isPlaylistPinned: Bool {
        favoritedPlaylistIds.contains(playlist.id)
    }

    @ViewBuilder
    private var playlistOverflowMenuContent: some View {
        ControlGroup {
            Button {
                Task { await downloadAllTracks() }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(rows.isEmpty || isDownloadingAll || allTracksCached)

            Button(action: toggleAllTrackFavorites) {
                Label(
                    allTracksFavorited ? "Favorited" : "Favorite",
                    systemImage: allTracksFavorited ? "star.fill" : "star"
                )
            }
            .disabled(rows.isEmpty)

            ShareLink(item: navigationTitleText.isEmpty ? playlist.name : navigationTitleText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .tint(Color.primary)

        Section {
            Button(action: togglePlaylistPinned) {
                Label(
                    isPlaylistPinned ? "Unpin Playlist" : "Pin Playlist",
                    systemImage: isPlaylistPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                app.presentAddToPlaylist(tracks: rows.map(\.track))
            } label: {
                Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(rows.isEmpty)
        }
        .tint(Color.primary)

        Section {
            Button(action: beginRename) {
                Label("Edit", systemImage: "pencil")
            }
            Button {} label: {
                Label("Start Collaboration", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(true)
            Menu {
                ForEach(PlaylistTrackSortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        HStack {
                            Label(order.rawValue, systemImage: order.systemImage)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            Button {} label: {
                Label("Move to Folder", systemImage: "folder")
            }
            .disabled(true)
        }
        .tint(Color.primary)

        Section {
            Button {
                Task { await playPlaylistNext() }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(filtered.isEmpty)
        }
        .tint(Color.primary)

        Section {
            Button {} label: {
                Label("Suggest Less", systemImage: "hand.thumbsdown")
            }
            .disabled(true)
        }
        .tint(Color.primary)

        Section {
            Button("Delete playlist", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    private var heroBlock: some View {
        VStack(spacing: 18) {
            AlbumArtworkView(url: source.artworkURL, cornerRadius: 14)
                .frame(width: heroArtSide, height: heroArtSide)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 6) {
                Text(navigationTitleText.isEmpty ? source.displayName : navigationTitleText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isAlbum ? backdropPalette.heroChromePrimary : .primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                if let subtitle = heroSubtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isAlbum ? backdropPalette.heroChromeSecondary : MusicDesign.secondaryLabel)
                        .multilineTextAlignment(.center)
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
                    .foregroundStyle(heroGlyphColor)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(heroCircleFill))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)

            Button {
                Task { await playAll() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(heroPlayCapsuleForeground)
                .frame(width: MusicDesign.albumHeroPrimaryCapsuleWidth, height: 54)
                .background(Capsule().fill(heroPlayCapsuleBackground))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)

            primaryActionButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    /// Hero glyph color — backdrop-aware in album mode, accent in playlist mode.
    private var heroGlyphColor: Color {
        isAlbum ? backdropPalette.heroGlassIcon : MusicDesign.accent
    }

    private var heroCircleFill: Color {
        isAlbum ? backdropPalette.heroGlassCircleFill : MusicDesign.chromeCapsuleFill
    }

    private var heroPlayCapsuleForeground: Color {
        isAlbum ? backdropPalette.heroPlayCapsuleForeground : .black
    }

    private var heroPlayCapsuleBackground: Color {
        isAlbum ? backdropPalette.heroPlayCapsuleBackground : .white
    }

    /// Right-hand action in the hero triplet. Album mode: `plus` → `arrow.down` → `checkmark`
    /// when fully downloaded (checkmark opens manage-download sheet). Playlist mode: download all.
    @ViewBuilder
    private var primaryActionButton: some View {
        if let album = albumOrNil, !app.isAlbumInLibrary(album.id) {
            Button {
                Task { await app.addAlbumToLibrary(album, tracks: allOrderedTracks) }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(rows.isEmpty ? heroGlyphColor.opacity(0.35) : heroGlyphColor)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(heroCircleFill))
            }
            .buttonStyle(.plain)
            .disabled(rows.isEmpty)
            .accessibilityLabel("Add to library")
        } else if showsDownloadedAlbumCheckmark {
            Button {
                showDownloadedAlbumActions = true
            } label: {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(heroGlyphColor)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(heroCircleFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage download and library")
        } else {
            Button {
                Task { await downloadAllTracks() }
            } label: {
                Group {
                    if isDownloadingAll {
                        ProgressView()
                            .tint(heroGlyphColor)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(
                                rows.isEmpty ? heroGlyphColor.opacity(0.35) : heroGlyphColor
                            )
                    }
                }
                .frame(width: 54, height: 54)
                .background(Circle().fill(heroCircleFill))
            }
            .buttonStyle(.plain)
            .disabled(rows.isEmpty || isDownloadingAll)
            .accessibilityLabel("Download")
        }
    }

    private func removeAllAlbumOfflineDownloads() {
        app.removeOfflineDownloads(trackIds: allOrderedTracks.map(\.id))
    }

    private func deleteAlbumFromLibraryAndOffline() async {
        guard let album = albumOrNil else { return }
        app.removeOfflineDownloads(trackIds: allOrderedTracks.map(\.id))
        await app.removeAlbumFromLibrary(album)
    }

    private func downloadAllTracks() async {
        guard let lib = app.activeLibrary, !rows.isEmpty else { return }
        isDownloadingAll = true
        defer { isDownloadingAll = false }
        for row in rows {
            do {
                let url = try lib.offlineDownloadURL(for: row.track)
                try await app.offline.cache(track: row.track, remote: url, headers: lib.httpHeadersForMediaRequests())
            } catch {}
        }
    }

    private func beginRename() {
        showPlaylistEditor = true
    }

    private func togglePlaylistPinned() {
        var ids = favoritedPlaylistIds
        if ids.contains(playlist.id) {
            ids.remove(playlist.id)
        } else {
            ids.insert(playlist.id)
        }
        favoritedRaw = ids.joined(separator: ",")
    }

    private func toggleAllTrackFavorites() {
        if allTracksFavorited {
            for row in rows where app.favoriteTrackIds.contains(row.track.id) {
                app.toggleFavoriteTrack(id: row.track.id)
            }
        } else {
            for row in rows where !app.favoriteTrackIds.contains(row.track.id) {
                app.toggleFavoriteTrack(id: row.track.id)
            }
        }
    }

    private func sortedRows(_ input: [PlaylistRowItem]) -> [PlaylistRowItem] {
        if isAlbum {
            // Album mode: always disc + index order (matches the track numbering on the
            // row chrome). Apply the Show-Complete-Album filter when the album is in
            // library and the user hasn't asked for the full tracklist.
            let ordered = input.sorted {
                if $0.track.discNumber != $1.track.discNumber { return $0.track.discNumber < $1.track.discNumber }
                return $0.track.indexNumber < $1.track.indexNumber
            }
            if let album = albumOrNil,
               librarySource,
               !showCompleteAlbum,
               app.isAlbumInLibrary(album.id) {
                let filtered = ordered.filter { app.isSongInLibrary($0.track.id) }
                return filtered.isEmpty ? ordered : filtered
            }
            return ordered
        }
        switch sortOrder {
        case .playlistOrder:
            return input
        case .title:
            return input.sorted {
                let title = $0.track.title.localizedCaseInsensitiveCompare($1.track.title)
                if title != .orderedSame { return title == .orderedAscending }
                return $0.track.artist.localizedCaseInsensitiveCompare($1.track.artist) == .orderedAscending
            }
        case .artist:
            return input.sorted {
                let artist = $0.track.artist.localizedCaseInsensitiveCompare($1.track.artist)
                if artist != .orderedSame { return artist == .orderedAscending }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
        case .album:
            return input.sorted {
                let album = $0.track.albumTitle.localizedCaseInsensitiveCompare($1.track.albumTitle)
                if album != .orderedSame { return album == .orderedAscending }
                if $0.track.discNumber != $1.track.discNumber { return $0.track.discNumber < $1.track.discNumber }
                if $0.track.indexNumber != $1.track.indexNumber { return $0.track.indexNumber < $1.track.indexNumber }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
        case .dateAdded:
            return input.sorted {
                let lhsDate = $0.track.libraryAddedDate ?? .distantPast
                let rhsDate = $1.track.libraryAddedDate ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
        }
    }

    private func songRow(_ row: PlaylistRowItem, displayIndex: Int, showsBottomDivider: Bool) -> some View {
        // Album mode and playlist mode share the exact same row chrome (swipe actions,
        // 3-dot menu options). The only branch is `onRemoveFromPlaylist` — albums don't
        // belong to a playlist that the user can remove tracks from, so the swipe
        // action collapses to "Delete File from Server" (admin) or nothing.
        let removeFromPlaylist: (() -> Void)? = isAlbum ? nil : { rowPendingRemoval = row }
        return LibrarySongRow(
            track: row.track,
            itemSize: app.songListItemSize,
            isFavorite: app.favoriteTrackIds.contains(row.track.id),
            isNowPlaying: app.player.activeTrack?.id == row.track.id,
            offlineDownload: offline.activeDownloads[row.track.id],
            isOfflineCached: app.offline.downloadedTrackIds.contains(row.track.id),
            onPlay: { Task { await play(row: row) } },
            onDownload: { Task { await cacheOffline(track: row.track) } },
            onCancelOfflineDownload: { app.offline.cancelDownload(trackId: row.track.id) },
            onFavorite: { app.toggleFavoriteTrack(id: row.track.id) },
            onPlayNext: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playNext(library: lib, track: row.track)
                    await MainActor.run { app.showTransientToast("Playing Next") }
                }
            },
            onAddToQueue: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.addToQueue(library: lib, track: row.track)
                    await MainActor.run { app.showTransientToast("Added to Queue") }
                }
            },
            hasActiveQueue: !app.player.queue.isEmpty,
            onGoToAlbum: isAlbum ? nil : { navigateAlbum = app.albumSummary(for: row.track) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [row.track]) },
            onRemoveFromPlaylist: removeFromPlaylist,
            onRemoveFromLibrary: app.isSongInLibrary(row.track.id)
                ? { Task { await app.removeSongFromLibrary(row.track) } } : nil,
            onDeleteFromLibrary: { app.beginLibraryTrackDeletion(row.track) },
            canDeleteFromLibrary: app.canDeleteFromLibrary,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(row.track.id)
                ? { try? app.offline.remove(trackId: row.track.id) } : nil,
            onAddToLibrary: app.isSongInLibrary(row.track.id)
                ? nil : { Task { await app.addSongToLibrary(row.track) } },
            isInLibrary: app.isSongInLibrary(row.track.id),
            hidesAddToLibraryChip: !isAlbum,
            showsArtwork: !isAlbum,
            showsArtist: !isAlbum,
            rowBackgroundFill: isAlbum ? .clear : MusicDesign.background,
            usesAlbumSwipeChrome: isAlbum,
            showsBottomDivider: showsBottomDivider,
            dividerPalette: isAlbum ? backdropPalette : nil,
            trackDisplayIndex: isAlbum ? displayIndex : nil,
            onPresentDownloadedDeleteSheet: {
                trackPendingDownloadedDelete = row.track
            }
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

    private func load() async {
        guard app.isSignedIn else {
            loadError = "Sign in to view your library."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            switch source {
            case .playlist(let p):
                rows = try await app.fetchPlaylistRows(playlistId: p.id)
            case .album(let album, _):
                // Album mode: fetch ordered album tracks and wrap them in
                // ``PlaylistRowItem``s so the rest of the view's reads (filtering,
                // sorting, playback) can stay shape-uniform with playlist mode.
                guard let lib = app.activeLibrary else { rows = []; return }
                let tracks = try await lib.tracks(forAlbumId: album.id)
                rows = tracks.enumerated().map { idx, track in
                    PlaylistRowItem(rowId: "album-\(album.id)-\(idx)-\(track.id)", track: track)
                }
            }
        } catch {
            loadError = error.localizedDescription
            rows = []
        }
    }

    private func removeRow(_ row: PlaylistRowItem) async {
        do {
            try await app.removePlaylistRow(playlistId: playlist.id, row: row)
            await load()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func deletePlaylist() async {
        do {
            try await app.deletePlaylist(playlistId: playlist.id)
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private var tracksForPlayback: [Track] {
        filtered.map(\.track)
    }

    private var playbackSource: PlaybackSource? {
        if isAlbum {
            // Album mode: ad-hoc queue with no playlist origin — Now Playing history
            // will record the album path via the track's `albumId` fallback.
            return nil
        }
        return .playlist(app.libraryPlaylists.first(where: { $0.id == playlist.id }) ?? playlist)
    }

    private func playAll() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracksForPlayback, startIndex: 0, source: playbackSource)
    }

    private func shuffleAll() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        try? await app.player.playAlbumShuffled(library: lib, tracks: tracksForPlayback, source: playbackSource)
    }

    private func playPlaylistNext() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        try? await app.player.playTracksNext(library: lib, tracks: tracksForPlayback)
    }

    private func play(row: PlaylistRowItem) async {
        guard let lib = app.activeLibrary else { return }
        let playbackTracks = tracksForPlayback
        guard let idx = filtered.firstIndex(where: { $0.rowId == row.rowId }) else { return }
        try? await app.player.playAlbum(library: lib, tracks: playbackTracks, startIndex: idx, source: playbackSource)
    }

    // MARK: - Album-mode helpers

    /// Album-mode overflow menu (in the navigation bar). Distinct from playlist's
    /// rename/delete-playlist actions.
    @ViewBuilder
    private var albumOverflowMenuContent: some View {
        if let album = albumOrNil {
            if !showsDownloadedAlbumCheckmark {
                ControlGroup {
                    Button {
                        Task { await downloadAllTracks() }
                    } label: {
                        Label("Download Album", systemImage: "arrow.down.circle")
                    }
                    .disabled(rows.isEmpty || isDownloadingAll)
                    if !app.isAlbumInLibrary(album.id) {
                        Button {
                            Task { await app.addAlbumToLibrary(album, tracks: allOrderedTracks) }
                        } label: {
                            Label("Add Album to Library", systemImage: "plus.square.on.square")
                        }
                    }
                }
                .tint(Color.primary)
            }

            // Lives outside the tinted ControlGroup so the destructive role renders red.
            if app.isAlbumInLibrary(album.id) {
                Section {
                    Button(role: .destructive) {
                        Task { await app.removeAlbumFromLibrary(album) }
                    } label: {
                        Label("Delete Album from Library", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Apple-Music-style "Show Complete Album" / "Show Library Only" toggle below the
    /// last track row. Renders only in album-library context with hidden tracks.
    @ViewBuilder
    private var showCompleteAlbumToggle: some View {
        if let album = albumOrNil, librarySource, app.isAlbumInLibrary(album.id) {
            let total = rows.count
            let inLibraryCount = rows.filter { app.isSongInLibrary($0.track.id) }.count
            if inLibraryCount > 0, inLibraryCount < total {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showCompleteAlbum.toggle()
                        }
                    } label: {
                        Text(showCompleteAlbum ? "Show Library Only" : "Show Complete Album")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(backdropPalette.heroChromePrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(backdropPalette.heroGlassCircleFill))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .padding(.horizontal, 22)
            }
        }
    }

    /// Album footer — release year / date + total duration summary.
    @ViewBuilder
    private var albumFooterBlock: some View {
        if let album = albumOrNil {
            VStack(alignment: .leading, spacing: 10) {
                if let line = album.releaseFooterDisplayString {
                    Text(line)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(backdropPalette.heroChromeSecondary)
                }
                if !rows.isEmpty {
                    Text(albumFooterDurationSummary)
                        .font(.subheadline)
                        .foregroundStyle(backdropPalette.heroChromeSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
        }
    }

    private var albumFooterDurationSummary: String {
        let n = rows.count
        let total = rows.reduce(0.0) { $0 + max($1.track.duration, 0) }
        let totalMin = max(1, Int(ceil(total / 60.0)))
        if n == 0 { return "No songs" }
        if n == 1 { return "1 song, \(totalMin) minutes" }
        return "\(n) songs, \(totalMin) minutes"
    }

    /// Scroll the tracklist to the active scroll target after the initial load and
    /// flash a brief highlight over the focused row. Defers when the focus track
    /// isn't yet in `rows`.
    private func scrollToFocusedTrackIfNeeded(proxy: ScrollViewProxy) {
        let targetId = activeScrollTrackId ?? scrollToTrackId
        guard !didScrollToFocusTrack,
              let trackId = targetId,
              let matchingRow = rows.first(where: { $0.track.id == trackId })
        else { return }
        didScrollToFocusTrack = true
        let targetRowId = matchingRow.rowId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(targetRowId, anchor: .center)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 0.18)) {
                highlightedRowId = targetRowId
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeOut(duration: 0.9)) {
                    highlightedRowId = nil
                }
            }
        }
    }
}

/// Library-mode album view auto-pop: when the user removes the last song of an album
/// from their library, ``libraryAlbumEntries`` loses the entry — at which point an
/// already-pushed library album view is stale and should pop back. Kept as its own
/// modifier so the parent body stays under the SwiftUI type-check budget.
private struct LibraryAlbumDismissObserver: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let isAlbum: Bool
    let librarySource: Bool
    let albumId: String?
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: app.libraryAlbumEntries) { _, _ in
            guard isAlbum, librarySource, let albumId, !app.isAlbumInLibrary(albumId) else { return }
            dismiss()
        }
    }
}

/// Watches ``AppModel/pendingPlaylistScroll`` and ``AppModel/pendingAlbumScroll`` and
/// triggers a scroll callback when the signal matches this detail view's source. Kept
/// in its own modifier so the parent body stays under the SwiftUI type-check budget.
private struct DetailScrollSignalObserver: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let playlistId: String?
    let albumId: String?
    let onScrollRequested: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: app.pendingPlaylistScroll) { _, request in
                guard let request, let playlistId, request.playlistId == playlistId else { return }
                app.pendingPlaylistScroll = nil
                onScrollRequested(request.trackId)
            }
            .onChange(of: app.pendingAlbumScroll) { _, request in
                guard let request, let albumId, request.albumId == albumId else { return }
                app.pendingAlbumScroll = nil
                onScrollRequested(request.trackId)
            }
    }
}

/// Navigation chrome modifier — uses the album-hero palette in album mode so the
/// status bar / title overlap a tinted backdrop; falls back to the standard
/// "new tab" chrome for playlists.
private struct DetailNavigationChrome: ViewModifier {
    let isAlbum: Bool
    let palette: ArtworkDynamicGradient.BackdropPalette

    func body(content: Content) -> some View {
        if isAlbum {
            content.musicHeroAlbumNavigationChrome(palette: palette)
        } else {
            content.musicNewTabNavigationChrome()
        }
    }
}

private struct PlaylistEditSheet: View {
    enum Mode {
        case create
        case edit(playlist: PlaylistSummary, rows: [PlaylistRowItem], onSaved: (String?) -> Void)
    }

    let mode: Mode

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description = ""
    @State private var visibleToAll: Bool
    @State private var editableRows: [PlaylistRowItem]
    @State private var selectedRowIds: Set<String> = []
    @State private var isSaving = false
    @State private var showAddTracks = false
    @State private var artworkURL: URL?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var pendingCoverData: Data?
    private let draftArtworkSeed: String

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var playlist: PlaylistSummary? {
        if case .edit(let playlist, _, _) = mode { return playlist }
        return nil
    }

    private var onSaved: ((String?) -> Void)? {
        if case .edit(_, _, let onSaved) = mode { return onSaved }
        return nil
    }

    private var meshArtworkSeed: String {
        playlist?.id ?? draftArtworkSeed
    }

    init(mode: Mode) {
        self.mode = mode
        draftArtworkSeed = UUID().uuidString
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _visibleToAll = State(initialValue: false)
            _editableRows = State(initialValue: [])
            _artworkURL = State(initialValue: nil)
        case .edit(let playlist, let rows, _):
            _title = State(initialValue: playlist.name)
            _visibleToAll = State(initialValue: playlist.isPublic ?? false)
            _editableRows = State(initialValue: rows)
            _artworkURL = State(initialValue: playlist.artworkURL)
        }
    }

    init(playlist: PlaylistSummary, rows: [PlaylistRowItem], onSaved: @escaping (String?) -> Void) {
        self.init(mode: .edit(playlist: playlist, rows: rows, onSaved: onSaved))
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedRows: [PlaylistRowItem] {
        editableRows.filter { selectedRowIds.contains($0.rowId) }
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    artworkEditor
                        .padding(.top, 18)

                    metadataFields

                    trackList
                        .padding(.top, 4)
                }
            }
            .background(MusicDesign.background)
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .accessibilityLabel("Done")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await removeSelectedRows() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.headline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedRowIds.isEmpty || isSaving)
                    .accessibilityLabel("Remove selected songs")
                }
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showAddTracks = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .accessibilityLabel("Add songs")
                }
            }
            .sheet(isPresented: $showAddTracks) {
                PlaylistTrackAddSheet(
                    playlistId: playlist?.id,
                    existingTrackIds: Set(editableRows.map(\.track.id)),
                    onAdded: { added in
                        appendAddedTracks(added)
                        if !isCreate {
                            onSaved?(nil)
                        }
                    }
                )
                .environmentObject(app)
            }
        }
    }

    private var artworkEditor: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let pendingCoverData, let coverImage = playlistCoverPreviewImage(data: pendingCoverData) {
                        coverImage
                            .resizable()
                            .scaledToFill()
                    } else if let artworkURL {
                        AlbumArtworkView(url: artworkURL, cornerRadius: 8)
                    } else {
                        RadioStationMeshArtworkView(
                            seedKey: RadioStationMeshArtwork.seedKey(stationId: meshArtworkSeed),
                            cornerRadius: 8,
                        )
                    }
                }
                .frame(width: 184, height: 184)
                .opacity(isUploadingCover ? 0.45 : 1)

                PhotosPicker(selection: $coverPickerItem, matching: .images, photoLibrary: .shared()) {
                    Circle()
                        .fill(MusicDesign.accent)
                        .frame(width: 52, height: 52)
                        .overlay {
                            if isUploadingCover {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "photo")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(isUploadingCover || isSaving)
                .offset(x: -8, y: -8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(isCreate
                ? "Tap to choose a cover — it uploads when you save the playlist."
                : "Tap to change playlist cover — saved to your server.")
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .onChange(of: coverPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await handleCoverPickerSelection(newItem) }
        }
    }

    private func handleCoverPickerSelection(_ item: PhotosPickerItem) async {
        isUploadingCover = true
        defer {
            isUploadingCover = false
            coverPickerItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            app.errorMessage = "Could not read the selected image."
            return
        }
        if isCreate {
            pendingCoverData = data
            artworkURL = nil
            return
        }
        guard let playlist else { return }
        do {
            let refreshed = try await app.updatePlaylistCoverImage(playlistId: playlist.id, imageData: data)
            artworkURL = refreshed
            pendingCoverData = nil
            onSaved?(nil)
        } catch {
            app.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var metadataFields: some View {
        VStack(spacing: 0) {
            TextField("Playlist name", text: $title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
#if os(iOS)
                .musicTextInputAutocapitalization(.words)
#endif

            Divider().background(MusicDesign.separator)

            TextField("Description", text: $description, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .padding(.vertical, 12)

            Divider().background(MusicDesign.separator)

            PlaylistVisibilityFields(isPublic: $visibleToAll)
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
    }

    private var trackList: some View {
        LazyVStack(spacing: 0) {
            ForEach(editableRows) { row in
                PlaylistEditableTrackRow(
                    row: row,
                    isSelected: selectedRowIds.contains(row.rowId),
                    onToggle: { toggle(row) }
                )
                Divider()
                    .background(MusicDesign.separator)
                    .padding(.leading, 82)
            }
        }
    }

    private func toggle(_ row: PlaylistRowItem) {
        if selectedRowIds.contains(row.rowId) {
            selectedRowIds.remove(row.rowId)
        } else {
            selectedRowIds.insert(row.rowId)
        }
    }

    private func appendAddedTracks(_ tracks: [Track]) {
        let start = editableRows.count
        let prefix = playlist?.id ?? draftArtworkSeed
        let newRows = tracks.enumerated().map { offset, track in
            PlaylistRowItem(rowId: "\(prefix)-added-\(start + offset)-\(track.id)", track: track)
        }
        editableRows.append(contentsOf: newRows)
    }

    private func removeSelectedRows() async {
        guard !selectedRows.isEmpty else { return }
        if isCreate {
            editableRows.removeAll { selectedRowIds.contains($0.rowId) }
            selectedRowIds.removeAll()
            return
        }
        guard let playlist else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.removePlaylistRows(playlistId: playlist.id, rows: selectedRows)
            editableRows.removeAll { selectedRowIds.contains($0.rowId) }
            selectedRowIds.removeAll()
            onSaved?(nil)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if isCreate {
                let created = try await app.createPlaylist(
                    name: trimmedTitle,
                    initialTracks: editableRows.map(\.track),
                    isPublic: visibleToAll,
                )
                if let pendingCoverData {
                    _ = try? await app.updatePlaylistCoverImage(playlistId: created.id, imageData: pendingCoverData)
                }
                dismiss()
            } else if let playlist {
                try await app.renamePlaylist(
                    playlistId: playlist.id,
                    name: trimmedTitle,
                    isPublic: visibleToAll,
                )
                onSaved?(trimmedTitle)
                dismiss()
            }
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

#if canImport(UIKit)
private func playlistCoverPreviewImage(data: Data) -> Image? {
    guard let uiImage = UIImage(data: data) else { return nil }
    return Image(uiImage: uiImage)
}
#else
private func playlistCoverPreviewImage(data: Data) -> Image? { nil }
#endif

private struct PlaylistEditableTrackRow: View {
    let row: PlaylistRowItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isSelected ? MusicDesign.accent : MusicDesign.secondaryLabel)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)

            AlbumArtworkView(url: row.track.artworkURL, cornerRadius: 5)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.track.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(row.track.artist)
                    .font(.caption)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .frame(width: 32, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct PlaylistTrackAddSheet: View {
    let playlistId: String?
    let existingTrackIds: Set<String>
    let onAdded: ([Track]) -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedTrackIds: Set<String> = []
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadError: String?

    private var filtered: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let available = tracks.filter { !existingTrackIds.contains($0.id) }
        guard !q.isEmpty else { return available }
        return available.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.albumTitle.lowercased().contains(q)
        }
    }

    private var selectedTracks: [Track] {
        tracks.filter { selectedTrackIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading, tracks.isEmpty {
                    ProgressView()
                        .tint(MusicDesign.accent)
                } else if let loadError, tracks.isEmpty {
                    ContentUnavailableView("Could not load songs", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    List(filtered) { track in
                        Button {
                            toggle(track)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedTrackIds.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTrackIds.contains(track.id) ? MusicDesign.accent : MusicDesign.secondaryLabel)
                                AlbumArtworkView(url: track.artworkURL, cornerRadius: 5)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundStyle(MusicDesign.secondaryLabel)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(MusicDesign.background)
            .navigationTitle("Add Songs")
            .musicNavigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await addSelected() }
                    }
                    .disabled(selectedTrackIds.isEmpty || isSaving)
                }
            }
            .task { await load() }
        }
    }

    private func toggle(_ track: Track) {
        if selectedTrackIds.contains(track.id) {
            selectedTrackIds.remove(track.id)
        } else {
            selectedTrackIds.insert(track.id)
        }
    }

    private func load() async {
        guard tracks.isEmpty else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        if !app.discoveryLibraryTracks.isEmpty {
            tracks = app.discoveryLibraryTracks
            return
        }

        guard let lib = app.activeLibrary else {
            loadError = "Sign in to browse your library."
            return
        }

        do {
            tracks = try await lib.allTracks(limit: 50_000)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func addSelected() async {
        let selected = selectedTracks
        guard !selected.isEmpty else { return }
        if let playlistId {
            isSaving = true
            defer { isSaving = false }
            do {
                try await app.addTracksToPlaylist(playlistId: playlistId, tracks: selected)
                onAdded(selected)
                dismiss()
            } catch {
                app.errorMessage = error.localizedDescription
            }
        } else {
            onAdded(selected)
            dismiss()
        }
    }
}

/// Reads `\.isSearching` (valid in descendants of `.searchable`) and swaps the
/// playlist header between the centered hero (idle) and the inline Play/Shuffle pills (searching).
/// Header section for both playlist and album detail lists — swaps the hero block for
/// a compact play/shuffle pill row while the user is actively typing in the search
/// field, so the search bar stays in view.
struct PlaylistHeroOrPillsHeader<Hero: View, Pills: View>: View {
    @Environment(\.isSearching) private var isSearching
    let hero: Hero
    let pills: Pills

    init(@ViewBuilder hero: () -> Hero, @ViewBuilder pills: () -> Pills) {
        self.hero = hero()
        self.pills = pills()
    }

    var body: some View {
        if isSearching {
            pills
        } else {
            hero
        }
    }
}

private extension View {
    /// Playlist detail only — album pages use a fixed tracklist (no in-page search).
    @ViewBuilder
    func playlistTrackSearchable(enabled: Bool, text: Binding<String>) -> some View {
        if enabled {
            #if os(iOS)
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
            #else
            searchable(text: text, prompt: "Search")
            #endif
        } else {
            self
        }
    }
}
