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
    case artist(String)
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
        case .artist(let name):
            ArtistPageView(input: .named(name))
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

// MARK: - Shell

private struct MainShellView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    /// Source namespace for the iOS 18+ zoom transition. The mini-player tap
    /// area marks itself as the source with ``matchedTransitionSource``; the
    /// presented full player applies ``navigationTransition(.zoom(...))`` so
    /// the system drives the entire shared-element animation between them —
    /// no manual matched-geometry plumbing required.
    @Namespace private var playerArtworkNamespace

    var body: some View {
        TabView(selection: $app.selectedTab) {
            Tab("Home", systemImage: AppTab.home.systemImage, value: AppTab.home) {
                HomeView()
            }
            Tab("New", systemImage: AppTab.new.systemImage, value: AppTab.new) {
                MusicNewTabView()
            }
            Tab("Radio", systemImage: AppTab.radio.systemImage, value: AppTab.radio) {
                RadioTabView()
            }
            Tab("Library", systemImage: AppTab.library.systemImage, value: AppTab.library) {
                LibraryView()
            }
            Tab("Search", systemImage: AppTab.search.systemImage, value: AppTab.search, role: .search) {
                SearchLibraryView()
            }
        }
        .tint(MusicDesign.accent)
        #if os(iOS)
        .tabBarMinimizeBehavior(app.selectedTab == .search ? .never : .onScrollDown)
        #endif
        .musicNativeTabChrome(isEnabled: app.player.showsMiniPlayerChrome) {
            TabViewMiniPlayerAccessory(
                showNowPlaying: $showNowPlaying,
                player: app.player,
                artworkNamespace: playerArtworkNamespace
            )
            .environmentObject(app)
        }
        .environmentObject(app.offline)
        .environmentObject(app.acquisition)
        .task {
            app.scheduleLibraryBootstrap()
            if app.isSignedIn {
                app.startLibraryMembershipAutoSync()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, app.isSignedIn else { return }
            Task { await app.refreshLibraryMembershipIfStale() }
        }
#if DEBUG
        .onChange(of: app.debugOpenPlayerRequests) { _, _ in
            guard app.player.activeTrack != nil else { return }
            showNowPlaying = true
        }
#endif
        .sheet(item: $app.playlistPickerPayload) { payload in
            AddToPlaylistSheet(tracks: payload.tracks)
                .environmentObject(app)
        }
        .modifier(LibraryTrackDeletionChrome())
        .modifier(LibraryErrorAlertChrome())
        .modifier(NowPlayingFullScreenCoverModifier(
            isPresented: $showNowPlaying,
            artworkNamespace: playerArtworkNamespace,
        ))
        .musicTransientToastChrome()
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
        content.fullScreenCover(isPresented: $isPresented) {
            NowPlayingGestureHost(isPresented: $isPresented)
                .ignoresSafeArea()
                .navigationTransition(
                    .zoom(sourceID: "playerArtwork", in: artworkNamespace),
                )
                .environmentObject(app)
                .environmentObject(app.offline)
                .environmentObject(app.acquisition)
                // The root toast overlay is occluded while this cover is up, so the
                // cover carries its own copy ("1 song added", sleep timer, etc.).
                // Never both visible at once — the cover is full-screen.
                .musicTransientToastChrome()
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
    @ObservedObject var player: PlaybackEngine
    /// Forwarded into the mini player so the tap button can mark itself as the
    /// zoom-transition source for the presented full player.
    let artworkNamespace: Namespace.ID

    private var layout: MiniPlayerLayout {
        #if os(iOS)
        placement == .inline ? .tabViewAccessoryInline : .tabViewAccessoryExpanded
        #else
        .tabViewAccessoryExpanded
        #endif
    }

    var body: some View {
        // The matched-transition-source modifier lives here — on the
        // accessory itself, which is rendered exactly once — instead of inside
        // ``MiniPlayerView`` on each layout's tap button. During the tab bar's
        // morph between `.inline` and `.expanded` placements, both layouts
        // could briefly be alive, registering two sources with the same id;
        // SwiftUI would then fail to pick one and fall back to the default
        // `fullScreenCover` slide-up animation. Anchoring at this layer keeps
        // exactly one source registered no matter what's happening below.
        MiniPlayerView(
            showNowPlaying: $showNowPlaying,
            player: player,
            layout: layout
        )
        .matchedTransitionSource(id: "playerArtwork", in: artworkNamespace)
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

private struct LibraryTrackDeletionChrome: ViewModifier {
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        content
            .alert(
                confirmationTitle,
                isPresented: Binding(
                    get: { app.libraryTrackPendingDeletion != nil },
                    set: { newValue in
                        if !newValue { app.cancelLibraryTrackDeletion() }
                    },
                ),
                actions: {
                    Button("Delete from Library", role: .destructive) {
                        Task { await app.confirmLibraryTrackDeletion() }
                    }
                    Button("Cancel", role: .cancel) {
                        app.cancelLibraryTrackDeletion()
                    }
                },
                message: {
                    Text(
                        "This removes the track from your media library on the server. Depending on server settings, the file on disk may be deleted as well.",
                    )
                },
            )
    }

    private var confirmationTitle: String {
        guard let t = app.libraryTrackPendingDeletion else {
            return "Delete from library?"
        }
        return "Delete \"\(t.title)\" from your library?"
    }
}

/// Wraps NowPlayingView with its drag-to-dismiss gesture. Keeping drag state here
/// prevents MainShellView from rebuilding every frame during a drag.
private struct NowPlayingGestureHost: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var app: AppModel
    /// Persisted drag offset — unlike `@GestureState`, survives through dismiss animation.
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissAnimating = false
    @State private var libraryNavigationDepth = 0
    @State private var hostHeight: CGFloat = 0
    /// Guards the drag-to-dismiss gesture until the present animation has settled,
    /// so incidental touches during the slide-up can't park the sheet at half height.
    @State private var fullyPresented = false
    @Environment(\.scenePhase) private var scenePhase

    /// 0…1 progress driving the Apple Music–style scale + corner-radius reveal.
    private var dragProgress: CGFloat {
        guard dragOffset > 0 else { return 0 }
        return min(dragOffset / 360, 1)
    }

    var body: some View {
        NowPlayingView(player: app.player, isPresented: $isPresented) { depth in
            libraryNavigationDepth = depth
        }
            .environmentObject(app)
            .environmentObject(app.offline)
            .environmentObject(app.acquisition)
            .scaleEffect(1 - dragProgress * 0.06, anchor: .center)
            .clipShape(RoundedRectangle(cornerRadius: dragProgress * 28, style: .continuous))
            .offset(y: max(0, dragOffset))
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { hostHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in hostHeight = h }
                }
            }
            .gesture(dismissDragGesture)
            .onChange(of: isPresented) { _, presented in
                if presented {
                    dragOffset = 0
                    isDismissAnimating = false
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                fullyPresented = true
            }
            .onChange(of: scenePhase) { old, new in
                print("[NP-DIAG] phase \(old)→\(new) dragOffset=\(dragOffset) isDismissAnimating=\(isDismissAnimating) fullyPresented=\(fullyPresented) hostHeight=\(hostHeight) isPresented=\(isPresented)")
            }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard fullyPresented, libraryNavigationDepth == 0, !isDismissAnimating else { return }
                let dy = value.translation.height
                let dx = value.translation.width
                guard dy > 0, abs(dy) > abs(dx) else { return }
                dragOffset = dy
            }
            .onEnded { value in
                guard fullyPresented, !isDismissAnimating else { return }
                let dy = value.translation.height
                let predictedDy = value.predictedEndTranslation.height
                let shouldDismiss = libraryNavigationDepth == 0
                    && (dy > 140 || predictedDy > 280)
                guard shouldDismiss else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                    return
                }
                // Hand the dismiss off to ``.fullScreenCover``'s
                // `.navigationTransition(.zoom)` — *do not* slide the view down
                // manually or disable animations on the `isPresented` mutation,
                // both of which previously bypassed the zoom and made the
                // dismiss look like the default cover slide-down. We just
                // flip `isPresented` and let the system animate the zoom back
                // to the mini player's matched-transition-source frame.
                isDismissAnimating = true
                isPresented = false
                // Reset transient drag transforms after the cover's zoom
                // animation has completed (slightly longer than the system
                // transition window so the reset doesn't snap mid-animation).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(420))
                    dragOffset = 0
                    isDismissAnimating = false
                }
            }
    }
}
