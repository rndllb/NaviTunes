import SwiftUI

// MARK: - Shared chrome (native `UIMenu` layout)

/// Trailing ``Section``s after the leading ``ControlGroup`` — matches ``NewTabChartOverflowPanel`` / chart ⋯.
enum ChartStyleSongOverflowChrome {
    @ViewBuilder
    static func trailingMenuSections(
        onGoToAlbum: @escaping () -> Void,
        onAddToPlaylist: (() -> Void)? = nil,
        onPlayNext: (() -> Void)? = nil
    ) -> some View {
        Section {
            if let onAddToPlaylist {
                Button(action: onAddToPlaylist) {
                    Label("Add to a Playlist", systemImage: "music.note.list")
                }
            } else {
                Button {} label: { Label("Add to a Playlist", systemImage: "music.note.list") }
                    .disabled(true)
            }
            if let onPlayNext {
                Button(action: onPlayNext) {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            } else {
                Button {} label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .disabled(true)
            }
        }
        .tint(Color.primary)

        Section {
            Button {} label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        }
        .tint(Color.primary)

        Section {
            Button(action: onGoToAlbum) {
                Label("Go to Album", systemImage: "music.note.square")
            }
            Button {} label: { Label("View Credits", systemImage: "info.circle") }
        }
        .tint(Color.primary)

        Section {
            Button {} label: { Label("Suggest Less", systemImage: "hand.thumbsdown") }
        }
        .tint(Color.primary)
    }
}

/// Inner menu items for **Request** + Share (embed inside another `Menu`, e.g. ``AppleMusicAlbumTrackRow``).
struct ChartStyleSongOverflowMenuContent: View {
    let shareItem: String
    let onAdd: () -> Void
    var addDisabled: Bool = false
    let onGoToAlbum: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        ControlGroup {
            Button(action: onAdd) {
                Label("Request", systemImage: "arrow.down.circle.fill")
            }
            .disabled(addDisabled)
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Label("Favorite", systemImage: "star.fill")
                }
            } else {
                Button {} label: {
                    Label("Favorite", systemImage: "star.fill")
                }
                .disabled(true)
            }
            ShareLink(item: shareItem) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .tint(Color.primary)

        ChartStyleSongOverflowChrome.trailingMenuSections(
            onGoToAlbum: onGoToAlbum,
            onAddToPlaylist: onAddToPlaylist,
            onPlayNext: onPlayNext
        )
    }
}

/// Full ⋯ control (chart carousel, list rows, …): `Menu` + label.
struct ChartStyleSongOverflowMenu: View {
    let shareItem: String
    let onAdd: () -> Void
    var addDisabled: Bool = false
    let onGoToAlbum: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        Menu {
            ChartStyleSongOverflowMenuContent(
                shareItem: shareItem,
                onAdd: onAdd,
                addDisabled: addDisabled,
                onGoToAlbum: onGoToAlbum,
                onAddToPlaylist: onAddToPlaylist,
                onPlayNext: onPlayNext,
                onToggleFavorite: onToggleFavorite
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Last.fm chart ⋯

/// Last.fm chart ⋯ on the **New** tab (same layout as missing-catalog / Downtify-not-in-library rows).
struct NewTabChartOverflowPanel: View {
    let track: LFMTrack
    let onAdd: () -> Void
    let onGoToAlbum: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        ChartStyleSongOverflowMenu(
            shareItem: "\(track.name) — \(track.artistName)",
            onAdd: onAdd,
            onGoToAlbum: onGoToAlbum,
            onAddToPlaylist: onAddToPlaylist,
            onPlayNext: onPlayNext,
            onToggleFavorite: onToggleFavorite
        )
    }
}

// MARK: - Album hero toolbar ⋯ (system `UIMenu` / Liquid Glass)

/// Inner items for library / browse album toolbar overflow — uses native ``Menu`` styling (not a custom popover).
struct AlbumToolbarOverflowMenuContent<ExtraContent: View>: View {
    @EnvironmentObject private var app: AppModel

    let shareItem: String
    let playlistTracks: [Track]
    /// Leading control (e.g. **Offline** download or **Request**); disabled when `nil`.
    let onLeading: (() -> Void)?
    /// When true, greys out the leading action (e.g. every playlist track is already saved offline).
    var leadingDisabled: Bool = false
    var leadingTitle: String = "Request"
    var leadingSystemImage: String = "plus"
    /// Prefer spoken hint for **Offline** (“download for offline use”).
    var leadingAccessibilityLabel: String? = nil
    @ViewBuilder var extraContent: () -> ExtraContent

    private var allPlaylistFavorited: Bool {
        guard !playlistTracks.isEmpty else { return false }
        return playlistTracks.allSatisfy { app.favoriteTrackIds.contains($0.id) }
    }

    private var canUsePlaylistActions: Bool {
        app.isSignedIn && !playlistTracks.isEmpty && app.activeLibrary != nil
    }

    var body: some View {
        Group {
            extraContent()

            ControlGroup {
                Button {
                    onLeading?()
                } label: {
                    Label(leadingTitle, systemImage: leadingSystemImage)
                }
                .disabled(onLeading == nil || leadingDisabled)
                .accessibilityLabel(leadingAccessibilityLabel ?? leadingTitle)

                Button(action: togglePlaylistFavorites) {
                    Label(
                        allPlaylistFavorited ? "Favorited" : "Favorite",
                        systemImage: allPlaylistFavorited ? "star.fill" : "star"
                    )
                }
                .disabled(playlistTracks.isEmpty)

                ShareLink(item: shareItem) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .tint(Color.primary)

            Section {
                if canUsePlaylistActions {
                    Button {
                        app.presentAddToPlaylist(tracks: playlistTracks)
                    } label: {
                        Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button {
                        Task { @MainActor in
                            guard let lib = app.activeLibrary else { return }
                            try? await app.player.playTracksNext(library: lib, tracks: playlistTracks)
                        }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                } else {
                    Button {} label: {
                        Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
                    }
                    .disabled(true)
                    Button {} label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(true)
                }
            }
            .tint(Color.primary)

            Section {
                Button {} label: {
                    Label("Suggest Less", systemImage: "hand.thumbsdown")
                }
                .disabled(true)
            }
            .tint(Color.primary)
        }
    }

    private func togglePlaylistFavorites() {
        if allPlaylistFavorited {
            for t in playlistTracks where app.favoriteTrackIds.contains(t.id) {
                app.toggleFavoriteTrack(id: t.id)
            }
        } else {
            for t in playlistTracks where !app.favoriteTrackIds.contains(t.id) {
                app.toggleFavoriteTrack(id: t.id)
            }
        }
    }
}

/// Toolbar ⋯ — system menu presentation (matches chart row overflow, gets platform chrome including Liquid Glass).
struct AlbumToolbarOverflowMenu<ExtraContent: View>: View {
    let shareItem: String
    let playlistTracks: [Track]
    let onLeading: (() -> Void)?
    var leadingDisabled: Bool = false
    var leadingTitle: String = "Request"
    var leadingSystemImage: String = "plus"
    var leadingAccessibilityLabel: String? = nil
    var ellipsisTint: Color = .white
    @ViewBuilder var extraContent: () -> ExtraContent

    var body: some View {
        Menu {
            AlbumToolbarOverflowMenuContent(
                shareItem: shareItem,
                playlistTracks: playlistTracks,
                onLeading: onLeading,
                leadingDisabled: leadingDisabled,
                leadingTitle: leadingTitle,
                leadingSystemImage: leadingSystemImage,
                leadingAccessibilityLabel: leadingAccessibilityLabel,
                extraContent: extraContent
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ellipsisTint)
        }
        .buttonStyle(.plain)
    }
}

extension AlbumToolbarOverflowMenu where ExtraContent == EmptyView {
    init(
        shareItem: String,
        playlistTracks: [Track],
        onLeading: (() -> Void)?,
        leadingDisabled: Bool = false,
        leadingTitle: String = "Request",
        leadingSystemImage: String = "plus",
        leadingAccessibilityLabel: String? = nil,
        ellipsisTint: Color = .white
    ) {
        self.init(
            shareItem: shareItem,
            playlistTracks: playlistTracks,
            onLeading: onLeading,
            leadingDisabled: leadingDisabled,
            leadingTitle: leadingTitle,
            leadingSystemImage: leadingSystemImage,
            leadingAccessibilityLabel: leadingAccessibilityLabel,
            ellipsisTint: ellipsisTint,
            extraContent: { EmptyView() }
        )
    }
}
