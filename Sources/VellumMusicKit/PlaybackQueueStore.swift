import Foundation

/// On-disk copy of the in-flight playback queue so the user can close the app
/// and resume where they left off (paused, at the track + position they stopped at).
struct PlaybackQueueSnapshot: Codable {
    var queue: [Track]
    var currentIndex: Int
    var position: TimeInterval
    var playlistSource: PlaylistSummary?
    var shuffle: Bool
    var repeatMode: String
    var savedAt: Date
    /// Pre-shuffle queue order — restored so toggling shuffle off after relaunch returns
    /// the queue to its natural order.
    var unshuffledQueue: [Track]? = nil
    /// Natural ordered track list from the most recently loaded source — used to detect
    /// manual queue reordering and to restore order when shuffle is disabled.
    var sourceQueueOrder: [Track]? = nil
}

enum PlaybackQueueStore {
    private static let filename = "playback-queue.json"

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

    static func load() -> PlaybackQueueSnapshot? {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data)
        else { return nil }
        return snap
    }

    static func save(_ snapshot: PlaybackQueueSnapshot) {
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
