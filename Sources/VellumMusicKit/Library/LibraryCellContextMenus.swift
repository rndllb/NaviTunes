import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// Transferable conformance lets the same cell that owns the context menu also act as
// a drag-and-drop source — the system coordinates UIContextMenuInteraction +
// UIDragInteraction so a lifted preview can be dragged to a drop destination.

extension AlbumSummary: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (album: AlbumSummary) in
            "\(album.title) — \(album.artist)"
        })
    }
}

extension PlaylistSummary: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \PlaylistSummary.name)
    }
}

/// Apple Music–style long-press menu for album cells. Drop in via `.libraryAlbumContextMenu(album)`.
struct LibraryAlbumContextMenuContent: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(LibraryPinStore.storageKey) private var pinnedStorage: String = "[]"
    let album: AlbumSummary

    private var pinRef: LibraryPinnedRef {
        LibraryPinnedRef(kind: .album, itemId: album.id)
    }

    private var isPinned: Bool {
        LibraryPinStore.contains(pinRef, in: pinnedStorage)
    }

    var body: some View {
        Section {
            Button {
                Task { await play() }
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                Task { await shuffle() }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            Button {
                Task { await playNext() }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
        .menuSectionPrimaryTint()

        Section {
            if !app.isAlbumInLibrary(album.id) {
                Button {
                    Task { await addAlbumToLibrary() }
                } label: {
                    Label("Add to Library", systemImage: "plus.square.on.square")
                }
            }
            Button {
                if !isPinned { app.retainAlbumForLibraryPin(album) }
                LibraryPinStore.toggle(pinRef, storage: &pinnedStorage)
            } label: {
                Label(
                    LibraryPinStore.menuLabel(kind: .album, isPinned: isPinned),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                Task { await addToPlaylist() }
            } label: {
                Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
            }
        }
        .menuSectionPrimaryTint()

        if app.isAlbumInLibrary(album.id) {
            Section {
                Button(role: .destructive) {
                    app.requestRemoveAlbumFromLibrary(album)
                } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
            }
            .menuSectionDestructiveTint()
        }

        Section {
            ShareLink(item: "\(album.title) — \(album.artist)") {
                Label("Share Album", systemImage: "square.and.arrow.up")
            }
        }
        .menuSectionPrimaryTint()

        NavidromeShareMenuSection(
            itemId: album.id,
            description: "\(album.title) — \(album.artist)"
        )
    }

    private func loadTracks() async throws -> [Track] {
        guard let lib = app.activeLibrary else { return [] }
        return try await lib.tracks(forAlbumId: album.id)
    }

    private func addAlbumToLibrary() async {
        do {
            let tracks = try await loadTracks()
            await app.addAlbumToLibrary(album, tracks: tracks)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func play() async { await perform(.play) }

    private func shuffle() async { await perform(.shuffle) }

    private func playNext() async { await perform(.playNext) }

    /// Same path as the album hero: the queue-replacement confirmation, and a real shuffle.
    private func perform(_ intent: AppModel.CollectionPlayIntent) async {
        do {
            let tracks = try await loadTracks()
            await app.playCollectionOrToast(tracks: tracks, source: nil, intent: intent)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func addToPlaylist() async {
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            app.presentAddToPlaylist(tracks: tracks)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

/// Apple Music–style long-press menu for playlist cells. Drop in via `.libraryPlaylistContextMenu(playlist)`.
struct LibraryPlaylistContextMenuContent: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(LibraryPinStore.storageKey) private var pinnedStorage: String = "[]"
    let playlist: PlaylistSummary

    private var pinRef: LibraryPinnedRef {
        LibraryPinnedRef(kind: .playlist, itemId: playlist.id)
    }

    private var isPinned: Bool {
        LibraryPinStore.contains(pinRef, in: pinnedStorage)
    }

    var body: some View {
        Section {
            Button {
                Task { await play() }
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                Task { await shuffle() }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            Button {
                Task { await playNext() }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
        .menuSectionPrimaryTint()

        Section {
            if !app.isPlaylistInLibrary(playlist.id) {
                Button {
                    Task { await app.addPlaylistToLibrary(playlist) }
                } label: {
                    Label("Add to Library", systemImage: "plus.square.on.square")
                }
            }
            Button {
                LibraryPinStore.toggle(pinRef, storage: &pinnedStorage)
            } label: {
                Label(
                    LibraryPinStore.menuLabel(kind: .playlist, isPinned: isPinned),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                Task { await addToPlaylist() }
            } label: {
                Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
            }
        }
        .menuSectionPrimaryTint()

        if app.isPlaylistInLibrary(playlist.id) {
            Section {
                Button(role: .destructive) {
                    app.requestRemovePlaylistFromLibrary(playlist)
                } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
            }
            .menuSectionDestructiveTint()
        }

        Section {
            ShareLink(item: playlist.name) {
                Label("Share Playlist", systemImage: "square.and.arrow.up")
            }
        }
        .menuSectionPrimaryTint()

        NavidromeShareMenuSection(itemId: playlist.id, description: playlist.name)
    }

    private func loadTracks() async throws -> [Track] {
        let rows = try await app.fetchPlaylistRows(playlistId: playlist.id)
        return rows.map(\.track)
    }

    private func play() async { await perform(.play) }

    private func shuffle() async { await perform(.shuffle) }

    private func playNext() async { await perform(.playNext) }

    /// Same path as the playlist hero: Kill Mode's filter, the everything-listened toast, the
    /// queue-replacement confirmation, and a real shuffle.
    private func perform(_ intent: AppModel.CollectionPlayIntent) async {
        do {
            let tracks = try await loadTracks()
            await app.playCollectionOrToast(
                tracks: tracks,
                source: .playlist(app.libraryPlaylist(id: playlist.id) ?? playlist),
                intent: intent
            )
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func addToPlaylist() async {
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            app.presentAddToPlaylist(tracks: tracks)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

/// Shared artwork preview size — used for both the contextMenu lift and the draggable drag preview
/// so the cover image stays continuous as the user transitions from long-press into a drag.
private let libraryCellLiftSize: CGFloat = 280

extension View {
    /// Long-press: zoomed artwork preview + Play / Shuffle / Play Next / Add to Playlist / Share.
    /// Per Apple docs, `.contextMenu` is applied first and `.draggable` second so the system
    /// can hand off the same lifted artwork into a drag-and-drop operation.
    func libraryAlbumContextMenu(_ album: AlbumSummary) -> some View {
        contextMenu {
            LibraryAlbumContextMenuContent(album: album)
        } preview: {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 16)
                .frame(width: libraryCellLiftSize, height: libraryCellLiftSize)
        }
        .draggable(album) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 16)
                .frame(width: libraryCellLiftSize, height: libraryCellLiftSize)
        }
    }

    /// Long-press on a Library hub pin tile — delegates to the regular context menu for the
    /// underlying type so pinned tiles match the rest of the app.
    @ViewBuilder
    func libraryPinnedItemContextMenu(_ item: LibraryPinnedItem, pinnedStorage: Binding<String>) -> some View {
        switch item {
        case .album(let album):
            self.libraryAlbumContextMenu(album)
        case .playlist(let playlist):
            self.libraryPlaylistContextMenu(playlist)
        case .track:
            self.contextMenu {
                Button(role: .destructive) {
                    LibraryPinStore.remove(item.pinRef, storage: &pinnedStorage.wrappedValue)
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
            }
        }
    }

    /// Long-press: dynamic home mixes get Play/Shuffle only; server playlists use the full menu.
    @ViewBuilder
    func homeMixOrPlaylistContextMenu(_ playlist: PlaylistSummary, app: AppModel) -> some View {
        if let mix = app.homeMix(forLibraryPlaylistId: playlist.id) {
            contextMenu {
                Button {
                    Task { await app.playHomeMix(mix, shuffle: false) }
                } label: {
                    Label("Play", systemImage: "play")
                }
                Button {
                    Task { await app.playHomeMix(mix, shuffle: true) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            } preview: {
                MixCollageArtworkView(
                    urls: mix.artworkURLs,
                    fallbackSeed: "homeMix:\(mix.id)",
                    cornerRadius: 16
                )
                .frame(width: libraryCellLiftSize, height: libraryCellLiftSize)
            }
        } else {
            libraryPlaylistContextMenu(playlist)
        }
    }

    /// Long-press: zoomed artwork preview + Play / Shuffle / Play Next / Pin / Add to Playlist / Share.
    func libraryPlaylistContextMenu(_ playlist: PlaylistSummary) -> some View {
        contextMenu {
            LibraryPlaylistContextMenuContent(playlist: playlist)
        } preview: {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: 16)
                .frame(width: libraryCellLiftSize, height: libraryCellLiftSize)
        }
        .draggable(playlist) {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: 16)
                .frame(width: libraryCellLiftSize, height: libraryCellLiftSize)
        }
    }
}
