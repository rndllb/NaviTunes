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

private struct MainShellView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
            TabView {
                Tab("Home", systemImage: "house.fill") { HomeView() }
                Tab("New", systemImage: "square.grid.2x2.fill") { MusicNewTabView() }
                Tab("Radio", systemImage: "dot.radiowaves.left.and.right") { RadioTabView() }
                Tab("Library", systemImage: "music.note.list") { LibraryView() }
                Tab(role: .search) { SearchLibraryView() }
            }
            .tint(MusicDesign.accent)
            .modifier(TabMiniPlayerShellModifier(
                showNowPlaying: $showNowPlaying,
                showMiniPlayer: app.player.activeTrack != nil,
                player: app.player
            ))
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
                NowPlayingView(isPresented: $showNowPlaying)
                    .environmentObject(app)
                    .ignoresSafeArea()
                    .zIndex(1)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom),
                        removal: .identity
                    ))
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.86), value: showNowPlaying)
    }
}

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

private struct TabMiniPlayerShellModifier: ViewModifier {
    @Binding var showNowPlaying: Bool
    var showMiniPlayer: Bool
    var player: PlaybackEngine

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showMiniPlayer {
                    MiniPlayerView(showNowPlaying: $showNowPlaying, player: player)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                        .padding(.bottom, bottomPadding)
                }
            }
    }

    private var bottomPadding: CGFloat {
        return 57
    }
}
