import Foundation

/// Origin row on the **New** tab — drives lookup terms and Downtify request.
enum BrowseAlbumDetailSource {
    case chartBrowse(artistName: String, title: String, imageURL: URL?, kind: String)
}
