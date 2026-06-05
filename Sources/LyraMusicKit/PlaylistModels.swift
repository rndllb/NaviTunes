import Foundation

/// Server-backed playlist (Jellyfin `Playlist` item or Navidrome Subsonic playlist).
struct PlaylistSummary: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let songCount: Int?
    let artworkURL: URL?
    /// Navidrome Subsonic `coverArt` id when the playlist has custom/mosaic art.
    let coverArtId: String?
    /// Jellyfin only: `IsPublic` — visible to all users on the server (`nil` if unknown / Navidrome).
    let isPublic: Bool?
    /// Server `created` (Navidrome) / `DateCreated` (Jellyfin).
    let libraryAddedDate: Date?
    /// Server `changed` (Navidrome) / `DateModified` (Jellyfin), when available.
    let serverUpdatedDate: Date?

    init(
        id: String,
        name: String,
        songCount: Int? = nil,
        artworkURL: URL? = nil,
        coverArtId: String? = nil,
        isPublic: Bool? = nil,
        libraryAddedDate: Date? = nil,
        serverUpdatedDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.artworkURL = artworkURL
        self.coverArtId = coverArtId
        self.isPublic = isPublic
        self.libraryAddedDate = libraryAddedDate
        self.serverUpdatedDate = serverUpdatedDate
    }
}

/// One row in a playlist detail view (supports duplicate tracks + backend-specific removal keys).
struct PlaylistRowItem: Identifiable, Hashable, Codable {
    /// Stable within the current loaded snapshot (used by SwiftUI `ForEach`).
    let rowId: String
    let track: Track
    /// Jellyfin playlist entry id (`PlaylistItemId`) for `DELETE .../Playlists/{id}/Items`.
    let jellyfinEntryId: String?
    /// Zero-based index for Navidrome `songIndexToRemove`.
    let navidromeIndex: Int?

    var id: String { rowId }

    init(rowId: String, track: Track, jellyfinEntryId: String? = nil, navidromeIndex: Int? = nil) {
        self.rowId = rowId
        self.track = track
        self.jellyfinEntryId = jellyfinEntryId
        self.navidromeIndex = navidromeIndex
    }
}

/// Drives the global “add to playlist” sheet (`MainShellView`).
struct PlaylistPickerPayload: Identifiable {
    let id = UUID()
    let tracks: [Track]

    init(tracks: [Track]) {
        self.tracks = tracks
    }
}
