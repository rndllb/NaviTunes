import Foundation
import CryptoKit

// T128 — "Request Discography" decision packet.
//
// Four numbers, all measured rather than reasoned about:
//   1. how big the request is, on the two artists named in the brief (Citizen, Nana Mouskouri)
//   2. what including singles & EPs costs over albums alone
//   3. how many already-owned releases the bulk request would wrongly ask for, on artists the
//      server actually holds part of the discography for
//   4. how many Lidarr calls the run issues, counted by the server that receives them
//
// MusicBrainz side is the shipping browse path (symlinked sources). Title matching is the
// shipping key functions, extracted verbatim in `Shims.swift`. Server side is the public
// Navidrome demo — a real Navidrome speaking real Subsonic, standing in for a library.

func line(_ s: String = "") { print(s); fflush(stdout) }

// MARK: - Server (public Navidrome demo)

struct ServerAlbum {
    let id: String
    let name: String
    /// Subsonic `musicBrainzId` on an album row: a RELEASE id, not a release-group id.
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
        return "u=\(user)&t=\(token)&s=\(salt)&v=1.16.1&c=VellumT128&f=json"
    }

    static func get(_ path: String, _ extra: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(base)/\(path).view?\(query())&\(extra)")!)
        req.setValue("VellumT128/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj["subsonic-response"] as? [String: Any] ?? [:]
    }

    static func artist(named name: String) async throws -> (id: String, mbid: String?)? {
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
                               musicBrainzId: (m?.isEmpty == false) ? m : nil)
        }
    }
}

/// Release id -> release-group id. Navidrome stores the release id; the browse endpoint the
/// discography is built from returns release groups, so the two cannot be compared without this.
func releaseGroupId(forRelease releaseId: String) async -> String? {
    guard let data = try? await MusicBrainzRequestQueue.shared.perform(
        path: "/release/\(releaseId)", query: [URLQueryItem(name: "inc", value: "release-groups")]
    ) else { return nil }
    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    return ((obj?["release-group"] as? [String: Any])?["id"] as? String)
}

// MARK: - The page's plan, replayed

/// Replays `ArtistViewModel.applyDiscography` + `makeDiscographyRequestPlan` for one artist.
///
/// The two loops below are the ownership decision as `ArtistViewModel.swift:965` makes it —
/// release-group id first, title keys second — followed by the two narrower suppressions
/// (live/compilation release groups are never offered; a single already present as a server
/// track is dropped). Nothing here is a second opinion about ownership: it is the same test in
/// the same order, run outside the view so it can be counted.
struct RequestPlan {
    var totalReleaseGroups = 0
    /// Every catalogue title for the artist, for the residual-risk pass.
    var allTitles: [String] = []
    var ownedServerAlbums = 0
    var suppressedAsOwned = 0
    var byBucket: [ArtistDiscographyBucket: [AcquisitionRelease]] = [:]
    /// Owned albums that matched no release group, and the release group that is plainly the same
    /// release — each one is a request the run would place for something already on the server.
    var wronglyRequested: [(owned: String, offered: String)] = []

    var requestable: [AcquisitionRelease] {
        ArtistDiscographyBucket.allCases.flatMap { byBucket[$0] ?? [] }
    }
    var albumsOnly: [AcquisitionRelease] { byBucket[.albums] ?? [] }
}

/// Loose comparison used ONLY to spot pairs the shipping matcher misses — never to decide
/// ownership. Strips suffix words the shipping key only strips when they end the title.
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

func buildPlan(
    releases: [AcquisitionRelease],
    ownedAlbums: [ServerAlbum],
    ownedReleaseGroupIdByAlbumId: [String: String]
) -> RequestPlan {
    var plan = RequestPlan()
    plan.totalReleaseGroups = releases.count
    plan.allTitles = releases.map(\.title)
    plan.ownedServerAlbums = ownedAlbums.count

    var ownedByReleaseGroupId: [String: ServerAlbum] = [:]
    var ownedByTitleKey: [String: ServerAlbum] = [:]
    for album in ownedAlbums {
        if let rg = ownedReleaseGroupIdByAlbumId[album.id], ownedByReleaseGroupId[rg] == nil {
            ownedByReleaseGroupId[rg] = album
        }
        for key in AlbumSummaryMatch.discographyTitleKeys(for: album.name) where ownedByTitleKey[key] == nil {
            ownedByTitleKey[key] = album
        }
    }

    var claimedAlbumIds = Set<String>()
    var offered: [AcquisitionRelease] = []
    for remote in releases {
        let bucket = remote.bucket
        let owned: ServerAlbum? = {
            if let rg = remote.releaseGroupMBID, !rg.isEmpty, let hit = ownedByReleaseGroupId[rg] { return hit }
            return AlbumSummaryMatch.discographyTitleKeys(for: remote.title)
                .lazy.compactMap { ownedByTitleKey[$0] }.first
        }()
        if let owned {
            guard claimedAlbumIds.insert(owned.id).inserted else { continue }
            plan.suppressedAsOwned += 1
            continue
        }
        guard bucket == .albums || bucket == .singlesAndEPs else { continue }
        plan.byBucket[bucket, default: []].append(remote)
        offered.append(remote)
    }

    // Owned albums that matched nothing, cross-checked against what is still being offered.
    for album in ownedAlbums where !claimedAlbumIds.contains(album.id) {
        let loose = loosePairKey(album.name)
        guard !loose.isEmpty else { continue }
        if let hit = offered.first(where: { loosePairKey($0.title) == loose }) {
            plan.wronglyRequested.append((owned: album.name, offered: hit.title))
        }
    }
    return plan
}

// MARK: - Report

func report(_ artistName: String, plan: RequestPlan) {
    let all = plan.requestable
    let albums = plan.albumsOnly
    let singles = plan.byBucket[.singlesAndEPs] ?? []
    line("──────────────────────────────────────────────────────────────")
    line("ARTIST: \(artistName)")
    line("  MusicBrainz release groups        : \(plan.totalReleaseGroups)")
    line("  server albums owned               : \(plan.ownedServerAlbums)")
    line("  suppressed as already-owned       : \(plan.suppressedAsOwned)")
    line("  dropped as live / compilation     : \(plan.totalReleaseGroups - plan.suppressedAsOwned - all.count)")
    line("  REQUEST DISCOGRAPHY would request : \(all.count)")
    line("     albums                         : \(albums.count)")
    line("     singles & EPs                  : \(singles.count)")
    line("  albums only  -> \(albums.count) requests")
    line("  albums + S&E -> \(all.count) requests   (difference: +\(all.count - albums.count))")
    if plan.wronglyRequested.isEmpty {
        line("  already-owned releases wrongly requested: 0")
    } else {
        line("  already-owned releases wrongly requested: \(plan.wronglyRequested.count)")
        for pair in plan.wronglyRequested {
            line("     owned \"\(pair.owned)\"  would be re-requested as  \"\(pair.offered)\"")
        }
    }
    line()
}

func measure(_ artistName: String) async -> RequestPlan? {
    let server = try? await Navidrome.artist(named: artistName)
    let ownedAlbums: [ServerAlbum]
    if let server, let list = try? await Navidrome.albums(forArtistId: server.id) {
        ownedAlbums = list
    } else {
        ownedAlbums = []
    }

    var artistMBID = server?.mbid
    if artistMBID == nil {
        artistMBID = await MusicBrainzService.shared.resolveArtist(named: artistName)?.id
    }
    guard let artistMBID else { line("ARTIST: \(artistName) — could not resolve, skipped"); return nil }

    await MusicBrainzRefreshLimiter.shared.reset()
    guard let disc = await MusicBrainzService.shared.discography(artistMBID: artistMBID, forceRefresh: true) else {
        line("ARTIST: \(artistName) — discography fetch failed, skipped"); return nil
    }

    var ownedRGByAlbumId: [String: String] = [:]
    for a in ownedAlbums where a.musicBrainzId != nil {
        if let rg = await releaseGroupId(forRelease: a.musicBrainzId!) { ownedRGByAlbumId[a.id] = rg }
    }

    let releases = disc.asAcquisitionReleases(artist: artistName)
    let plan = buildPlan(
        releases: releases,
        ownedAlbums: ownedAlbums,
        ownedReleaseGroupIdByAlbumId: ownedRGByAlbumId
    )
    report(artistName, plan: plan)
    return plan
}

// MARK: - Residual re-request risk, measured on real titles

/// How much of the "silently re-request something I own" risk is left after the bare-suffix
/// widening shipped.
///
/// The demo library holds 1–4 albums per artist, which is too thin to answer this by counting
/// duplicates on it. So the question is asked the other way round, on a large set of real
/// catalogue titles: **if the library held this exact release, tagged the way libraries actually
/// tag things, would the matcher still recognise it as owned?** Every "no" is a release the bulk
/// request would ask for again.
///
/// The variants are the ones that show up in real tagging, not invented stress cases.
enum ResidualRisk {
    /// `sameRelease: true` means the variant is a different *tagging* of the same release, so a
    /// miss is a wrong re-request. `false` is a control: a genuinely different release, where a
    /// miss is the correct answer and a match would be the bug.
    struct Variant {
        let name: String
        let sameRelease: Bool
        let apply: (String) -> String
    }

    static let variants: [Variant] = [
        Variant(name: "<title> EP", sameRelease: true) { "\($0) EP" },
        Variant(name: "<title> - EP", sameRelease: true) { "\($0) - EP" },
        Variant(name: "<title> Single", sameRelease: true) { "\($0) Single" },
        Variant(name: "<title> (Deluxe)", sameRelease: true) { "\($0) (Deluxe)" },
        Variant(name: "<title> (Deluxe Edition)", sameRelease: true) { "\($0) (Deluxe Edition)" },
        Variant(name: "<title> [Deluxe Edition]", sameRelease: true) { "\($0) [Deluxe Edition]" },
        Variant(name: "<title> Deluxe Edition", sameRelease: true) { "\($0) Deluxe Edition" },
        Variant(name: "<title> (Remastered)", sameRelease: true) { "\($0) (Remastered)" },
        Variant(name: "<title> Remastered", sameRelease: true) { "\($0) Remastered" },
        Variant(name: "<title> (2011 Remaster)", sameRelease: true) { "\($0) (2011 Remaster)" },
        Variant(name: "<title> (Bonus Track Version)", sameRelease: true) { "\($0) (Bonus Track Version)" },
        Variant(name: "<title> (Explicit)", sameRelease: true) { "\($0) (Explicit)" },
        Variant(name: "<title> (Expanded Edition)", sameRelease: true) { "\($0) (Expanded Edition)" },
        Variant(name: "<title>: Deluxe", sameRelease: true) { "\($0): Deluxe" },
        Variant(name: "<title> [control: Vol. 1]", sameRelease: false) { "\($0) Vol. 1" },
    ]

    /// The shipping suppression, asked once: does an owned album tagged `owned` collapse onto the
    /// catalogue title `catalog`?
    static func suppresses(owned: String, catalog: String) -> Bool {
        let ownedKeys = Set(AlbumSummaryMatch.discographyTitleKeys(for: owned))
        return AlbumSummaryMatch.discographyTitleKeys(for: catalog).contains { ownedKeys.contains($0) }
    }

    static func run(titlesByArtist: [(String, [String])]) {
        line("──────────────────────────────────────────────────────────────")
        line("RESIDUAL RE-REQUEST RISK (measured on real catalogue titles)")
        let all = titlesByArtist.flatMap(\.1)
        line("  real titles examined: \(all.count) across \(titlesByArtist.count) artists")
        line("  Each row asks: if the library held this exact release under this tagging, would")
        line("  the shipping matcher still see it as owned? A miss on a same-release row is a")
        line("  release the run would silently ask for again.")
        line()
        var worstSameRelease = 0
        for v in variants {
            let missed = all.filter { !suppresses(owned: v.apply($0), catalog: $0) }
            let pct = all.isEmpty ? 0 : Double(missed.count) * 100 / Double(all.count)
            if v.sameRelease { worstSameRelease = max(worstSameRelease, missed.count) }
            let name = v.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            if missed.isEmpty {
                line("    \(name)  suppressed: all \(all.count)      misses: 0")
            } else {
                line("    \(name)  misses: \(missed.count) (\(String(format: "%.1f", pct))%)  e.g. \"\(v.apply(missed[0]))\"")
            }
        }
        line()
        line("  worst same-release variant: \(worstSameRelease) of \(all.count) titles")
        line()
    }
}

// MARK: - Lidarr call count

/// Issues the plan through the **shipping** `LidarrAcquisitionPlugin.enqueue`, pointed at a
/// counting stub, and reads the count off the server that received the calls.
enum LidarrCost {
    static let port = 8787
    static var base: String { "http://127.0.0.1:\(port)" }

    static func counters() async -> [String: Any]? {
        guard let url = URL(string: "\(base)/__counters") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func reset() async {
        guard let url = URL(string: "\(base)/__reset") else { return }
        _ = try? await URLSession.shared.data(from: url)
    }

    /// Counters *and* the stub's library, so case A starts with nothing already added.
    static func wipe() async {
        guard let url = URL(string: "\(base)/__wipe") else { return }
        _ = try? await URLSession.shared.data(from: url)
    }

    static func run(artistName: String, releases: [AcquisitionRelease]) async {
        line("──────────────────────────────────────────────────────────────")
        line("LIDARR CALL COST — \(artistName), \(releases.count) releases")
        guard await counters() != nil else {
            line("  counting stub not running on \(base); skipped.")
            line("  start it with: python3 docs/verification/harness-t128/stub_lidarr_count.py \(port)")
            line()
            return
        }

        AcquisitionConfigStore.set(base, .lidarr, "baseURL")
        AcquisitionConfigStore.set("t128", .lidarr, "apiKey")
        let plugin = LidarrAcquisitionPlugin()
        guard plugin.isConfigured else { line("  plugin refused the config; skipped"); line(); return }

        // Case A: every album is new to Lidarr (the cold case — a discography nobody has asked
        // for before, which is exactly what this button is for).
        await wipe()
        var failures = 0
        for release in releases {
            do { _ = try await plugin.enqueue(release.acquisitionRequest) } catch { failures += 1 }
        }
        let a = await counters() ?? [:]
        printCounters("A. album new to Lidarr (every release)", a, releases: releases.count, failures: failures)

        // Case B: the same run again. Every album now exists in the stub's library, which is the
        // re-run / partially-requested case and takes the shorter branch of
        // `addOrSearchExistingAlbum`.
        await reset()
        failures = 0
        for release in releases {
            do { _ = try await plugin.enqueue(release.acquisitionRequest) } catch { failures += 1 }
        }
        let b = await counters() ?? [:]
        printCounters("B. album already in Lidarr (re-run)", b, releases: releases.count, failures: failures)
    }

    static func printCounters(_ label: String, _ c: [String: Any], releases: Int, failures: Int) {
        let total = (c["total"] as? Int) ?? 0
        line("  \(label)")
        line("     HTTP calls to Lidarr : \(total)")
        line("     per release          : \(releases == 0 ? 0 : total / releases) (\(String(format: "%.2f", releases == 0 ? 0 : Double(total) / Double(releases))))")
        if failures > 0 { line("     enqueues that threw  : \(failures)") }
        if let byPath = c["byPath"] as? [String: Int] {
            for key in byPath.keys.sorted() {
                line("       \(key)  ×\(byPath[key] ?? 0)")
            }
        }
        line()
    }
}

// MARK: - main

@main
struct Measure {
    static func main() async {
        line("=== T128 — Request Discography: decision packet ===")
        line("MusicBrainz: shipping browse path. matcher: shipping key functions, verbatim.")
        line("server: public Navidrome demo (read-only). Lidarr: local counting stub.")
        line("started \(ISO8601DateFormatter.mbLogFormatter.string(from: Date()))")
        line()

        line("### SCOPE — what the action requests, and what singles & EPs add")
        line()
        var citizenPlan: RequestPlan?
        var titlesByArtist: [(String, [String])] = []
        for name in ["Citizen", "Nana Mouskouri"] {
            let plan = await measure(name)
            if name == "Citizen" { citizenPlan = plan }
            if let plan { titlesByArtist.append((name, plan.allTitles)) }
        }

        line("### WRONGLY REQUESTED — artists whose discography the server partly holds")
        line()
        for name in ["Ugress", "Nine Inch Nails", "Front 242"] {
            if let plan = await measure(name) { titlesByArtist.append((name, plan.allTitles)) }
        }

        // Volume for the residual-risk pass: the demo library is too small to answer it by
        // counting duplicates, so it is answered against a large pool of real catalogue titles.
        line("### RESIDUAL RISK — fetching extra catalogues for volume")
        line()
        for name in ["Metallica", "Radiohead", "Weezer", "JAY-Z"] {
            if let plan = await measure(name) { titlesByArtist.append((name, plan.allTitles)) }
        }
        ResidualRisk.run(titlesByArtist: titlesByArtist)

        if let citizenPlan {
            await LidarrCost.run(artistName: "Citizen", releases: citizenPlan.requestable)
        }

        line("finished \(ISO8601DateFormatter.mbLogFormatter.string(from: Date()))")
    }
}
