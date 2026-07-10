import CryptoKit
import Foundation

/// Identity + storage layer for the per-user "Vellum Library" magic playlist.
///
/// The library magic playlist is a private, opaque-named playlist Vellum creates on
/// the active Jellyfin / Navidrome backend the first time the user signs in. It
/// holds:
///
///   * **Tracks** — the songs the user has added to their Vellum library.
///   * **Comment** (Jellyfin: `Overview`) — JSON-encoded ``LibraryMembershipPayload``
///     listing album/playlist library membership with per-item add dates.
///
/// Membership is the single source of truth across devices; the local
/// ``UserDefaults`` entry only caches the resolved playlist id for fast startup.
enum LibraryMembership {
    /// Stable server identity for hashing — host plus non-default port so
    /// `https://music.example.com:4533` and `https://music.example.com` match when
    /// they point at the same Navidrome/Jellyfin instance (as long as URLs agree).
    static func normalizedServerKey(from url: URL) -> String {
        let host = (url.host ?? url.absoluteString).lowercased()
        if let port = url.port, port != 80, port != 443 {
            return "\(host):\(port)"
        }
        return host
    }

    static func normalizedServerKey(from baseURLString: String) -> String? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return normalizedServerKey(from: url)
    }

    /// `__vellum_<sha256(server/user)[0..12]>` — deterministic per (backend, server, user).
    /// Same input → same name on every device, so find-or-create converges across logins.
    static func magicPlaylistName(backend: BackendKind, serverKey: String?, userKey: String) -> String {
        let normalizedServer = (serverKey ?? "").lowercased()
        let normalizedUser = userKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seed = "\(backend.rawValue)/\(normalizedServer)/\(normalizedUser)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "__vellum_\(hex.prefix(12))"
    }

    /// Names to probe on the server, newest canonical first. Includes a legacy host-only
    /// hash so devices that used an older Vellum build still find the same playlist.
    static func candidateMagicPlaylistNames(
        backend: BackendKind,
        serverKey: String?,
        userKey: String,
        baseURLString: String,
    ) -> [String] {
        var names: [String] = []
        func append(_ name: String) {
            if !names.contains(name) { names.append(name) }
        }
        append(magicPlaylistName(backend: backend, serverKey: serverKey, userKey: userKey))
        if let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
           let hostOnly = url.host?.lowercased() {
            let legacy = magicPlaylistName(backend: backend, serverKey: hostOnly, userKey: userKey)
            append(legacy)
        }
        return names
    }

    /// Pre-rebrand equivalents of the current candidate names — same hash, old `__lyra_`
    /// prefix. The magic-playlist hash never included the app name (only backend/server/user),
    /// so the Lyra → Vellum rename only changed the prefix. A one-time migration uses these to
    /// find the user's existing `__lyra_…` playlist and rename it to `__vellum_…`.
    static func legacyLyraMagicPlaylistNames(
        backend: BackendKind,
        serverKey: String?,
        userKey: String,
        baseURLString: String,
    ) -> [String] {
        candidateMagicPlaylistNames(
            backend: backend, serverKey: serverKey, userKey: userKey, baseURLString: baseURLString,
        ).map { $0.replacingOccurrences(of: "__vellum_", with: "__lyra_") }
    }

    /// True for names produced by ``magicPlaylistName(backend:serverKey:userKey:)``. Used to
    /// strip the magic playlist out of any user-facing playlist listing even when the
    /// cached id is stale.
    static func isMagicPlaylistName(_ name: String) -> Bool {
        guard name.hasPrefix("__vellum_") else { return false }
        let suffix = name.dropFirst("__vellum_".count)
        return suffix.count == 12 && suffix.allSatisfy(\.isHexDigit)
    }

    // MARK: - Cached playlist id (UserDefaults)

    private static func defaultsKey(backend: BackendKind, serverKey: String?, userKey: String) -> String {
        let normalizedServer = (serverKey ?? "").lowercased()
        let normalizedUser = userKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "VellumMusic.libraryPlaylistId.\(backend.rawValue).\(normalizedServer).\(normalizedUser)"
    }

    static func cachedPlaylistId(backend: BackendKind, serverKey: String?, userKey: String) -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey(backend: backend, serverKey: serverKey, userKey: userKey))
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func cachePlaylistId(_ id: String, backend: BackendKind, serverKey: String?, userKey: String) {
        UserDefaults.standard.set(id, forKey: defaultsKey(backend: backend, serverKey: serverKey, userKey: userKey))
    }

    static func clearCachedPlaylistId(backend: BackendKind, serverKey: String?, userKey: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(backend: backend, serverKey: serverKey, userKey: userKey))
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
