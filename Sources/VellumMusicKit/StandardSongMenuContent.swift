import SwiftUI

/// Shared content body for any song-row 3-dot (⋯) Menu in the app. Mirrors the
/// option set used by `LibrarySongRow`'s inline Menu so every surface that exposes
/// per-song actions shows the same options in the same order — search, artist
/// page Top Songs, queue, browse, etc. New song-row surfaces should construct
/// their own ⋯ button (sized to that surface's chrome) and use this view as the
/// Menu's content rather than rolling a custom subset.
///
/// Each callback is optional; sections that depend on a missing callback are
/// hidden. Pass `nil` for actions that don't apply at this surface.
struct StandardSongMenuContent: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(LibraryPinStore.storageKey) private var pinnedStorage: String = "[]"

    let track: Track

    /// Play this song now. Only some surfaces offer it — on a list row, tapping the row already
    /// plays it, so it is redundant there and those call sites pass `nil`.
    var onPlay: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    /// Album-scoped, not song-scoped: adds the song's whole album. Search offers it because a
    /// search result is often the way you find an album you do not have yet.
    var onAddAlbumToLibrary: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onAddToLibrary: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    var onRemoveDownload: (() -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onGoToArtist: (() -> Void)? = nil
    var onRemoveFromLibrary: (() -> Void)? = nil
    var onDeleteFromLibrary: (() -> Void)? = nil
    /// Only meaningful when the row actually belongs to a user playlist. Album detail and home
    /// mixes pass `nil`, and the item is then hidden — an album track is not "in" a playlist.
    var onRemoveFromPlaylist: (() -> Void)? = nil

    private var isInLibrary: Bool { app.isSongInLibrary(track.id) }
    private var isOfflineCached: Bool { app.offline.downloadedTrackIds.contains(track.id) }
    private var isFavorite: Bool { app.favoriteTrackIds.contains(track.id) }
    private var trackPinRef: LibraryPinnedRef { LibraryPinnedRef(kind: .track, itemId: track.id) }
    private var isPinnedToLibrary: Bool { LibraryPinStore.contains(trackPinRef, in: pinnedStorage) }
    private var canDeleteFromLibrary: Bool { app.canDeleteFromLibrary }

    var body: some View {
        ControlGroup {
            if !isInLibrary, let onAddToLibrary {
                Button(action: onAddToLibrary) {
                    Label("Add to Library", systemImage: "plus")
                }
            } else if isInLibrary, !isOfflineCached, let onDownload {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down")
                }
            }
            if let onFavorite {
                Button(action: onFavorite) {
                    Label(isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: isFavorite ? "star.fill" : "star")
                }
            }
            ShareLink(item: "\(track.title) — \(track.artist)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .tint(Color.primary)

        Section {
            Button {
                if !isPinnedToLibrary {
                    app.retainTrackForLibraryPin(track)
                }
                LibraryPinStore.toggle(trackPinRef, storage: &pinnedStorage)
            } label: {
                Label(
                    LibraryPinStore.menuLabel(kind: .track, isPinned: isPinnedToLibrary),
                    systemImage: isPinnedToLibrary ? "pin.slash" : "pin"
                )
            }
            if let onAddToPlaylist {
                Button(action: onAddToPlaylist) {
                    Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
                }
            }
            if let onAddAlbumToLibrary {
                Button(action: onAddAlbumToLibrary) {
                    // `plus.square.on.square` is what `LibraryAlbumContextMenuContent` already
                    // uses for adding an album, and it is a symbol this module verifies at
                    // runtime. Do not invent a name here — see T063, where `music.note.square`
                    // did not exist and rendered as blank space with no error.
                    Label("Add Album to Library", systemImage: "plus.square.on.square")
                }
            }
        }
        .tint(Color.primary)

        if onPlay != nil || onPlayNext != nil || onAddToQueue != nil {
            Section {
                if let onPlay {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play")
                    }
                }
                if let onPlayNext {
                    Button(action: onPlayNext) {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                if let onAddToQueue {
                    Button(action: onAddToQueue) {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                }
            }
            .tint(Color.primary)
        }

        if onGoToAlbum != nil || onGoToArtist != nil {
            Section {
                if let onGoToAlbum {
                    Button(action: onGoToAlbum) {
                        // `music.note.square` does not exist in SF Symbols — it resolved to nil
                        // and rendered as blank space with no build error. `square.stack` is the
                        // glyph this app already uses for Albums in the Library filter.
                        Label("Go to Album", systemImage: "square.stack")
                    }
                }
                if let onGoToArtist {
                    Button(action: onGoToArtist) {
                        Label("Go to Artist", systemImage: "music.microphone")
                    }
                }
            }
            .tint(Color.primary)
        }

        NavidromeShareMenuSection(
            itemId: track.id,
            description: "\(track.title) — \(track.artist)"
        )

        if isOfflineCached, let onRemoveDownload {
            Section {
                Button(action: onRemoveDownload) {
                    Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                }
            }
            .tint(Color.primary)
        }

        if let onRemoveFromPlaylist {
            Section {
                // Deliberately text-only. The icon was `text.badge.minus`, which resolves fine —
                // this is not a missing-symbol bug — but it is a "lines with a badge" glyph sitting
                // in the same menu as `text.append` (Add to Queue) and
                // `text.line.first.and.arrowtriangle.forward` (Play Next). At menu size the three
                // are near-indistinguishable, so the one destructive item in the menu read as just
                // another queue action. No icon is clearer than a misleading one; the red
                // destructive tint already carries the weight.
                Button(role: .destructive, action: onRemoveFromPlaylist) {
                    Text("Remove from Playlist")
                }
            }
            .tint(MusicDesign.destructiveAction)
        }

        if onRemoveFromLibrary != nil || (canDeleteFromLibrary && onDeleteFromLibrary != nil) {
            Section {
                if let onRemoveFromLibrary {
                    Button(role: .destructive, action: onRemoveFromLibrary) {
                        Label("Delete from Library", systemImage: "trash")
                    }
                }
                if canDeleteFromLibrary, let onDeleteFromLibrary {
                    Button(role: .destructive, action: onDeleteFromLibrary) {
                        Label("Delete File from Server", systemImage: "xmark.bin")
                    }
                }
            }
            .tint(MusicDesign.destructiveAction)
        }
    }
}
