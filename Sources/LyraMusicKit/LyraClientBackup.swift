import Foundation
import UniformTypeIdentifiers

struct LyraClientBackupMeta: Codable, Equatable {
    var version: Int = 1
    var createdAt: Date
    var serverURL: String?
    var username: String?
    var completedScrobbleCount: Int
    var exclusionCount: Int
}

struct LyraClientBackupPayload: Codable, Equatable {
    var meta: LyraClientBackupMeta
    var completedScrobbles: [CompletedScrobble]
    var scrobbleExclusions: [ScrobbleExclusion]
    var playbackSettings: LyraPlaybackSettingsSnapshot?
}

struct LyraPlaybackSettingsSnapshot: Codable, Equatable {
    var wifiStreamBitRate: String
    var cellularStreamBitRate: String
    var wifiStreamFormat: String
    var cellularStreamFormat: String
    var downloadFormat: String
    var downloadQualityTier: String
    var skipBackwardInterval: String
    var skipForwardInterval: String
    var remoteControlMode: String
    var showSkipIntervalButtons: Bool
    var showSleepTimerButton: Bool
    var metadataRefreshThreshold: String
}

enum LyraClientBackupRestoreMode {
    case replace
    case merge
}

struct LyraClientBackupRestoreResult: Equatable {
    var scrobbleCount: Int
    var scrobbleSkipped: Int
    var exclusionCount: Int
    var exclusionSkipped: Int
    var appliedPlaybackSettings: Bool
}

enum LyraClientBackupService {
    static let fileExtension = "lyrabackup"

    @MainActor
    static func makePayload(from app: AppModel) -> LyraClientBackupPayload {
        LyraClientBackupPayload(
            meta: LyraClientBackupMeta(
                createdAt: Date(),
                serverURL: app.baseURLString.nilIfBlank,
                username: app.username.nilIfBlank,
                completedScrobbleCount: app.scrobbleService.store.completed.count,
                exclusionCount: app.scrobbleService.store.exclusions.count,
            ),
            completedScrobbles: app.scrobbleService.store.completed,
            scrobbleExclusions: app.scrobbleService.store.exclusions,
            playbackSettings: app.playbackSettingsSnapshot(),
        )
    }

    static func encode(_ payload: LyraClientBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> LyraClientBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LyraClientBackupPayload.self, from: data)
    }

    static func suggestedFilename(for payload: LyraClientBackupPayload) -> String {
        let stamp = ISO8601DateFormatter().string(from: payload.meta.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        return "lyra-backup-\(stamp).\(fileExtension)"
    }

    @MainActor
    static func restore(
        payload: LyraClientBackupPayload,
        into app: AppModel,
        mode: LyraClientBackupRestoreMode,
    ) -> LyraClientBackupRestoreResult {
        let store = app.scrobbleService.store
        var scrobbleCount = 0
        var scrobbleSkipped = 0
        var exclusionCount = 0
        var exclusionSkipped = 0

        switch mode {
        case .replace:
            store.replaceCompleted(payload.completedScrobbles)
            store.replaceExclusions(payload.scrobbleExclusions)
            scrobbleCount = payload.completedScrobbles.count
            exclusionCount = payload.scrobbleExclusions.count
        case .merge:
            let mergeScrobbles = store.mergeCompleted(payload.completedScrobbles)
            scrobbleCount = mergeScrobbles.inserted
            scrobbleSkipped = mergeScrobbles.skipped
            let mergeExclusions = store.mergeExclusions(payload.scrobbleExclusions)
            exclusionCount = mergeExclusions.inserted
            exclusionSkipped = mergeExclusions.skipped
        }

        let appliedPlayback = payload.playbackSettings.map { app.applyPlaybackSettingsSnapshot($0) } ?? false
        return LyraClientBackupRestoreResult(
            scrobbleCount: scrobbleCount,
            scrobbleSkipped: scrobbleSkipped,
            exclusionCount: exclusionCount,
            exclusionSkipped: exclusionSkipped,
            appliedPlaybackSettings: appliedPlayback,
        )
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension UTType {
    static var lyraClientBackup: UTType {
        UTType(exportedAs: "com.randll.lyra.client-backup", conformingTo: .json)
    }
}
