import Foundation

struct OfflineCachedTrackEntry: Identifiable, Hashable {
    let id: String
    let track: Track
    let relativePath: String
    let fileBytes: Int64
    let localArtworkURL: URL?
    let localFileURL: URL?
}

struct CachedImageEntry: Identifiable, Hashable {
    enum Source: String {
        case remoteArtwork
        case offlineDownload
        case accountAvatar
    }

    let id: String
    let source: Source
    let title: String
    let subtitle: String
    let fileBytes: Int64
    let previewURL: URL?
    let deleteToken: String
}

struct LibraryMetadataEntry: Identifiable, Hashable {
    enum Kind: String {
        case album
        case playlist
        case track
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let savedAt: Date?
}

struct LocalCacheUsageSummary: Equatable {
    var downloadedMusicBytes: Int64 = 0
    var downloadedTrackCount: Int = 0
    var imageCacheBytes: Int64 = 0
    var imageCacheCount: Int = 0
    var metadataEntryCount: Int = 0
    var metadataSavedAt: Date?
}

enum LocalCacheByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
