import SwiftUI

// MARK: - Shared chrome (native `UIMenu` layout)

/// Trailing ``Section``s after the leading ``ControlGroup`` — matches ``NewTabChartOverflowPanel`` / chart ⋯.
enum ChartStyleSongOverflowChrome {
    @ViewBuilder
    static func trailingMenuSections(
        onGoToAlbum: (() -> Void)? = nil,
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

        if let onGoToAlbum {
            Section {
                Button(action: onGoToAlbum) {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            .tint(Color.primary)
        }
    }
}

/// Inner menu items for **Request** + Share (embed inside another `Menu`, e.g. ``AppleMusicAlbumTrackRow``).
struct ChartStyleSongOverflowMenuContent: View {
    let shareItem: String
    let onAdd: () -> Void
    var addDisabled: Bool = false
    var navidromeShareItemId: String? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        ControlGroup {
            Button(action: onAdd) {
                RequestActionLabel()
            }
            .disabled(addDisabled)
            Button {} label: {
                Image(systemName: "plus")
            }
            .disabled(true)
            .accessibilityLabel("Add to library unavailable until requested")
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

        if let navidromeShareItemId {
            NavidromeShareMenuSection(itemId: navidromeShareItemId, description: shareItem)
        }
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

// MARK: - Chart browse ⋯

/// Chart browse ⋯ on the **New** tab (same layout as missing-catalog / the request backend-not-in-library rows).
struct NewTabChartOverflowPanel: View {
    let track: ChartTrack
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

/// **New** tab song row ⋯ — library ``StandardSongMenuContent`` when the release is on the
/// server; chart **Request** menu while missing or downloading.
struct NewTabChartRowOverflowMenu: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var acquisition: AcquisitionManager
    let chart: ChartTrack
    let onRequest: () -> Void
    let onBrowseAlbum: () -> Void
    var onGoToLibraryAlbum: ((AlbumSummary) -> Void)? = nil

    var body: some View {
        if let job = acquisition.job(forKey: chart.acquisitionRequest.requestKey), !job.status.isTerminal {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: min(1, job.progress))
                    .tint(MusicDesign.accent)
                    .frame(width: 52)
                Text("\(Int((min(1, job.progress) * 100).rounded()))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
            .frame(width: 54, alignment: .trailing)
        } else if let track = app.resolvedServerTrack(for: chart) {
            Menu {
                StandardSongMenuContent(
                    track: track,
                    onPlayNext: {
                        Task { @MainActor in
                            try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [track])
                        }
                    },
                    onAddToQueue: {
                        Task { @MainActor in
                            guard let lib = app.activeLibrary else { return }
                            try? await app.player.addToQueue(library: lib, track: track)
                            app.showTransientToast("Added to Queue")
                        }
                    },
                    onFavorite: { app.toggleFavoriteTrack(id: track.id) },
                    onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
                    onAddToLibrary: app.isSongInLibrary(track.id)
                        ? nil
                        : { Task { await app.addSongToLibrary(track) } },
                    onDownload: app.isSongInLibrary(track.id)
                        && !app.offline.downloadedTrackIds.contains(track.id)
                        ? { app.enqueueOfflineTrack(track) }
                        : nil,
                    onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                        ? { try? app.offline.remove(trackId: track.id) }
                        : nil,
                    onGoToAlbum: {
                        let album = app.albumSummary(for: track)
                        if let onGoToLibraryAlbum {
                            onGoToLibraryAlbum(album)
                        }
                    },
                    onRemoveFromLibrary: app.isSongInLibrary(track.id)
                        ? { Task { await app.removeSongFromLibrary(track) } }
                        : nil,
                    onDeleteFromLibrary: app.canDeleteFromLibrary
                        ? { app.beginLibraryTrackDeletion(track) }
                        : nil
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuOrder(.fixed)
        } else {
            NewTabChartOverflowPanel(
                track: chart,
                onAdd: onRequest,
                onGoToAlbum: onBrowseAlbum
            )
        }
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
                    if leadingTitle == "Request" {
                        RequestActionLabel()
                    } else {
                        Label(leadingTitle, systemImage: leadingSystemImage)
                    }
                }
                .disabled(onLeading == nil || leadingDisabled)
                .accessibilityLabel(leadingAccessibilityLabel ?? leadingTitle)

                if leadingTitle == "Request" {
                    Button {} label: {
                        Image(systemName: "plus")
                    }
                    .disabled(true)
                    .accessibilityLabel("Add to library unavailable until requested")
                }

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
