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
    @State private var collapseState = MiniPlayerCollapseState()

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
                Tab("New", systemImage: "square.grid.2x2.fill", value: AppTab.new) { MusicNewTabView() }
                Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: AppTab.radio) { RadioTabView() }
                Tab("Library", systemImage: "music.note.list", value: AppTab.library) { LibraryView() }
                Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) { SearchLibraryView() }
            }
            .tint(MusicDesign.accent)
            .musicHidesTabBar()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomChrome(
                    showNowPlaying: $showNowPlaying,
                    selectedTab: $selectedTab,
                    player: app.player,
                    collapseState: collapseState
                )
                .environmentObject(app)
            }
            .environment(collapseState)
            .task {
                await app.refreshLibraryAlbums()
                await app.refreshNewTabBrowse()
                await app.refreshLibraryStatistics()
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

// MARK: - Bottom chrome (mini player + custom tab bar / collapsed pill)

private struct BottomChrome: View {
    @EnvironmentObject private var app: AppModel
    @Binding var showNowPlaying: Bool
    @Binding var selectedTab: AppTab
    var player: PlaybackEngine
    var collapseState: MiniPlayerCollapseState

    private var hasTrack: Bool { player.activeTrack != nil }
    private var isCollapsed: Bool { collapseState.isCollapsed && hasTrack }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedRow
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                    ))
            } else {
                expandedStack
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                    ))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isCollapsed)
    }

    // MARK: Expanded

    private var expandedStack: some View {
        VStack(spacing: 0) {
            if hasTrack {
                MiniPlayerView(showNowPlaying: $showNowPlaying, player: player)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            customTabBar
        }
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 21))
                        Text(tab.label)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selectedTab == tab ? MusicDesign.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    // MARK: Collapsed

    private var collapsedRow: some View {
        HStack(spacing: 12) {
            collapsedLeftPill
            Spacer(minLength: 0)
            collapsedSearchButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var collapsedLeftPill: some View {
        HStack(spacing: 0) {
            // Tab icon — tap to expand bar
            Button {
                collapseState.expand()
            } label: {
                Image(systemName: selectedTab.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Art + play/pause — tap to toggle playback
            if let track = player.activeTrack {
                let artURL = app.resolvedArtworkURL(for: track)
                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        AlbumArtworkView(url: artURL, cornerRadius: 5)
                            .frame(width: 30, height: 30)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 0)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .musicGlassCapsuleInteractiveChrome()
    }

    private var collapsedSearchButton: some View {
        Button {
            selectedTab = .search
            collapseState.expand()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .musicGlassEffect(in: Circle())
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
/// prevents MainShellView (and its TabView) from rebuilding every frame during a drag.
private struct NowPlayingGestureHost: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var app: AppModel
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NowPlayingView()
            .environmentObject(app)
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
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
