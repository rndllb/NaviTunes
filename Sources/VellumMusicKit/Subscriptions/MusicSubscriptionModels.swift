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
    /// What the last completeness pass found, kept so the Following list can show it straight
    /// after a relaunch instead of "Nothing missing" until a new pass finishes. Optional, so a
    /// file written before this existed still decodes.
    var lastStatuses: [SubscriptionReleaseStatus]?

    init(
        name: String,
        artistMBID: String? = nil,
        coverURL: URL? = nil,
        dateFollowed: Date = Date(),
        requestedReleaseIds: Set<String> = [],
        lastChecked: Date? = nil,
        lastStatuses: [SubscriptionReleaseStatus]? = nil
    ) {
        self.name = name
        self.artistMBID = artistMBID
        self.coverURL = coverURL
        self.dateFollowed = dateFollowed
        self.requestedReleaseIds = requestedReleaseIds
        self.lastChecked = lastChecked
        self.lastStatuses = lastStatuses
    }

    /// Whether this follow is the artist named `name` (with `mbid` when known).
    ///
    /// The artist page learns an MBID only once the request plugin answers, so the same artist
    /// arrives first by name and later by MBID. Comparing `id`s made those two different
    /// artists: the bell showed "not following" for someone already followed, and a second tap
    /// followed them twice. Two MBIDs that disagree are two artists, even with one name.
    func matches(name: String, mbid: String?) -> Bool {
        if let mbid, let artistMBID { return mbid == artistMBID }
        let target = LibraryTrackMatcher.normalize(name)
        return !target.isEmpty && LibraryTrackMatcher.normalize(self.name) == target
    }
}

/// Per-release outcome the engine computed on its last pass. UI status only — not the
/// source of truth (that's the server catalog + `requestedReleaseIds`).
struct SubscriptionReleaseStatus: Identifiable, Hashable, Sendable, Codable {
    enum State: String, Sendable, Codable {
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

/// Where the engine keeps followed artists. The app uses ``disk``; tests pass an in-memory pair.
struct MusicSubscriptionPersistence {
    var load: () -> [FollowedArtist]
    var save: ([FollowedArtist]) -> Void

    static let disk = MusicSubscriptionPersistence(
        load: { MusicSubscriptionStore.load() },
        save: { MusicSubscriptionStore.save($0) }
    )
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
