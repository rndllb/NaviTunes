import SwiftUI

public struct RootView: View {
    @EnvironmentObject private var app: AppModel

    public init() {}
    public var body: some View {
        Group {
            if app.isSignedIn {
                MainShellView()
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut, value: app.isSignedIn)
        .preferredColorScheme(app.themePreference.colorScheme)
        .tint(MusicDesign.accent)
#if DEBUG
        .onAppear { DebugUIRemote.install(app: app) }
#endif
    }
}

// MARK: - Tab model

enum NowPlayingDeepLink: Hashable {
    case album(AlbumSummary, scrollToTrackId: String? = nil, librarySource: Bool = true)
    /// Carries the artist's id alongside the name where the source had one, so the most-used
    /// route to an artist page identifies the artist rather than describing them. A bare name
    /// lands on whichever artist of that name a lookup returns, and same-named acts are common.
    case artist(ArtistNameNavigation)
    case playlist(PlaylistSummary, scrollToTrackId: String? = nil)
}

/// Renders the destination view for a "Go to Album/Playlist/Artist" deep link inside whichever
/// tab's ``NavigationStack`` pushes it. ``scrollToTrackId`` lands the list at the active track
/// immediately on first appear (no scroll animation); the already-visible path goes through
/// ``pendingPlaylistScroll`` / ``pendingAlbumScroll`` and animates the scroll + highlight.
struct DeepLinkDestinationContent: View {
    @EnvironmentObject private var app: AppModel
    let link: NowPlayingDeepLink

    var body: some View {
        switch link {
        case .album(let album, let scrollToTrackId, let librarySource):
            ServerPlaylistDetailView(album: album, librarySource: librarySource, scrollToTrackId: scrollToTrackId)
        case .artist(let nav):
            ArtistPageView(input: nav.artistPageInput)
        case .playlist(let playlist, let scrollToTrackId):
            ServerPlaylistDetailView(
                playlist: playlist,
                scrollToTrackId: scrollToTrackId,
                preloadedRows: app.cachedPlaylistRows(playlistId: playlist.id)
            )
        }
    }
}

/// Apply to each tab's ``NavigationStack`` root so a "Go to Album/Playlist/Artist" deep link
/// pushes within that tab. Path-based (`NavigationPath`-append), not single-slot
/// `.navigationDestination(item:)` — the old binding-based approach replaced the current
/// destination when a second deep link fired (e.g. user on an artist page hits Now Playing
/// → Go to Artist → the new artist swapped in instead of stacking on top). Gated by
/// ``AppModel/deepLinkTab`` so only the tab the user was on at trigger time consumes the push,
/// and the tab bar stays visible throughout.
struct DeepLinkPushModifier: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @Binding var path: NavigationPath
    let tab: AppTab

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: NowPlayingDeepLink.self) { link in
                DeepLinkDestinationContent(link: link)
            }
            .onChange(of: app.presentedDeepLink) { _, newValue in
                guard app.deepLinkTab == tab, let link = newValue else { return }
#if DEBUG
                DebugUIRemote.log("NP-DEEPLINK append tab=\(tab) depth=\(path.count)")
#endif
                path.append(link)
                // Consume so a subsequent set of the same link still triggers onChange.
                app.presentedDeepLink = nil
                app.deepLinkTab = nil
            }
#if DEBUG
            .onChange(of: app.debugPopRequests) { _, _ in
                guard app.selectedTab == tab, !path.isEmpty else { return }
                path.removeLast()
            }
#endif
    }
}

extension View {
    func deepLinkPush(tab: AppTab, path: Binding<NavigationPath>) -> some View {
        modifier(DeepLinkPushModifier(path: path, tab: tab))
    }
}

/// Scroll request emitted by "Go to Playlist" so an already-visible ``ServerPlaylistDetailView``
/// can scroll to the now-playing track without being re-pushed onto the nav stack.
struct PendingPlaylistScroll: Equatable {
    let playlistId: String
    let trackId: String
}

/// Same as ``PendingPlaylistScroll`` but keyed to an album id for album-mode detail views.
struct PendingAlbumScroll: Equatable {
    let albumId: String
    let trackId: String
}

enum AppTab: Int, Hashable, CaseIterable {
    case home, new, radio, library, search

    // MARK: Dock customization (the iPad dock's Edit mode and Settings → Tabs)

    static let orderStorageKey = "navitunes.tab-order"
    static let customizationStorageKey = "navitunes.tab-customization"
    static let defaultOrderRaw = "home,new,radio,library"

    /// Tabs the user can reorder or hide. Search is pinned at the end and always present.
    static let customizableTabs: [AppTab] = [.home, .new, .radio, .library]

    var storageToken: String {
        switch self {
        case .home: "home"
        case .new: "new"
        case .radio: "radio"
        case .library: "library"
        case .search: "search"
        }
    }

    var customizationID: String { "app.navitunes.tab.\(storageToken)" }

    /// Home is the launch page and stays in the dock.
    var canHide: Bool { self != .home && self != .search }

    static func ordered(from raw: String) -> [AppTab] {
        var seen = Set<AppTab>()
        var order: [AppTab] = []
        for token in raw.split(separator: ",") {
            guard let tab = customizableTabs.first(where: { $0.storageToken == token }),
                  seen.insert(tab).inserted else { continue }
            order.append(tab)
        }
        for tab in customizableTabs where seen.insert(tab).inserted {
            order.append(tab)
        }
        return order
    }

    static func raw(from order: [AppTab]) -> String {
        var seen = Set<AppTab>()
        return order.compactMap { seen.insert($0).inserted ? $0.storageToken : nil }.joined(separator: ",")
    }

    static func defaultCustomization() -> TabViewCustomization { TabViewCustomization() }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .new: "square.grid.2x2.fill"
        case .radio: "dot.radiowaves.left.and.right"
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .home: "Home"
        case .new: "New"
        case .radio: "Radio"
        case .library: "Library"
        case .search: "Search"
        }
    }
}

/// What the dock has selected. The five main tabs keep living in ``AppModel/selectedTab``; the
/// iPad sidebar adds Library pages and playlists, which have no tab of their own.
enum DockSelection: Hashable {
    case tab(AppTab)
    case recentlyAdded
    case libraryRow(String)
    case allPlaylists
    case favoriteSongs
    case playlist(String)
}

// MARK: - Shell

private struct MainShellView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    @State private var showSettingsFromSidebar = false
    @State private var showNewPlaylistFromSidebar = false
    @State private var sidebarIsEditing = false
    @Environment(\.horizontalSizeClass) private var shellSizeClass
    /// Where the page area sits on screen (right of a pinned sidebar). The iPad mini player centers on it.
    @State private var padContentFrame: CGRect = .zero
    @StateObject private var playlistIcons = SidebarPlaylistIconStore()
    @StateObject private var accountAvatar = SidebarAccountAvatarStore()
    @State private var sidebarSelection: DockSelection?
    /// The Library page the top dock's item shows; it keeps the last one when you visit Home, New or Radio.
    @State private var lastLibraryPage: DockSelection = .recentlyAdded
    @AppStorage("sidebarPlaylistsSort") private var playlistSortRaw = PlaylistSort.title.rawValue
    @AppStorage(AppTab.customizationStorageKey) private var tabCustomization = AppTab.defaultCustomization()
    @AppStorage(AppTab.orderStorageKey) private var tabOrderRaw = AppTab.defaultOrderRaw
    /// Namespace for the mini-player → player morph.
    ///
    /// **The system does not drive this transition.** This comment used to say that it did —
    /// that the accessory marked itself with `matchedTransitionSource` and the presented player
    /// applied `navigationTransition(.zoom(...))`, with no manual plumbing. That mechanism is
    /// not wired up anywhere: nothing applies a `navigationTransition` for `"playerArtwork"`,
    /// and the paired `matchedTransitionSource` has been removed. The morph is driven entirely
    /// by ``NowPlayingCoverPresenter`` and ``NowPlayingCoverAnimator`` in UIKit, deliberately —
    /// see the presenter's own doc comment for the `fullScreenCover` crash class that exists to
    /// avoid. Restoring the system mechanism would reintroduce it, which is why the description
    /// is corrected here rather than deleted.
    ///
    /// The namespace itself is kept because it is still handed to the accessory.
    @Namespace private var playerArtworkNamespace

    /// The profile picture, loaded here and handed over as a finished image: the avatar view keeps its
    /// picture in its own state, which does not refresh inside the sidebar's bottom bar.
    @ViewBuilder
    private var sidebarAvatar: some View {
        if let image = accountAvatar.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(MusicDesign.separator, lineWidth: 1))
        } else {
            AccountProfileAvatarView(diameter: 36)
        }
    }

    private var sidebarAccountName: String {
        let user = app.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? "Account" : user
    }

    /// iPad lets the system hide tabs in its own Edit mode; iPhone has no Edit mode, so hidden
    /// tabs are dropped here.
    /// Card size for horizontal shelves: on iPad one row's worth fits the page exactly (five across, four
    /// with the sidebar open); iPhone keeps its fixed size.
    private var padShelfCardSide: CGFloat {
        guard isPad, padContentFrame.width > 0 else { return MusicDesign.shelfCardWidth }
        return MusicPadColumns.shelfCardSide(
            pageWidth: padContentFrame.width,
            inset: MusicDesign.newTabHorizontalInset,
            gap: 14
        )
    }

    /// Room each page keeps clear beneath the floating iPad mini player.
    private var padMiniPlayerReservedHeight: CGFloat {
        usesPadMiniPlayer && app.player.showsMiniPlayerChrome ? MusicPadMiniPlayer.reservedHeight : 0
    }

    private var usesPadMiniPlayer: Bool {
        MusicPadDock.hidesPageProfile(sizeClass: shellSizeClass)
    }

    /// The iPad mini player: a fixed-size glass capsule centered on the page area. The system
    /// accessory chooses its own width and height, so on iPad it is drawn here instead.
    @ViewBuilder
    private var padMiniPlayerOverlay: some View {
        if usesPadMiniPlayer && app.player.showsMiniPlayerChrome {
            GeometryReader { geo in
                let screen = geo.frame(in: .global)
                let page = padContentFrame.width > 0 ? padContentFrame : screen
                let width = min(MusicPadMiniPlayer.width, max(0, page.width - 48))
                TabViewMiniPlayerAccessory(
                    showNowPlaying: $showNowPlaying,
                    player: app.player,
                    artworkNamespace: playerArtworkNamespace
                )
                .environmentObject(app)
                .frame(width: width, height: MusicPadMiniPlayer.height)
                .musicGlassCapsuleInteractiveChrome()
                .position(
                    x: page.midX - screen.minX,
                    y: geo.size.height - MusicPadMiniPlayer.height / 2 - MusicPadMiniPlayer.bottomGap
                )
            }
        }
    }

    private var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// The tab/page the dock shows. On iPad the Library tab does not exist; its pages live in the
    /// sidebar, so a request for the Library tab (deep links, launch tab) lands on Recently Added.
    private var dockSelection: Binding<DockSelection> {
        Binding(
            get: {
                if let sidebarSelection { return sidebarSelection }
                if isPad && app.selectedTab == .library { return .recentlyAdded }
                return .tab(app.selectedTab)
            },
            set: { newValue in
                if case .tab(let tab) = newValue {
                    sidebarSelection = nil
                    app.selectedTab = tab
                } else {
                    sidebarSelection = newValue
                }
            }
        )
    }

    private static func isLibraryPage(_ selection: DockSelection) -> Bool {
        switch selection {
        case .recentlyAdded, .libraryRow, .allPlaylists, .favoriteSongs, .playlist: true
        case .tab: false
        }
    }

    private var currentLibraryPage: DockSelection {
        if let sidebarSelection, Self.isLibraryPage(sidebarSelection) { return sidebarSelection }
        return lastLibraryPage
    }

    private func libraryPageTitle(_ page: DockSelection) -> String {
        switch page {
        case .libraryRow(let raw): LibraryRow(rawValue: raw)?.title ?? "Library"
        case .allPlaylists: "All Playlists"
        case .favoriteSongs: "Favorite Songs"
        case .playlist(let id): app.libraryPlaylist(id: id)?.name ?? "Playlist"
        default: "Recently Added"
        }
    }

    private var libraryRows: [LibraryRow] {
        LibraryRow.allCases.filter { $0 != .playlists }
    }

    private var sortedPlaylists: [PlaylistSummary] {
        let playlists = app.libraryPlaylists
        switch PlaylistSort(rawValue: playlistSortRaw) ?? .title {
        case .title:
            return playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateAdded:
            return playlists.sorted { ($0.libraryAddedDate ?? .distantPast) > ($1.libraryAddedDate ?? .distantPast) }
        case .updatedDate:
            return playlists.sorted { ($0.serverUpdatedDate ?? .distantPast) > ($1.serverUpdatedDate ?? .distantPast) }
        case .lastPlayed, .playlistType:
            return playlists
        }
    }

    /// A sidebar page: its own navigation stack, with the title on the dock's row like Apple Music.
    private func sidebarPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack { content() }
            .toolbarTitleDisplayMode(.inlineLarge)
            .environment(\.shelfCardSide, padShelfCardSide)
            .reportsPadContentFrame($padContentFrame)
            .safeAreaPadding(.bottom, padMiniPlayerReservedHeight)
    }

    @ViewBuilder
    private func libraryRowPage(_ row: LibraryRow) -> some View {
        switch row {
        case .playlists: LibraryPlaylistsView()
        case .artists: LibraryArtistsView()
        case .albums: AlbumsGridView()
        case .songs: LibrarySongsView()
        case .genres: LibraryGenresView()
        case .downloaded: LibraryDownloadedView()
        }
    }

    private var dockTabs: [AppTab] {
        let ordered = AppTab.ordered(from: tabOrderRaw)
        if isPad { return ordered.filter { $0 != .library } }
        return ordered.filter { !$0.canHide || tabCustomization[sidebarVisibility: $0.customizationID] != .hidden }
    }

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        tabRootContent(tab)
            .environment(\.shelfCardSide, padShelfCardSide)
            .reportsPadContentFrame($padContentFrame)
            .safeAreaPadding(.bottom, padMiniPlayerReservedHeight)
    }

    @ViewBuilder
    private func tabRootContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .new: MusicNewTabView()
        case .radio: RadioTabView()
        case .library: LibraryView()
        case .search: SearchLibraryView()
        }
    }

    var body: some View {
        TabView(selection: dockSelection) {
            // Search leads the sidebar, as in Apple Music. In the top dock the search role always sits last.
            Tab("Search", systemImage: AppTab.search.systemImage, value: DockSelection.tab(.search), role: .search) {
                SearchLibraryView()
            }
            .customizationID(AppTab.search.customizationID)
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            ForEach(dockTabs, id: \.self) { tab in
                Tab(tab.label, systemImage: tab.systemImage, value: DockSelection.tab(tab)) {
                    tabRoot(tab)
                }
                .customizationID(tab.customizationID)
                .customizationBehavior(tab.canHide ? .automatic : .reorderable, for: .sidebar, .tabBar)
            }

            if isPad {
                // In the top dock the Library section shows as one item between Radio and Search, and the system
                // names it after the section. Named for the active Library page there (like Apple Music),
                // and "Library" in the sidebar: a pinned sidebar leaves the page starting to its right.
                let sectionTitle = padContentFrame.minX > 100 ? "Library" : libraryPageTitle(currentLibraryPage)
                TabSection(sectionTitle) {
                    Tab("Recently Added", systemImage: "clock", value: DockSelection.recentlyAdded) {
                        sidebarPage { LibraryView(recentlyAddedOnly: true) }
                    }
                    .customizationID("app.navitunes.library.recentlyAdded")
                    ForEach(libraryRows) { row in
                        Tab(row.title, systemImage: row.symbol, value: DockSelection.libraryRow(row.rawValue)) {
                            sidebarPage { libraryRowPage(row) }
                        }
                        .customizationID("app.navitunes.library.\(row.rawValue)")
                    }
                }
                .customizationID("app.navitunes.section.library")

                TabSection("Playlists") {
                    Tab("All Playlists", systemImage: "square.grid.3x3", value: DockSelection.allPlaylists) {
                        sidebarPage { LibraryPlaylistsView() }
                    }
                    .customizationID("app.navitunes.playlists.all")
                    .customizationBehavior(.disabled, for: .sidebar, .tabBar)
                    Tab(value: DockSelection.favoriteSongs) {
                        sidebarPage { FavoritePlaylistView() }
                    } label: {
                        Label {
                            Text("Favorite Songs")
                        } icon: {
                            FavoriteSongsPlaylistArtwork(cornerRadius: 5, size: 26)
                        }
                    }
                    .customizationID("app.navitunes.playlists.favorites")
                    .customizationBehavior(.disabled, for: .sidebar, .tabBar)
                    ForEach(sortedPlaylists) { playlist in
                        Tab(value: DockSelection.playlist(playlist.id)) {
                            sidebarPage { ServerPlaylistDetailView(playlist: playlist) }
                        } label: {
                            Label {
                                Text(playlist.name)
                            } icon: {
                                if let icon = playlistIcons.icons[playlist.id] {
                                    Image(uiImage: icon).renderingMode(.original)
                                } else {
                                    Image(systemName: "music.note.list")
                                }
                            }
                        }
                        .customizationID("app.navitunes.playlist.\(playlist.id)")
                        .customizationBehavior(.disabled, for: .sidebar, .tabBar)
                    }
                }
                .customizationID("app.navitunes.section.playlists")
                .defaultVisibility(.hidden, for: .tabBar)
                .sectionActions {
                    Button("New Playlist", systemImage: "plus") { showNewPlaylistFromSidebar = true }
                    // Sorting only shows while the sidebar is being edited.
                    if sidebarIsEditing {
                        Menu("Sort Playlists", systemImage: "arrow.up.arrow.down") {
                            Picker("Sort Playlists", selection: $playlistSortRaw) {
                                ForEach([PlaylistSort.title, .dateAdded, .updatedDate], id: \.rawValue) { sort in
                                    Text(sort.rawValue).tag(sort.rawValue)
                                }
                            }
                        }
                    }
                }
            }
        }
        .tint(MusicDesign.accent)
        #if os(iOS)
        // iPad: the tab bar sits at the top and the sidebar button turns it into a side dock, as in Zelefin.
        // iPhone keeps the bottom bar.
        .tabViewStyle(.sidebarAdaptable)
        .background(SidebarEditingObserver(isEditing: $sidebarIsEditing, tint: isPad ? MusicDesign.accent : nil))
        .tabViewCustomization($tabCustomization)
        .tabViewSidebarBottomBar {
            Button {
                showSettingsFromSidebar = true
            } label: {
                HStack(spacing: 12) {
                    sidebarAvatar
                    Text(sidebarAccountName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account and settings")
        }
        .sheet(isPresented: $showNewPlaylistFromSidebar) {
            NewPlaylistNameSheet()
                .environmentObject(app)
                .presentationDetents([.large])
        }
        .onChange(of: app.selectedTab) { _, _ in sidebarSelection = nil }
        .onChange(of: sidebarSelection) { _, selection in
            if let selection, Self.isLibraryPage(selection) { lastLibraryPage = selection }
        }
        .task(id: "\(app.accountAvatarRevision)-\(app.username)-\(app.isSignedIn)") {
            guard isPad else { return }
            await accountAvatar.load(app: app)
        }
        .task(id: app.libraryPlaylists.map(\.id)) {
            guard isPad else { return }
            await playlistIcons.load(app.libraryPlaylists, app: app)
        }
        .sheet(isPresented: $showSettingsFromSidebar) {
            NavigationStack { SettingsView() }
                .environmentObject(app)
                .environmentObject(app.offline)
                .environmentObject(app.acquisition)
                .environmentObject(app.subscriptions)
        }
        .tabBarMinimizeBehavior(app.selectedTab == .search ? .never : .onScrollDown)
        #endif
        .musicNativeTabChrome(isEnabled: app.player.showsMiniPlayerChrome && !usesPadMiniPlayer) {
            TabViewMiniPlayerAccessory(
                showNowPlaying: $showNowPlaying,
                player: app.player,
                artworkNamespace: playerArtworkNamespace
            )
            .environmentObject(app)
        }
        .overlay { padMiniPlayerOverlay }
        .environmentObject(app.offline)
        .environmentObject(app.acquisition)
        .environmentObject(app.subscriptions)
        .task {
            app.scheduleLibraryBootstrap()
            if app.isSignedIn {
                app.startLibraryMembershipAutoSync()
                // Cold launch needs its own kick. `onChange(of: scenePhase)` below fires on a
                // *change*, not on the initial value, so on a fresh start nothing polled the
                // acquisition backend at all until the user happened to place a request or open
                // Settings → Music Requests. A download that finished while the app was closed
                // went unnoticed until then.
                app.acquisition.refreshOnForeground()
                await app.refreshSubscriptionsIfStale()
            }
        }
        .onChange(of: app.isSignedIn) { _, signedIn in
            // And again when sign-in completes after launch, which is the case the `task` above
            // misses: at that point `isSignedIn` was still false and there was no backend to ask.
            guard signedIn else { return }
            app.acquisition.refreshOnForeground()
            Task { await app.refreshSubscriptionsIfStale() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, app.isSignedIn else { return }
            Task { await app.refreshLibraryMembershipIfStale() }
            Task { await app.refreshSubscriptionsIfStale() }
            // Unattended download polling is deliberately time-boxed, so coming back to the app
            // is when a request that finished while it was away gets noticed.
            app.acquisition.refreshOnForeground()
        }
        .onChange(of: showNowPlaying) { _, presented in
            app.isNowPlayingCoverPresented = presented
            #if canImport(UIKit)
            if !presented { OverPlayerSheetPresenter.shared.dismiss(animated: false) }
            #endif
        }
        .onChange(of: app.openNowPlayingRequests) { _, _ in
            // Only when there is something to show. Raising an empty player from a widget tap
            // would replace the app the user asked for with a blank screen they have to dismiss.
            guard app.player.activeTrack != nil else { return }
            showNowPlaying = true
        }
        // AddToPlaylist is presented through the UIKit `OverPlayerSheetPresenter` on iOS
        // (see `AppModel.presentAddToPlaylist`) so a SwiftUI `.sheet` never shares the root
        // presentation host with the Now Playing `.fullScreenCover`. That pairing aborts in
        // `-[UIViewController _dismissViewControllerWithAnimationController…]` on iOS 26.6
        // (SwiftUI `SheetBridge` dismiss). macOS has no UIKit presenter, so it keeps the sheet.
        #if !canImport(UIKit)
        .sheet(item: $app.playlistPickerPayload) { payload in
            AddToPlaylistSheet(tracks: payload.tracks)
                .environmentObject(app)
        }
        #endif
        .libraryRemovalConfirmationChrome()
        .modifier(LibraryErrorAlertChrome())
        .modifier(NowPlayingFullScreenCoverModifier(
            isPresented: $showNowPlaying,
            artworkNamespace: playerArtworkNamespace,
        ))
        .musicTransientToastChrome()
        .musicQueueReplacementChrome()
    }
}

/// Cross-platform shim: on iOS, presents the full player via
/// ``fullScreenCover`` with the iOS 18 `.zoom` shared-element transition
/// originating from the mini-player tap area. On macOS / other platforms
/// (where `fullScreenCover` and `navigationTransition` aren't available),
/// falls back to a plain overlay so the rest of the build keeps working.
private struct NowPlayingFullScreenCoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let artworkNamespace: Namespace.ID
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        #if os(iOS)
        // Deliberately **not** `fullScreenCover`. Both crash reports off the device end in
        // `SwiftUI.SheetBridge.preferencesDidChange` → `dismissViewControllerAnimated:` →
        // `objc_exception_throw`: SheetBridge dismisses the instant the binding changes, and on
        // an open-then-immediately-close that lands on top of an unfinished present. The
        // survivable version of the same collision is the one the touch probe caught — the
        // presentation container left standing over the app with every tap going nowhere.
        // ``NowPlayingCoverPresenter`` owns `present`/`dismiss` so those calls can wait for
        // UIKit instead of being forced through, and the open and close are both run by
        // `CoverZoomAnimator` — the same animator album and playlist detail use.
        content.background {
            NowPlayingCoverPresenter(
                isPresented: $isPresented,
                content: {
                    NowPlayingGestureHost(isPresented: $isPresented)
                        .ignoresSafeArea()
                        // The root toast overlay is occluded while this cover is up, so the
                        // cover carries its own copy ("1 song added", sleep timer, etc.).
                        // Never both visible at once — the cover is full-screen.
                        .musicTransientToastChrome()
                        // Same occlusion argument as the toast: tap-to-play is reachable
                        // from over-player sheets, so the cover carries its own alert.
                        .musicQueueReplacementChrome()
                        // And again for removals: the player's ⋯ menu offers "Delete from
                        // Library", which without this resolves to an alert nobody can see.
                        .libraryRemovalConfirmationChrome()
                        // And once more for `errorMessage`. The runaway-skip guard stops
                        // playback and explains why through this alert, and the moment it is
                        // most likely to fire is while the user is watching the player, which
                        // is exactly when the root copy is occluded.
                        .modifier(LibraryErrorAlertChrome())
                        // Injected **outermost**, and every one of them, because a
                        // `UIHostingController` inherits no SwiftUI environment. Under
                        // `fullScreenCover` the cover picked these up from the shell's
                        // ancestors, so injecting them further in was enough; here it is not.
                        // With the toast chrome applied inside the injections, its
                        // `@EnvironmentObject var app` trapped on the first tap:
                        //   EnvironmentObject.error() ← MusicTransientToastChrome.body
                        .environmentObject(app)
                        .environmentObject(app.offline)
                        .environmentObject(app.acquisition)
                        .environmentObject(app.subscriptions)
                        .tint(MusicDesign.accent)
                },
                // The one value-typed thing baked into the closure above. Everything else there
                // is an object the player observes for itself. Add to this if that changes.
                contentRevision: MusicDesign.accent,
                canDismiss: { NowPlayingCoverState.shared.libraryNavigationDepth == 0 }
            )
        }
        #else
        ZStack {
            content
            if isPresented {
                NowPlayingGestureHost(isPresented: $isPresented)
                    .ignoresSafeArea()
                    .zIndex(1)
                    .transition(.move(edge: .bottom))
                    .environmentObject(app)
                    .environmentObject(app.offline)
                    .environmentObject(app.acquisition)
                    .environmentObject(app.subscriptions)
            }
        }
        .animation(
            isPresented ? .spring(response: 0.45, dampingFraction: 0.85) : nil,
            value: isPresented,
        )
        #endif
    }
}

// MARK: - Native tab view bottom accessory (system liquid glass)

private struct TabViewMiniPlayerAccessory: View {
    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif
    @EnvironmentObject private var app: AppModel
    @Binding var showNowPlaying: Bool
    /// Forwarded into the mini player. Not ``ObservedObject`` here — observing
    /// ``PlaybackEngine`` on the accessory re-renders the zoom source mid-transition
    /// and breaks the ``tabViewBottomAccessory`` ↔ ``fullScreenCover`` morph on iOS 26.
    let player: PlaybackEngine
    let artworkNamespace: Namespace.ID

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var layout: MiniPlayerLayout {
        #if os(iOS)
        if MusicPadDock.hidesPageProfile(sizeClass: horizontalSizeClass) { return .tabViewAccessoryPad }
        return placement == .inline ? .tabViewAccessoryInline : .tabViewAccessoryExpanded
        #else
        .tabViewAccessoryExpanded
        #endif
    }

    var body: some View {
        MiniPlayerView(
            showNowPlaying: $showNowPlaying,
            player: player,
            layout: layout,
            onRequestExpand: expandNowPlaying
        )
        .background {
            #if os(iOS)
            // NOT dead, despite sitting next to the scaffolding that was: this populates
            // `MiniPlayerZoomSourceRegistry`, which `NowPlayingCoverAnimator` reads as the
            // fallback origin rect for the zoom.
            MiniPlayerZoomSourceAnchor()
            #endif
        }
        // The `.matchedTransitionSource(id: "playerArtwork", in: artworkNamespace)` that used to
        // be here is removed: nothing in the module applies the paired
        // `navigationTransition(.zoom(sourceID: "playerArtwork"))`, so it armed a SwiftUI zoom
        // that had no destination and could never run.
    }

    private func expandNowPlaying() {
        // Flip presentation from the accessory layer (same view as the zoom source),
        // then reconcile playback on the next turn so ``PlaybackEngine`` publishes
        // don't rebuild this subtree while the transition is pairing.
        showNowPlaying = true
        Task { @MainActor in
            player.reconcilePlaybackSessionAfterUIMilestone()
        }
    }
}

// MARK: - Alert modifiers

private struct LibraryErrorAlertChrome: ViewModifier {
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { app.errorMessage != nil },
                    set: { newValue in
                        if !newValue { app.errorMessage = nil }
                    },
                ),
                actions: {
                    Button("OK", role: .cancel) {
                        app.errorMessage = nil
                    }
                },
                message: {
                    Text(app.errorMessage ?? "")
                },
            )
    }
}

/// Hosts NowPlayingView inside the cover.
///
/// The drag-to-dismiss used to live here as a SwiftUI `DragGesture` that faked the motion
/// (scale + corner radius + offset) and then flipped `isPresented` for the system zoom to
/// animate. Both halves are gone: ``NowPlayingCoverZoomController`` owns a `UIPanGestureRecognizer`
/// that drives `CoverZoomAnimator` directly, so the page genuinely follows the finger and the
/// transition is ours to complete. This view now only wires the two ends together.
private struct NowPlayingGestureHost: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var app: AppModel
    var body: some View {
        NowPlayingView(player: app.player, isPresented: $isPresented) { depth in
            // Read imperatively by the dismiss gesture, which is a UIKit recognizer living
            // outside this tree — see ``NowPlayingCoverState``.
            NowPlayingCoverState.shared.libraryNavigationDepth = depth
        }
#if DEBUG
            // Diagnostic only. UIKit's hit-test shows a tap reaching the player's hosting view,
            // but says nothing about what SwiftUI does with it afterwards. This logs every tap
            // SwiftUI's own gesture system recognises, which separates "the touch never reaches
            // SwiftUI's recogniser" from "it does, and the control still doesn't fire".
            // `simultaneousGesture` so it cannot steal anything from a button.
            .simultaneousGesture(
                TapGesture().onEnded { DebugUIRemote.log("NP-SWIFTUI tap recognised") }
            )
#endif
            .environmentObject(app)
            .environmentObject(app.offline)
            .environmentObject(app.acquisition)
            .environmentObject(app.subscriptions)
    }

}


// MARK: - Sidebar playlist pieces (iPad)

/// The signed-in user's profile picture as a plain image for the sidebar's bottom row.
@MainActor
final class SidebarAccountAvatarStore: ObservableObject {
    @Published private(set) var image: UIImage?
    private static let pixels: CGFloat = 36 * 3

    func load(app: AppModel) async {
        guard let identity = app.accountAvatarIdentity else {
            image = nil
            return
        }
        if let cached = AccountAvatarCache.cachedDecodedImage(identity: identity, maxPixelSize: Self.pixels) {
            image = UIImage(cgImage: cached)
        }
        guard let url = app.accountAvatarURL else { return }
        await AccountAvatarCache.prefetch(url: url, identity: identity)
        if let refreshed = AccountAvatarCache.cachedDecodedImage(identity: identity, maxPixelSize: Self.pixels) {
            image = UIImage(cgImage: refreshed)
        }
    }
}

/// Playlist cover art rendered to fixed-size icons for the sidebar. The sidebar sizes whatever
/// view it is given as a full-size image, so the artwork is pre-rendered to a small rounded
/// `UIImage`, the way system icons are.
@MainActor
final class SidebarPlaylistIconStore: ObservableObject {
    static let side: CGFloat = 28
    /// Decoded at the size the Library grids use (`AlbumArtworkView`'s default), so this shares their
    /// decoded-image cache entry instead of fetching a second, tiny copy that can come back stale.
    static let sourcePixels: CGFloat = 768
    @Published private(set) var icons: [String: UIImage] = [:]

    func load(_ playlists: [PlaylistSummary], app: AppModel) async {
        for playlist in playlists where icons[playlist.id] == nil {
            // The library's own record of the playlist and the resolver the Library grids use, so the sidebar shows
            // the cover they show. The plain playlist list carries a generic cover id that Navidrome answers
            // with its default vinyl.
            let url = app.homeMix(forLibraryPlaylistId: playlist.id)?.artworkURLs.first
                ?? app.resolvedArtworkURL(for: app.libraryPlaylist(id: playlist.id) ?? playlist)
            guard let url,
                  let cg = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: Self.sourcePixels)
            else { continue }
            icons[playlist.id] = Self.rounded(cg)
        }
    }

    private static func rounded(_ cg: CGImage) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).addClip()
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

#if os(iOS)
/// Reports whether the sidebar is in Edit mode. SwiftUI does not expose that, but the tab bar
/// controller behind `TabView` tells its delegate when editing begins and ends. The observer sits in
/// front of SwiftUI's own delegate and forwards everything else to it.
private struct SidebarEditingObserver: UIViewControllerRepresentable {
    @Binding var isEditing: Bool
    /// Accent wash for the sidebar panel (nil = leave the sidebar as the system draws it).
    var tint: Color?

    func makeUIViewController(context: Context) -> Finder {
        let finder = Finder()
        finder.view.isUserInteractionEnabled = false
        finder.onFound = { controller in
            context.coordinator.attach(to: controller)
        }
        return finder
    }

    func updateUIViewController(_ controller: Finder, context: Context) {
        context.coordinator.setEditing = { editing in
            DispatchQueue.main.async { isEditing = editing }
        }
        controller.tint = tint.map { UIColor($0) }
        controller.findIfNeeded()
        controller.applyTint()
    }

    func makeCoordinator() -> Proxy { Proxy() }

    final class Finder: UIViewController {
        var onFound: ((UITabBarController) -> Void)?
        private var found = false
        private weak var tabController: UITabBarController?
        var tint: UIColor?
        private static let tintTag = 9317

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyTint()
        }

        /// Lays a flat accent wash inside the sidebar panel's glass, behind its list, so the tint takes the
        /// panel's own shape. The panel is a private `_UITabOutlineView` > `UIVisualEffectView`.
        func applyTint() {
            guard let tabController else { return }
            guard let panel = Self.view(named: "_UITabOutlineView", in: tabController.view),
                  let effect = panel.subviews.first(where: { $0 is UIVisualEffectView }) as? UIVisualEffectView
            else { return }
            let container = effect.contentView
            let existing = container.viewWithTag(Self.tintTag) as? SidebarTintView
            guard let tint else {
                existing?.removeFromSuperview()
                return
            }
            if let existing {
                existing.update(color: tint)
            } else {
                let view = SidebarTintView(color: tint)
                view.tag = Self.tintTag
                view.frame = container.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.insertSubview(view, at: 0)
            }
        }

        private static func view(named name: String, in root: UIView) -> UIView? {
            if String(describing: type(of: root)) == name { return root }
            for child in root.subviews {
                if let match = view(named: name, in: child) { return match }
            }
            return nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            findIfNeeded()
        }

        func findIfNeeded() {
            guard !found else { return }
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            if let tab = Self.tabBarController(in: root) {
                found = true
                tabController = tab
                onFound?(tab)
                applyTint()
            }
        }

        private static func tabBarController(in controller: UIViewController) -> UITabBarController? {
            if let tab = controller as? UITabBarController { return tab }
            for child in controller.children {
                if let tab = tabBarController(in: child) { return tab }
            }
            return nil
        }
    }

    /// A flat, faint wash of the accent color.
    final class SidebarTintView: UIView {
        init(color: UIColor) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            update(color: color)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        func update(color: UIColor) {
            backgroundColor = color.withAlphaComponent(0.10)
        }
    }

    final class Proxy: NSObject, UITabBarControllerDelegate {
        var setEditing: ((Bool) -> Void)?
        private weak var original: UITabBarControllerDelegate?

        func attach(to controller: UITabBarController) {
            guard controller.delegate !== self else { return }
            original = controller.delegate
            controller.delegate = self
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original as? NSObject)?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }

        func tabBarControllerWillBeginEditing(_ tabBarController: UITabBarController) {
            setEditing?(true)
            original?.tabBarControllerWillBeginEditing?(tabBarController)
        }

        func tabBarControllerDidEndEditing(_ tabBarController: UITabBarController) {
            setEditing?(false)
            original?.tabBarControllerDidEndEditing?(tabBarController)
        }
    }
}
#else
private struct SidebarEditingObserver: View {
    @Binding var isEditing: Bool
    var tint: Color?
    var body: some View { EmptyView() }
}
#endif


// MARK: - iPad mini player metrics

enum MusicPadMiniPlayer {
    // Sized against Apple Music's iPad mini player side by side on the same iPad: it measured about 14%
    // narrower and 10% shorter than the first guess (800 x 72), and sits right at the safe-area edge.
    static let width: CGFloat = 690
    static let height: CGFloat = 65
    static let bottomGap: CGFloat = 0
    /// Space the pages keep clear beneath the floating mini player.
    static var reservedHeight: CGFloat { height + 16 }
}

private extension View {
    /// Reports this page's frame in window coordinates so the floating mini player can center on it.
    func reportsPadContentFrame(_ frame: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newValue in
            if newValue != frame.wrappedValue { frame.wrappedValue = newValue }
        }
    }
}
