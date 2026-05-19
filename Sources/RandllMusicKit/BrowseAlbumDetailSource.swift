import Foundation

/// Origin row on the **New** tab — drives lookup terms and Downtify request.
enum BrowseAlbumDetailSource {
    case lfm(artistName: String, title: String, imageURL: URL?, kind: String)
}
