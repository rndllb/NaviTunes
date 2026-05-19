import SwiftUI

// MARK: - Add to playlist (global sheet)

struct AddToPlaylistSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let tracks: [Track]

    @State private var newPlaylistName = ""
    @State private var jellyfinVisibleToAll = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("New playlist") {
                    TextField("Playlist name", text: $newPlaylistName)
                        .musicTextInputAutocapitalization(.words)
                    if app.backendKind == .jellyfin {
                        Toggle("Visible to all", isOn: $jellyfinVisibleToAll)
                        Text("Other Jellyfin users on this server can see public playlists.")
                            .font(.caption)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
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
                jellyfinVisibleToAll: app.backendKind == .jellyfin && jellyfinVisibleToAll
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
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var jellyfinVisibleToAll = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)
#if os(iOS)
                    .musicTextInputAutocapitalization(.words)
#endif
                if app.backendKind == .jellyfin {
                    Toggle("Visible to all", isOn: $jellyfinVisibleToAll)
                    Text("Other Jellyfin users on this server can see public playlists.")
                        .font(.caption)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(MusicDesign.background)
            .navigationTitle("New playlist")
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
            try await app.createPlaylist(
                name: trimmed,
                initialTracks: [],
                jellyfinVisibleToAll: app.backendKind == .jellyfin && jellyfinVisibleToAll
            )
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - New folder sheet

struct NewFolderNameSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $name)
                #if os(iOS)
                    .musicTextInputAutocapitalization(.words)
                #endif
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
            try await app.createPlaylist(name: trimmed, initialTracks: [])
            dismiss()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Server playlist detail

struct ServerPlaylistDetailView: View {
    let playlist: PlaylistSummary

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [PlaylistRowItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var navigateAlbum: AlbumSummary?
    @State private var showRename = false
    @State private var renameField = ""
    @State private var renameVisibleToAll = false
    @State private var isRenameWorking = false
    @State private var showDeleteConfirm = false
    @State private var navigationTitleText = ""

    private var filtered: [PlaylistRowItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.track.title.lowercased().contains(q)
                || $0.track.artist.lowercased().contains(q)
                || $0.track.albumTitle.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                searchSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                playShuffleRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                if isLoading, rows.isEmpty {
                    ProgressView()
                        .tint(MusicDesign.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let loadError, rows.isEmpty {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .padding(.horizontal, 20)
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        "No songs",
                        systemImage: "music.note.list",
                        description: Text(
                            searchText.isEmpty
                                ? "Add tracks from your library. Changes sync with \(app.backendKind.title)."
                                : "Nothing matches your search."
                        )
                    )
                    .padding(.top, 32)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.rowId) { index, row in
                            songRow(row)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await removeRow(row) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            if index < filtered.count - 1 {
                                Divider()
                                    .background(MusicDesign.separator)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 8)
        }
        .background(MusicDesign.background)
        .navigationTitle(navigationTitleText.isEmpty ? playlist.name : navigationTitleText)
        .musicNavigationBarTitleDisplayMode(.large)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .navigationDestination(item: $navigateAlbum) { album in
            AlbumDetailView(album: album)
        }
        .onAppear {
            if navigationTitleText.isEmpty {
                navigationTitleText = playlist.name
            }
        }
        .task { await load() }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename") {
                        renameField = navigationTitleText.isEmpty ? playlist.name : navigationTitleText
                        if let updated = app.libraryPlaylists.first(where: { $0.id == playlist.id }) {
                            renameVisibleToAll = updated.isPublic ?? false
                        } else {
                            renameVisibleToAll = playlist.isPublic ?? false
                        }
                        showRename = true
                    }
                    Button("Delete playlist", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                }
            }
        }
        .sheet(isPresented: $showRename) {
            NavigationStack {
                Form {
                    TextField("Playlist name", text: $renameField)
#if os(iOS)
                        .musicTextInputAutocapitalization(.words)
#endif
                    if app.backendKind == .jellyfin {
                        Toggle("Visible to all", isOn: $renameVisibleToAll)
                        Text("Other Jellyfin users on this server can see public playlists.")
                            .font(.caption)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(MusicDesign.background)
                .navigationTitle("Rename playlist")
                .musicNavigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showRename = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await saveRename() }
                        }
                        .disabled(
                            renameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRenameWorking
                        )
                    }
                }
                .musicNavigationChrome()
            }
        }
        .confirmationDialog(
            "Delete “\(navigationTitleText.isEmpty ? playlist.name : navigationTitleText)”?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
        ) {
            Button("Delete", role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button("Cancel", role: .cancel) {}
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

    private func songRow(_ row: PlaylistRowItem) -> some View {
        LibrarySongRow(
            track: row.track,
            isFavorite: app.favoriteTrackIds.contains(row.track.id),
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
                }
            },
            onGoToAlbum: { navigateAlbum = app.albumSummary(for: row.track) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [row.track]) },
            onDeleteFromLibrary: { app.beginLibraryTrackDeletion(row.track) },
            canDeleteFromLibrary: app.canDeleteFromLibrary,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(row.track.id)
                ? { try? app.offline.remove(trackId: row.track.id) } : nil
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
            loadError = "Sign in to view playlists."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            rows = try await app.fetchPlaylistRows(playlistId: playlist.id)
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

    private func saveRename() async {
        let trimmed = renameField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRenameWorking = true
        defer { isRenameWorking = false }
        do {
            try await app.renamePlaylist(
                playlistId: playlist.id,
                name: trimmed,
                jellyfinVisibleToAll: app.backendKind == .jellyfin ? renameVisibleToAll : nil
            )
            navigationTitleText = trimmed
            showRename = false
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

    private func playAll() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracksForPlayback, startIndex: 0)
    }

    private func shuffleAll() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        let shuffled = tracksForPlayback.shuffled()
        try? await app.player.playAlbum(library: lib, tracks: shuffled, startIndex: 0)
    }

    private func play(row: PlaylistRowItem) async {
        guard let lib = app.activeLibrary else { return }
        let playbackTracks = tracksForPlayback
        guard let idx = filtered.firstIndex(where: { $0.rowId == row.rowId }) else { return }
        try? await app.player.playAlbum(library: lib, tracks: playbackTracks, startIndex: idx)
    }
}
