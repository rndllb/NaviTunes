import Foundation
import CryptoKit

// T125 alignment measurement. Counts how the artist page's discography suppression behaves now
// that external releases come from MusicBrainz instead of Lidarr.
//
// Server side is a real Navidrome (the public demo instance, Navidrome 0.63.2). MusicBrainz side
// is the shipping browse path. Title matching uses the shipping key functions, extracted verbatim.

func line(_ s: String = "") { print(s); fflush(stdout) }

struct ServerAlbum {
    let id: String
    let name: String
    let artist: String
    /// Subsonic `musicBrainzId` on an album. Measured to be a RELEASE id, not a release group id.
    let musicBrainzId: String?
}

enum Navidrome {
    static let base = "https://demo.navidrome.org/rest"
    static let user = "demo"
    static let pass = "demo"

    static func query() -> String {
        let salt = String(UUID().uuidString.prefix(8)).lowercased()
        let token = Insecure.MD5.hash(data: Data((pass + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "u=\(user)&t=\(token)&s=\(salt)&v=1.16.1&c=VellumT125&f=json"
    }

    static func get(_ path: String, _ extra: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(base)/\(path).view?\(query())&\(extra)")!)
        req.setValue("VellumT125/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj["subsonic-response"] as? [String: Any] ?? [:]
    }

    static func artistMBID(named name: String) async throws -> (id: String, mbid: String?)? {
        let r = try await get("getArtists", "")
        let indexes = (r["artists"] as? [String: Any])?["index"] as? [[String: Any]] ?? []
        for idx in indexes {
            for a in (idx["artist"] as? [[String: Any]] ?? []) where (a["name"] as? String) == name {
                let mbid = (a["musicBrainzId"] as? String)?.trimmingCharacters(in: .whitespaces)
                return (a["id"] as? String ?? "", (mbid?.isEmpty == false) ? mbid : nil)
            }
        }
        return nil
    }

    static func albums(forArtistId id: String) async throws -> [ServerAlbum] {
        let r = try await get("getArtist", "id=\(id)")
        let albums = (r["artist"] as? [String: Any])?["album"] as? [[String: Any]] ?? []
        return albums.map {
            let m = ($0["musicBrainzId"] as? String)?.trimmingCharacters(in: .whitespaces)
            return ServerAlbum(id: $0["id"] as? String ?? "",
                               name: $0["name"] as? String ?? "",
                               artist: $0["artist"] as? String ?? "",
                               musicBrainzId: (m?.isEmpty == false) ? m : nil)
        }
    }
}

/// Resolves a MusicBrainz *release* id to its *release group* id. Navidrome stores the release id,
/// while the browse endpoint that builds the discography returns release groups, so the two cannot
/// be compared without this hop.
func releaseGroupId(forRelease releaseId: String) async -> String? {
    guard let data = try? await MusicBrainzRequestQueue.shared.perform(
        path: "/release/\(releaseId)", query: [URLQueryItem(name: "inc", value: "release-groups")]
    ) else { return nil }
    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    return ((obj?["release-group"] as? [String: Any])?["id"] as? String)
}

/// Loose comparison used ONLY to spot pairs the shipping matcher misses. Strips the word suffixes
/// that `albumVersionBaseKey` only removes when they follow a dash.
func loosePairKey(_ raw: String) -> String {
    var t = AlbumSummaryMatch.normalizedAlbumTitleLoose(raw)
    let words = ["ep", "single", "album", "deluxe edition", "deluxe", "expanded edition",
                 "remastered", "remaster", "the remixes", "remixes"]
    var changed = true
    while changed {
        changed = false
        for w in words where t.hasSuffix(" " + w) {
            t = String(t.dropLast(w.count + 1)).trimmingCharacters(in: .whitespaces)
            changed = true
        }
    }
    return t
}

struct Report {
    var serverAlbums = 0, mbReleases = 0
    var matchedById = 0, matchedByTitle = 0, unmatched = 0
    var mbSuppressed = 0
    var duplicatePairs: [(String, String)] = []
}

@main
struct Align {
    static func main() async {
        line("=== T125 alignment count: server albums vs MusicBrainz discography ===")
        line("server: public Navidrome demo (0.63.2). matcher: shipping key functions, verbatim.")
        line("started \(ISO8601DateFormatter.mbLogFormatter.string(from: Date()))")
        line()

        for artistName in ["Nine Inch Nails", "Ugress", "Front 242"] {
            await measure(artistName)
        }
        await ReentryProbe.run()
    }

    static func measure(_ artistName: String) async {
        line("──────────────────────────────────────────────────────────────")
        line("ARTIST: \(artistName)")
        guard let found = try? await Navidrome.artistMBID(named: artistName) else {
            line("  not on the server, skipped"); return
        }
        guard let albums = try? await Navidrome.albums(forArtistId: found.id), !albums.isEmpty else {
            line("  no albums, skipped"); return
        }
        var rep = Report()
        rep.serverAlbums = albums.count
        line("  server albums: \(albums.count)   server artist MBID: \(found.mbid ?? "none")")

        // Resolve the artist MBID the same way the app does when the server has none.
        var artistMBID = found.mbid
        if artistMBID == nil {
            artistMBID = await MusicBrainzService.shared.resolveArtist(named: artistName)?.id
            line("  (server had no artist MBID; resolved by search to \(artistMBID ?? "nil"))")
        }
        guard let artistMBID else { line("  could not resolve artist, skipped"); return }

        await MusicBrainzRefreshLimiter.shared.reset()
        guard let disc = await MusicBrainzService.shared.discography(artistMBID: artistMBID, forceRefresh: true) else {
            line("  discography fetch failed, skipped"); return
        }
        rep.mbReleases = disc.releaseGroups.count
        line("  MusicBrainz release groups: \(disc.total) (complete=\(disc.isComplete))")

        // ---- id path: resolve each owned album's release id to its release group id.
        var ownedRGByAlbumId: [String: String] = [:]
        let withIds = albums.filter { $0.musicBrainzId != nil }
        line("  owned albums carrying a MusicBrainz id: \(withIds.count) of \(albums.count)")
        for a in withIds {
            if let rg = await releaseGroupId(forRelease: a.musicBrainzId!) {
                ownedRGByAlbumId[a.id] = rg
            }
        }
        let mbRGIds = Set(disc.releaseGroups.map(\.id))

        // ---- the shipping suppression, replayed exactly.
        var remoteByTitleKey: [String: MusicBrainzReleaseGroup] = [:]
        for rg in disc.releaseGroups {
            for k in AlbumSummaryMatch.discographyTitleKeys(for: rg.title) where remoteByTitleKey[k] == nil {
                remoteByTitleKey[k] = rg
            }
        }
        var suppressedRGIds = Set<String>()
        var unmatchedOwned: [ServerAlbum] = []
        for a in albums {
            if let rg = ownedRGByAlbumId[a.id], mbRGIds.contains(rg) {
                rep.matchedById += 1
                suppressedRGIds.insert(rg)
                continue
            }
            if let hit = AlbumSummaryMatch.discographyTitleKeys(for: a.name)
                .lazy.compactMap({ remoteByTitleKey[$0] }).first {
                rep.matchedByTitle += 1
                suppressedRGIds.insert(hit.id)
            } else {
                rep.unmatched += 1
                unmatchedOwned.append(a)
            }
        }
        rep.mbSuppressed = suppressedRGIds.count

        // ---- duplicates: an owned album and an MB release that are plainly the same release
        // but did not match, so both would render.
        for a in unmatchedOwned {
            let loose = loosePairKey(a.name)
            guard !loose.isEmpty else { continue }
            for rg in disc.releaseGroups where !suppressedRGIds.contains(rg.id) {
                if loosePairKey(rg.title) == loose {
                    rep.duplicatePairs.append((a.name, rg.title))
                    break
                }
            }
        }

        line()
        line("  RESULT")
        line("    MB releases suppressed as already-owned : \(rep.mbSuppressed) of \(rep.mbReleases)")
        line("    owned albums that matched nothing       : \(rep.unmatched) of \(rep.serverAlbums)")
        line("    split — matched by id                   : \(rep.matchedById)")
        line("    split — matched by title                : \(rep.matchedByTitle)")
        line("    split — not matched at all              : \(rep.unmatched)")
        if rep.duplicatePairs.isEmpty {
            line("    duplicate pairs (own it AND see it offered): none")
        } else {
            line("    duplicate pairs (own it AND see it offered): \(rep.duplicatePairs.count)")
            for (owned, mb) in rep.duplicatePairs {
                line("      owned \"\(owned)\"  vs  MusicBrainz \"\(mb)\"")
            }
        }
        if !unmatchedOwned.isEmpty {
            line("    owned albums matching nothing:")
            for a in unmatchedOwned { line("      \"\(a.name)\"") }
        }
        line()
    }
}

// MARK: - Re-entry cost

/// Measures what re-opening an artist page actually spends against MusicBrainz.
///
/// Reading the code says `.task` calls the non-forcing load, but that only covers the discography
/// fetch. The page also has to know *which* artist it is looking at, and resolving that by name is
/// its own request — so the honest measure is requests spent per open, not which function is called.
enum ReentryProbe {
    static func run() async {
        line("──────────────────────────────────────────────────────────────")
        line("RE-ENTRY COST (requests spent per artist-page open)")
        let name = "Nine Inch Nails"

        await MusicBrainzRefreshLimiter.shared.reset()
        await MusicBrainzRequestLog.shared.reset()
        let a0 = await MusicBrainzRequestLog.shared.snapshot().count
        guard let resolved = await MusicBrainzService.shared.resolveArtist(named: name) else {
            line("  could not resolve, skipped"); return
        }
        _ = await MusicBrainzService.shared.discography(artistMBID: resolved.id)
        let a1 = await MusicBrainzRequestLog.shared.snapshot().count
        line("  first open  (cold cache): \(a1 - a0) requests")

        // Second open: same path, nothing forced. This is "leave and come back".
        await MusicBrainzRefreshLimiter.shared.reset()
        let b0 = await MusicBrainzRequestLog.shared.snapshot().count
        guard let again = await MusicBrainzService.shared.resolveArtist(named: name) else { return }
        _ = await MusicBrainzService.shared.discography(artistMBID: again.id)
        let b1 = await MusicBrainzRequestLog.shared.snapshot().count
        line("  second open (warm cache): \(b1 - b0) requests   <- must be 0")

        // Third open with the name-resolution memo cleared, standing in for a relaunched app
        // where only the on-disk caches survive.
        await MusicBrainzService.shared.clearSessionMemoForVerification()
        await MusicBrainzRefreshLimiter.shared.reset()
        let c0 = await MusicBrainzRequestLog.shared.snapshot().count
        guard let third = await MusicBrainzService.shared.resolveArtist(named: name) else { return }
        _ = await MusicBrainzService.shared.discography(artistMBID: third.id)
        let c1 = await MusicBrainzRequestLog.shared.snapshot().count
        line("  after a relaunch (memo cleared, disk kept): \(c1 - c0) requests   <- must be 0")
        line()
    }
}
