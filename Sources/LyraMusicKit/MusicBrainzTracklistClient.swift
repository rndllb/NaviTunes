import Foundation

/// Fetches a readable track list from MusicBrainz (release group → official-ish release → recordings).
enum MusicBrainzTracklistClient {
    private static let userAgent = "LyraMusic/1.0 (https://github.com/randll)"

    /// Best-effort lookup of a **release group** id from artist + album (or single) title via MusicBrainz search.
    static func findReleaseGroupId(artist: String, albumTitle: String) async -> String? {
        let artistT = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumT = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistT.isEmpty, !albumT.isEmpty else { return nil }

        let escapedArtist = artistT.replacingOccurrences(of: "\"", with: "")
        let escapedAlbum = albumT.replacingOccurrences(of: "\"", with: "")
        let query = "artist:\"\(escapedArtist)\" AND releasegroup:\"\(escapedAlbum)\""

        guard var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release-group") else {
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = comps.url else { return nil }

        do {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, res) = try await URLSession.shared.data(for: req)
            guard let http = res as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let groups = obj["release-groups"] as? [[String: Any]] ?? []
            guard let first = groups.first, let id = first["id"] as? String else { return nil }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// `releaseGroupId` is a MusicBrainz **release group** UUID (same family Lidarr uses as `foreignAlbumId`).
    static func tracksForReleaseGroup(_ releaseGroupId: String) async -> [BrowseAlbumPreviewTrack] {
        let rg = releaseGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rg.count >= 36 else { return [] }

        guard let rgURL = URL(string: "https://musicbrainz.org/ws/2/release-group/\(rg)?inc=releases&fmt=json") else {
            return []
        }

        do {
            var rgReq = URLRequest(url: rgURL)
            rgReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (rgData, rgResp) = try await URLSession.shared.data(for: rgReq)
            guard let http = rgResp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return [] }
            guard let obj = try JSONSerialization.jsonObject(with: rgData) as? [String: Any] else { return [] }
            let releases: [[String: Any]]?
            if let r = obj["releases"] as? [[String: Any]] {
                releases = r
            } else if let rg = obj["release-group"] as? [String: Any],
                      let r = rg["releases"] as? [[String: Any]] {
                releases = r
            } else {
                releases = nil
            }
            guard let releaseList = releases,
                  let releaseId = preferredReleaseId(from: releaseList)
            else {
                return []
            }

            try await Task.sleep(nanoseconds: 350_000_000)

            guard let relURL = URL(string: "https://musicbrainz.org/ws/2/release/\(releaseId)?inc=recordings&fmt=json") else {
                return []
            }
            var relReq = URLRequest(url: relURL)
            relReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (relData, relResp) = try await URLSession.shared.data(for: relReq)
            guard let http2 = relResp as? HTTPURLResponse, (200 ..< 300).contains(http2.statusCode) else { return [] }
            guard let relObj = try JSONSerialization.jsonObject(with: relData) as? [String: Any],
                  let media = relObj["media"] as? [[String: Any]]
            else {
                return []
            }

            return tracks(fromMedia: media)
        } catch {
            return []
        }
    }

    private static func preferredReleaseId(from releases: [[String: Any]]) -> String? {
        let official = releases.filter { (($0["status"] as? String) ?? "").localizedCaseInsensitiveCompare("Official") == .orderedSame }
        let pool = official.isEmpty ? releases : official
        let sorted = pool.sorted {
            let da = ($0["date"] as? String) ?? ""
            let db = ($1["date"] as? String) ?? ""
            if da != db { return da < db }
            let ta = ($0["title"] as? String) ?? ""
            let tb = ($1["title"] as? String) ?? ""
            return ta < tb
        }
        guard let id = sorted.first?["id"] as? String else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tracks(fromMedia media: [[String: Any]]) -> [BrowseAlbumPreviewTrack] {
        var rows: [BrowseAlbumPreviewTrack] = []
        var global = 0

        for medium in media.sorted(by: { jsonInt($0["position"]) < jsonInt($1["position"]) }) {
            guard let trackArr = medium["tracks"] as? [[String: Any]] else { continue }
            let sortedTracks = trackArr.sorted {
                let pa = trackSortKey($0)
                let pb = trackSortKey($1)
                return pa < pb
            }
            for tr in sortedTracks {
                global += 1
                let posVal = jsonInt(tr["position"])
                let numVal = jsonInt(tr["number"])
                let displayNum = posVal > 0 ? posVal : (numVal > 0 ? numVal : global)

                let title: String = {
                    if let t = tr["title"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return t
                    }
                    if let rec = tr["recording"] as? [String: Any],
                       let t = rec["title"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return t
                    }
                    return "Track \(displayNum)"
                }()

                let lengthMs: Int? = {
                    if let i = tr["length"] as? Int { return i }
                    if let i = tr["length"] as? NSNumber { return i.intValue }
                    if let rec = tr["recording"] as? [String: Any] {
                        if let i = rec["length"] as? Int { return i }
                        if let i = rec["length"] as? NSNumber { return i.intValue }
                    }
                    return nil
                }()

                let dur = lengthMs.map { TimeInterval($0) / 1000.0 }

                let recId = (tr["recording"] as? [String: Any])?["id"] as? String
                let tid = tr["id"] as? String
                let stable = recId ?? tid ?? "mb-row-\(global)"
                rows.append(BrowseAlbumPreviewTrack(id: stable, position: displayNum, title: title, duration: dur))
            }
        }

        return rows
    }

    private static func trackSortKey(_ tr: [String: Any]) -> Int {
        let p = jsonInt(tr["position"])
        if p > 0 { return p }
        return jsonInt(tr["number"])
    }

    private static func jsonInt(_ value: Any?) -> Int {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }
}