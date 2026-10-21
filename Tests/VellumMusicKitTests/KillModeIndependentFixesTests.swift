import Foundation
import Testing

@testable import VellumMusicKit

/// Kill Mode defects that sit outside the auto-advance exclusion: stale ids (K9), collection
/// playback from the long-press menu (K12), the Kill List header (K14), and cleanup (K15).
///
/// Everything here is exercised through pure seams — `AppModel` is never constructed — so no
/// player, server, keychain or view is involved.
@MainActor
@Suite("Kill Mode independent fixes")
struct KillModeIndependentFixesTests {
    private static func track(_ id: String) -> Track {
        Track(
            id: id,
            title: "T-\(id)",
            albumId: "album",
            albumTitle: "Album",
            artist: "Artist",
            duration: 100,
            discNumber: 1,
            indexNumber: 1,
            artworkURL: nil,
        )
    }

    private static func tracks(_ ids: [String]) -> [Track] { ids.map(track) }

    // MARK: - K9: stale ids after a rescan

    /// The removal list is newest-skip-first and the Kill List renders it in that order. The
    /// expected order is neither sorted nor reverse-sorted after the swap, so a rebuild through a
    /// `Set` (or a sort) cannot land on it by accident.
    @Test("K9: remapping the removal list keeps newest-skip-first order")
    func remapKeepsPendingOrder() {
        let pending = ["kill": ["H", "G", "F", "E", "D", "C", "B", "A"]]
        let result = AppModel.killModeMarksRemapped(pending: pending, passed: [:], swaps: ["D": "Z9"])
        #expect(result.pending["kill"] == ["H", "G", "F", "E", "Z9", "C", "B", "A"])
    }

    @Test("K9: kept (green) marks follow the swap, in every playlist")
    func remapMovesPassed() {
        let result = AppModel.killModeMarksRemapped(
            pending: [:],
            passed: ["kill": ["A", "B"], "other": ["A"]],
            swaps: ["A": "A2"]
        )
        #expect(result.passed["kill"] == ["A2", "B"])
        #expect(result.passed["other"] == ["A2"])
    }

    /// A rescan can hand an old id the id of a song already on the list. One row per id, and it
    /// keeps the newer (earlier) position.
    @Test("K9: a swap onto an id already listed does not duplicate it")
    func remapDedupesPending() {
        let result = AppModel.killModeMarksRemapped(
            pending: ["kill": ["B", "C", "A"]],
            passed: [:],
            swaps: ["A": "B"]
        )
        #expect(result.pending["kill"] == ["B", "C"])
    }

    /// Skip wins over a completed play everywhere else in Kill Mode; a swap must not produce a
    /// song that is both red and green.
    @Test("K9: a swap that makes a song both red and green leaves it red")
    func remapRedWins() {
        let result = AppModel.killModeMarksRemapped(
            pending: ["kill": ["A"]],
            passed: ["kill": ["A2", "B"]],
            swaps: ["A": "A2"]
        )
        #expect(result.pending["kill"] == ["A2"])
        #expect(result.passed["kill"] == ["B"])
    }

    // MARK: - K12: the long-press menu bypassed the hero path

    /// Partly listened: A kept, B marked for removal. The menu's Play used to start on A.
    @Test("K12: menu Play on a partly listened playlist starts on the first unheard song")
    func menuPlayStartsOnFirstUnheard() {
        let plan = AppModel.collectionPlaybackPlan(
            intent: .play,
            tracks: Self.tracks(["A", "B", "C", "D"]),
            isKillModeEnabled: true,
            pending: ["B"],
            passed: ["A"]
        )
        #expect(plan.action == .start(shuffled: false))
        #expect(plan.tracks.map(\.id) == ["C", "D"])
        #expect(plan.startIndex == 0)
    }

    /// `shuffled: true` routes to `playAlbumShuffled`, the only call that sets `shuffleMode`.
    @Test("K12: menu Shuffle filters listened songs and turns shuffle on")
    func menuShuffleFiltersAndSetsShuffle() {
        let plan = AppModel.collectionPlaybackPlan(
            intent: .shuffle,
            tracks: Self.tracks(["A", "B", "C", "D"]),
            isKillModeEnabled: true,
            pending: ["B"],
            passed: ["A"]
        )
        #expect(plan.action == .start(shuffled: true))
        #expect(Set(plan.tracks.map(\.id)) == ["C", "D"])
    }

    @Test("K12: menu Play on a fully listened playlist plays nothing and says why")
    func menuPlayEverythingListened() {
        let plan = AppModel.collectionPlaybackPlan(
            intent: .play,
            tracks: Self.tracks(["A", "B"]),
            isKillModeEnabled: true,
            pending: ["A", "B"],
            passed: []
        )
        #expect(plan.action == .everythingListened)
    }

    @Test("K12: outside Kill Mode the menu plays the whole collection in order")
    func menuPlayWithoutKillMode() {
        let plan = AppModel.collectionPlaybackPlan(
            intent: .play,
            tracks: Self.tracks(["A", "B"]),
            isKillModeEnabled: false,
            pending: ["A"],
            passed: ["B"]
        )
        #expect(plan.action == .start(shuffled: false))
        #expect(plan.tracks.map(\.id) == ["A", "B"])
    }

    // MARK: - c3: Play Next from the menu

    /// The collection is filtered before it is inserted. The auto-advance exclusion only filters
    /// when the *playing* source is this playlist, so without this a Play Next onto some other
    /// queue replayed every listened song.
    @Test("c3: menu Play Next on a kill-mode playlist inserts only unheard songs")
    func menuPlayNextFiltersBeforeInsert() {
        let plan = AppModel.collectionPlaybackPlan(
            intent: .playNext,
            tracks: Self.tracks(["A", "B", "C", "D"]),
            isKillModeEnabled: true,
            pending: ["B"],
            passed: ["A"]
        )
        #expect(plan.action == .insertNext)
        #expect(plan.tracks.map(\.id) == ["C", "D"])
    }

    @Test("c3: menu Play Next on an unlocked playlist inserts every kept song")
    func menuPlayNextUnlocked() {
        let plan = AppModel.collectionPlaybackPlan(
            intent: .playNext,
            tracks: Self.tracks(["A", "B", "C"]),
            isKillModeEnabled: true,
            pending: ["B"],
            passed: ["A", "C"]
        )
        #expect(plan.action == .insertNext)
        #expect(plan.tracks.map(\.id) == ["A", "C"])
    }

    // MARK: - K14: the Kill List header

    /// Ids outside the playlist's rows — removed elsewhere, or stale — must not count.
    @Test("K14: header counts only marks that match a row in this playlist")
    func headerIntersectsWithRows() {
        let progress = KillListProgress(
            rowTrackIds: ["A", "B", "C", "D"],
            pending: ["A", "X", "Y"],
            passed: ["B", "U", "V", "W"],
            totalSongCount: 4
        )
        #expect(progress.removed == 1)
        #expect(progress.kept == 1)
        #expect(progress.listened == 2)
        #expect(progress.percentListened == 50)
        #expect(progress.percentRemoved == 25)
        #expect(progress.keptFraction == 0.25)
        #expect(progress.removedFraction == 0.25)
    }

    /// `songCount` can lag the rows. The two bar segments together must never overflow the track.
    @Test("K14: bar widths are clamped to the total")
    func headerBarsClamped() {
        let progress = KillListProgress(
            rowTrackIds: ["A", "B", "C"],
            pending: ["A", "B"],
            passed: ["C"],
            totalSongCount: 2
        )
        #expect(progress.listened == 2)
        #expect(progress.keptFraction + progress.removedFraction <= 1)
        #expect(progress.keptFraction >= 0 && progress.removedFraction >= 0)
    }

    // MARK: - K15: cleanup

    @Test("K15: deleting a playlist forgets its Kill Mode state and nobody else's")
    func deleteForgetsPlaylistState() {
        let result = AppModel.killModeStateForgettingPlaylist(
            "gone",
            enabled: ["gone", "kept"],
            pending: ["gone": ["A"], "kept": ["B"]],
            passed: ["gone": ["C"], "kept": ["D"]]
        )
        #expect(result.enabled == ["kept"])
        #expect(result.pending == ["kept": ["B"]])
        #expect(result.passed == ["kept": ["D"]])
    }

    private final class Defaults {
        let suiteName = "T330.KillModeStore.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: suiteName)! }
        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }

    /// Playlist ids are per server. Two servers can hand out the same id for different playlists.
    @Test("K15: one server's marks are invisible on another server")
    func storeIsScopedPerServer() {
        let box = Defaults()
        let serverA = KillModeStore.scope(backend: .navidrome, baseURLString: "https://a.example.com", userKey: "alice")!
        let serverB = KillModeStore.scope(backend: .navidrome, baseURLString: "https://b.example.com", userKey: "alice")!

        KillModeStore.saveEnabled(["1"], scope: serverA, defaults: box.defaults)
        KillModeStore.savePending(["1": ["X"]], scope: serverA, defaults: box.defaults)
        KillModeStore.savePassed(["1": ["Y"]], scope: serverA, defaults: box.defaults)

        #expect(KillModeStore.load(scope: serverB, defaults: box.defaults) == KillModeStore.Snapshot())
    }

    /// Sign-out forgets nothing on disk; signing back in to the same server finds it all.
    @Test("K15: signing back in to the same server restores progress")
    func sameServerRestoresProgress() {
        let box = Defaults()
        let scope = KillModeStore.scope(backend: .navidrome, baseURLString: "https://a.example.com", userKey: "alice")!
        KillModeStore.saveEnabled(["1"], scope: scope, defaults: box.defaults)
        KillModeStore.savePending(["1": ["X", "W"]], scope: scope, defaults: box.defaults)
        KillModeStore.savePassed(["1": ["Y"]], scope: scope, defaults: box.defaults)

        let again = KillModeStore.scope(backend: .navidrome, baseURLString: "https://A.example.com/", userKey: "Alice")!
        #expect(again == scope)
        #expect(KillModeStore.load(scope: again, defaults: box.defaults) == KillModeStore.Snapshot(
            enabled: ["1"],
            pending: ["1": ["X", "W"]],
            passed: ["1": ["Y"]]
        ))
    }

    @Test("K15: a different user on the same server gets a different scope")
    func scopeIncludesUser() {
        let a = KillModeStore.scope(backend: .navidrome, baseURLString: "https://a.example.com", userKey: "alice")
        let b = KillModeStore.scope(backend: .navidrome, baseURLString: "https://a.example.com", userKey: "guest")
        let c = KillModeStore.scope(backend: .jellyfin, baseURLString: "https://a.example.com", userKey: "alice")
        #expect(a != b)
        #expect(a != c)
        #expect(KillModeStore.scope(backend: .navidrome, baseURLString: "", userKey: "alice") == nil)
        #expect(KillModeStore.scope(backend: .navidrome, baseURLString: "https://a.example.com", userKey: nil) == nil)
    }

    /// History written before scoping (including what `LegacyLyraMigration` copied from `lyra.*`)
    /// is adopted by the first account that loads, exactly once, and the unscoped copy stays on disk.
    @Test("K15: unscoped history is adopted once and never deleted")
    func legacyHistoryAdoptedOnce() throws {
        let box = Defaults()
        let encoder = JSONEncoder()
        box.defaults.set(try encoder.encode(["1"]), forKey: "vellum.killMode.enabledPlaylists")
        box.defaults.set(try encoder.encode(["1": ["X"]]), forKey: "vellum.killMode.pendingRemovals")
        box.defaults.set(try encoder.encode(["1": ["Y"]]), forKey: "vellum.killMode.passed")

        let first = KillModeStore.scope(backend: .navidrome, baseURLString: "https://a.example.com", userKey: "alice")!
        let second = KillModeStore.scope(backend: .navidrome, baseURLString: "https://b.example.com", userKey: "alice")!

        let adopted = KillModeStore.Snapshot(enabled: ["1"], pending: ["1": ["X"]], passed: ["1": ["Y"]])
        #expect(KillModeStore.load(scope: first, defaults: box.defaults) == adopted)
        #expect(KillModeStore.load(scope: second, defaults: box.defaults) == KillModeStore.Snapshot())
        #expect(KillModeStore.load(scope: first, defaults: box.defaults) == adopted)
        #expect(box.defaults.data(forKey: "vellum.killMode.pendingRemovals") != nil)
    }
}
