import Foundation

/// An artist the user "follows". Vellum watches the active plugin's discography
/// (Lidarr library, or DroppedNeedle search) and auto-requests anything missing
/// from the connected server. Following works with **zero** plugins — without a
/// catalog the missing releases simply surface as a wishlist.
struct FollowedArtist: Codable, Identifiable, Hashable, Sendable {
    /// Stable id: the artist MBID when known, else a normalized-name fallback so the
    /// same artist isn't followed twice under different casing/punctuation.
    var id: String { artistMBID.map { "mbid:\($0)" } ?? "name:\(LibraryTrackMatcher.normalize(name))" }

    var name: String
    var artistMBID: String?
    var coverURL: URL?
    var dateFollowed: Date
    /// Release-group MBIDs we've already enqueued, so a re-check doesn't re-request them.
    var requestedReleaseIds: Set<String>
    var lastChecked: Date?

    init(
        name: String,
        artistMBID: String? = nil,
        coverURL: URL? = nil,
        dateFollowed: Date = Date(),
        requestedReleaseIds: Set<String> = [],
        lastChecked: Date? = nil
    ) {
        self.name = name
        self.artistMBID = artistMBID
        self.coverURL = coverURL
        self.dateFollowed = dateFollowed
        self.requestedReleaseIds = requestedReleaseIds
        self.lastChecked = lastChecked
    }
}

/// Per-release outcome the engine computed on its last pass. UI status only — not the
/// source of truth (that's the server catalog + `requestedReleaseIds`).
struct SubscriptionReleaseStatus: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case have        // already on the connected server — nothing to do
        case requested   // handed to the active acquisition plugin this/earlier pass
        case pending     // missing, but no plugin can fetch it (wishlist / graceful degradation)
    }

    /// Release-group MBID.
    var id: String
    var title: String
    var year: Int?
    var coverURL: URL?
    var state: State
}

/// On-disk store for followed artists. Mirrors `LibrarySnapshotStore`'s file layout
/// (`Application Support/VellumMusic/…`) so persisted "wanted" state survives relaunches
/// and never depends on any plugin being present.
enum MusicSubscriptionStore {
    private static let filename = "subscriptions.json"

    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("VellumMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static func load() -> [FollowedArtist] {
        guard let url = try? fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([FollowedArtist].self, from: data)
        else { return [] }
        return items
    }

    static func save(_ items: [FollowedArtist]) {
        guard let url = try? fileURL(),
              let data = try? JSONEncoder().encode(items)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
