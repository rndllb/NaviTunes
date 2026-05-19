import Foundation

/// On-disk copy of the last successful library sync for offline browsing and playback.
struct LibrarySnapshot: Codable {
    var albums: [AlbumSummary] = []
    var tracks: [Track] = []
    var playlists: [PlaylistSummary] = []
    var favoriteTrackIds: [String] = []
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

    static func save(_ snapshot: LibrarySnapshot) {
        guard let url = try? fileURL() else { return }
        var snap = snapshot
        snap.savedAt = Date()
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
