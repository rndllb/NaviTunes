import Foundation

/// A lightweight song descriptor used for fuzzy matching external metadata (chart browse,
/// album-preview rows, acquisition results) against the user's library / catalog `Track`s.
/// Decodes defensively because external payloads vary in key names and value types.
struct MatchableSong: Decodable, Identifiable, Hashable {
    var id: String { songId }
    let songId: String
    let name: String
    let artists: [String]
    let albumName: String
    let url: String
    let coverURL: URL?
    let year: Int?
    let explicit: Bool

    enum CodingKeys: String, CodingKey {
        case songId = "song_id"
        case name, artists
        case albumName = "album_name"
        case url
        case coverURL = "cover_url"
        case year, explicit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = try c.decode(String.self, forKey: .songId)
        name = try c.decode(String.self, forKey: .name)
        artists = (try? c.decode([String].self, forKey: .artists)) ?? []
        albumName = (try? c.decode(String.self, forKey: .albumName)) ?? ""
        url = try c.decode(String.self, forKey: .url)
        // cover_url may be absent, null, or an empty string
        if let raw = try? c.decodeIfPresent(String.self, forKey: .coverURL), !raw.isEmpty,
           let parsed = URL(string: raw),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            coverURL = parsed
        } else {
            coverURL = nil
        }
        // year can be Int or String in the wild
        if let i = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = Int(s)
        } else {
            year = nil
        }
        // explicit can be Bool or Int (0/1)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .explicit) {
            explicit = b
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .explicit) {
            explicit = i != 0
        } else {
            explicit = false
        }
    }

    init(songId: String, name: String, artists: [String], albumName: String, url: String, coverURL: URL?, year: Int?, explicit: Bool) {
        self.songId = songId
        self.name = name
        self.artists = artists
        self.albumName = albumName
        self.url = url
        self.coverURL = coverURL
        self.year = year
        self.explicit = explicit
    }

    init(chartTrack track: ChartTrack) {
        self.init(
            songId: "chart:\(track.id)",
            name: track.name,
            artists: [track.artistName],
            albumName: "",
            url: "",
            coverURL: track.imageURL,
            year: nil,
            explicit: false
        )
    }
}
