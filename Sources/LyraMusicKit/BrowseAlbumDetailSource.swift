import Foundation

/// Origin row on the **New** tab — drives lookup terms and the request backend request.
enum BrowseAlbumDetailSource {
    case chartBrowse(artistName: String, title: String, imageURL: URL?, kind: String)

    /// Stable key for the cover zoom transition — chart rows have no server
    /// item id, so the origin cell and the pushed detail derive the same key
    /// from artist + title.
    var coverZoomId: String {
        switch self {
        case .chartBrowse(let artistName, let title, _, _):
            return "chart-browse:\(artistName)|\(title)"
        }
    }
}
