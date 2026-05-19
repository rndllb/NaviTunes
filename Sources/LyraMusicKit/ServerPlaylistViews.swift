import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    @State private var isDownloadingAll = false
    @State private var sortOrder: PlaylistTrackSortOrder = .playlistOrder
    @AppStorage("favoritedPlaylistIds") private var favoritedRaw: String = ""

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
        ScrollView {
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

            VStack(alignment: .leading, spacing: 0) {
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
        }
        .background(MusicDesign.background)
#if os(iOS)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
#else
        .searchable(text: $searchText, prompt: "Search")
#endif
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNewTabNavigationChrome()
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
                    playlistOverflowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                }
                .menuOrder(.fixed)
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
        var parts: [String] = []
        let count = playlist.songCount ?? rows.count
        if count > 0 {
            parts.append("\(count) song\(count == 1 ? "" : "s")")
        }
        if let date = playlist.libraryAddedDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append("Updated \(formatter.localizedString(for: date, relativeTo: Date()))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var allTracksCached: Bool {
        !rows.isEmpty && rows.allSatisfy { app.offline.downloadedTrackIds.contains($0.track.id) }
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
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: 14)
                .frame(width: heroArtSide, height: heroArtSide)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 6) {
                Text(navigationTitleText.isEmpty ? playlist.name : navigationTitleText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                if let subtitle = heroSubtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MusicDesign.secondaryLabel)
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
                    .foregroundStyle(MusicDesign.accent)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(MusicDesign.chromeCapsuleFill))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)

            Button {
                Task { await playAll() }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: MusicDesign.albumHeroPrimaryCapsuleWidth, height: 54)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)

            Button {
                Task { await downloadAllTracks() }
            } label: {
                Group {
                    if isDownloadingAll {
                        ProgressView()
                            .tint(MusicDesign.accent)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(
                                rows.isEmpty || allTracksCached
                                    ? MusicDesign.accent.opacity(0.35)
                                    : MusicDesign.accent
                            )
                    }
                }
                .frame(width: 54, height: 54)
                .background(Circle().fill(MusicDesign.chromeCapsuleFill))
            }
            .buttonStyle(.plain)
            .disabled(rows.isEmpty || isDownloadingAll || allTracksCached)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
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
        renameField = navigationTitleText.isEmpty ? playlist.name : navigationTitleText
        if let updated = app.libraryPlaylists.first(where: { $0.id == playlist.id }) {
            renameVisibleToAll = updated.isPublic ?? false
        } else {
            renameVisibleToAll = playlist.isPublic ?? false
        }
        showRename = true
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

    private func songRow(_ row: PlaylistRowItem) -> some View {
        LibrarySongRow(
            track: row.track,
            itemSize: app.songListItemSize,
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

    private var playbackSource: PlaybackSource {
        .playlist(app.libraryPlaylists.first(where: { $0.id == playlist.id }) ?? playlist)
    }

    private func playAll() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracksForPlayback, startIndex: 0, source: playbackSource)
    }

    private func shuffleAll() async {
        guard let lib = app.activeLibrary, !tracksForPlayback.isEmpty else { return }
        let shuffled = tracksForPlayback.shuffled()
        try? await app.player.playAlbum(library: lib, tracks: shuffled, startIndex: 0, source: playbackSource)
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
}

/// Reads `\.isSearching` (valid in descendants of `.searchable`) and swaps the
/// playlist header between the centered hero (idle) and the inline Play/Shuffle pills (searching).
private struct PlaylistHeroOrPillsHeader<Hero: View, Pills: View>: View {
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
