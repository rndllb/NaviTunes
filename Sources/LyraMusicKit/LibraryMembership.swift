import CryptoKit
import Foundation

/// Identity + storage layer for the per-user "Lyra Library" magic playlist.
///
/// The library magic playlist is a private, opaque-named playlist Lyra creates on
/// the active Jellyfin / Navidrome backend the first time the user signs in. It
/// holds:
///
///   * **Tracks** — the songs the user has added to their Lyra library.
///   * **Comment** (Jellyfin: `Overview`) — JSON-encoded ``LibraryMembershipPayload``
///     listing album/playlist library membership with per-item add dates.
///
/// Membership is the single source of truth across devices; the local
/// ``UserDefaults`` entry only caches the resolved playlist id for fast startup.
enum LibraryMembership {
    /// `__lyra_<sha256(host/user)[0..12]>` — deterministic per (backend, host, user).
    /// Same input → same name on every device, so find-or-create converges across logins.
    static func magicPlaylistName(backend: BackendKind, host: String?, userKey: String) -> String {
        let normalizedHost = (host ?? "").lowercased()
        let normalizedUser = userKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seed = "\(backend.rawValue)/\(normalizedHost)/\(normalizedUser)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "__lyra_\(hex.prefix(12))"
    }

    /// True for names produced by ``magicPlaylistName(backend:host:userKey:)``. Used to
    /// strip the magic playlist out of any user-facing playlist listing even when the
    /// cached id is stale.
    static func isMagicPlaylistName(_ name: String) -> Bool {
        guard name.hasPrefix("__lyra_") else { return false }
        let suffix = name.dropFirst("__lyra_".count)
        return suffix.count == 12 && suffix.allSatisfy(\.isHexDigit)
    }

    // MARK: - Cached playlist id (UserDefaults)

    private static func defaultsKey(backend: BackendKind, host: String?, userKey: String) -> String {
        let normalizedHost = (host ?? "").lowercased()
        let normalizedUser = userKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "LyraMusic.libraryPlaylistId.\(backend.rawValue).\(normalizedHost).\(normalizedUser)"
    }

    static func cachedPlaylistId(backend: BackendKind, host: String?, userKey: String) -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey(backend: backend, host: host, userKey: userKey))
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func cachePlaylistId(_ id: String, backend: BackendKind, host: String?, userKey: String) {
        UserDefaults.standard.set(id, forKey: defaultsKey(backend: backend, host: host, userKey: userKey))
    }

    static func clearCachedPlaylistId(backend: BackendKind, host: String?, userKey: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(backend: backend, host: host, userKey: userKey))
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}

/// JSON payload stored in the magic playlist's `comment` (Subsonic) / `Overview` (Jellyfin)
/// field. Tracks album- and playlist-level library membership with per-item add dates so
/// "Recently Added" reflects the moment the user added each entity, not when the server
/// scanned it.
struct LibraryMembershipPayload: Codable, Equatable {
    struct Entry: Codable, Equatable, Hashable {
        let id: String
        let added: Date
    }

    var albums: [Entry]
    var playlists: [Entry]
    /// Schema version for forward compatibility — newer clients can detect older payloads
    /// and migrate without clobbering. Kept small so the JSON stays compact.
    var v: Int

    init(albums: [Entry] = [], playlists: [Entry] = [], v: Int = 1) {
        self.albums = albums
        self.playlists = playlists
        self.v = v
    }

    static let empty = LibraryMembershipPayload()

    /// Tolerant decode — an absent or malformed comment field becomes an empty payload
    /// rather than blocking sign-in. Callers re-encode and write a clean payload on the
    /// next mutation.
    static func decode(_ raw: String?) -> LibraryMembershipPayload {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LibraryMembershipPayload.self, from: data)) ?? .empty
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let str = String(data: data, encoding: .utf8) else {
            return "{\"albums\":[],\"playlists\":[],\"v\":1}"
        }
        return str
    }

    mutating func upsertAlbum(id: String, addedAt date: Date = Date()) {
        if albums.contains(where: { $0.id == id }) { return }
        albums.append(Entry(id: id, added: date))
    }

    mutating func removeAlbum(id: String) {
        albums.removeAll { $0.id == id }
    }

    mutating func upsertPlaylist(id: String, addedAt date: Date = Date()) {
        if playlists.contains(where: { $0.id == id }) { return }
        playlists.append(Entry(id: id, added: date))
    }

    mutating func removePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
    }
}
