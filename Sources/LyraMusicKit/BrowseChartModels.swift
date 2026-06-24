import Foundation

/// External chart / browse metadata (iTunes new releases, etc.).
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
    var imageURL: URL?
    /// First-release date when known (iTunes `releaseDate`); drives the
    /// "New This Week" vs "Recent Releases" recency split on the New tab.
    var releaseDate: Date? = nil
}

extension ChartTrack {
    /// Unified acquisition request for **New** tab chart rows.
    var acquisitionRequest: AcquisitionRequest {
        let isAlbum = browseKind.caseInsensitiveCompare("Album") == .orderedSame
        return AcquisitionRequest(
            artist: artistName,
            trackTitle: isAlbum ? nil : name,
            albumTitle: isAlbum ? name : nil,
            coverURL: imageURL
        )
    }
}

/// Resolved server/library state for a **New** tab chart row.
enum NewTabChartRowState: Equatable {
    case libraryTrack(Track)
    case serverAlbum(AlbumSummary)
    case missing

    var isOnServer: Bool {
        switch self {
        case .missing: return false
        case .libraryTrack, .serverAlbum: return true
        }
    }
}
