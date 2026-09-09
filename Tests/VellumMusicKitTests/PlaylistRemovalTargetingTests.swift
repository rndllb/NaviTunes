import Foundation
import Testing

@testable import VellumMusicKit

/// Navidrome deletes playlist songs by **position**, so a removal target is only valid against
/// the exact fetch its index came from. Any view that holds rows across a removal — the edit
/// sheet, the kill list — is carrying indices that now point at a *different song*.
///
/// These cover the mapping that has to happen before a position reaches the server. The first
/// one is C61 verbatim: two ordinary taps in one edit-sheet session deleted B and D when the
/// user asked for B and C.
@Suite("PlaylistRemovalTargeting")
struct PlaylistRemovalTargetingTests {
    private static func track(_ id: String) -> Track {
        Track(
            id: id,
            title: "Song \(id)",
            albumId: "album",
            albumTitle: "Album",
            artist: "Artist",
            duration: 180,
            discNumber: 1,
            indexNumber: 1,
            artworkURL: nil,
        )
    }

    /// Mirrors `NavidromeClient.fetchPlaylistRows`: `navidromeIndex` is the zero-based position
    /// in *this* fetch.
    private static func rows(_ ids: [String]) -> [PlaylistRowItem] {
        ids.enumerated().map { idx, id in
            PlaylistRowItem(rowId: "pl-\(idx)-\(id)", track: track(id), jellyfinEntryId: nil, navidromeIndex: idx)
        }
    }

    private static func jellyfinRows(_ ids: [String]) -> [PlaylistRowItem] {
        ids.enumerated().map { idx, id in
            PlaylistRowItem(rowId: "pl-\(idx)-\(id)", track: track(id), jellyfinEntryId: "entry-\(id)", navidromeIndex: nil)
        }
    }

    // MARK: - C61

    /// [A,B,C,D,E] → remove B → server is [A,C,D,E] → the sheet still holds C at index 2, which
    /// is now **D**. Resolving by track id has to come back with position 1.
    @Test("a snapshot index that went stale after a prior removal resolves to the song the user picked")
    func staleIndexResolvesToRequestedSong() throws {
        let snapshot = Self.rows(["A", "B", "C", "D", "E"])
        let live = Self.rows(["A", "C", "D", "E"])
        let requestedC = snapshot[2]

        // The hazard, stated as a fact about the inputs: sending the snapshot index verbatim
        // targets D.
        #expect(requestedC.navidromeIndex == 2)
        #expect(live[2].track.id == "D")

        let resolution = PlaylistRemovalTargeting.resolveByTrackId(requested: [requestedC], live: live)
        #expect(resolution.goneTrackIds.isEmpty)
        #expect(resolution.resolved.map(\.track.id) == ["C"])
        #expect(try PlaylistRemovalTargeting.navidromeDeletionOrder(resolution.resolved).map(\.index) == [1])
    }

    // MARK: - Ordering

    /// Within one batch the server resolves every index against the playlist as it was before
    /// the request, so descending order is what keeps a multi-select correct.
    @Test("a batch is ordered highest position first")
    func batchIsDescending() throws {
        let live = Self.rows(["A", "B", "C", "D", "E"])
        let requested = [live[1], live[3], live[0]]

        let resolution = PlaylistRemovalTargeting.resolveByTrackId(requested: requested, live: live)
        let order = try PlaylistRemovalTargeting.navidromeDeletionOrder(resolution.resolved)
        #expect(order.map(\.index) == [3, 1, 0])
        #expect(order.map(\.trackId) == ["D", "B", "A"])
    }

    @Test("a row with no position is refused rather than guessed at")
    func missingIndexThrows() {
        let orphan = PlaylistRowItem(rowId: "no-index", track: Self.track("A"))
        #expect(throws: (any Error).self) {
            try PlaylistRemovalTargeting.navidromeDeletionOrder([orphan])
        }
    }

    // MARK: - Duplicates

    /// A playlist can hold the same song twice. Two requested copies must consume two distinct
    /// live positions, or the second request deletes a position that no longer holds that song.
    @Test("duplicate track ids resolve to distinct positions")
    func duplicatesResolveToDistinctPositions() throws {
        let live = Self.rows(["A", "B", "B", "C"])
        let resolution = PlaylistRemovalTargeting.resolveByTrackId(requested: [live[1], live[2]], live: live)
        #expect(try PlaylistRemovalTargeting.navidromeDeletionOrder(resolution.resolved).map(\.index) == [2, 1])
    }

    @Test("a third copy of a twice-present song is reported gone, not mapped onto a survivor")
    func overRequestedDuplicateIsGone() throws {
        let snapshot = Self.rows(["A", "B", "B", "C"])
        let live = Self.rows(["A", "B", "C"])
        let resolution = PlaylistRemovalTargeting.resolveByTrackId(
            requested: [snapshot[1], snapshot[2]],
            live: live,
        )
        #expect(resolution.resolved.map(\.navidromeIndex) == [1])
        #expect(resolution.goneTrackIds == ["B"])
    }

    // MARK: - Already gone

    /// Another client (or an interrupted batch) can have removed the target already. That is the
    /// desired end state, so it must not fail the rest of the batch.
    @Test("a target that left the playlist comes back as gone and does not block the others")
    func missingTargetIsReportedGone() throws {
        let snapshot = Self.rows(["A", "B", "C"])
        let live = Self.rows(["A", "C"])
        let resolution = PlaylistRemovalTargeting.resolveByTrackId(
            requested: [snapshot[1], snapshot[2]],
            live: live,
        )
        #expect(resolution.goneTrackIds == ["B"])
        #expect(try PlaylistRemovalTargeting.navidromeDeletionOrder(resolution.resolved).map(\.index) == [1])
    }

    @Test("an empty live playlist reports every target gone")
    func emptyLivePlaylist() {
        let resolution = PlaylistRemovalTargeting.resolveByTrackId(requested: Self.rows(["A", "B"]), live: [])
        #expect(resolution.resolved.isEmpty)
        #expect(resolution.goneTrackIds == ["A", "B"])
    }

    // MARK: - Jellyfin

    /// Jellyfin entry ids are stable, so the only question is whether the entry still exists.
    @Test("jellyfin rows keep their entry ids and only drop what is gone")
    func jellyfinKeepsEntryIds() {
        let snapshot = Self.jellyfinRows(["A", "B", "C"])
        let live = Self.jellyfinRows(["A", "C"])
        let resolution = PlaylistRemovalTargeting.resolveByEntryId(
            requested: [snapshot[0], snapshot[1]],
            live: live,
        )
        #expect(resolution.resolved.compactMap(\.jellyfinEntryId) == ["entry-A"])
        #expect(resolution.goneTrackIds == ["B"])
    }

    /// A row with no entry id has to stay in `resolved` so the caller's own "missing entry id"
    /// guard is the thing that reports it — silently dropping it would report success for a
    /// removal that never happened.
    @Test("a jellyfin row with no entry id is passed through, not swallowed")
    func jellyfinRowWithoutEntryIdIsPassedThrough() {
        let orphan = PlaylistRowItem(rowId: "no-entry", track: Self.track("A"))
        let resolution = PlaylistRemovalTargeting.resolveByEntryId(requested: [orphan], live: [])
        #expect(resolution.resolved.count == 1)
        #expect(resolution.goneTrackIds.isEmpty)
    }
}
