import SwiftUI

/// Search tab: pinned search field at the top; Discover / Library scope appears only
/// while the search session is active, styled like login's Jellyfin / Navidrome segmented picker.
struct SearchLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var scope: SearchScope = .discover
    @State private var searchText = ""
    @State private var navigationPath = NavigationPath()
    @FocusState private var searchFieldFocused: Bool

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchSessionActive: Bool {
        searchFieldFocused || !trimmedQuery.isEmpty
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                if navigationPath.isEmpty {
                    SearchTabHeader(
                        searchText: $searchText,
                        scope: $scope,
                        searchFieldFocused: $searchFieldFocused,
                        showsScopePicker: isSearchSessionActive,
                    )
                }
                DiscoverySearchView(
                    searchText: $searchText,
                    scope: $scope,
                    navigationPath: $navigationPath,
                    isSearchSessionActive: isSearchSessionActive,
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationDestination(for: SearchNavTarget.self) { target in
                searchDestination(target)
            }
            .deepLinkPush(tab: .search, path: $navigationPath)
        }
        .animation(.easeInOut(duration: 0.2), value: isSearchSessionActive)
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
        case .acquire(let result):
            AcquireResultDetailView(result: result)
        }
    }
}

// MARK: - Search header

private struct SearchTabHeader: View {
    @Binding var searchText: String
    @Binding var scope: SearchScope
    @FocusState.Binding var searchFieldFocused: Bool
    let showsScopePicker: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(MusicDesign.secondaryLabel)
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text(scope == .discover ? "Server catalog & downloads" : "Your library")
                        .foregroundStyle(MusicDesign.secondaryLabel),
                )
                .focused($searchFieldFocused)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))

            if showsScopePicker {
                DiscoverLibraryScopeBar(scope: $scope)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, showsScopePicker ? 4 : 12)
        .background(MusicDesign.background)
    }
}
