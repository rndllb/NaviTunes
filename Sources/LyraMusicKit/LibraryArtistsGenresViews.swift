import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct LibraryArtistListSection: Identifiable, Equatable {
    let id: String
    let artists: [LibraryArtistSummary]
}

private enum LibraryArtistLibraryFilter: String, CaseIterable {
    case allArtists
    case favorites
    case downloads
}

/// Full artists list without scrubber state — `Equatable` so bias tweaks don't rebuild all rows.
private struct LibraryArtistsListBody: View, Equatable {
    @Binding var query: String
    let isLoading: Bool
    let artists: [LibraryArtistSummary]
    let displayedSections: [LibraryArtistListSection]
    let loadError: String?
    let emptyTitle: String
    let emptyDescription: String
    let showsArtistSections: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query == rhs.query
            && lhs.isLoading == rhs.isLoading
            && lhs.artists.count == rhs.artists.count
            && lhs.displayedSections == rhs.displayedSections
            && lhs.loadError == rhs.loadError
            && lhs.emptyTitle == rhs.emptyTitle
            && lhs.emptyDescription == rhs.emptyDescription
            && lhs.showsArtistSections == rhs.showsArtistSections
    }

    var body: some View {
        List {
            if isLoading, artists.isEmpty {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if let loadError, artists.isEmpty {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if !isLoading, artists.isEmpty {
                ContentUnavailableView(
                    "No artists",
                    systemImage: "mic",
                    description: Text("Your library didn’t return any artist entries.")
                )
                .padding(.top, 48)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if !showsArtistSections {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "mic",
                    description: Text(emptyDescription)
                )
                .padding(.top, 32)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                LibraryArtistSectionsList(sections: displayedSections)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(MusicDesign.background)
    }
}

/// Artist rows only — `Equatable` so scrubber scroll tweaks don't rebuild thousands of cells.
private struct LibraryArtistSectionsList: View, Equatable {
    let sections: [LibraryArtistListSection]

    var body: some View {
        ForEach(sections) { section in
            Section {
                sectionLetterRow(section.id)
                ForEach(Array(section.artists.enumerated()), id: \.element.id) { index, artist in
                    artistNavigationRow(artist)
                        .musicChevronRowDivider(.artistArtwork, shows: index < section.artists.count - 1)
                }
            }
        }
    }

    private func sectionLetterRow(_ letter: String) -> some View {
        Text(letter)
            .font(.title2.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .id(LibraryAlphabetIndex.artistScrollSectionID(letter))
    }

    private func artistNavigationRow(_ artist: LibraryArtistSummary) -> some View {
        NavigationLink {
            LibraryArtistAlbumsView(artist: artist)
        } label: {
            LibraryArtistRowLabel(artist: artist)
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .id(artist.id)
    }
}

private struct LibraryArtistRowLabel: View {
    let artist: LibraryArtistSummary

    var body: some View {
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
                .padding(.trailing, 9)
        }
        .padding(.leading, 20)
        .padding(.trailing, 17)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Library → **Artists** (Jellyfin `MusicArtist` / Navidrome `getArtists`).
struct LibraryArtistsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager

    init(downloadsOnly: Bool = false) {
        _libraryFilter = State(initialValue: downloadsOnly ? .downloads : .allArtists)
    }

    @State private var artists: [LibraryArtistSummary] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var query = ""
    @State private var libraryFilter: LibraryArtistLibraryFilter
    @State private var displayedSections: [LibraryArtistListSection] = []
    @State private var scrubberSelectedLetter: String?
    @State private var lastScrubbedLetter: String?

    private var scrubberLetters: [String] {
        displayedSections.map(\.id)
    }

    private var hasDisplayedArtists: Bool {
        !displayedSections.isEmpty
    }

    private static func sectionScrollID(_ letter: String) -> String {
        LibraryAlphabetIndex.artistScrollSectionID(letter)
    }

    private var emptyTitle: String {
        switch libraryFilter {
        case .allArtists: return "No artists"
        case .favorites: return "No favorite artists"
        case .downloads: return "No downloaded artists"
        }
    }

    private func recomputeDisplayed() {
        let byLibrary: [LibraryArtistSummary]
        switch libraryFilter {
        case .allArtists:
            byLibrary = artists
        case .favorites:
            let favNames = favoriteArtistNormalizedNames()
            byLibrary = artists.filter { favNames.contains(normalizedArtistKey($0.name)) }
        case .downloads:
            let downloadNames = downloadedArtistNormalizedNames()
            byLibrary = artists.filter { downloadNames.contains(normalizedArtistKey($0.name)) }
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [LibraryArtistSummary]
        if q.isEmpty {
            filtered = byLibrary
        } else {
            filtered = byLibrary.filter { $0.name.lowercased().contains(q) }
        }
        let sorted = filtered.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        displayedSections = Self.groupIntoSections(sorted)
    }

    private static func groupIntoSections(_ artists: [LibraryArtistSummary]) -> [LibraryArtistListSection] {
        LibraryAlphabetIndex.groupedSections(artists) { artist in
            LibraryAlphabetIndex.sectionLetter(for: artist.name)
        }
        .map { LibraryArtistListSection(id: $0.id, artists: $0.items) }
    }

    private func scrollToSection(_ letter: String, proxy: ScrollViewProxy) {
        guard scrubberLetters.contains(letter) else { return }
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
            proxy.scrollTo(Self.sectionScrollID(letter), anchor: .top)
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

    private func normalizedArtistKey(_ name: String) -> String {
        LibraryTrackMatcher.normalize(name)
    }

    private func favoriteArtistNormalizedNames() -> Set<String> {
        var names = Set<String>()
        for id in app.favoriteTrackIds {
            if let track = app.discoveryTrackById[id] {
                let key = normalizedArtistKey(track.artist)
                if !key.isEmpty { names.insert(key) }
            }
        }
        return names
    }

    private func downloadedArtistNormalizedNames() -> Set<String> {
        var names = Set<String>()
        for track in app.tracksForDownloadedLibrary() {
            let key = normalizedArtistKey(track.artist)
            if !key.isEmpty { names.insert(key) }
        }
        return names
    }

    private var emptyDescriptionText: String {
        switch libraryFilter {
        case .allArtists:
            return query.isEmpty
                ? "Your library didn't return any artist entries."
                : "Nothing matches your search."
        case .favorites:
            return query.isEmpty
                ? "Favorite songs from an artist will show that artist here."
                : "Nothing matches your search."
        case .downloads:
            return query.isEmpty
                ? "Artists with offline downloads will appear here."
                : "Nothing matches your search."
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            // ZStack so the scrubber is a sibling of the List, not an overlay on
            // it. As an overlay it inherited the List's coordinate space and rode
            // along with the UITableView when it overscrolled / transitioned its
            // nav bar at the scroll top. As a ZStack sibling its frame is
            // anchored to the NavigationStack content area and stays put.
            ZStack(alignment: .trailing) {
                libraryArtistsList(scrollProxy: scrollProxy)

                if hasDisplayedArtists, !scrubberLetters.isEmpty {
                    LibraryAlphabetScrubberHost(
                        letters: scrubberLetters,
                        selectedLetter: scrubberSelectedLetter,
                        onSelect: { letter in
                            scrollToSection(letter, proxy: scrollProxy)
                        },
                        onScrubEnd: endScrubbing,
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func libraryArtistsList(scrollProxy: ScrollViewProxy) -> some View {
        LibraryArtistsListBody(
            query: $query,
            isLoading: isLoading,
            artists: artists,
            displayedSections: displayedSections,
            loadError: loadError,
            emptyTitle: emptyTitle,
            emptyDescription: emptyDescriptionText,
            showsArtistSections: hasDisplayedArtists,
        )
        .equatable()
        .musicLibrarySectionScreen(title: "Artists")
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                Menu {
                    filterMenuContent
                } label: {
                    MusicLibraryToolbarIcon(systemName: "line.3.horizontal")
                }
                .menuOrder(.fixed)
            }
        }
        .musicLibraryToolbarMonochromeControls()
        .searchable(text: $query, placement: .automatic, prompt: Text("Artists"))
        .task(id: "\(app.isSignedIn)-\(app.backendKind)") { await load() }
        .refreshable { await load() }
        .onChange(of: artists) { _, _ in recomputeDisplayed() }
        .onChange(of: query) { _, _ in recomputeDisplayed() }
        .onChange(of: libraryFilter) { _, _ in recomputeDisplayed() }
        .onChange(of: app.favoriteTrackIds) { _, _ in
            if libraryFilter == .favorites { recomputeDisplayed() }
        }
        .onChange(of: offline.downloadedTrackIds) { _, _ in
            if libraryFilter == .downloads { recomputeDisplayed() }
        }
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Button {
            libraryFilter = .allArtists
        } label: {
            HStack {
                Label("All Artists", systemImage: "mic")
                Spacer(minLength: 16)
                if libraryFilter == .allArtists {
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

    private func load() async {
        guard app.isSignedIn else {
            artists = []
            displayedSections = []
            loadError = "Sign in to browse artists."
            isLoading = false
            return
        }
        guard let lib = app.activeLibrary else {
            artists = []
            displayedSections = []
            loadError = "No library connection."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            artists = try await lib.libraryArtists(limit: 12_000)
            recomputeDisplayed()
        } catch {
            loadError = error.localizedDescription
            artists = []
            displayedSections = []
        }
    }
}

/// Albums for one library artist — songs list removed; artist pic + name sits
/// above the play/shuffle row, which still drives playback over all of the
/// artist's tracks behind the scenes.
struct LibraryArtistAlbumsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    let artist: LibraryArtistSummary

    @State private var albums: [AlbumSummary] = []
    /// Loaded but not displayed — used by the play/shuffle row to start
    /// playback across the artist's entire library catalogue.
    @State private var tracks: [Track] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var navigateAlbum: AlbumSummary?
    @State private var query = ""

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    private var hasAnyContent: Bool {
        !albums.isEmpty || !tracks.isEmpty
    }

    /// Albums filtered by the searchable query — matches album title or artist
    /// (case-insensitive substring). Empty query passes everything through.
    private var filteredAlbums: [AlbumSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return albums }
        return albums.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    private var playbackTracks: [Track] {
        let albumIds = Set(filteredAlbums.map(\.id))
        guard !albumIds.isEmpty else { return [] }
        return tracks.filter { albumIds.contains($0.albumId) }
    }

    var body: some View {
        // ScrollView (not List) on purpose: `NavigationLink`s embedded in a
        // List row pick up the row's tap chrome — both the auto-disclosure
        // chevron on every cell AND a row-level tap target that interferes
        // with album navigation (back button cycles through them). Matching
        // the LibraryView Albums grid pattern avoids both issues.
        ScrollView {
            if isLoading, !hasAnyContent {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let loadError, !hasAnyContent {
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
            } else if !hasAnyContent {
                ContentUnavailableView(
                    "No music",
                    systemImage: "music.note",
                    description: Text("No songs or albums for this artist were found in your library.")
                )
                .padding(.top, 48)
            } else {
                // Extracted so the inner view can read `\.isSearching` from the
                // .searchable scope below — true the moment the user taps the
                // search bar (even before typing). Hero collapses; play/shuffle
                // and the grid slide up under the search bar.
                ArtistAlbumsScrollContent(
                    artist: artist,
                    filteredAlbums: filteredAlbums,
                    tracksAvailable: !playbackTracks.isEmpty,
                    query: query,
                    columns: columns,
                    onPlay: { Task { await playTracksFrom(startIndex: 0) } },
                    onShuffle: { Task { await shuffleTracks() } }
                )
            }
        }
        .background(MusicDesign.background)
        // Artist name lives in the hero row now; keep the nav title empty so
        // it doesn't show in the navigation bar.
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationChrome()
        .musicNavigationBarVisibleWhenPushed()
        // Same .searchable pattern the Genres view uses — system places the
        // bar in the navigation drawer above the scroll content (above the
        // hero), and `filteredAlbums` narrows the grid as the user types.
        .searchable(text: $query, placement: .automatic, prompt: Text("Albums"))
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: true)
        }
        .task(id: artist.id) { await load() }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .refreshable { await load() }
    }

    private func playTracksFrom(startIndex: Int) async {
        guard let lib = app.activeLibrary, !playbackTracks.isEmpty else { return }
        let i = min(max(0, startIndex), playbackTracks.count - 1)
        try? await app.player.playAlbum(library: lib, tracks: playbackTracks, startIndex: i)
    }

    private func shuffleTracks() async {
        guard let lib = app.activeLibrary, !playbackTracks.isEmpty else { return }
        let shuffled = playbackTracks.shuffled()
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

/// Scroll content for the artist albums view — pulled out into its own struct
/// so it can read `@Environment(\.isSearching)` from the parent `.searchable`
/// scope. When the user taps the search bar, the artist hero collapses and the
/// play/shuffle row + grid slide up under the search bar.
private struct ArtistAlbumsScrollContent: View {
    @Environment(\.isSearching) private var isSearching

    let artist: LibraryArtistSummary
    let filteredAlbums: [AlbumSummary]
    let tracksAvailable: Bool
    let query: String
    let columns: [GridItem]
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            if !isSearching {
                artistHero
                    .padding(.top, 16)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            playShuffleRow
                .padding(.top, isSearching ? 12 : 8)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            if !filteredAlbums.isEmpty {
                albumsGrid
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isSearching)
    }

    private var artistHero: some View {
        VStack(spacing: 10) {
            AlbumArtworkView(url: artist.artworkURL, cornerRadius: 42.5)
                .frame(width: 85, height: 85)
                .clipShape(Circle())

            Text(artist.name)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private var playShuffleRow: some View {
        LibraryPlayShuffleRow(
            isDisabled: !tracksAvailable,
            onPlay: onPlay,
            onShuffle: onShuffle,
        )
    }

    private var albumsGrid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(filteredAlbums) { album in
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

/// Library → **Genres** (Jellyfin `MusicGenre` / Navidrome `getGenres`).
struct LibraryGenresView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    private let downloadsOnly: Bool

    init(downloadsOnly: Bool = false) {
        self.downloadsOnly = downloadsOnly
    }

    @State private var genres: [LibraryGenreSummary] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var query = ""

    private var downloadedGenreNames: Set<String> {
        Set(
            app.tracksForDownloadedLibrary().flatMap(\.genres).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        )
    }

    private var scopeGenres: [LibraryGenreSummary] {
        guard downloadsOnly else { return genres }
        let names = downloadedGenreNames
        guard !names.isEmpty else { return [] }
        return genres.filter { names.contains($0.name.lowercased()) }
    }

    private var filtered: [LibraryGenreSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return scopeGenres }
        return scopeGenres.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isLoading, genres.isEmpty {
                    ProgressView()
                        .tint(MusicDesign.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if let loadError, genres.isEmpty {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if !isLoading, genres.isEmpty {
                    ContentUnavailableView(
                        downloadsOnly ? "No downloaded genres" : "No genres",
                        systemImage: "paintbrush.pointed",
                        description: Text(
                            downloadsOnly
                                ? "Genres from your offline downloads will appear here."
                                : app.backendKind == .navidrome
                                    ? "Try refreshing after tagging albums, or confirm your server supports getGenres."
                                    : "Jellyfin didn’t return genre items or album genre tags for the sampled library."
                        )
                    )
                    .padding(.top, 48)
                } else if !isLoading, downloadsOnly, scopeGenres.isEmpty {
                    ContentUnavailableView(
                        "No downloaded genres",
                        systemImage: "paintbrush.pointed",
                        description: Text("Genres from your offline downloads will appear here.")
                    )
                    .padding(.top, 48)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, genre in
                        NavigationLink {
                            LibraryGenreAlbumsView(genre: genre)
                        } label: {
                            genreRow(genre)
                        }
                        .buttonStyle(.plain)
                        .musicChevronRowDivider(.symbolIcon, shows: index < filtered.count - 1)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(MusicDesign.background)
        .musicLibrarySectionScreen(title: "Genres")
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

            MusicNavigationChevron()
        }
        .musicChevronRowPadding()
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
        .musicInlineNavigationTitleScreen()
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
