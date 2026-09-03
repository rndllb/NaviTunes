import Foundation

/// On-disk cache of track lists fetched from a request backend, keyed by MusicBrainz
/// release-group id.
///
/// **Deliberately not under the freshness rule that governs the rest of the metadata caches.**
/// A published release's track list is immutable: the songs on a record that came out in 1996 are
/// the songs on it now. Re-fetching on a weekly timer would spend requests to learn nothing, and
/// each of those requests is a catalog lookup against a backend whose text-search path is already
/// known to fail. So an entry here has no expiry and is never refreshed on age alone.
///
/// The one thing that must not be cached is a *miss*. An empty result means the lookup failed or
/// the backend did not know the release yet — both are transient, and pinning them permanently
/// would turn a momentary outage into an album that never shows a track list again. Only non-empty
/// lists are written.
enum AcquisitionTrackListCache {
    /// One cached track list.
    struct Entry: Codable, Sendable {
        struct Row: Codable, Sendable {
            var id: String
            var position: Int
            var title: String
            var duration: TimeInterval?
        }

        var key: String
        var fetchedAt: Date
        var rows: [Row]
        /// Which release inside the group these tracks came from, and why it was chosen. Recorded
        /// so a surprising track list can be explained later without re-running the selection.
        var releaseNote: String?
    }

    /// Key for a track list. The plugin kind is part of it because two backends can disagree about
    /// the same release group, and a list fetched from one must not be served as the other's.
    static func key(pluginKind: String, releaseGroupMBID: String) -> String {
        "\(pluginKind):\(releaseGroupMBID)"
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("VellumMusic", isDirectory: true)
            .appendingPathComponent("tracklists", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for key: String) throws -> URL {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let safe = String(key.map { allowed.contains($0) ? $0 : "_" })
        return try directory().appendingPathComponent(safe + ".json")
    }

    static func load(_ key: String) -> Entry? {
        guard let url = try? fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.key == key,
              !entry.rows.isEmpty
        else { return nil }
        return entry
    }

    static func loadAsync(_ key: String) async -> Entry? {
        await Task.detached(priority: .userInitiated) { load(key) }.value
    }

    /// Writes a track list. Refuses empty lists — see the note on the type.
    @discardableResult
    static func save(key: String, rows: [Entry.Row], releaseNote: String?) -> Bool {
        guard !rows.isEmpty, let url = try? fileURL(for: key) else { return false }
        let entry = Entry(key: key, fetchedAt: Date(), rows: rows, releaseNote: releaseNote)
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    @discardableResult
    static func saveAsync(key: String, rows: [Entry.Row], releaseNote: String?) async -> Bool {
        await Task.detached(priority: .utility) { save(key: key, rows: rows, releaseNote: releaseNote) }.value
    }

    /// Drops everything. Wired to the app's cache clearing, which is the only case where removing
    /// an immutable answer is the right call — the user asking to reclaim disk.
    static func clearAll() {
        guard let dir = try? directory() else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension BrowseAlbumPreviewTrack {
    init(cached row: AcquisitionTrackListCache.Entry.Row) {
        self.init(id: row.id, position: row.position, title: row.title, duration: row.duration)
    }

    var cacheRow: AcquisitionTrackListCache.Entry.Row {
        .init(id: id, position: position, title: title, duration: duration)
    }
}
