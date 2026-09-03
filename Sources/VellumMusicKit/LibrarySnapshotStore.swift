import Foundation

/// On-disk copy of the last successful library sync for offline browsing and playback.
struct LibrarySnapshot: Codable {
    var albums: [AlbumSummary] = []
    var tracks: [Track] = []
    var playlists: [PlaylistSummary] = []
    var favoriteTrackIds: [String] = []
    /// Resolved server-side id of the user's "Vellum Library" magic playlist. Cached so
    /// the Library tab can render the user's curated set immediately on cold launch
    /// without waiting for ``AppModel.refreshLibraryMembership`` to round-trip.
    var libraryMagicPlaylistId: String?
    /// Song IDs in the user's library (mirror of the magic playlist's tracks).
    var librarySongIds: [String] = []
    /// Album-level library membership with per-album add dates (mirror of the magic
    /// playlist's `comment` payload).
    var libraryAlbumEntries: [LibraryMembershipPayload.Entry] = []
    /// Playlist-level library membership (mirror of `comment.playlists`).
    var libraryPlaylistEntries: [LibraryMembershipPayload.Entry] = []
    var savedAt: Date = .distantPast
    /// Schema stamp — see ``PersistedModelSchema``. Defaults to `0` so a snapshot written before
    /// this existed decodes cleanly and is then rejected as too old, rather than failing to decode.
    var schemaVersion: Int = 0
}

enum LibrarySnapshotStore {
    private static let filename = "library-snapshot.json"
    private static let writeLock = NSLock()
    private static var writeGeneration: UInt64 = 0

    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent("VellumMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static func load() -> LibrarySnapshot? {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        else { return nil }
        // A snapshot written by an older schema decodes fine and is quietly wrong — it carries
        // `nil` for fields added since. Treated as a miss so it refills from the server.
        guard snap.schemaVersion >= PersistedModelSchema.current else { return nil }
        return snap
    }

    /// Off-main JSON decode + disk read. Use from app startup so the main thread
    /// stays free while the (potentially multi-MB) snapshot deserializes.
    static func loadAsync() async -> LibrarySnapshot? {
        await Task.detached(priority: .userInitiated) { load() }.value
    }

    static func save(_ snapshot: LibrarySnapshot) {
        writeLock.lock()
        let generation = writeGeneration
        writeLock.unlock()
        guard let url = try? fileURL() else { return }
        var snap = snapshot
        snap.savedAt = Date()
        snap.schemaVersion = PersistedModelSchema.current
        guard let data = try? JSONEncoder().encode(snap) else { return }
        writeLock.lock()
        let stillCurrent = generation == writeGeneration
        writeLock.unlock()
        guard stillCurrent else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Off-main JSON encode + atomic write. Callers should hand off a value snapshot
    /// captured on the main actor; the encode happens on a background priority task.
    static func saveAsync(_ snapshot: LibrarySnapshot) {
        writeLock.lock()
        let generation = writeGeneration
        writeLock.unlock()
        Task.detached(priority: .utility) {
            writeLock.lock()
            let stillCurrent = generation == writeGeneration
            writeLock.unlock()
            guard stillCurrent else { return }
            save(snapshot)
        }
    }

    static func clear() {
        writeLock.lock()
        writeGeneration &+= 1
        writeLock.unlock()
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func entryCountAsync() async -> Int {
        guard let snap = await loadAsync() else { return 0 }
        return snap.albums.count + snap.playlists.count + snap.tracks.count
    }

    static func entryCount() -> Int {
        guard let snap = load() else { return 0 }
        return snap.albums.count + snap.playlists.count + snap.tracks.count
    }

    static func metadataEntries() -> [LibraryMetadataEntry] {
        guard let snap = load() else { return [] }
        var out: [LibraryMetadataEntry] = []
        out.reserveCapacity(snap.albums.count + snap.playlists.count)

        for album in snap.albums {
            out.append(LibraryMetadataEntry(
                id: "album:\(album.id)",
                kind: .album,
                title: album.title,
                subtitle: album.artist,
                artworkURL: album.artworkURL,
                savedAt: snap.savedAt,
            ))
        }
        for playlist in snap.playlists {
            out.append(LibraryMetadataEntry(
                id: "playlist:\(playlist.id)",
                kind: .playlist,
                title: playlist.name,
                subtitle: playlist.songCount.map { "\($0) songs" } ?? "Playlist",
                artworkURL: playlist.artworkURL,
                savedAt: snap.savedAt,
            ))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func removeMetadataEntry(id: String) {
        guard var snap = load() else { return }
        if id.hasPrefix("album:") {
            let albumId = String(id.dropFirst("album:".count))
            snap.albums.removeAll { $0.id == albumId }
            snap.tracks.removeAll { $0.albumId == albumId }
        } else if id.hasPrefix("playlist:") {
            let playlistId = String(id.dropFirst("playlist:".count))
            snap.playlists.removeAll { $0.id == playlistId }
        } else {
            return
        }
        save(snap)
    }
}
