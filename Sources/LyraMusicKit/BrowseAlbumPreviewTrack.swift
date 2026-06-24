import Foundation

/// A non-playable metadata row (iTunes catalog / Lidarr lookup) shown before the album exists in Jellyfin/Navidrome.
struct BrowseAlbumPreviewTrack: Identifiable, Sendable {
    let id: String
    let position: Int
    let title: String
    let duration: TimeInterval?
}
