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

    init(track: Track, playcount: Int = 0) {
        self.init(
            id: track.id,
            name: track.title,
            artistName: track.artist,
            imageURL: track.artworkURL,
            playcount: playcount,
            browseKind: "Single"
        )
    }
}

struct ChartAlbum: Identifiable {
    let id: String
    let name: String
    let artistName: String
    var imageURL: URL?
    /// First-release date when known; drives the "New This Week" vs
    /// "Recent Releases" recency split on the New tab.
    var releaseDate: Date? = nil
    /// Plugin-native id for off-server tracklist fetches (`native:` / `mbid:`).
    var pluginLookupId: String? = nil

    init(
        id: String,
        name: String,
        artistName: String,
        imageURL: URL?,
        releaseDate: Date? = nil,
        pluginLookupId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.imageURL = imageURL
        self.releaseDate = releaseDate
        self.pluginLookupId = pluginLookupId
    }

    init(serverAlbum album: AlbumSummary) {
        self.init(
            id: album.id,
            name: album.title,
            artistName: album.artist,
            imageURL: album.artworkURL,
            releaseDate: album.releaseDate ?? album.releaseYear.flatMap { year in
                var comps = DateComponents()
                comps.year = year
                comps.month = 1
                comps.day = 1
                return Calendar(identifier: .gregorian).date(from: comps)
            }
        )
    }

    init(release: AcquisitionRelease) {
        self.init(
            id: release.id,
            name: release.title,
            artistName: release.artist,
            imageURL: release.artworkURL,
            releaseDate: release.releaseDate,
            pluginLookupId: release.trackLookupId
        )
    }
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
