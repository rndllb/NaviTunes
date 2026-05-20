import SwiftUI

/// Library → **Artists** (Jellyfin `MusicArtist` / Navidrome `getArtists`).
struct LibraryArtistsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var artists: [LibraryArtistSummary] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var query = ""

    private var filtered: [LibraryArtistSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if isLoading, artists.isEmpty {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
            } else if let loadError, artists.isEmpty {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isLoading, artists.isEmpty {
                ContentUnavailableView(
                    "No artists",
                    systemImage: "mic",
                    description: Text("Your library didn’t return any artist entries.")
                )
                .padding(.top, 48)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, artist in
                            NavigationLink {
                                LibraryArtistAlbumsView(artist: artist)
                            } label: {
                                artistRow(artist)
                            }
                            .buttonStyle(.plain)
                            if index < filtered.count - 1 {
                                Divider()
                                    .background(MusicDesign.separator)
                                    .padding(.leading, 86)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(MusicDesign.background)
        .navigationTitle("Artists")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .searchable(text: $query, placement: .automatic, prompt: Text("Artists"))
        .task(id: "\(app.isSignedIn)-\(app.backendKind)") { await load() }
        .refreshable { await load() }
    }

    private func artistRow(_ artist: LibraryArtistSummary) -> some View {
        HStack(spacing: 14) {
            AlbumArtworkView(url: artist.artworkURL, cornerRadius: 6)
                .frame(width: 52, height: 52)
                .clipShape(Circle())

            Text(artist.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func load() async {
        guard app.isSignedIn else {
            artists = []
            loadError = "Sign in to browse artists."
            isLoading = false
            return
        }
        guard let lib = app.activeLibrary else {
            artists = []
            loadError = "No library connection."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            artists = try await lib.libraryArtists(limit: 12_000)
        } catch {
            loadError = error.localizedDescription
            artists = []
        }
    }
}

/// Tracks and albums for one library artist.
struct LibraryArtistAlbumsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    let artist: LibraryArtistSummary

    @State private var albums: [AlbumSummary] = []
    @State private var tracks: [Track] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var navigateAlbum: AlbumSummary?
    @State private var trackPendingDownloadedDelete: Track?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    private var hasAnyContent: Bool {
        !albums.isEmpty || !tracks.isEmpty
    }

    var body: some View {
        List {
            if isLoading, !hasAnyContent {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if let loadError, !hasAnyContent {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if !hasAnyContent {
                ContentUnavailableView(
                    "No music",
                    systemImage: "music.note",
                    description: Text("No songs or albums for this artist were found in your library.")
                )
                .padding(.top, 48)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                if !tracks.isEmpty {
                    songsSection
                }
                if !albums.isEmpty {
                    albumsSection
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .navigationTitle(artist.name)
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
        }
        .task(id: artist.id) { await load() }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .downloadedTrackDeleteSheet(
            track: $trackPendingDownloadedDelete,
            app: app,
            offline: offline
        )
    }

    private var songsSection: some View {
        Section {
            playShuffleTracksRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 14, trailing: 20))

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                songRow(track, showsBottomDivider: index < tracks.count - 1)
            }
        } header: {
            Text("Songs")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.top, 8)
        }
    }

    private var playShuffleTracksRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: tracks.isEmpty,
            onPlay: { Task { await playTracksFrom(startIndex: 0) } },
            onShuffle: { Task { await shuffleTracks() } },
        )
    }

    private var albumsSection: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink {
                        ServerPlaylistDetailView(album: album, librarySource: true)
                    } label: {
                        LibraryBrowsingAlbumGridCell(album: album)
                    }
                    .buttonStyle(.plain)
                    .libraryAlbumContextMenu(album)
                }
            }
            .padding(.horizontal, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 16, trailing: 12))
        } header: {
            Text("Albums")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.top, tracks.isEmpty ? 8 : 0)
        }
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
        } catch {}
    }

    private func play(track: Track) async {
        guard let lib = app.activeLibrary else { return }
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracks, startIndex: idx)
    }

    private func playTracksFrom(startIndex: Int) async {
        guard let lib = app.activeLibrary, !tracks.isEmpty else { return }
        let i = min(max(0, startIndex), tracks.count - 1)
        try? await app.player.playAlbum(library: lib, tracks: tracks, startIndex: i)
    }

    private func shuffleTracks() async {
        guard let lib = app.activeLibrary, !tracks.isEmpty else { return }
        let shuffled = tracks.shuffled()
        try? await app.player.playAlbum(library: lib, tracks: shuffled, startIndex: 0)
    }

    private func load() async {
        guard let lib = app.activeLibrary else {
            albums = []
            tracks = []
            loadError = "No library connection."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            async let albumTask = lib.albums(forLibraryArtistId: artist.id, limit: 4000)
            async let trackTask = lib.tracks(forLibraryArtistId: artist.id, limit: 8000)
            let (albs, trks) = try await (albumTask, trackTask)
            albums = albs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            tracks = trks
        } catch {
            loadError = error.localizedDescription
            albums = []
            tracks = []
        }
    }
}
/// Library → **Genres** (Jellyfin `MusicGenre` / Navidrome `getGenres`).
struct LibraryGenresView: View {
    @EnvironmentObject private var app: AppModel
    @State private var genres: [LibraryGenreSummary] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var query = ""

    private var filtered: [LibraryGenreSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return genres }
        return genres.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if isLoading, genres.isEmpty {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
            } else if let loadError, genres.isEmpty {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isLoading, genres.isEmpty {
                ContentUnavailableView(
                    "No genres",
                    systemImage: "paintbrush.pointed",
                    description: Text(
                        app.backendKind == .navidrome
                            ? "Try refreshing after tagging albums, or confirm your server supports getGenres."
                            : "Jellyfin didn’t return genre items or album genre tags for the sampled library."
                    )
                )
                .padding(.top, 48)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, genre in
                            NavigationLink {
                                LibraryGenreAlbumsView(genre: genre)
                            } label: {
                                genreRow(genre)
                            }
                            .buttonStyle(.plain)
                            if index < filtered.count - 1 {
                                Divider()
                                    .background(MusicDesign.separator)
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(MusicDesign.background)
        .navigationTitle("Genres")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .searchable(text: $query, placement: .automatic, prompt: Text("Genres"))
        .task(id: "\(app.isSignedIn)-\(app.backendKind)") { await load() }
        .refreshable { await load() }
    }

    private func genreRow(_ genre: LibraryGenreSummary) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.accent)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(genre.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let n = genre.albumCount, n > 0 {
                    Text("\(n) albums")
                        .font(.caption)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func load() async {
        guard app.isSignedIn else {
            genres = []
            loadError = "Sign in to browse genres."
            isLoading = false
            return
        }
        guard let lib = app.activeLibrary else {
            genres = []
            loadError = "No library connection."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            genres = try await lib.libraryGenres(limit: 2000)
        } catch {
            loadError = error.localizedDescription
            genres = []
        }
    }
}

/// Albums tagged with a genre.
struct LibraryGenreAlbumsView: View {
    @EnvironmentObject private var app: AppModel
    let genre: LibraryGenreSummary

    @State private var albums: [AlbumSummary] = []
    @State private var loadError: String?
    @State private var isLoading = true

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            if isLoading, albums.isEmpty {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let loadError, albums.isEmpty {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
            } else if albums.isEmpty {
                ContentUnavailableView(
                    "No albums",
                    systemImage: "square.stack",
                    description: Text("No albums match this genre in your library.")
                )
                .padding(.top, 48)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink {
                            ServerPlaylistDetailView(album: album, librarySource: true)
                        } label: {
                            LibraryBrowsingAlbumGridCell(album: album)
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
        .navigationTitle(genre.name)
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        .task(id: genre.id) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let lib = app.activeLibrary else {
            albums = []
            loadError = "No library connection."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            albums = try await lib.albums(inGenre: genre, limit: 4000)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            loadError = error.localizedDescription
            albums = []
        }
    }
}

private struct LibraryBrowsingAlbumGridCell: View {
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
