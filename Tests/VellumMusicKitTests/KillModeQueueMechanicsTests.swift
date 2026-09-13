import Foundation
import Testing

@testable import VellumMusicKit

/// Kill Mode's queue mechanics: the last-song skip (K4), shuffle mid-run (K7), where a skip lands
/// (K8), a playlist edited mid-run (K10), duplicate rows (K11), and what Up Next lists (K13).
///
/// Engine tests use `restore`, which builds queue state without loading anything, so no player or
/// server is involved.
@MainActor
@Suite("Kill Mode queue mechanics")
struct KillModeQueueMechanicsTests {
    private static let playlist = PlaylistSummary(id: "kill", name: "Kill")

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

    private static func engine(_ ids: [String], current: Int = 0, repeatMode: String = "off") -> PlaybackEngine {
        let engine = PlaybackEngine()
        engine.restore(
            library: nil,
            snapshot: PlaybackQueueSnapshot(
                queue: ids.map(track),
                currentIndex: current,
                position: 0,
                playlistSource: playlist,
                shuffle: false,
                repeatMode: repeatMode,
                savedAt: Date(),
                sourceQueueOrder: ids.map(track),
            )
        )
        return engine
    }

    private final class Skips {
        var ids: [String] = []
        var listened: Set<String>
        init(listened: Set<String> = []) { self.listened = listened }
    }

    /// Wires the engine through the app's own installer. A skip marks the song listened, as the app's
    /// red mark does, so the exclusion sees it.
    private static func wire(_ engine: PlaybackEngine, _ skips: Skips) {
        AppModel.wireKillModeHooks(
            on: engine,
            skipped: { track, _, _ in
                skips.ids.append(track.id)
                skips.listened.insert(track.id)
            },
            completed: { _, _, _ in },
            excludes: { skips.listened.contains($0.id) }
        )
    }

    // MARK: - K4: skipping the last song never marked it

    @Test("K4: skipping the last song with repeat off marks it")
    func skipLastSongMarks() {
        let engine = Self.engine(["A", "B"], current: 1)
        let skips = Skips()
        Self.wire(engine, skips)

        engine.skipNext()

        #expect(skips.ids == ["B"], "the last song's skip was never reported")
        #expect(engine.currentIndex == 1)
        #expect(!engine.isPlaying)
        engine.reset()
    }

    @Test("K4: skipping the last song under repeat-one marks it too")
    func skipLastSongRepeatOneMarks() {
        let engine = Self.engine(["A", "B"], current: 1, repeatMode: "one")
        let skips = Skips()
        Self.wire(engine, skips)

        engine.skipNext()

        #expect(skips.ids == ["B"])
        #expect(engine.currentIndex == 1)
        engine.reset()
    }

    // MARK: - K8: a forward skip landed on listened songs

    @Test("K8: the repeat-all wrap passes over a listened first song")
    func repeatAllWrapSkipsListened() {
        let engine = Self.engine(["A", "B", "C"], current: 2, repeatMode: "all")
        let skips = Skips(listened: ["A"])
        Self.wire(engine, skips)

        engine.skipNext()

        #expect(engine.currentIndex == 1, "the wrap landed on a listened song")
        #expect(skips.ids == ["C"])
        engine.reset()
    }

    @Test("K8: a mid-queue skip passes over listened songs")
    func midQueueSkipSkipsListened() {
        let engine = Self.engine(["A", "X", "Y", "B"], current: 0)
        let skips = Skips(listened: ["X", "Y"])
        Self.wire(engine, skips)

        engine.skipNext()

        #expect(engine.currentIndex == 3, "the skip landed on a listened song")
        engine.reset()
    }

    /// The skip is marked before the landing is chosen, so under repeat-all it cannot land back on
    /// the song it just rejected.
    @Test("K8: a repeat-all skip with nothing else unheard does not replay the skipped song")
    func repeatAllSkipDoesNotReplaySkipped() {
        let engine = Self.engine(["A", "B"], current: 0, repeatMode: "all")
        let skips = Skips(listened: ["B"])
        Self.wire(engine, skips)

        engine.skipNext()

        #expect(skips.ids == ["A"])
        #expect(engine.currentIndex == 0)
        #expect(!engine.isPlaying)
        engine.reset()
    }

    /// The deliberate route to a listened song: queue it on its own. Passes with or without the K8
    /// change — T329's exemption already covered it — and is here so K8 cannot take it away.
    @Test("K8 guard: a listened song queued on its own is still where the skip lands")
    func skipStillReachesHandPickedSong() async throws {
        let engine = Self.engine(["A", "B"])
        let skips = Skips(listened: ["X"])
        Self.wire(engine, skips)
        try await engine.playNext(library: nil, track: Self.track("X"))

        engine.skipNext()

        #expect(engine.currentIndex == 1)
        #expect(engine.queue[engine.currentIndex].id == "X")
        engine.reset()
    }

    // MARK: - K7: shuffle pulled played rows back into Up Next

    @Test("K7: shuffling a Kill Mode run leaves played rows behind the cursor")
    func killModeShuffleKeepsPlayedRowsBehind() {
        let engine = Self.engine(["A", "B", "C", "D", "E"], current: 2)
        engine.isKillModeRun = { true }

        engine.toggleShuffle()

        #expect(engine.currentIndex == 2, "the cursor moved, so played rows are ahead of it")
        #expect(engine.queue.prefix(3).map(\.id) == ["A", "B", "C"])
        #expect(Set(engine.queue.dropFirst(3).map(\.id)) == ["D", "E"])
        engine.reset()
    }

    /// Passes with or without the K7 change: restoring used the snapshot either way.
    @Test("K7 guard: shuffling off again restores the natural order in place")
    func killModeShuffleRestores() {
        let engine = Self.engine(["A", "B", "C", "D", "E"], current: 2)
        engine.isKillModeRun = { true }

        engine.toggleShuffle()
        if engine.isQueueOutOfNaturalOrder { engine.toggleShuffle() }

        #expect(engine.queue.map(\.id) == ["A", "B", "C", "D", "E"])
        #expect(engine.currentIndex == 2)
        engine.reset()
    }

    /// Outside Kill Mode, shuffling everything is intended. Passes with or without the change; it
    /// fails if the fix leaks out of Kill Mode.
    @Test("K7 guard: outside Kill Mode, shuffle still draws from the whole queue")
    func normalShuffleUsesWholeQueue() {
        let engine = Self.engine(["A", "B", "C", "D"], current: 2)
        engine.isKillModeRun = { false }

        engine.toggleShuffle()

        #expect(engine.currentIndex == 0)
        #expect(engine.queue.first?.id == "C")
        #expect(Set(engine.queue.dropFirst().map(\.id)) == ["A", "B", "D"])
        engine.reset()
    }

    // MARK: - K10: a playlist edited mid-run

    @Test("K10: a song removed from the playlist leaves the run ahead of the cursor")
    func removedSongLeavesUpNext() {
        let engine = Self.engine(["A", "B", "C", "D"], current: 1)

        engine.dropTracksRemovedFromSource(["D"])

        #expect(engine.queue.map(\.id) == ["A", "B", "C"])
        #expect(engine.currentIndex == 1)
        #expect(!engine.isInSourceQueueOrder(trackId: "D"))
        engine.reset()
    }

    /// The trap: the id-based removal advances when it hits the active song. This must not.
    @Test("K10: removing the playing song keeps it playing and stops it being marked")
    func removedActiveSongKeepsPlaying() {
        let engine = Self.engine(["A", "B", "C"], current: 1)

        engine.dropTracksRemovedFromSource(["B"])

        #expect(engine.queue.map(\.id) == ["A", "B", "C"])
        #expect(engine.currentIndex == 1)
        #expect(engine.activeTrack?.id == "B")
        #expect(!engine.isInSourceQueueOrder(trackId: "B"), "the song would be re-marked under a playlist it has left")
        #expect(AppModel.killModeMarkPlaylistId(
            source: .playlist(Self.playlist),
            enabledPlaylistIds: ["kill"],
            wasUserQueued: false,
            isInSourceQueueOrder: engine.isInSourceQueueOrder(trackId: "B")
        ) == nil)
        engine.reset()
    }

    @Test("K10: a removed song does not come back when shuffle is turned off")
    func removedSongStaysGoneAfterUnshuffle() {
        let engine = Self.engine(["A", "B", "C", "D"], current: 0)
        engine.toggleShuffle()

        engine.dropTracksRemovedFromSource(["C"])
        if engine.isQueueOutOfNaturalOrder { engine.toggleShuffle() }

        #expect(engine.queue.map(\.id) == ["A", "B", "D"])
        #expect(engine.currentIndex == 0)
        engine.reset()
    }

    /// Passes with or without the K10 change (nothing was removed before either). It fails if the
    /// removal starts reaching rows the user queued by hand.
    @Test("K10 guard: a song queued by hand stays queued")
    func handQueuedCopySurvives() async throws {
        let engine = Self.engine(["A", "B"])
        try await engine.playNext(library: nil, track: Self.track("X"))

        engine.dropTracksRemovedFromSource(["X"])

        #expect(engine.queue.map(\.id) == ["A", "X", "B"])
        engine.reset()
    }

    /// Passes with or without the K10 change. It fails if a fix removes the rows but not the source
    /// order, which lights the shuffle button on a queue nobody reordered.
    @Test("K10 guard: the queue still reads as in natural order")
    func dropKeepsNaturalOrder() {
        let engine = Self.engine(["A", "B", "C"], current: 0)

        engine.dropTracksRemovedFromSource(["B"])

        #expect(!engine.isQueueOutOfNaturalOrder)
        engine.reset()
    }

    // MARK: - K11: duplicate rows

    @Test("K11: removing one of two rows of a song keeps the song's marks")
    func oneOfTwoRowsKeepsMarks() {
        let leaving = PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
            candidates: ["X"],
            liveTrackIds: ["A", "X", "B", "X"],
            committedRowTrackIds: ["X"]
        )
        #expect(leaving.isEmpty, "the surviving copy's marks were cleared")
    }

    @Test("K11: removing every row of a song clears its marks")
    func allRowsClearMarks() {
        let leaving = PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
            candidates: ["X", "A"],
            liveTrackIds: ["A", "X", "B", "X"],
            committedRowTrackIds: ["X", "A", "X"]
        )
        #expect(leaving == ["X", "A"])
    }

    /// Jellyfin reports a removed *entry* as gone even when the song has another entry still there.
    @Test("K11: a row already gone clears marks only if no copy of the song is left")
    func goneRowRespectsSurvivingCopy() {
        let leaving = PlaylistRemovalTargeting.trackIdsLeavingPlaylist(
            candidates: ["X", "Z"],
            liveTrackIds: ["A", "X"],
            committedRowTrackIds: []
        )
        #expect(leaving == ["Z"])
    }

    // MARK: - K13: Up Next lists songs Kill Mode will pass over

    @Test("K13: Up Next does not list songs the natural end will skip")
    func upNextHidesExcludedRows() {
        let engine = Self.engine(["A", "X", "B", "Y", "C"])
        engine.autoAdvanceExclusion = { ["X", "Y"].contains($0.id) }

        #expect(engine.upNextEntries().map(\.track.id) == ["B", "C"])
        engine.reset()
    }

    /// The mapping proof. `C` is list position 1 but raw offset 3; a gesture that passed the list
    /// position through would hit `X` or `B` instead.
    @Test("K13: swipe-to-remove on a listed row removes that song, not the one at its list position")
    func swipeRemovesListedSong() throws {
        let engine = Self.engine(["A", "X", "B", "Y", "C"])
        engine.autoAdvanceExclusion = { ["X", "Y"].contains($0.id) }

        let entries = engine.upNextEntries()
        let c = try #require(entries.first { $0.track.id == "C" })
        #expect(entries.firstIndex { $0.track.id == "C" } == 1)
        #expect(c.upNextOffset == 3)
        engine.removeUpNextItems(at: IndexSet(integer: c.upNextOffset))

        #expect(engine.queue.map(\.id) == ["A", "X", "B", "Y"])
        engine.reset()
    }

    @Test("K13: drag-to-reorder moves the listed songs, and hidden rows stay put")
    func dragMovesListedSongs() throws {
        let engine = Self.engine(["A", "X", "B", "Y", "C"])
        engine.autoAdvanceExclusion = { ["X", "Y"].contains($0.id) }

        // Drag C (list position 1) above B (list position 0).
        let entries = engine.upNextEntries()
        let move = try #require(UpNextRows.moveArguments(entries: entries, source: IndexSet(integer: 1), destination: 0))
        engine.moveUpNextItem(from: move.source, to: move.destination)

        #expect(engine.queue.map(\.id) == ["A", "X", "C", "B", "Y"])
        #expect(engine.upNextEntries().map(\.track.id) == ["C", "B"])

        // And back down past the end of the list.
        let again = engine.upNextEntries()
        let down = try #require(UpNextRows.moveArguments(entries: again, source: IndexSet(integer: 0), destination: 2))
        engine.moveUpNextItem(from: down.source, to: down.destination)

        #expect(engine.upNextEntries().map(\.track.id) == ["B", "C"])
        #expect(engine.queue.map(\.id) == ["A", "X", "B", "C", "Y"])
        engine.reset()
    }
}
