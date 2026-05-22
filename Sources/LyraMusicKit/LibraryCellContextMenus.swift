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

        if app.isAlbumInLibrary(album.id) {
            Section {
                Button(role: .destructive) {
                    Task { await app.removeAlbumFromLibrary(album) }
                } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
            }
            .tint(MusicDesign.destructiveAction)
        }

        Section {
            ShareLink(item: "\(album.title) — \(album.artist)") {
                Label("Share Album", systemImage: "square.and.arrow.up")
            }
        }
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

    private func play() async {
        guard let lib = app.activeLibrary else { return }
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            try await app.player.playAlbum(library: lib, tracks: tracks, startIndex: 0)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func shuffle() async {
        guard let lib = app.activeLibrary else { return }
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            try await app.player.playAlbum(library: lib, tracks: tracks.shuffled(), startIndex: 0)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func playNext() async {
        guard let lib = app.activeLibrary else { return }
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            try await app.player.playTracksNext(library: lib, tracks: tracks)
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

        if app.isPlaylistInLibrary(playlist.id) {
            Section {
                Button(role: .destructive) {
                    Task { await app.removePlaylistFromLibrary(playlist) }
                } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
            }
            .tint(MusicDesign.destructiveAction)
        }

        Section {
            ShareLink(item: playlist.name) {
                Label("Share Playlist", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func loadTracks() async throws -> [Track] {
        let rows = try await app.fetchPlaylistRows(playlistId: playlist.id)
        return rows.map(\.track)
    }

    private func play() async {
        guard let lib = app.activeLibrary else { return }
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            try await app.player.playAlbum(
                library: lib,
                tracks: tracks,
                startIndex: 0,
                source: .playlist(playlist)
            )
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func shuffle() async {
        guard let lib = app.activeLibrary else { return }
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            try await app.player.playAlbum(
                library: lib,
                tracks: tracks.shuffled(),
                startIndex: 0,
                source: .playlist(playlist)
            )
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func playNext() async {
        guard let lib = app.activeLibrary else { return }
        do {
            let tracks = try await loadTracks()
            guard !tracks.isEmpty else { return }
            try await app.player.playTracksNext(library: lib, tracks: tracks, sourcePlaylistId: playlist.id)
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

    /// Long-press on a Library hub pin tile — unpin only (navigation is a tap).
    func libraryPinnedItemContextMenu(_ item: LibraryPinnedItem, pinnedStorage: Binding<String>) -> some View {
        contextMenu {
            Button(role: .destructive) {
                LibraryPinStore.remove(item.pinRef, storage: &pinnedStorage.wrappedValue)
            } label: {
                Label(
                    LibraryPinStore.menuLabel(for: item, isPinned: true),
                    systemImage: "pin.slash"
                )
            }
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
