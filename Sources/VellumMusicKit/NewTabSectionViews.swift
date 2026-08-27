import SwiftUI

enum NewTabSectionDestination: Hashable {
    case bestNewSongs
    case newThisWeek
    case recentReleases
    case trendingSongs
}

struct NewTabSectionDetailView: View {
    let section: NewTabSectionDestination
    @EnvironmentObject private var app: AppModel

    var body: some View {
        switch section {
        case .bestNewSongs:
            NewTabChartListView(title: "Best New Songs", tracks: app.newTabTopTracks)
        case .newThisWeek:
            NewTabChartAlbumsGridView(title: "New This Week", albums: app.newTabRecentReleases)
        case .recentReleases:
            NewTabChartAlbumsGridView(title: "Recent Releases", albums: app.newTabDiscoverReleases)
        case .trendingSongs:
            NewTabChartAlbumsGridView(title: "Trending Songs", albums: app.newTabFromYourArtists)
        }
    }
}

// MARK: - Song-style list (Library → Songs layout)

struct NewTabChartListView: View {
    let title: String
    let tracks: [ChartTrack]

    @EnvironmentObject private var app: AppModel
    @State private var navigateLibraryTrack: Track?
    @State private var navigateLibraryAlbum: AlbumSummary?
    @State private var browseChartSingle: ChartTrack?
    @State private var navigateArtist: ArtistNameNavigation?

    private var itemSize: SongListItemSize { app.songListItemSize }

    private var listRowDividerKind: MusicChevronRowDivider.Kind {
        .custom(leading: MusicChevronRowMetrics.artworkDividerLeading(side: itemSize.artworkSide, spacing: 14))
    }

    var body: some View {
        List {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "music.note.list",
                    description: Text("Pull to refresh on the New tab.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    trackListRow(track)
                        .librarySongListRowStyle()
                        .musicChevronRowDivider(listRowDividerKind, shows: index < tracks.count - 1)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .newTabSectionDetailScreen(title: title)
        .navigationDestination(item: $navigateLibraryTrack) { track in
            ServerPlaylistDetailView(album: app.albumSummary(for: track), scrollToTrackId: track.id)
        }
        .navigationDestination(item: $navigateLibraryAlbum) { album in
            ServerPlaylistDetailView(album: album)
        }
        .navigationDestination(item: $browseChartSingle) { track in
            BrowseAlbumDetailView(source: .chartBrowse(
                artistName: track.artistName,
                title: track.name,
                imageURL: track.imageURL,
                kind: track.browseKind,
                albumId: track.id
            ))
        }
        .navigationDestination(item: $navigateArtist) { item in
            ArtistPageView(input: .named(item.id))
        }
    }

    private func trackListRow(_ track: ChartTrack) -> some View {
        let rowState = app.newTabChartRowState(for: track)
        return HStack(spacing: 0) {
            Button {
                switch rowState {
                case .libraryTrack(let lib):
                    navigateLibraryTrack = lib
                case .serverAlbum(let album):
                    navigateLibraryAlbum = album
                case .missing:
                    browseChartSingle = track
                }
            } label: {
                rowMainContent(title: track.name, artist: track.artistName, artworkURL: track.imageURL)
                    .coverZoomSource(id: coverZoomId(for: track, rowState: rowState), style: .custom)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            NewTabChartRowOverflowMenu(
                chart: track,
                onRequest: { Task { await requestAcquisition(for: track) } },
                onBrowseAlbum: { browseChartSingle = track },
                onGoToLibraryAlbum: { navigateLibraryAlbum = $0 }
            )
        }
        .musicChevronRowPadding()
        .padding(.vertical, itemSize.libraryVerticalPadding)
        .contentShape(Rectangle())
    }

    private func coverZoomId(for track: ChartTrack, rowState: NewTabChartRowState) -> String {
        switch rowState {
        case .libraryTrack(let lib):
            return lib.albumId
        case .serverAlbum(let album):
            return album.id
        case .missing:
            return BrowseAlbumDetailSource.chartBrowse(
                artistName: track.artistName,
                title: track.name,
                imageURL: track.imageURL,
                kind: track.browseKind,
                albumId: track.id
            ).coverZoomId
        }
    }

    private func rowMainContent(title: String, artist: String, artworkURL: URL?) -> some View {
        HStack(spacing: 14) {
            AlbumArtworkView(url: artworkURL, cornerRadius: 6)
                .frame(width: itemSize.artworkSide, height: itemSize.artworkSide)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(itemSize.titleFont.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                ArtistNameButton(name: artist, font: itemSize.subtitleFont) {
                    navigateArtist = ArtistNameNavigation(id: artist)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private func requestAcquisition(for track: ChartTrack) async {
        if app.newTabChartRowState(for: track).isOnServer {
            app.showTransientToast("Already on your server")
            return
        }
        let request = track.acquisitionRequest
        if request.trackTitle != nil,
           LibraryTrackMatcher.matchesLibrary(title: track.name, artists: [track.artistName], titleIndex: app.libraryTrackTitleIndex) {
            app.showTransientToast("Already in your library")
            return
        }
        await app.requestAcquisition(request)
    }
}

// MARK: - Album grid (Library → Albums layout)

struct NewTabChartAlbumsGridView: View {
    let title: String
    let albums: [ChartAlbum]

    @EnvironmentObject private var app: AppModel
    @State private var navigateLibraryAlbum: AlbumSummary?
    @State private var navigateArtist: ArtistNameNavigation?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicDesign.gridMinCell), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            if albums.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "square.stack",
                    description: Text("Pull to refresh on the New tab.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        albumGridLink(album)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .scrollIndicators(.hidden)
        .background(MusicDesign.background)
        .newTabSectionDetailScreen(title: title)
        .navigationDestination(item: $navigateLibraryAlbum) { album in
            ServerPlaylistDetailView(album: album)
        }
        .navigationDestination(item: $navigateArtist) { item in
            ArtistPageView(input: .named(item.id))
        }
    }

    @ViewBuilder
    private func albumGridLink(_ album: ChartAlbum) -> some View {
        if let lib = app.libraryAlbumReleaseIndex.firstMatch(artist: album.artistName, albumTitle: album.name) {
            Button {
                navigateLibraryAlbum = lib
            } label: {
                NewTabChartAlbumGridCell(
                    album: album,
                    onArtistTap: { navigateArtist = ArtistNameNavigation(id: album.artistName) },
                )
                    .coverZoomSource(id: lib.id, style: .custom)
            }
            .buttonStyle(.plain)
        } else {
            let source = BrowseAlbumDetailSource.chartBrowse(
                artistName: album.artistName,
                title: album.name,
                imageURL: album.imageURL,
                kind: "Album",
                albumId: album.pluginLookupId ?? album.id
            )
            NavigationLink {
                BrowseAlbumDetailView(source: source)
            } label: {
                NewTabChartAlbumGridCell(
                    album: album,
                    onArtistTap: { navigateArtist = ArtistNameNavigation(id: album.artistName) },
                )
                    .coverZoomSource(id: source.coverZoomId, style: .custom)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NewTabChartAlbumGridCell: View {
    let album: ChartAlbum
    let onArtistTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.imageURL, cornerRadius: MusicDesign.albumCorner)
            Text(album.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            ArtistNameButton(name: album.artistName, font: .caption, onTap: onArtistTap)
        }
    }
}

private extension View {
    func newTabSectionDetailScreen(title: String) -> some View {
        navigationTitle(title)
            .musicNavigationBarTitleDisplayMode(.inline)
            .musicNewTabNavigationChrome()
            .musicInlineNavigationTitleScreen()
            .musicNavigationBarVisibleWhenPushed()
    }
}
