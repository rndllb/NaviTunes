import SwiftUI

private enum SearchScope: String, CaseIterable {
    case downtify = "Downtify"
    case library = "Library"
}

private struct RecentQuery: Codable, Identifiable, Equatable {
    var query: String
    var id: String { query }
}

private enum RecentQueryStore {
    private static let key = "discovery_recent_queries_v2"
    private static let maxCount = 24

    static func load() -> [RecentQuery] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentQuery].self, from: data)
        else { return [] }
        return decoded
    }

    static func append(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var items = load()
        items.removeAll { $0.query.caseInsensitiveCompare(q) == .orderedSame }
        items.insert(RecentQuery(query: q), at: 0)
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct DiscoverySearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var scope: SearchScope = .downtify
    @State private var searchText = ""
    @State private var recent: [RecentQuery] = RecentQueryStore.load()

    // Downtify state
    @State private var downtifyResults: [DowntifySong] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var downloadingIds: Set<String> = []
    @State private var downtifyDownloadFraction: [String: Double] = [:]
    @State private var toast: String?
    /// Pushes album detail without using `NavigationLink` inside `List` (avoids the extra system chevron).
    @State private var navigateToLibraryTrack: Track?

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredLibrary: [AlbumSummary] {
        let q = trimmedQuery
        guard !q.isEmpty else { return app.libraryAlbums }
        return app.libraryAlbums.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        Group {
            if app.libraryAlbums.isEmpty && scope == .library && app.libraryAlbumsLoadError == nil {
                ProgressView("Loading library...")
                    .tint(MusicDesign.accent)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listContent
            }
        }
        .background(MusicDesign.background)
        .navigationTitle("")
        /// Hide system nav chrome so the scope bar can sit directly under the status bar (Apple Music–style).
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .musicNavigationChrome()
        .searchable(text: $searchText, prompt: scope == .downtify ? "Artists, songs, albums" : "Albums and artists")
        .safeAreaInset(edge: .top, spacing: 0) {
            scopePickerChrome
        }
        .onSubmit(of: .search) { submitSearch() }
        .onChange(of: scope) { _, _ in
            downtifyResults = []
            searchError = nil
            if !trimmedQuery.isEmpty && scope == .downtify { Task { await runDowntifySearch() } }
        }
        .onChange(of: searchText) { _, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                downtifyResults = []
                searchError = nil
            }
        }
        .refreshable { await app.refreshLibraryAlbums() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(MusicDesign.chromeCapsuleFill))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task(id: scope) {
            guard scope == .downtify, app.isSignedIn else { return }
            if app.libraryTrackTitleIndex.isEmpty, !app.libraryAlbums.isEmpty {
                await app.refreshLibraryTrackMatchIndex()
            }
        }
        .navigationDestination(item: $navigateToLibraryTrack) { track in
            AlbumDetailView(album: app.albumSummary(for: track), scrollToTrackId: track.id)
        }
    }

    // MARK: - Scope picker

    /// Full-width segmented control pinned under the status bar (nav bar hidden on iOS).
    private var scopePickerChrome: some View {
        scopePicker
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(MusicDesign.background)
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(SearchScope.allCases, id: \.self) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
    }

    // MARK: - Content

    @ViewBuilder
    private var listContent: some View {
        if scope == .downtify {
            downtifyContent
        } else {
            libraryContent
        }
    }

    // MARK: - Downtify

    private var downtifyContent: some View {
        List {
            if trimmedQuery.isEmpty {
                Section {
                    recentHeader
                    if recent.isEmpty {
                        Text("Search Downtify to find and download music.")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(recent) { item in
                            Button {
                                searchText = item.query
                                Task { await runDowntifySearch() }
                            } label: {
                                Text(item.query).foregroundStyle(.primary)
                            }
                            .listRowBackground(MusicDesign.tertiarySurfaceFill.opacity(0.55))
                        }
                    }
                }

                if !app.downtifyConfigured {
                    Section {
                        Text("Add your Downtify server URL in Settings to enable search and downloads.")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .listRowBackground(Color.clear)
                    }
                }
            } else if isSearching {
                Section {
                    HStack {
                        ProgressView().tint(MusicDesign.accent)
                        Text("Searching Downtify\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.leading, 8)
                    }
                    .listRowBackground(Color.clear)
                }
            } else if let err = searchError {
                Section {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            } else if downtifyResults.isEmpty {
                Section {
                    Text("No results for \"\(trimmedQuery)\".")
                        .font(.subheadline)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(downtifyResults, id: \.songId) { song in
                    downtifyRow(song)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func downtifyRow(_ song: DowntifySong) -> some View {
        let libraryTrack = resolvedLibraryTrack(for: song)

        return HStack(spacing: 12) {
            Group {
                if let track = libraryTrack {
                    Button {
                        navigateToLibraryTrack = track
                    } label: {
                        downtifyRowArtworkAndTitles(song)
                    }
                    .buttonStyle(.plain)
                } else {
                    downtifyRowArtworkAndTitles(song)
                }
            }

            Spacer(minLength: 0)

            if downloadingIds.contains(song.songId) {
                VStack(alignment: .trailing, spacing: 3) {
                    if let fr = downtifyDownloadFraction[song.songId] {
                        ProgressView(value: min(1, fr))
                            .tint(MusicDesign.accent)
                            .frame(width: 56)
                        Text("\(Int((min(1, fr) * 100).rounded()))%")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    } else {
                        ProgressView()
                            .tint(MusicDesign.accent)
                    }
                }
                .frame(width: 56, alignment: .trailing)
            } else {
                downtifySearchOverflowMenu(song: song, libraryTrack: libraryTrack)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
    }

    /// Mirrors ``NewTabChartOverflowPanel``: native `Menu` + `ControlGroup` (UIKit `UIMenu`).
    @ViewBuilder
    private func downtifySearchOverflowMenu(song: DowntifySong, libraryTrack: Track?) -> some View {
        let shareItem = "\(song.name) — \(song.artists.joined(separator: ", "))"
        if let track = libraryTrack {
            Menu {
                ControlGroup {
                    Button {
                        navigateToLibraryTrack = track
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {} label: {
                        Label("Favorite", systemImage: "star.fill")
                    }
                    ShareLink(item: shareItem) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .tint(Color.primary)

                ChartStyleSongOverflowChrome.trailingMenuSections(onGoToAlbum: {})
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            ChartStyleSongOverflowMenu(
                shareItem: shareItem,
                onAdd: { Task { await downloadSong(song) } },
                addDisabled: !app.downtifyConfigured || downloadingIds.contains(song.songId),
                onGoToAlbum: {}
            )
        }
    }

    private func resolvedLibraryTrack(for song: DowntifySong) -> Track? {
        LibraryTrackMatcher.firstLibraryTrack(matching: song, in: app.discoveryLibraryTracks)
    }

    @ViewBuilder
    private func downtifyRowArtworkAndTitles(_ song: DowntifySong) -> some View {
        HStack(spacing: 12) {
            Group {
                if let art = song.coverURL {
                    RemoteArtworkScaledFill(url: art, maxPixelSize: 180) {
                        artPlaceholder
                    }
                } else {
                    artPlaceholder
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(song.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if song.explicit == true {
                        Image(systemName: "e.square.fill")
                            .font(.caption2)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
                }
                Text("Song \u{00B7} \(song.artists.joined(separator: ", "))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
        }
    }

    private var artPlaceholder: some View {
        ZStack {
            MusicDesign.chromeCapsuleFill
            Image(systemName: "music.note")
                .font(.body)
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
    }

    // MARK: - Library

    private var libraryContent: some View {
        List {
            if trimmedQuery.isEmpty {
                Section {
                    recentHeader
                    if recent.isEmpty {
                        Text("Search albums and artists in your library.")
                            .font(.subheadline)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(recent) { item in
                            Button {
                                searchText = item.query
                            } label: {
                                Text(item.query).foregroundStyle(.primary)
                            }
                            .listRowBackground(MusicDesign.tertiarySurfaceFill.opacity(0.55))
                        }
                    }
                }
            }

            Section {
                ForEach(filteredLibrary) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        albumRow(album)
                    }
                    .listRowBackground(MusicDesign.tertiarySurfaceFill.opacity(0.55))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var recentHeader: some View {
        HStack {
            Text("Recently Searched")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if !recent.isEmpty {
                Button("Clear") {
                    RecentQueryStore.clear()
                    recent = []
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MusicDesign.accent)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
        .listRowBackground(Color.clear)
    }

    private func albumRow(_ album: AlbumSummary) -> some View {
        HStack(spacing: 14) {
            AlbumArtworkView(url: album.artworkURL)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func submitSearch() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        RecentQueryStore.append(q)
        recent = RecentQueryStore.load()
        if scope == .downtify { Task { await runDowntifySearch() } }
    }

    private func runDowntifySearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        downtifyResults = []
        defer { isSearching = false }
        do {
            downtifyResults = try await DowntifyClient.search(query: q)
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func downloadSong(_ song: DowntifySong) async {
        guard !downloadingIds.contains(song.songId) else { return }
        guard !LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) else {
            flashToast("Already in your library")
            return
        }
        downloadingIds.insert(song.songId)
        downtifyDownloadFraction[song.songId] = 0
        defer {
            downloadingIds.remove(song.songId)
            downtifyDownloadFraction.removeValue(forKey: song.songId)
        }
        do {
            let name = try await DowntifyClient.downloadSong(song) { p in
                Task { @MainActor in
                    downtifyDownloadFraction[song.songId] = p
                }
            }
            flashToast("Downloading \"\(name)\"")
        } catch {
            flashToast(error.localizedDescription)
        }
    }

    private func flashToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            toast = nil
        }
    }
}
