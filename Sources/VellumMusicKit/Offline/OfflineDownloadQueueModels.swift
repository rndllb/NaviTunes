import Foundation

struct OfflineQueuePayload: Codable {
    var version: Int = 1
    var items: [OfflineDownloadQueueItem] = []
}

// MARK: - Queue item kinds

enum OfflineDownloadQueueItemKind: String, Codable, CaseIterable {
    case album
    case playlist
    case favorites
    case track
}

enum OfflineDownloadQueueStatus: String, Codable {
    case queued
    case downloading
    case complete
    case error
    case paused
}

struct OfflineDownloadQueueItem: Codable, Identifiable, Equatable {
    static let favoritesItemId = "__vellum_favorites__"

    var id: String
    var kind: OfflineDownloadQueueItemKind
    /// Album id, playlist id, favorites sentinel, or track id for single-track jobs.
    var itemId: String
    var name: String
    var tracks: [Track]
    var status: OfflineDownloadQueueStatus
    var completedTrackIds: Set<String>
    var addedAt: Date
    var errorMessage: String?
    /// Tracks that errored this run. Optional so queues persisted by older builds
    /// still decode. A failed track no longer aborts the rest of the item — the
    /// worker skips it and keeps downloading; Retry re-attempts just these.
    var failedTrackIds: Set<String>?

    var failedIds: Set<String> { failedTrackIds ?? [] }

    var pendingTracks: [Track] {
        let failed = failedIds
        return tracks.filter { !completedTrackIds.contains($0.id) && !failed.contains($0.id) }
    }

    var progressFraction: Double {
        guard !tracks.isEmpty else { return status == .complete ? 1 : 0 }
        return Double(completedTrackIds.count) / Double(tracks.count)
    }

    var isTerminal: Bool {
        status == .complete || status == .error
    }
}

// MARK: - Cached item metadata (manifest v4)

struct OfflineCachedItemRecord: Codable, Equatable {
    var kind: OfflineDownloadQueueItemKind
    var name: String
    var trackIds: [String]
    var addedAt: Date
}

// MARK: - Download settings

enum OfflineMaxConcurrentDownloads: Int, CaseIterable, Identifiable {
    case one = 1
    case three = 3
    case five = 5

    var id: Int { rawValue }

    var title: String { "\(rawValue)" }
}

enum OfflineStorageLimitMode: String, CaseIterable, Identifiable {
    case none
    case fixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "No limit"
        case .fixed: return "Fixed cap"
        }
    }
}

enum AutoOfflineMode: String, CaseIterable, Identifiable {
    case wifiOnly = "wifi-only"
    case homeWifi = "home-wifi"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifiOnly: return "When not on Wi‑Fi"
        case .homeWifi: return "When away from home Wi‑Fi"
        }
    }
}
