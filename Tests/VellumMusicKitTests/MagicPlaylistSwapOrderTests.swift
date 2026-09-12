import Foundation
import Testing

@testable import VellumMusicKit

/// A stale-id swap is two unrelated server writes — add the current ids, remove the stale ones —
/// with no transaction around them. The process can die in the gap (the app is used in a car), so
/// something *will* be left behind on a bad day. These tests pin which.
///
/// Remove-first leaves the tracks gone from the library: the Subsonic remove is by index, batched,
/// not rolled back, and once the stale ids are gone nothing records what should have been re-added.
/// Add-first leaves the same song listed twice, under its stale id and its current one — ugly and
/// recoverable. Make before break.
///
/// Worth stating because it is easy to misread: `.add` and `.remove` do **not** carry the same
/// tracks twice. `swaps` maps a stale id to the track that replaced it, so `.add` carries the
/// values' *current* ids and `.remove` carries the *keys*, which are the old ids the server no
/// longer uses. Two different sets of strings.
@Suite("Magic playlist swap ordering")
struct MagicPlaylistSwapOrderTests {
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

    /// stale id -> the track that replaced it after a server rescan
    private static let swaps: [String: Track] = [
        "stale-1": track("current-1"),
        "stale-2": track("current-2"),
    ]

    /// The invariant the whole fix exists for.
    @Test("the add step is ordered before the remove step")
    func addComesBeforeRemove() {
        let steps = AppModel.magicPlaylistSwapSteps(for: Self.swaps)
        #expect(steps.count == 2)

        guard case .add = steps.first else {
            Issue.record("first step was \(String(describing: steps.first)) — a mid-failure here deletes library songs")
            return
        }
        guard case .remove = steps.last else {
            Issue.record("last step was \(String(describing: steps.last))")
            return
        }
    }

    /// Guards against the misreading that this re-adds the tracks it is about to remove.
    @Test("add carries current ids and remove carries stale ids — different values")
    func addAndRemoveCarryDifferentIds() {
        let steps = AppModel.magicPlaylistSwapSteps(for: Self.swaps)

        var added: [String] = []
        var removed: Set<String> = []
        for step in steps {
            switch step {
            case let .add(ids): added = ids
            case let .remove(ids): removed = ids
            }
        }

        #expect(added == ["current-1", "current-2"])
        #expect(removed == ["stale-1", "stale-2"])
        #expect(Set(added).isDisjoint(with: removed))
    }

    @Test("an empty swap map produces no server writes at all")
    func emptySwapsProduceNoSteps() {
        #expect(AppModel.magicPlaylistSwapSteps(for: [:]).isEmpty)
    }
}
