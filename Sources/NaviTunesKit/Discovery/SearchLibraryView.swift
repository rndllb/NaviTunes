import SwiftUI

/// Search tab: pinned search field at the top; Discover / Library scope appears only
/// while the search session is active, styled like login's Jellyfin / Navidrome segmented picker.
struct SearchLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var scope: SearchScope = .discover
    @State private var searchText = ""
    @State private var navigationPath = NavigationPath()
    @FocusState private var searchFieldFocused: Bool
    /// The search session, held open across navigation.
    ///
    /// Focus alone cannot express it: pushing a detail resigns the text field, so a session
    /// opened by tapping the bar *without typing* — the recents / browse view — collapsed the
    /// moment anything was opened from it, and popping back landed on the plain Discover page
    /// instead of the view the user came from. Latched on focus and cleared only by the
    /// header's ✕, which is the one deliberate "leave search" action there is.
    @State private var searchSessionLatched = false

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchSessionActive: Bool {
        searchSessionLatched || searchFieldFocused || !trimmedQuery.isEmpty
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Deliberately *not* gated on `navigationPath.isEmpty`. Removing the header
                // while something is pushed took ~110pt out of the root's layout, so the page
                // revealed behind a dismiss sat that much too high and visibly dropped back
                // into place as the path emptied at the end of the transition. There is
                // nothing to hide: a pushed screen covers this root completely.
                SearchTabHeader(
                    searchText: $searchText,
                    scope: $scope,
                    searchFieldFocused: $searchFieldFocused,
                    sessionActive: isSearchSessionActive,
                    showsScopePicker: isSearchSessionActive,
                    onCancel: { searchSessionLatched = false },
                )
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
            .onChange(of: searchFieldFocused) { _, focused in
                if focused { searchSessionLatched = true }
            }
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
        case .musicBrainzArtist(let artist):
            ArtistPageView(input: .musicBrainzArtist(artist))
        case .musicBrainzArtistId(let id, let name):
            ArtistPageView(input: .musicBrainzArtistId(id: id, name: name))
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
    /// The owner's latched session — see `SearchLibraryView.searchSessionLatched`. The header
    /// has to agree with it or the ✕ would vanish while the session it dismisses is still up.
    let sessionActive: Bool
    let showsScopePicker: Bool
    let onCancel: () -> Void

    private var isSearching: Bool { sessionActive || searchFieldFocused || !searchText.isEmpty }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    private var isPad: Bool { MusicPadDock.hidesPageProfile(sizeClass: sizeClass) }

    var body: some View {
        if isPad {
            padBody
        } else {
            phoneBody
        }
    }

    /// iPad, as in Apple Music: no "Search" title or avatar, just the field and the scope pill on one row.
    /// With the dock along the top the row sits beneath it; with the sidebar open it takes the dock's row.
    /// Where the page's top edge sits on screen. Measured from a marker above the row, so the row's own
    /// padding cannot feed back into it.
    @State private var pageTopY: CGFloat = 88

    /// With the sidebar open there is no dock to sit under, so the row rises to the dock's own row: its top is
    /// the status bar plus 8pt, the same place Apple Music puts it. The content below rises with it.
    private var padTopPadding: CGFloat {
        guard tabBarPlacement == .sidebar else { return 0 }
        return (MusicPadDock.statusBarHeight + 8) - pageTopY
    }

    private var padBody: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { pageTopY = $0 }
            padRow
                .padding(.top, padTopPadding)
        }
    }

    private var padRow: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(MusicDesign.secondaryLabel)
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text(scope == .discover ? "Artists, Songs, and More" : "Songs, Albums, Artists")
                        .foregroundStyle(MusicDesign.secondaryLabel),
                )
                .font(.title3)
                .focused($searchFieldFocused)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .tint(MusicDesign.accent)
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
            .padding(.horizontal, 16)
            .frame(height: 44)
            .musicGlassEffect(in: Capsule(style: .continuous))

            if isSearching {
                Button {
                    searchText = ""
                    searchFieldFocused = false
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .musicGlassEffect(in: Circle())
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }

            MusicGlassSegmentPillBar(
                options: Array(SearchScope.allCases),
                selection: $scope,
                title: { $0.rawValue },
                isLarge: true,
            )
            .frame(width: 233)
        }
        .animation(.smooth(duration: 0.25), value: isSearching)
        .padding(.horizontal, 16)
        // Under the top dock the page already starts 11pt below it, as in Apple Music.
        .padding(.bottom, 12)
        .background(MusicDesign.background)
    }

    private var phoneBody: some View {
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
                        prompt: Text(scope == .discover ? "Artists, Songs, and More" : "Songs, Albums, Artists")
                            .foregroundStyle(MusicDesign.secondaryLabel),
                    )
                    .focused($searchFieldFocused)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .tint(MusicDesign.accent)
                    // No mic affordance by design: the system keyboard already carries a
                    // dictation key, so a second entry point here would duplicate it at the
                    // cost of a microphone permission and an audio-session negotiation
                    // against the player. The trailing slot is the clear button only.
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .musicGlassEffect(in: Capsule(style: .continuous))

                if isSearching {
                    Button {
                        searchText = ""
                        searchFieldFocused = false
                        onCancel()
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
