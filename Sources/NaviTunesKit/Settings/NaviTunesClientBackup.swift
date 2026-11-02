import Foundation
import UniformTypeIdentifiers

struct NaviTunesClientBackupMeta: Codable, Equatable {
    var version: Int = 1
    var createdAt: Date
    var serverURL: String?
    var username: String?
    var completedScrobbleCount: Int
}

struct NaviTunesClientBackupPayload: Codable, Equatable {
    var meta: NaviTunesClientBackupMeta
    var completedScrobbles: [CompletedScrobble]
    // `scrobbleExclusions` was here until #7 removed the Exclusions feature. Backups that still
    // carry it decode fine: the decoder ignores keys it does not know.
    var playbackSettings: NaviTunesPlaybackSettingsSnapshot?
    /// Kill Mode history for the signed-in account. Optional so older backups still decode.
    var killMode: NaviTunesKillModeBackup? = nil
    /// Library pins, in their order. Optional so older backups still decode.
    var pinnedItems: [LibraryPinnedRef]? = nil
}

/// One account's Kill Mode state, as `KillModeStore` keeps it.
struct NaviTunesKillModeBackup: Codable, Equatable {
    var enabledPlaylistIds: [String]
    /// playlistId → trackIds queued for removal, newest first.
    var pendingRemovals: [String: [String]]
    /// playlistId → trackIds kept (green), sorted.
    var passedTracks: [String: [String]]
}

/// Reads and writes the device-local parts of a backup — Kill Mode history and library pins —
/// straight from their stores, so the round trip can be tested against a scratch defaults suite.
enum NaviTunesClientBackupLocalState {
    /// `nil` when signed out: Kill Mode is kept per account, and there is no account to read.
    static func killModeSection(scope: String?, defaults: UserDefaults = .standard) -> NaviTunesKillModeBackup? {
        guard let scope else { return nil }
        let snapshot = KillModeStore.load(scope: scope, defaults: defaults)
        return NaviTunesKillModeBackup(
            enabledPlaylistIds: snapshot.enabled.sorted(),
            pendingRemovals: snapshot.pending,
            passedTracks: snapshot.passed.mapValues { $0.sorted() }
        )
    }

    /// Returns how many playlists' Kill Mode state the restore touched.
    @discardableResult
    static func restoreKillMode(
        _ backup: NaviTunesKillModeBackup?,
        scope: String?,
        mode: NaviTunesClientBackupRestoreMode,
        defaults: UserDefaults = .standard,
    ) -> Int {
        // No section means the backup predates it: leave this phone's history alone, even on
        // Replace, rather than wipe it with nothing.
        guard let backup, let scope else { return 0 }
        var enabled = Set(backup.enabledPlaylistIds)
        var pending = backup.pendingRemovals
        var passed = backup.passedTracks.mapValues { Set($0) }
        if mode == .merge {
            let local = KillModeStore.load(scope: scope, defaults: defaults)
            enabled.formUnion(local.enabled)
            // The phone's own list first (its order is newest-first), then what only the backup has.
            for (playlistId, localIds) in local.pending {
                let extra = (pending[playlistId] ?? []).filter { !localIds.contains($0) }
                pending[playlistId] = localIds + extra
            }
            passed.merge(local.passed) { $0.union($1) }
        }
        KillModeStore.saveEnabled(enabled, scope: scope, defaults: defaults)
        KillModeStore.savePending(pending, scope: scope, defaults: defaults)
        KillModeStore.savePassed(passed, scope: scope, defaults: defaults)
        return Set(enabled).union(pending.keys).union(passed.keys).count
    }

    static func pinsSection(defaults: UserDefaults = .standard) -> [LibraryPinnedRef]? {
        LibraryPinStore.decode(defaults.string(forKey: LibraryPinStore.storageKey) ?? "[]")
    }

    /// Returns how many pins the library has after the restore.
    @discardableResult
    static func restorePins(
        _ pins: [LibraryPinnedRef]?,
        mode: NaviTunesClientBackupRestoreMode,
        defaults: UserDefaults = .standard,
    ) -> Int {
        guard let pins else { return pinsSection(defaults: defaults)?.count ?? 0 }
        var result = pins
        if mode == .merge {
            let local = pinsSection(defaults: defaults) ?? []
            result = local + pins.filter { pin in !local.contains(pin) }
        }
        // The Library hub reads this key through `@AppStorage`, so it redraws on its own.
        defaults.set(LibraryPinStore.encode(result), forKey: LibraryPinStore.storageKey)
        return result.count
    }
}

struct NaviTunesPlaybackSettingsSnapshot: Codable, Equatable {
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

enum NaviTunesClientBackupRestoreMode {
    case replace
    case merge
}

struct NaviTunesClientBackupRestoreResult: Equatable {
    var scrobbleCount: Int
    var scrobbleSkipped: Int
    /// Playlists with Kill Mode state after the restore; nil when the backup had none or no
    /// account is signed in.
    var killModePlaylistCount: Int?
    /// Pins after the restore; nil when the backup had none.
    var pinCount: Int?
    var appliedPlaybackSettings: Bool
}

enum NaviTunesClientBackupService {
    static let fileExtension = "navitunesbackup"

    @MainActor
    static func makePayload(from app: AppModel) -> NaviTunesClientBackupPayload {
        NaviTunesClientBackupPayload(
            meta: NaviTunesClientBackupMeta(
                createdAt: Date(),
                serverURL: app.baseURLString.nilIfBlank,
                username: app.username.nilIfBlank,
                completedScrobbleCount: app.scrobbleService.store.completed.count,
            ),
            completedScrobbles: app.scrobbleService.store.completed,
            playbackSettings: app.playbackSettingsSnapshot(),
            killMode: NaviTunesClientBackupLocalState.killModeSection(scope: KillModeStore.activeScope),
            pinnedItems: NaviTunesClientBackupLocalState.pinsSection(),
        )
    }

    static func encode(_ payload: NaviTunesClientBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> NaviTunesClientBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NaviTunesClientBackupPayload.self, from: data)
    }

    static func suggestedFilename(for payload: NaviTunesClientBackupPayload) -> String {
        let stamp = ISO8601DateFormatter().string(from: payload.meta.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        return "navitunes-backup-\(stamp).\(fileExtension)"
    }

    @MainActor
    static func restore(
        payload: NaviTunesClientBackupPayload,
        into app: AppModel,
        mode: NaviTunesClientBackupRestoreMode,
    ) -> NaviTunesClientBackupRestoreResult {
        let store = app.scrobbleService.store
        var scrobbleCount = 0
        var scrobbleSkipped = 0

        switch mode {
        case .replace:
            store.replaceCompleted(payload.completedScrobbles)
            scrobbleCount = payload.completedScrobbles.count
        case .merge:
            let mergeScrobbles = store.mergeCompleted(payload.completedScrobbles)
            scrobbleCount = mergeScrobbles.inserted
            scrobbleSkipped = mergeScrobbles.skipped
        }

        var killModeCount: Int?
        if payload.killMode != nil, let scope = KillModeStore.activeScope {
            killModeCount = NaviTunesClientBackupLocalState.restoreKillMode(payload.killMode, scope: scope, mode: mode)
            app.reloadKillModeStateForAccount()
        }
        let pinCount = payload.pinnedItems.map { NaviTunesClientBackupLocalState.restorePins($0, mode: mode) }

        let appliedPlayback = payload.playbackSettings.map { app.applyPlaybackSettingsSnapshot($0) } ?? false
        return NaviTunesClientBackupRestoreResult(
            scrobbleCount: scrobbleCount,
            scrobbleSkipped: scrobbleSkipped,
            killModePlaylistCount: killModeCount,
            pinCount: pinCount,
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
    static var navitunesClientBackup: UTType {
        UTType(exportedAs: "com.randll.vellum.client-backup", conformingTo: .json)
    }
}
