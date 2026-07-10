import Foundation

/// Origin row on the **New** tab — drives lookup terms and the request backend request.
enum BrowseAlbumDetailSource {
    /// `albumId` is the iTunes collection id (when the row came from iTunes), used to pull the
    /// exact tracklist from the iTunes lookup API. `nil` for rows from other sources.
    case chartBrowse(artistName: String, title: String, imageURL: URL?, kind: String, albumId: String?)

    /// Stable key for the cover zoom transition — chart rows have no server
    /// item id, so the origin cell and the pushed detail derive the same key
    /// from artist + title.
    var coverZoomId: String {
        switch self {
        case .chartBrowse(let artistName, let title, _, _, _):
            return "chart-browse:\(artistName)|\(title)"
        }
    }
}
