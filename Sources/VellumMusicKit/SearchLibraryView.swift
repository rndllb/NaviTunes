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
        .coverZoomContext()
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
        case .namedArtist(let name):
            ArtistPageView(input: .named(name))
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

    private var isSearching: Bool { searchFieldFocused || !searchText.isEmpty }

    var body: some View {
        VStack(spacing: isSearching ? 10 : 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Search")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                MusicToolbarSettingsAvatarLink(diameter: 45)
            }
            .frame(maxHeight: isSearching ? 0 : nil, alignment: .top)
            .opacity(isSearching ? 0 : 1)
            .clipped()
            .allowsHitTesting(!isSearching)
            .accessibilityHidden(isSearching)

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(MusicDesign.secondaryLabel)
                    TextField(
                        "",
                        text: $searchText,
                        prompt: Text(scope == .discover ? "Artists, Songs, and More" : "Your Library")
                            .foregroundStyle(MusicDesign.secondaryLabel),
                    )
                    .focused($searchFieldFocused)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .tint(MusicDesign.accent)
                    if searchText.isEmpty {
                        Image(systemName: "microphone.fill")
                            .font(.body)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                    } else {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MusicDesign.secondaryLabel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .musicGlassEffect(in: Capsule(style: .continuous))

                if isSearching {
                    Button {
                        searchText = ""
                        searchFieldFocused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .musicGlassEffect(in: Circle())
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .animation(.smooth(duration: 0.25), value: isSearching)

            if showsScopePicker {
                MusicGlassSegmentPillBar(
                    options: Array(SearchScope.allCases),
                    selection: $scope,
                    title: { $0.rawValue }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isSearching ? 8 : 0)
        .padding(.bottom, showsScopePicker ? 4 : 12)
        .background(MusicDesign.background)
        .animation(.easeInOut(duration: 0.22), value: isSearching)
    }
}
