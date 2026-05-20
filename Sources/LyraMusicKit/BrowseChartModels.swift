import Foundation

/// External chart / browse metadata (MusicBrainz new releases, etc.).
struct ChartTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?
    let playcount: Int
    /// `"Album"` when the row represents a release; `"Single"` for single-track rows.
    let browseKind: String

    init(id: String, name: String, artistName: String, imageURL: URL?, playcount: Int, browseKind: String = "Single") {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.imageURL = imageURL
        self.playcount = playcount
        self.browseKind = browseKind
    }
}

struct ChartAlbum: Identifiable {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?
}
