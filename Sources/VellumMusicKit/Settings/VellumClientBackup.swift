import Foundation
import UniformTypeIdentifiers

struct VellumClientBackupMeta: Codable, Equatable {
    var version: Int = 1
    var createdAt: Date
    var serverURL: String?
    var username: String?
    var completedScrobbleCount: Int
    var exclusionCount: Int
}

struct VellumClientBackupPayload: Codable, Equatable {
    var meta: VellumClientBackupMeta
    var completedScrobbles: [CompletedScrobble]
    var scrobbleExclusions: [ScrobbleExclusion]
    var playbackSettings: VellumPlaybackSettingsSnapshot?
}

struct VellumPlaybackSettingsSnapshot: Codable, Equatable {
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
    /// Optional so backups written before AutoMix existed still decode.
    var autoMixEnabled: Bool?
}

enum VellumClientBackupRestoreMode {
    case replace
    case merge
}

struct VellumClientBackupRestoreResult: Equatable {
    var scrobbleCount: Int
    var scrobbleSkipped: Int
    var exclusionCount: Int
    var exclusionSkipped: Int
    var appliedPlaybackSettings: Bool
}

enum VellumClientBackupService {
    static let fileExtension = "vellumbackup"

    @MainActor
    static func makePayload(from app: AppModel) -> VellumClientBackupPayload {
        VellumClientBackupPayload(
            meta: VellumClientBackupMeta(
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

    static func encode(_ payload: VellumClientBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> VellumClientBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VellumClientBackupPayload.self, from: data)
    }

    static func suggestedFilename(for payload: VellumClientBackupPayload) -> String {
        let stamp = ISO8601DateFormatter().string(from: payload.meta.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        return "vellum-backup-\(stamp).\(fileExtension)"
    }

    @MainActor
    static func restore(
        payload: VellumClientBackupPayload,
        into app: AppModel,
        mode: VellumClientBackupRestoreMode,
    ) -> VellumClientBackupRestoreResult {
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
        return VellumClientBackupRestoreResult(
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
    static var vellumClientBackup: UTType {
        UTType(exportedAs: "com.randll.vellum.client-backup", conformingTo: .json)
    }
}
