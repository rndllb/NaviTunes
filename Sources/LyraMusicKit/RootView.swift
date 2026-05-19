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
    @State private var selectedTab: AppTab = .home

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
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
            .musicNativeTabChrome(isEnabled: app.player.activeTrack != nil) {
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
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showNowPlaying)
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
    @State private var dragOffset: CGFloat = 0
    @State private var libraryNavigationDepth = 0

    var body: some View {
        NowPlayingView { depth in
            libraryNavigationDepth = depth
        }
            .environmentObject(app)
            .environmentObject(app.offline)
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard libraryNavigationDepth == 0 else { return }
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        guard libraryNavigationDepth == 0 else {
                            dragOffset = 0
                            return
                        }
                        if value.translation.height > 150 || value.predictedEndTranslation.height > 250 {
                            isPresented = false
                        } else {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .onDisappear { dragOffset = 0 }
    }
}
