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
    @State private var searchText = ""

    private var filteredPlaylists: [PlaylistSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return app.libraryPlaylists }
        return app.libraryPlaylists.filter { $0.name.lowercased().contains(query) }
    }

    /// True when every track being added is already in the playlist (per cached
    /// rows). Drives the "already added" checkmark — best-effort, no network.
    private func alreadyContainsAll(_ playlistId: String) -> Bool {
        guard let rows = app.cachedPlaylistRows(playlistId: playlistId) else { return false }
        let ids = Set(rows.map(\.track.id))
        return tracks.allSatisfy { ids.contains($0.id) }
    }

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
                    } else if filteredPlaylists.isEmpty {
                        Text("No playlists match \u{201C}\(searchText)\u{201D}.")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    } else {
                        ForEach(filteredPlaylists) { pl in
                            Button {
                                Task { await addToExisting(pl) }
                            } label: {
                                HStack {
                                    Text(pl.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if alreadyContainsAll(pl.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(MusicDesign.accent)
                                            .accessibilityLabel("Already added")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(isWorking)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MusicDesign.background)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find a playlist")
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
            app.showTransientToast("Added to \(name)")
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func addToExisting(_ playlist: PlaylistSummary) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let added = try await app.addTracksToPlaylist(playlistId: playlist.id, tracks: tracks)
            app.dismissPlaylistPicker()
            dismiss()
            app.showTransientToast(added > 0 ? "Added to \(playlist.name)" : "Already in \(playlist.name)")
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
    case homeMix(mixId: String)

    var isAlbum: Bool {
        if case .album = self { return true }
        return false
    }

    var isHomeMix: Bool {
        if case .homeMix = self { return true }
        return false
    }

    var albumOrNil: AlbumSummary? {
        if case .album(let album, _) = self { return album }
        return nil
    }

    var homeMixIdOrNil: String? {
        if case .homeMix(let id) = self { return id }
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
        case .homeMix: return nil
        }
    }

    var displayName: String {
        switch self {
        case .album(let a, _): return a.title
        case .playlist(let p): return p.name
        case .homeMix: return "Mix"
        }
    }

    var sourceId: String {
        switch self {
        case .album(let a, _): return "album-\(a.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        case .homeMix(let id): return "homeMix-\(id)"
        }
    }
}

struct ServerPlaylistDetailView: View {
    let source: LibraryDetailSource
    /// Album-mode deep-link: when set, scrolls the tracklist to this id after load.
    var scrollToTrackId: String? = nil
    /// When true (the default), this view is treated as "behind the Now Playing player" and
    /// publishes its album/playlist id on ``AppModel/currentlyVisibleAlbumId`` /
    /// ``currentlyVisiblePlaylistId`` so Go to Playlist/Album can detect that the destination
    /// is already on screen. The player's own internal NavigationStack passes `false` to opt out.
    var tracksVisibility: Bool = true

    init(playlist: PlaylistSummary, scrollToTrackId: String? = nil, tracksVisibility: Bool = true, preloadedRows: [PlaylistRowItem]? = nil) {
        self.source = .playlist(playlist)
        self.scrollToTrackId = scrollToTrackId
        self.tracksVisibility = tracksVisibility
        let cached = preloadedRows ?? []
        _rows = State(initialValue: cached)
        _isLoading = State(initialValue: cached.isEmpty)
        _displayedRows = State(initialValue: cached)
    }

    init(album: AlbumSummary, librarySource: Bool = false, scrollToTrackId: String? = nil, tracksVisibility: Bool = true) {
        self.source = .album(album, librarySource: librarySource)
        self.scrollToTrackId = scrollToTrackId
        self.tracksVisibility = tracksVisibility
    }

    init(homeMixId: String, tracksVisibility: Bool = true) {
        self.source = .homeMix(mixId: homeMixId)
        self.scrollToTrackId = nil
        self.tracksVisibility = tracksVisibility
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
    private var isHomeMix: Bool { source.isHomeMix }
    /// Album detail layout (numbered rows, hero triplet, no in-page search). Also used for dynamic home mixes.
    private var isAlbumStyleDetail: Bool { isAlbum || isHomeMix }

    private var activeHomeMix: HomeMix? {
        guard let mixId = source.homeMixIdOrNil else { return nil }
        return app.homeMixes.first { $0.id == mixId }
    }

    private var homeMixContentToken: String {
        guard let mix = activeHomeMix else { return "" }
        return mix.tracks.map(\.id).joined(separator: "|")
    }
    private var albumOrNil: AlbumSummary? { source.albumOrNil }
    private var librarySource: Bool { source.librarySource }

    /// Hero/backdrop art — uses offline disk art + fresh server URLs, not stale snapshot URLs.
    private var resolvedDetailArtworkURL: URL? {
        if isHomeMix { return activeHomeMix?.artworkURLs.first }
        switch source {
        case .album(let album, _):
            return app.resolvedArtworkURL(for: album)
        case .playlist(let playlist):
            return app.resolvedArtworkURL(for: playlist)
        case .homeMix:
            return nil
        }
    }

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @EnvironmentObject private var downtify: DowntifyDownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var rows: [PlaylistRowItem] = []
    @State private var previewTracks: [BrowseAlbumPreviewTrack] = []
    /// Album mode only: held true while the MusicBrainz tracklist is in flight so the
    /// whole list stays in its loading state and the missing rows never pop in late.
    @State private var isLoadingPreviewTracks: Bool = false
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
    @AppStorage(LibraryPinStore.storageKey) private var pinnedStorage: String = "[]"

    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback
    @State private var showCompleteAlbum: Bool = false
    @State private var showDownloadedAlbumActions = false
    @State private var trackPendingDownloadedDelete: Track?
    @State private var didScrollToFocusTrack = false
    @State private var highlightedRowId: String? = nil
    @State private var activeScrollTrackId: String? = nil
    @State private var scrollHighlightTask: Task<Void, Never>?
    @State private var displayedRows: [PlaylistRowItem] = []
    /// How many rows the List renders right now. Hydrating a very large playlist
    /// (1000+ songs) in full while the push/pop animation runs makes the
    /// transition stutter — so the first render is one comfortable screenful and
    /// the window grows ahead of the scroll position (sentinel row in the
    /// ForEach). Invisible to the user: no spinners, no pagination UI, and
    /// playback/search always operate on the full ``displayedRows``.
    @State private var rowRenderLimit = ServerPlaylistDetailView.rowRenderChunk
    private static let rowRenderChunk = 150

    /// Album-mode unified row: a real library track, or a MusicBrainz-only track the
    /// user can request via Downtify.
    private enum AlbumMergedRow: Identifiable {
        case library(PlaylistRowItem, displayIndex: Int)
        case missing(BrowseAlbumPreviewTrack, displayIndex: Int)

        var id: String {
            switch self {
            case .library(let r, _): return "lib-\(r.rowId)"
            case .missing(let p, _): return "miss-\(p.id)"
            }
        }

        var displayIndexValue: Int {
            switch self {
            case .library(_, let i), .missing(_, let i): return i
            }
        }
    }

    /// Personal-library album detail (Library tab) where some server tracks may be hidden
    /// until the user taps Show Complete Album.
    private var isPersonalLibraryAlbum: Bool {
        guard let album = albumOrNil, librarySource else { return false }
        return app.isAlbumInLibrary(album.id)
    }

    /// MusicBrainz merge rows (missing / Request tracks) — only after Show Complete Album
    /// for personal-library albums; always on for catalog browse where Downtify applies.
    private var shouldShowMergedAlbumTracklist: Bool {
        guard isAlbum, !previewTracks.isEmpty else { return false }
        if isPersonalLibraryAlbum { return showCompleteAlbum }
        return true
    }

    private var shouldLoadAlbumPreviewTracks: Bool {
        guard isAlbum else { return false }
        if isPersonalLibraryAlbum { return showCompleteAlbum }
        return true
    }

    /// Album-mode merged rows: MusicBrainz order, library tracks matched in, missing
    /// tracks as Request rows, server orphans appended. Empty when not applicable.
    private var albumMergedRows: [AlbumMergedRow] {
        guard isAlbum, !previewTracks.isEmpty else { return [] }
        let libraryRows = displayedRows  // already sorted disc/index + complete-album filtered
        var usedRowIds = Set<String>()
        var out: [AlbumMergedRow] = []
        let includeMissing = shouldShowMergedAlbumTracklist

        for (loopIdx, preview) in previewTracks.enumerated() {
            let displayIdx = preview.position > 0 ? preview.position : loopIdx + 1
            let probe = DowntifySong(songId: "mb:\(preview.id)", name: preview.title,
                                     artists: [albumOrNil?.artist ?? ""], albumName: albumOrNil?.title ?? "",
                                     url: "", coverURL: nil, year: nil, explicit: false)
            if let match = libraryRows.first(where: {
                !usedRowIds.contains($0.rowId) &&
                LibraryTrackMatcher.trackMatchesDowntifySong($0.track, song: probe)
            }) {
                out.append(.library(match, displayIndex: displayIdx))
                usedRowIds.insert(match.rowId)
            } else if includeMissing {
                out.append(.missing(preview, displayIndex: displayIdx))
            }
        }
        // Append library orphans MusicBrainz didn't list.
        var nextIdx = (out.map(\.displayIndexValue).max() ?? 0) + 1
        for row in libraryRows where !usedRowIds.contains(row.rowId) {
            out.append(.library(row, displayIndex: nextIdx))
            nextIdx += 1
        }
        return out
    }

    private func recomputeDisplayedRows() {
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
        let next = sortedRows(base)
        // Skip the reassignment when content is unchanged — a new array value
        // forces SwiftUI to re-diff the entire tracklist, which is the dominant
        // main-thread cost on large playlists (load() recomputes unconditionally
        // after its background refresh, usually with identical rows).
        guard next.map(\.rowId) != displayedRows.map(\.rowId) else { return }
        displayedRows = next
    }

    /// Album mode only: fetch the full MusicBrainz tracklist so missing tracks can be
    /// shown + requested. Best-effort; failure silently falls back to server-only rows.
    /// Drives `isLoadingPreviewTracks` so the host view can keep its single loading
    /// state up until previews resolve — owned + missing rows then appear together.
    private func loadPreviewTracksIfAlbum() async {
        guard let album = albumOrNil, previewTracks.isEmpty else { return }
        isLoadingPreviewTracks = true
        defer { isLoadingPreviewTracks = false }
        guard let rgId = await MusicBrainzTracklistClient.findReleaseGroupId(
            artist: album.artist, albumTitle: album.title
        ) else { return }
        let tracks = await MusicBrainzTracklistClient.tracksForReleaseGroup(rgId)
        guard !tracks.isEmpty else { return }
        await MainActor.run {
            self.previewTracks = tracks
            recomputeDisplayedRows()
        }
    }

    /// Zoom-transition key — must match the id cover cells mark with
    /// `coverZoomSource(id:)`. Home mixes key on their synthetic playlist id
    /// because that's what the Library playlist rows render.
    private var coverZoomId: String {
        switch source {
        case .album(let album, _): return album.id
        case .playlist(let playlist): return playlist.id
        case .homeMix(let mixId): return HomeMix.libraryPlaylistIdPrefix + mixId
        }
    }

    var body: some View {
        detailScrollContainer
            .coverZoomDestination(id: coverZoomId)
            .playlistTrackSearchable(enabled: !isAlbumStyleDetail, text: $searchText)
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .modifier(DetailNavigationChrome(palette: backdropPalette))
            .musicNavigationBarVisibleWhenPushed()
            .navigationDestination(item: $navigateAlbum) { album in
                ServerPlaylistDetailView(album: album, librarySource: true)
            }
            .onAppear(perform: detailOnAppear)
            .modifier(LibraryAlbumDismissObserver(
                isAlbum: isAlbum,
                librarySource: librarySource,
                albumId: albumOrNil?.id,
                dismiss: { dismiss() }
            ))
            .task { await load() }
            .task(id: detailBackdropTaskID) {
                await refreshDetailBackdropPalette()
            }
            .onChange(of: app.libraryCatalogEpoch) { _, _ in
                Task { await load() }
            }
            .onChange(of: app.homeMixes.map(\.id)) { _, _ in
                guard isHomeMix else { return }
                Task { await load() }
            }
            .onChange(of: homeMixContentToken) { _, _ in
                guard isHomeMix else { return }
                Task { await load() }
            }
            .refreshable {
                if isHomeMix { app.refreshHomeMixes() }
                await load()
            }
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
                playlistEditorSheet
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
                itemKind: isAlbum ? .album : .playlist,
                includeDeleteFromLibrary: isAlbum,
                onRemoveDownload: { removeAllAlbumOfflineDownloads() },
                onDeleteFromLibrary: { Task { await deleteAlbumFromLibraryAndOffline() } },
            ))
            .downloadedTrackDeleteSheet(
                track: $trackPendingDownloadedDelete,
                app: app,
                offline: offline
            )
            .onDisappear(perform: detailOnDisappear)
            .onChange(of: rows) { _, _ in recomputeDisplayedRows() }
            .onChange(of: searchText) { _, _ in recomputeDisplayedRows() }
            .onChange(of: sortOrder) { _, _ in recomputeDisplayedRows() }
            .onChange(of: showCompleteAlbum) { _, expanded in
                recomputeDisplayedRows()
                if expanded, isAlbum, previewTracks.isEmpty {
                    Task { await loadPreviewTracksIfAlbum() }
                }
            }
            .onChange(of: app.libraryCatalogEpoch) { _, _ in recomputeDisplayedRows() }
            .onChange(of: app.librarySongIds) { _, _ in recomputeDisplayedRows() }
            .onChange(of: previewTracks.map(\.id)) { _, _ in recomputeDisplayedRows() }
    }

    private var detailBackdropTaskID: String {
        "\(resolvedDetailArtworkURL?.absoluteString ?? "")-\(app.playlistBackdropEnabled)-\(colorScheme)"
    }

    private func refreshDetailBackdropPalette() async {
        guard app.playlistBackdropEnabled else {
            await MainActor.run { backdropPalette = .listSurface(colorScheme: colorScheme) }
            return
        }
        let palette = await ArtworkDynamicGradient.analyzeBackdrop(from: resolvedDetailArtworkURL)
        await MainActor.run { backdropPalette = palette }
    }

    private func detailOnAppear() {
        if navigationTitleText.isEmpty {
            if isHomeMix, let mix = activeHomeMix {
                navigationTitleText = mix.title
            } else {
                navigationTitleText = source.displayName
            }
        }
        if tracksVisibility {
            switch source {
            case .playlist(let p): app.currentlyVisiblePlaylistId = p.id
            case .album(let a, _): app.currentlyVisibleAlbumId = a.id
            case .homeMix: break
            }
        }
        hydrateFromCacheIfNeeded()
    }

    private func detailOnDisappear() {
        scrollHighlightTask?.cancel()
        if tracksVisibility {
            switch source {
            case .playlist(let p):
                if app.currentlyVisiblePlaylistId == p.id { app.currentlyVisiblePlaylistId = nil }
            case .album(let a, _):
                if app.currentlyVisibleAlbumId == a.id { app.currentlyVisibleAlbumId = nil }
            case .homeMix:
                break
            }
        }
    }

    @ViewBuilder
    private var playlistEditorSheet: some View {
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

    private var detailScrollContainer: some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .top) {
                AlbumHeroBackdropView(artworkURL: resolvedDetailArtworkURL, palette: backdropPalette)
                detailTrackList(scrollProxy: scrollProxy)
            }
        }
    }

    @ViewBuilder
    private func detailTrackList(scrollProxy: ScrollViewProxy) -> some View {
        List {
            Section {
                PlaylistHeroOrPillsHeader(
                    hero: { heroBlock.padding(.top, 8).padding(.bottom, 22) },
                    pills: {
                        LibraryPlayShuffleRow(
                            isDisabled: displayedRows.isEmpty,
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
        .listRowSpacing(isAlbumStyleDetail ? 5 : 0)
        .modifier(AlbumDetailListContentMargins(isAlbum: isAlbumStyleDetail))
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .environment(\.defaultMinListRowHeight, isAlbumStyleDetail ? 0 : 44)
        .onChange(of: rowsContentToken, initial: true) { _, _ in
            scrollToFocusedTrackIfNeeded(proxy: scrollProxy)
        }
        .modifier(DetailScrollSignalObserver(
            playlistId: source.playlistOrNil?.id,
            albumId: source.albumOrNil?.id,
            onScrollRequested: { trackId in
                activeScrollTrackId = trackId
                didScrollToFocusTrack = false
                scrollToFocusedTrackIfNeeded(proxy: scrollProxy)
            }
        ))
    }

    /// O(1) change token for "the tracklist content landed / changed" — the previous
    /// `rows.map(\.track.id)` built and compared an N-element array on every body
    /// evaluation, which scales badly on 1000+ song playlists.
    private var rowsContentToken: String {
        "\(rows.count)|\(rows.first?.rowId ?? "")|\(rows.last?.rowId ?? "")"
    }

    /// Branched rows for the List: empty / loading states + the track ForEach +
    /// (album-mode only) Show-Complete-Album toggle and metadata footer.
    @ViewBuilder
    private var trackRows: some View {
        let visible = displayedRows
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
        } else if shouldShowMergedAlbumTracklist {
            let merged = albumMergedRows
            ForEach(Array(merged.enumerated()), id: \.element.id) { index, mergedRow in
                let showsBottomDivider = index < merged.count - 1
                switch mergedRow {
                case .library(let row, let displayIndex):
                    let highlightOpacity: Double = row.rowId == highlightedRowId ? 0.28 : 0
                    songRow(row, displayIndex: displayIndex, showsBottomDivider: showsBottomDivider)
                        .albumTrackListRowStyle(highlightOpacity: highlightOpacity)
                case .missing(let preview, let displayIndex):
                    missingAlbumRow(preview, displayIndex: displayIndex, showsBottomDivider: showsBottomDivider)
                        .albumTrackListRowStyle()
                }
            }
            showCompleteAlbumToggle
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            albumFooterBlock
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        } else {
            let windowed = visible.prefix(rowRenderLimit)
            ForEach(Array(windowed.enumerated()), id: \.element.rowId) { index, row in
                let showsBottomDivider = index < visible.count - 1
                let highlightOpacity: Double = row.rowId == highlightedRowId ? 0.28 : 0
                Group {
                    if isAlbumStyleDetail {
                        songRow(row, displayIndex: index + 1, showsBottomDivider: showsBottomDivider)
                            .albumTrackListRowStyle(highlightOpacity: highlightOpacity)
                    } else {
                        songRow(row, displayIndex: index + 1, showsBottomDivider: showsBottomDivider)
                            .heroBackdropSongListRowStyle(highlightOpacity: highlightOpacity)
                    }
                }
                .onAppear {
                    extendRowRenderWindow(afterRealizing: index, totalRows: visible.count)
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
        if isAlbumStyleDetail {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                if let url = resolvedDetailArtworkURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(backdropPalette.heroChromePrimary)
                    }
                }
                Menu {
                    if isHomeMix {
                        homeMixOverflowMenuContent
                    } else {
                        albumOverflowMenuContent
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(backdropPalette.heroChromePrimary)
                }
                .menuOrder(.fixed)
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                killModeToolbarButton
                Menu {
                    playlistOverflowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(backdropPalette.heroChromePrimary)
                }
                .menuOrder(.fixed)
            }
        }
    }

    /// Sits in the trailing toolbar group, immediately left of the 3-dot menu. Hidden
    /// unless there is at least one pending removal — Kill Mode on/off lives in the menu.
    @ViewBuilder
    private var killModeToolbarButton: some View {
        let count = killModePendingCount
        if count > 0 {
            NavigationLink {
                PlaylistKillListView(playlistId: playlist.id, rows: rows)
            } label: {
                Image(systemName: "scissors")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .overlay(alignment: .topTrailing) {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 8, y: -6)
                    }
            }
            .accessibilityLabel("\(count) song\(count == 1 ? "" : "s") to remove")
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Nothing matches your search." }
        if isHomeMix { return "This mix updates from your listening history and may change when you refresh." }
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
        case .homeMix:
            return activeHomeMix?.libraryDetailSubtitle
        }
    }

    /// Album-only artist + detail split so the hero can render the artist name as a
    /// tappable link (push to ``ArtistPageView``) while keeping the rest of the
    /// metadata line as static text. `nil` artist means non-album source or unknown.
    private var heroAlbumArtistSplit: (artist: String, detail: String?)? {
        guard case .album(let album, _) = source else { return nil }
        let trimmed = album.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tracks = rows.map(\.track)
        let detail = AlbumHeroMetadataLine.compose(album: album, tracks: tracks)
        return (trimmed, detail.isEmpty ? nil : detail)
    }

    /// Apple Music–style: tapping the literal "Various Artists" string on an album
    /// page would surface a useless artist page (every collaboration on the server).
    /// Match Apple's behavior by treating it as non-tappable.
    private static func isTappableArtist(_ name: String) -> Bool {
        name.lowercased() != "various artists"
    }

    /// Album hero subtitle line — artist name is a NavigationLink to ``ArtistPageView``
    /// for album sources; playlists keep the existing static Text path.
    ///
    /// Suppresses the system's auto-disclosure chevron with
    /// ``navigationLinkIndicatorVisibility(.hidden)`` — otherwise an extra `>`
    /// glyph slots in between the artist name and the detail text and the link
    /// claims a wider hit area than its label, pushing the metadata to the right.
    @ViewBuilder
    private var heroSubtitleLine: some View {
        if let split = heroAlbumArtistSplit {
            HStack(spacing: 6) {
                if Self.isTappableArtist(split.artist) {
                    NavigationLink {
                        ArtistPageView(input: .named(split.artist))
                    } label: {
                        Text(split.artist)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(backdropPalette.heroChromeSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .navigationLinkIndicatorVisibility(.hidden)
                } else {
                    Text(split.artist)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(backdropPalette.heroChromeSecondary)
                }
                if let detail = split.detail {
                    Text("· \(detail)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(backdropPalette.heroChromeSecondary)
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(.center)
        } else if let subtitle = heroSubtitle {
            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(backdropPalette.heroChromeSecondary)
                .multilineTextAlignment(.center)
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
        // Order-independent check — don't pay `allOrderedTracks`' map + sort on
        // every body evaluation of a large playlist.
        !rows.isEmpty && rows.allSatisfy { app.offline.downloadedTrackIds.contains($0.track.id) }
    }

    private var showsDownloadedCheckmark: Bool {
        if isHomeMix {
            return allTracksCached
        }
        if isAlbum, let album = albumOrNil {
            return app.isAlbumInLibrary(album.id) && allTracksCached
        }
        return !isAlbumStyleDetail && allTracksCached
    }

    private var showsDownloadedAlbumCheckmark: Bool {
        showsDownloadedCheckmark && isAlbum
    }

    private var allTracksFavorited: Bool {
        !rows.isEmpty && rows.allSatisfy { app.favoriteTrackIds.contains($0.track.id) }
    }

    private var playlistPinRef: LibraryPinnedRef {
        LibraryPinnedRef(kind: .playlist, itemId: playlist.id)
    }

    private var isPlaylistPinned: Bool {
        LibraryPinStore.contains(playlistPinRef, in: pinnedStorage)
    }

    private var isAlbumPinned: Bool {
        guard let album = albumOrNil else { return false }
        return LibraryPinStore.contains(LibraryPinnedRef(kind: .album, itemId: album.id), in: pinnedStorage)
    }

    @ViewBuilder
    private var playlistOverflowMenuContent: some View {
        if !showsDownloadedCheckmark {
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
        } else {
            ControlGroup {
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
        }

        Section {
            Button(action: togglePlaylistPinned) {
                Label(
                    LibraryPinStore.menuLabel(kind: .playlist, isPinned: isPlaylistPinned),
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
            .disabled(displayedRows.isEmpty)
        }
        .tint(Color.primary)

        Section {
            Button {
                app.toggleKillMode(playlistId: playlist.id)
            } label: {
                let enabled = app.isKillModeEnabled(playlistId: playlist.id)
                Label {
                    Text("Kill Mode  ")
                        + Text(enabled ? "ON" : "OFF")
                            .foregroundColor(enabled ? .red : .secondary)
                            .fontWeight(.bold)
                } icon: {
                    Image(systemName: "scissors")
                }
            }
        }
        .tint(Color.primary)

        NavidromeShareMenuSection(
            itemId: playlist.id,
            description: navigationTitleText.isEmpty ? playlist.name : navigationTitleText
        )

        Section {
            Button("Delete playlist", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    private var heroBlock: some View {
        VStack(spacing: 18) {
            heroArtwork
                .frame(width: heroArtSide, height: heroArtSide)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 6) {
                Text(navigationTitleText.isEmpty ? source.displayName : navigationTitleText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                heroSubtitleLine
            }

            actionButtonTriplet
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var heroArtwork: some View {
        if isHomeMix, let mix = activeHomeMix {
            MixCollageArtworkView(
                urls: mix.artworkURLs,
                fallbackSeed: "homeMix:\(mix.id)",
                cornerRadius: 14
            )
        } else {
            AlbumArtworkView(url: resolvedDetailArtworkURL, cornerRadius: 14)
        }
    }

    /// Pending tracks (Kill Mode) that still resolve to a current playlist row. Stale ids
    /// from tracks already removed by other paths are excluded from the toolbar badge.
    private var killModePendingCount: Int {
        guard !isAlbumStyleDetail else { return 0 }
        let pending = app.killModePendingTrackIds(playlistId: playlist.id)
        guard !pending.isEmpty else { return 0 }
        let rowIds = Set(rows.map(\.track.id))
        return pending.intersection(rowIds).count
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
            .disabled(displayedRows.isEmpty)

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
            .disabled(displayedRows.isEmpty)

            primaryActionButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    /// Hero glyph color — backdrop-aware for albums and regular playlists.
    private var heroGlyphColor: Color {
        backdropPalette.heroGlassIcon
    }

    private var heroCircleFill: Color {
        backdropPalette.heroGlassCircleFill
    }

    private var heroPlayCapsuleForeground: Color {
        backdropPalette.heroPlayCapsuleForeground
    }

    private var heroPlayCapsuleBackground: Color {
        backdropPalette.heroPlayCapsuleBackground
    }

    /// Right-hand action in the hero triplet. Album mode: `plus` → `arrow.down` → `checkmark`
    /// when fully downloaded (checkmark opens manage-download sheet). Playlist mode: same
    /// download → checkmark flow when every track is cached offline.
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
        } else if showsDownloadedCheckmark {
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
            .accessibilityLabel(isAlbum ? "Manage download and library" : "Manage downloads")
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
        if let album = albumOrNil {
            app.removeOfflineCachedItem(itemId: album.id)
        } else if case .playlist(let playlist) = source {
            app.removeOfflineCachedItem(itemId: playlist.id)
        } else {
            app.removeOfflineDownloads(trackIds: allOrderedTracks.map(\.id))
        }
    }

    private func deleteAlbumFromLibraryAndOffline() async {
        guard let album = albumOrNil else { return }
        app.removeOfflineCachedItem(itemId: album.id)
        await app.removeAlbumFromLibrary(album)
    }

    private func downloadAllTracks() async {
        guard app.activeLibrary != nil, !allOrderedTracks.isEmpty else { return }
        isDownloadingAll = true
        defer { isDownloadingAll = false }
        let tracks = allOrderedTracks
        if let album = albumOrNil {
            app.enqueueOfflineAlbum(album, tracks: tracks)
        } else if case .playlist(let playlist) = source {
            app.enqueueOfflinePlaylist(playlist, tracks: tracks)
        } else {
            app.offline.enqueueTracks(tracks)
        }
        app.showTransientToast("Added to download queue")
    }

    private func beginRename() {
        showPlaylistEditor = true
    }

    private func togglePlaylistPinned() {
        LibraryPinStore.toggle(playlistPinRef, storage: &pinnedStorage)
    }

    private func toggleAlbumPinned() {
        guard let album = albumOrNil else { return }
        if !isAlbumPinned {
            app.retainAlbumForLibraryPin(album)
        }
        LibraryPinStore.toggle(LibraryPinnedRef(kind: .album, itemId: album.id), storage: &pinnedStorage)
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

    /// MusicBrainz-only track row — same chrome as owned rows; tap (play affordance) requests via Downtify.
    @ViewBuilder
    private func missingAlbumRow(_ preview: BrowseAlbumPreviewTrack, displayIndex: Int, showsBottomDivider: Bool) -> some View {
        let previewJob = downtifyJob(forPreview: preview)
        let isRequesting = previewJob.map { !$0.status.isTerminal } ?? false
        let downtifyProgress: OfflineDownloadUIState? = {
            guard let previewJob, !previewJob.status.isTerminal else { return nil }
            return .progress(min(1, max(0, previewJob.progress)))
        }()

        AppleMusicAlbumTrackRow(
            index: displayIndex,
            title: preview.title,
            subtitle: "Not in library",
            offlineDownload: downtifyProgress,
            isOfflineCached: false,
            isInLibrary: false,
            isInServerCatalog: false,
            greysTitle: true,
            showsOfflineIndicator: isRequesting,
            backdropPalette: backdropPalette,
            showsBottomDivider: showsBottomDivider,
            onRowTap: {
                Task { await requestMissingTrack(preview) }
            },
            menuContent: {
                ChartStyleSongOverflowMenuContent(
                    shareItem: "\(preview.title) — \(albumOrNil?.artist ?? "")",
                    onAdd: { Task { await requestMissingTrack(preview) } },
                    addDisabled: !app.downtifyConfigured || isRequesting
                )
            }
        )
    }

    /// Match a preview row to a manager job by normalized title (previews have no URL).
    private func downtifyJob(forPreview preview: BrowseAlbumPreviewTrack) -> DowntifyJob? {
        let keys = Set(LibraryTrackMatcher.normalizedTitleKeys(from: preview.title))
        guard !keys.isEmpty else { return nil }
        return downtify.jobs.values.first { job in
            guard let t = job.title, !t.isEmpty else { return false }
            return !Set(LibraryTrackMatcher.normalizedTitleKeys(from: t)).isDisjoint(with: keys)
        }
    }

    private func requestMissingTrack(_ preview: BrowseAlbumPreviewTrack) async {
        guard app.downtifyConfigured else {
            app.showTransientToast("Add your Downtify URL in Settings first.")
            return
        }
        await downtify.enqueue(artist: albumOrNil?.artist ?? "", title: preview.title)
        app.showTransientToast("Requested “\(preview.title)”")
    }

    private func songRow(_ row: PlaylistRowItem, displayIndex: Int, showsBottomDivider: Bool) -> some View {
        // Album mode and playlist mode share the exact same row chrome (swipe actions,
        // 3-dot menu options). The only branch is `onRemoveFromPlaylist` — albums don't
        // belong to a playlist that the user can remove tracks from, so the swipe
        // action collapses to "Delete File from Server" (admin) or nothing.
        return TrackDownloadProgressReader(progress: offline.progressModel, trackId: row.track.id) { downloadState in
            songRowContent(row, downloadState: downloadState, displayIndex: displayIndex, showsBottomDivider: showsBottomDivider)
        }
    }

    private func songRowContent(_ row: PlaylistRowItem, downloadState: OfflineDownloadUIState?, displayIndex: Int, showsBottomDivider: Bool) -> some View {
        let removeFromPlaylist: (() -> Void)? = isAlbumStyleDetail ? nil : { rowPendingRemoval = row }
        return LibrarySongRow(
            track: row.track,
            artworkURL: app.resolvedArtworkURL(for: row.track),
            itemSize: app.songListItemSize,
            isFavorite: app.favoriteTrackIds.contains(row.track.id),
            isNowPlaying: app.player.activeTrack?.id == row.track.id,
            offlineDownload: downloadState,
            isOfflineCached: app.offline.downloadedTrackIds.contains(row.track.id),
            onPlay: { Task { await play(row: row) } },
            onDownload: { Task { await cacheOffline(track: row.track) } },
            onCancelOfflineDownload: { app.offline.cancelDownload(trackId: row.track.id) },
            onFavorite: { app.toggleFavoriteTrack(id: row.track.id) },
            onPlayNext: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    let originId = isAlbumStyleDetail ? nil : source.playlistOrNil?.id
                    try? await app.player.playNext(library: lib, track: row.track, sourcePlaylistId: originId)
                    await MainActor.run { app.showTransientToast("Playing Next") }
                }
            },
            onAddToQueue: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    let originId = isAlbumStyleDetail ? nil : source.playlistOrNil?.id
                    try? await app.player.addToQueue(library: lib, track: row.track, sourcePlaylistId: originId)
                    await MainActor.run { app.showTransientToast("Added to Queue") }
                }
            },
            hasActiveQueue: !app.player.queue.isEmpty,
            onGoToAlbum: isAlbumStyleDetail ? nil : { navigateAlbum = app.albumSummary(for: row.track) },
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
            hidesAddToLibraryChip: !isAlbumStyleDetail,
            showsArtwork: !isAlbumStyleDetail,
            showsArtist: !isAlbumStyleDetail,
            rowBackgroundFill: .clear,
            usesAlbumSwipeChrome: isAlbumStyleDetail,
            showsBottomDivider: showsBottomDivider,
            dividerPalette: isAlbumStyleDetail ? backdropPalette : nil,
            rowLabelPalette: isAlbumStyleDetail ? nil : backdropPalette,
            trackDisplayIndex: isAlbumStyleDetail ? displayIndex : nil,
            onPresentDownloadedDeleteSheet: {
                trackPendingDownloadedDelete = row.track
            }
        )
        .equatable()
    }

    private func cacheOffline(track: Track) async {
        app.enqueueOfflineTrack(track)
    }

    private func hydrateFromCacheIfNeeded() {
        guard case .playlist(let p) = source, rows.isEmpty,
              let cached = app.cachedPlaylistRows(playlistId: p.id), !cached.isEmpty else { return }
        rows = cached
        isLoading = false
        recomputeDisplayedRows()
    }

    private func load() async {
        guard app.isSignedIn else {
            loadError = "Sign in to view your library."
            rows = []
            isLoading = false
            recomputeDisplayedRows()
            return
        }
        hydrateFromCacheIfNeeded()
        loadError = nil
        let showSpinner = rows.isEmpty
        if showSpinner { isLoading = true }
        defer {
            isLoading = false
            recomputeDisplayedRows()
        }
        do {
            switch source {
            case .playlist(let p):
                let fresh = try await app.fetchPlaylistRows(playlistId: p.id)
                if rows.isEmpty || fresh.map(\.track.id) != rows.map(\.track.id) {
                    rows = fresh
                }
            case .album(let album, _):
                let offlineTracks = offline.cachedTracks(forAlbumId: album.id)
                if !offlineTracks.isEmpty,
                   offlineTracks.allSatisfy({ offline.downloadedTrackIds.contains($0.id) }) {
                    rows = offlineTracks.enumerated().map { idx, track in
                        PlaylistRowItem(rowId: "album-\(album.id)-\(idx)-\(track.id)", track: track)
                    }
                } else if let lib = app.activeLibrary {
                    let tracks = try await lib.tracks(forAlbumId: album.id)
                    rows = tracks.enumerated().map { idx, track in
                        PlaylistRowItem(rowId: "album-\(album.id)-\(idx)-\(track.id)", track: track)
                    }
                } else if rows.isEmpty {
                    rows = []
                }
            case .homeMix(let mixId):
                if let mix = app.homeMixes.first(where: { $0.id == mixId }) {
                    navigationTitleText = mix.title
                    let fresh = mix.tracks.enumerated().map { idx, track in
                        PlaylistRowItem(rowId: "homemix-\(mixId)-\(idx)-\(track.id)", track: track)
                    }
                    if rows.isEmpty || fresh.map(\.track.id) != rows.map(\.track.id) {
                        rows = fresh
                    }
                } else if rows.isEmpty {
                    rows = []
                }
            }
        } catch {
            if rows.isEmpty {
                loadError = error.localizedDescription
                rows = []
            }
        }
        if isAlbum, previewTracks.isEmpty, shouldLoadAlbumPreviewTracks {
            Task { await loadPreviewTracksIfAlbum() }
        }
    }

    private func removeRow(_ row: PlaylistRowItem) async {
        guard !isHomeMix else { return }
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
        displayedRows.map(\.track)
    }

    private var playbackSource: PlaybackSource? {
        if isAlbumStyleDetail {
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
        guard let idx = displayedRows.firstIndex(where: { $0.rowId == row.rowId }) else { return }
        try? await app.player.playAlbum(library: lib, tracks: playbackTracks, startIndex: idx, source: playbackSource)
    }

    // MARK: - Album-mode helpers

    /// Album-mode overflow menu (in the navigation bar). Distinct from playlist's
    /// rename/delete-playlist actions.
    @ViewBuilder
    private var homeMixOverflowMenuContent: some View {
        if !showsDownloadedCheckmark {
            ControlGroup {
                Button {
                    Task { await downloadAllTracks() }
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle")
                }
                .disabled(rows.isEmpty || isDownloadingAll || allTracksCached)

                Button(action: toggleAllTrackFavorites) {
                    Label(
                        allTracksFavorited ? "Favorited" : "Favorite",
                        systemImage: allTracksFavorited ? "star.fill" : "star"
                    )
                }
                .disabled(rows.isEmpty)
            }
            .tint(Color.primary)
        } else {
            ControlGroup {
                Button(action: toggleAllTrackFavorites) {
                    Label(
                        allTracksFavorited ? "Favorited" : "Favorite",
                        systemImage: allTracksFavorited ? "star.fill" : "star"
                    )
                }
                .disabled(rows.isEmpty)
            }
            .tint(Color.primary)
        }
    }

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

            Section {
                Button(action: toggleAlbumPinned) {
                    Label(
                        LibraryPinStore.menuLabel(kind: .album, isPinned: isAlbumPinned),
                        systemImage: isAlbumPinned ? "pin.slash" : "pin"
                    )
                }
            }
            .tint(Color.primary)

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

            NavidromeShareMenuSection(
                itemId: album.id,
                description: "\(album.title) — \(album.artist)"
            )
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

    /// Grows the render window when the user nears its end. Realized rows call
    /// this from `onAppear`; growing in chunks well ahead of the visible edge
    /// keeps scrolling seamless (the user never sees the boundary).
    private func extendRowRenderWindow(afterRealizing index: Int, totalRows: Int) {
        guard rowRenderLimit < totalRows, index >= rowRenderLimit - 40 else { return }
        rowRenderLimit += Self.rowRenderChunk
    }

    private func scrollToFocusedTrackIfNeeded(proxy: ScrollViewProxy) {
        // Initial-mount focus uses ``scrollToTrackId`` (Now Playing → Go to ... pushes a fresh
        // detail view) — jump straight to the row, no scroll animation. The already-visible path
        // sets ``activeScrollTrackId`` from a ``pendingPlaylistScroll`` / ``pendingAlbumScroll``
        // signal — animate that scroll so the user sees it land in context.
        let isFromSignal = activeScrollTrackId != nil
        let targetId = activeScrollTrackId ?? scrollToTrackId
        guard !didScrollToFocusTrack,
              let trackId = targetId,
              let matchingRow = rows.first(where: { $0.track.id == trackId })
        else { return }
        didScrollToFocusTrack = true
        let targetRowId = matchingRow.rowId
        // The focus row may sit beyond the windowed first render — expand to the
        // full tracklist before scrolling so the target row exists in the List.
        if let targetIndex = displayedRows.firstIndex(where: { $0.rowId == targetRowId }),
           targetIndex >= rowRenderLimit {
            rowRenderLimit = max(displayedRows.count, rowRenderLimit)
        }
        scrollHighlightTask?.cancel()
        scrollHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            if isFromSignal {
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(targetRowId, anchor: .center)
                }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            } else {
                proxy.scrollTo(targetRowId, anchor: .center)
            }
            withAnimation(.easeIn(duration: 0.18)) {
                highlightedRowId = targetRowId
            }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.9)) {
                highlightedRowId = nil
            }
        }
    }
}

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

/// Navigation chrome modifier — artwork-derived hero palette for albums and playlists.
private struct DetailNavigationChrome: ViewModifier {
    let palette: ArtworkDynamicGradient.BackdropPalette

    func body(content: Content) -> some View {
        content.musicHeroAlbumNavigationChrome(palette: palette)
    }
}

/// Identifiable wrapper so a freshly-picked cover image can drive a `.sheet(item:)`
/// crop step before it's stashed/uploaded.
private struct CoverCropSubject: Identifiable {
    let id = UUID()
    let imageData: Data
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
    @State private var coverCropSubject: CoverCropSubject?
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
        .sheet(item: $coverCropSubject) { subject in
            cropSheet(for: subject)
        }
    }

    @ViewBuilder
    private func cropSheet(for subject: CoverCropSubject) -> some View {
        #if canImport(UIKit)
        if let uiImage = UIImage(data: subject.imageData) {
            SquareImageCropView(
                image: uiImage,
                onCancel: { coverCropSubject = nil },
                onCrop: { cropped in
                    coverCropSubject = nil
                    Task { await applyCoverImage(cropped) }
                },
            )
        } else {
            Color.clear.onAppear {
                coverCropSubject = nil
                Task { await applyCoverImage(subject.imageData) }
            }
        }
        #else
        Color.clear.onAppear {
            coverCropSubject = nil
            Task { await applyCoverImage(subject.imageData) }
        }
        #endif
    }

    /// Picking only loads the image now — the user frames it in ``SquareImageCropView``
    /// before it's stashed (create) or uploaded (edit) via ``applyCoverImage``.
    private func handleCoverPickerSelection(_ item: PhotosPickerItem) async {
        defer { coverPickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            app.errorMessage = "Could not read the selected image."
            return
        }
        coverCropSubject = CoverCropSubject(imageData: data)
    }

    private func applyCoverImage(_ data: Data) async {
        isUploadingCover = true
        defer { isUploadingCover = false }
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
    @EnvironmentObject private var app: AppModel
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

            AlbumArtworkView(url: app.resolvedArtworkURL(for: row.track), cornerRadius: 5)
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
                                AlbumArtworkView(url: app.resolvedArtworkURL(for: track), cornerRadius: 5)
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
