import Foundation

/// Track lists for releases the user does not own, from MusicBrainz.
///
/// This is the only source that can answer the question at all. A request backend's catalog lookup
/// returns pressings with media and counts but never the tracks themselves — measured against a
/// live Lidarr, whose release rows carry `media` and `mediumCount` and `trackCount` and no `tracks`
/// key in any of them. That is structural rather than occasional: an album nobody has added yet has
/// no id on the backend to fetch tracks against, so there is nothing for it to return.
///
/// One request per release group. `inc=recordings` brings every pressing's track list back inline,
/// so choosing between pressings costs nothing extra.
enum AcquisitionTrackListMusicBrainzSource {
    /// Cache namespace. Distinct from any request backend's, because these track lists come from a
    /// different source and must not be served as though a backend had supplied them.
    static let cacheNamespace = "musicbrainz"

    /// Track list for a release group, cached permanently once found.
    static func tracks(releaseGroupMBID: String) async -> [BrowseAlbumPreviewTrack] {
        let mbid = releaseGroupMBID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mbid.count >= 36 else { return [] }

        let cacheKey = AcquisitionTrackListCache.key(pluginKind: cacheNamespace, releaseGroupMBID: mbid)
        if let cached = await AcquisitionTrackListCache.loadAsync(cacheKey) {
            return cached.rows.map(BrowseAlbumPreviewTrack.init(cached:))
        }

        guard let data = try? await MusicBrainzRequestQueue.shared.perform(
            path: "/release",
            query: [
                URLQueryItem(name: "release-group", value: mbid),
                URLQueryItem(name: "inc", value: "recordings+media"),
                URLQueryItem(name: "limit", value: "100"),
            ]
        ),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let releases = object["releases"] as? [[String: Any]]
        else { return [] }

        guard let chosen = preferredRelease(from: releases) else { return [] }
        let tracks = parseTracks(from: chosen)
        guard !tracks.isEmpty else { return [] }

        await AcquisitionTrackListCache.saveAsync(
            key: cacheKey,
            rows: tracks.map(\.cacheRow),
            releaseNote: (chosen["title"] as? String).map { title in
                "\(title) [\(chosen["id"] as? String ?? "?")]"
            }
        )
        return tracks
    }

    /// Picks which pressing supplies the list, on the same principle used for a request backend's
    /// releases: prefer the one the user is most likely to actually end up with, and prefer to
    /// under-promise when pressings disagree.
    ///
    /// 1. **Official status.** A bootleg or promo pressing can carry a track order nobody else has.
    ///    This is the closest analogue MusicBrainz has to "the release you will actually get".
    /// 2. **Single disc before multi-disc**, then **fewest tracks** — the standard edition rather
    ///    than a deluxe or a box set. Deliberately not the longest: bonus tracks that never arrive
    ///    read as a failed download, whereas a standard edition with extras reads as a bonus.
    /// 3. **A stable tie-break** on release id, so the same album shows the same track list on
    ///    every open rather than changing as MusicBrainz reorders its response.
    ///
    /// Track lists are never merged across pressings. A union would manufacture a track list no
    /// edition actually has and present it more confidently than any real one.
    static func preferredRelease(from releases: [[String: Any]]) -> [String: Any]? {
        let withTracks = releases.filter { trackCount($0) > 0 }
        guard !withTracks.isEmpty else { return nil }

        let official = withTracks.filter { ($0["status"] as? String)?.lowercased() == "official" }
        let pool = official.isEmpty ? withTracks : official

        return pool.min { a, b in
            let (da, db) = (mediaCount(a) <= 1 ? 0 : 1, mediaCount(b) <= 1 ? 0 : 1)
            if da != db { return da < db }
            let (ta, tb) = (trackCount(a), trackCount(b))
            if ta != tb { return ta < tb }
            return (a["id"] as? String ?? "") < (b["id"] as? String ?? "")
        }
    }

    private static func mediaCount(_ release: [String: Any]) -> Int {
        (release["media"] as? [[String: Any]])?.count ?? 0
    }

    private static func trackCount(_ release: [String: Any]) -> Int {
        (release["media"] as? [[String: Any]] ?? []).reduce(0) {
            $0 + (($1["tracks"] as? [[String: Any]])?.count ?? 0)
        }
    }

    /// Flattens a pressing's media into one ordered list. Multi-disc releases number their tracks
    /// from 1 on each disc, so positions are renumbered across the whole release rather than
    /// trusted verbatim — otherwise a two-disc album shows two track ones.
    private static func parseTracks(from release: [String: Any]) -> [BrowseAlbumPreviewTrack] {
        var out: [BrowseAlbumPreviewTrack] = []
        for medium in (release["media"] as? [[String: Any]] ?? []) {
            for track in (medium["tracks"] as? [[String: Any]] ?? []) {
                let recording = track["recording"] as? [String: Any]
                // Trimmed locally rather than via a shared string helper: this file deliberately
                // depends on as little of the MusicBrainz layer as possible.
                func nonEmpty(_ value: Any?) -> String? {
                    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !s.isEmpty else { return nil }
                    return s
                }
                guard let title = nonEmpty(track["title"]) ?? nonEmpty(recording?["title"]) else { continue }
                // MusicBrainz reports lengths in milliseconds, and often only on the recording.
                let millis = (track["length"] as? NSNumber)?.doubleValue
                    ?? (recording?["length"] as? NSNumber)?.doubleValue
                let id = (track["id"] as? String) ?? (recording?["id"] as? String) ?? "\(out.count)"
                out.append(BrowseAlbumPreviewTrack(
                    id: "mb-track:\(id)",
                    position: out.count + 1,
                    title: title,
                    duration: millis.map { $0 / 1000 }
                ))
            }
        }
        return out
    }
}
