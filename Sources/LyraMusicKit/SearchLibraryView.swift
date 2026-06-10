import SwiftUI

/// Search tab: `Tab(role: .search)` + Discover / Library scope pill pinned above content.
struct SearchLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var scope: SearchScope = .discover
    @State private var searchText = ""
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            DiscoverySearchView(
                searchText: $searchText,
                scope: $scope,
                navigationPath: $navigationPath,
            )
            .padding(.top, navigationPath.isEmpty ? DiscoverySearchLayout.scopeBarClearance : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationDestination(for: SearchNavTarget.self) { target in
                searchDestination(target)
            }
            .deepLinkPush(tab: .search, path: $navigationPath)
        }
        .coverZoomContext()
        .overlay(alignment: .top) {
            if navigationPath.isEmpty {
                DiscoverLibraryScopeBar(scope: $scope)
                    #if os(iOS)
                    .safeAreaPadding(.top, 6)
                    #endif
                    .background {
                        MusicDesign.background
                            .ignoresSafeArea(edges: .top)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: navigationPath.isEmpty)
        .background(MusicDesign.background)
        .navigationTitle("")
        .musicNewTabRootHidesNavigationBar()
        .musicNewTabNavigationChrome()
        .tint(MusicDesign.accent)
    }

    @ViewBuilder
    private func searchDestination(_ target: SearchNavTarget) -> some View {
        switch target {
        case .song(let track):
            ServerPlaylistDetailView(album: app.albumSummary(for: track), scrollToTrackId: track.id)
        case .album(let album):
            ServerPlaylistDetailView(album: album)
        case .playlist(let playlist):
            ServerPlaylistDetailView(playlist: playlist)
        case .artist(let artist):
            ArtistPageView(input: .libraryArtist(artist))
        case .genre(let genre):
            LibraryGenreAlbumsView(genre: genre)
        case .downtify(let song):
            DowntifySongDetailView(song: song)
        }
    }
}
