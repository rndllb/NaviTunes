import Foundation
import Testing

@testable import NaviTunesKit

/// #5: Backup & Restore carries Kill Mode history and library pins, which exist nowhere but this
/// phone. Everything runs against a scratch `UserDefaults` suite; the app's own data is untouched.
@Suite("Backup & Restore: Kill Mode history and pins (#5)")
struct ClientBackupLocalStateTests {
    static let scope = "navidrome|music.example|alice"

    static func scratch() -> UserDefaults {
        let name = "t788-backup-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static let pins = [
        LibraryPinnedRef(kind: .playlist, itemId: "pl-1"),
        LibraryPinnedRef(kind: .album, itemId: "al-7"),
        LibraryPinnedRef(kind: .track, itemId: "tr-3"),
    ]

    static func seed(_ d: UserDefaults) {
        KillModeStore.saveEnabled(["pl-1", "pl-2"], scope: scope, defaults: d)
        KillModeStore.savePending(["pl-1": ["tr-9", "tr-4"], "pl-2": ["tr-1"]], scope: scope, defaults: d)
        KillModeStore.savePassed(["pl-1": ["tr-5", "tr-6"]], scope: scope, defaults: d)
        d.set(LibraryPinStore.encode(pins), forKey: LibraryPinStore.storageKey)
    }

    /// Backup → file bytes → a fresh phone → restore.
    static func roundTrip(from source: UserDefaults, into target: UserDefaults, mode: NaviTunesClientBackupRestoreMode) throws {
        let payload = NaviTunesClientBackupPayload(
            meta: NaviTunesClientBackupMeta(createdAt: Date(timeIntervalSince1970: 1_790_000_000), completedScrobbleCount: 0),
            completedScrobbles: [],
            playbackSettings: nil,
            killMode: NaviTunesClientBackupLocalState.killModeSection(scope: scope, defaults: source),
            pinnedItems: NaviTunesClientBackupLocalState.pinsSection(defaults: source)
        )
        let decoded = try NaviTunesClientBackupService.decode(NaviTunesClientBackupService.encode(payload))
        NaviTunesClientBackupLocalState.restoreKillMode(decoded.killMode, scope: scope, mode: mode, defaults: target)
        NaviTunesClientBackupLocalState.restorePins(decoded.pinnedItems, mode: mode, defaults: target)
    }

    @Test("Kill Mode history and pins survive backup, then restore onto an empty phone")
    func roundTripOntoEmptyPhone() throws {
        let source = Self.scratch()
        Self.seed(source)
        let target = Self.scratch()

        try Self.roundTrip(from: source, into: target, mode: .replace)

        #expect(KillModeStore.load(scope: Self.scope, defaults: target) == KillModeStore.load(scope: Self.scope, defaults: source))
        let restored = KillModeStore.load(scope: Self.scope, defaults: target)
        #expect(restored.enabled == ["pl-1", "pl-2"])
        #expect(restored.pending["pl-1"] == ["tr-9", "tr-4"], "the newest-first order of skipped songs is part of the history")
        #expect(restored.passed["pl-1"] == ["tr-5", "tr-6"])
        #expect(LibraryPinStore.decode(target.string(forKey: LibraryPinStore.storageKey) ?? "[]") == Self.pins)
    }

    @Test("merge keeps what the phone has and adds what the backup has")
    func mergeUnions() throws {
        let source = Self.scratch()
        Self.seed(source)
        let target = Self.scratch()
        KillModeStore.saveEnabled(["pl-3"], scope: Self.scope, defaults: target)
        KillModeStore.savePending(["pl-1": ["tr-2"]], scope: Self.scope, defaults: target)
        target.set(LibraryPinStore.encode([LibraryPinnedRef(kind: .album, itemId: "al-9"), Self.pins[0]]), forKey: LibraryPinStore.storageKey)

        try Self.roundTrip(from: source, into: target, mode: .merge)

        let merged = KillModeStore.load(scope: Self.scope, defaults: target)
        #expect(merged.enabled == ["pl-1", "pl-2", "pl-3"])
        #expect(merged.pending["pl-1"] == ["tr-2", "tr-9", "tr-4"])
        #expect(merged.pending["pl-2"] == ["tr-1"])
        #expect(merged.passed["pl-1"] == ["tr-5", "tr-6"])
        #expect(LibraryPinStore.decode(target.string(forKey: LibraryPinStore.storageKey) ?? "[]").map(\.id)
            == ["album:al-9", "playlist:pl-1", "album:al-7", "track:tr-3"])
    }

    @Test("a backup made before this existed leaves Kill Mode and pins alone, even on Replace")
    func olderBackupLeavesStateAlone() throws {
        let target = Self.scratch()
        Self.seed(target)
        let before = KillModeStore.load(scope: Self.scope, defaults: target)
        NaviTunesClientBackupLocalState.restoreKillMode(nil, scope: Self.scope, mode: .replace, defaults: target)
        NaviTunesClientBackupLocalState.restorePins(nil, mode: .replace, defaults: target)
        #expect(KillModeStore.load(scope: Self.scope, defaults: target) == before)
        #expect(LibraryPinStore.decode(target.string(forKey: LibraryPinStore.storageKey) ?? "[]") == Self.pins)
    }

    @Test("signed out, there is no account to back Kill Mode up from or restore it into")
    func noScopeNoKillMode() {
        let d = Self.scratch()
        Self.seed(d)
        #expect(NaviTunesClientBackupLocalState.killModeSection(scope: nil, defaults: d) == nil)
    }
}
