import Foundation

/// On-disk copy of the last successful library sync for offline browsing and playback.
struct LibrarySnapshot: Codable {
    var albums: [AlbumSummary] = []
    var tracks: [Track] = []
    var playlists: [PlaylistSummary] = []
    var favoriteTrackIds: [String] = []
    /// Resolved server-side id of the user's "Lyra Library" magic playlist. Cached so
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
}

enum LibrarySnapshotStore {
    private static let filename = "library-snapshot.json"

    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let dir = base.appendingPathComponent("LyraMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static func load() -> LibrarySnapshot? {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        else { return nil }
        return snap
    }

    /// Off-main JSON decode + disk read. Use from app startup so the main thread
    /// stays free while the (potentially multi-MB) snapshot deserializes.
    static func loadAsync() async -> LibrarySnapshot? {
        await Task.detached(priority: .userInitiated) { load() }.value
    }

    static func save(_ snapshot: LibrarySnapshot) {
        guard let url = try? fileURL() else { return }
        var snap = snapshot
        snap.savedAt = Date()
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Off-main JSON encode + atomic write. Callers should hand off a value snapshot
    /// captured on the main actor; the encode happens on a background priority task.
    static func saveAsync(_ snapshot: LibrarySnapshot) {
        Task.detached(priority: .utility) { save(snapshot) }
    }

    static func clear() {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
