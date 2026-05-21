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
    }
}

// MARK: - Tab model

enum NowPlayingDeepLink: Equatable {
    /// `librarySource: false` opens the full album view (server catalog tracks); `true`
    /// opens the library-only filtered view. "Go to Album" from Now Playing flips to
    /// `false` when the active track isn't in the user's library, so the user lands on
    /// a view that actually contains the track they're playing.
    case album(AlbumSummary, scrollToTrackId: String? = nil, librarySource: Bool = true)
    case artist(String)
    case playlist(PlaylistSummary, scrollToTrackId: String? = nil)
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
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
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
                Tab(value: AppTab.search, role: .search) {
                    SearchLibraryView()
                } label: {
                    Label("Search", systemImage: AppTab.search.systemImage)
                }
            }
            .tint(MusicDesign.accent)
            #if os(iOS)
            .tabBarMinimizeBehavior(app.selectedTab == .search ? .never : .onScrollDown)
            #endif
            .musicNativeTabChrome(isEnabled: app.player.showsMiniPlayerChrome) {
                TabViewMiniPlayerAccessory(
                    showNowPlaying: $showNowPlaying,
                    player: app.player
                )
                .environmentObject(app)
            }
            .environmentObject(app.offline)
            .task {
                app.scheduleLibraryBootstrap()
            }
            .sheet(item: $app.playlistPickerPayload) { payload in
                AddToPlaylistSheet(tracks: payload.tracks)
                    .environmentObject(app)
            }
            .modifier(LibraryTrackDeletionChrome())
            .modifier(LibraryErrorAlertChrome())

            if showNowPlaying {
                NowPlayingGestureHost(isPresented: $showNowPlaying)
                    .ignoresSafeArea()
                    .zIndex(1)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(
            showNowPlaying
                ? .spring(response: 0.45, dampingFraction: 0.85)
                : nil,
            value: showNowPlaying
        )
        .musicTransientToastChrome()
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
            layout: layout
        )
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
                isDismissAnimating = true
                let dismissTarget = max(hostHeight, predictedDy, dy) + 40
                withAnimation(.easeOut(duration: 0.28)) {
                    dragOffset = dismissTarget
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isPresented = false
                        dragOffset = 0
                        isDismissAnimating = false
                    }
                }
            }
    }
}
