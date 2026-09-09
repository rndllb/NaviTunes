import Foundation

struct CachedAlbumTracks: Equatable {
    var tracks: [Track]
    var retrievedAt: Date
}
