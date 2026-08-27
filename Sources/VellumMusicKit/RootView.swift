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
        .environmentObject(app.subscriptions)
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
        .onChange(of: showNowPlaying) { _, presented in
            app.isNowPlayingCoverPresented = presented
            #if canImport(UIKit)
            if !presented { OverPlayerSheetPresenter.shared.dismiss(animated: false) }
            #endif
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

    private var layout: MiniPlayerLayout {
        #if os(iOS)
        placement == .inline ? .tabViewAccessoryInline : .tabViewAccessoryExpanded
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
