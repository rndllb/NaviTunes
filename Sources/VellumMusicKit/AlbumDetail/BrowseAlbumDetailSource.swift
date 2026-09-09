import Foundation

/// Origin row on the **New** tab — drives lookup terms and the request backend request.
enum BrowseAlbumDetailSource {
    /// `albumId` is the iTunes collection id (when the row came from iTunes), used to pull the
    /// exact tracklist from the iTunes lookup API. `nil` for rows from other sources.
    case chartBrowse(artistName: String, title: String, imageURL: URL?, kind: String, albumId: String?)

    /// MusicBrainz release-group id, when the row that opened this view carried one.
    ///
    /// ``AcquisitionRelease/trackLookupId`` encodes it as `mbid:<id>`; this is the matching
    /// decode, kept beside nothing else that parses that string so the two stay in step.
    ///
    /// It matters because a request built from this view used to be assembled out of the artist
    /// and title text alone, discarding an exact identity the row already held — and the text
    /// route through Lidarr's metadata proxy is the one that fails.
    var releaseGroupMBID: String? {
        switch self {
        case .chartBrowse(_, _, _, _, let albumId):
            guard let albumId, albumId.hasPrefix("mbid:") else { return nil }
            let id = String(albumId.dropFirst("mbid:".count))
            // MBIDs are UUIDs; anything shorter is some other id that happened to be prefixed.
            return id.count >= 36 ? id : nil
        }
    }

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
