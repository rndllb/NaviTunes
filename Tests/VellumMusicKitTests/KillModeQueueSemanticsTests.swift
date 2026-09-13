import Foundation
import Testing

@testable import VellumMusicKit

/// Kill Mode's auto-advance exclusion, its marking, and the hand-queued provenance both depend on.
///
/// Kill Mode burns a playlist down: each song plays once, a skip marks it red, a natural end marks
/// it green, and listened songs are skipped over on later runs. Hand-queueing is the exception, and
/// it has two halves that must not be confused:
///
/// - a **single song** queued by hand plays even if listened — the user picked it;
/// - a **whole collection** queued at once (the playlist hero's Play Next, a cell menu) still
///   respects the filter — same intent as pressing play on it.
///
/// Engine tests use `restore`, which builds queue state without loading anything, so no player or
/// server is involved.
@MainActor
@Suite("Kill Mode queue semantics")
struct KillModeQueueSemanticsTests {
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

    // MARK: - K1: a listened song queued on its own is skipped at natural end

    /// All three walks are checked because they are three separate consumers of the exclusion.
    /// `upcomingQueueIndices` is the one that matters most: it is what stages the next item into the
    /// AVQueuePlayer, so a fix that only reached `nextAdvanceIndex` would still drop the song on the
    /// gapless path.
    @Test("K1: Play Next on one listened song makes it the next track on every walk")
    func playNextSingleListenedSongPlays() async throws {
        let engine = Self.engine(["A", "B"])
        engine.autoAdvanceExclusion = { $0.id == "X" }

        try await engine.playNext(library: nil, track: Self.track("X"))

        #expect(engine.queue.map(\.id) == ["A", "X", "B"])
        #expect(engine.upcomingQueueIndices(limit: 1) == [1], "gapless staging skipped the hand-queued song")
        #expect(engine.nextAdvanceIndex() == 1, "natural-end advance skipped the hand-queued song")
        #expect(engine.autoSkipIndex() == 1, "failure auto-skip skipped the hand-queued song")
        engine.reset()
    }

    @Test("K1: Add to Queue on one listened song plays it too")
    func addToQueueSingleListenedSongPlays() async throws {
        let engine = Self.engine(["A", "B"])
        engine.autoAdvanceExclusion = { $0.id == "X" }

        try await engine.addToQueue(library: nil, track: Self.track("X"))

        #expect(engine.queue.map(\.id) == ["A", "X", "B"])
        #expect(engine.upcomingQueueIndices(limit: 1) == [1])
        #expect(engine.nextAdvanceIndex() == 1)
        engine.reset()
    }

    /// The other half of the rule. Honouring queued ids blindly would make the playlist hero's Play
    /// Next replay a playlist the user has already burned down.
    @Test("K1 rule: Play Next on a whole playlist still skips its listened songs")
    func playTracksNextCollectionRespectsFilter() async throws {
        let engine = Self.engine(["A", "B"])
        engine.autoAdvanceExclusion = { $0.id == "X" }

        try await engine.playTracksNext(library: nil, tracks: [Self.track("X"), Self.track("Y")])

        #expect(engine.queue.map(\.id) == ["A", "X", "Y", "B"])
        #expect(engine.upcomingQueueIndices(limit: 1) == [2])
        #expect(engine.nextAdvanceIndex() == 2)
        #expect(engine.autoSkipIndex() == 2)
        engine.reset()
    }

    @Test("K1 rule: Add to Queue on a whole collection still skips its listened songs")
    func addTracksToQueueCollectionRespectsFilter() async throws {
        let engine = Self.engine(["A", "B"])
        engine.autoAdvanceExclusion = { $0.id == "X" }

        try await engine.addTracksToQueue(library: nil, tracks: [Self.track("X"), Self.track("Y")])

        #expect(engine.queue.map(\.id) == ["A", "X", "Y", "B"])
        #expect(engine.nextAdvanceIndex() == 2)
        engine.reset()
    }

    /// Re-queueing replaces the row (`removeUpcomingOccurrences`), so the latest entry point is the
    /// intent that describes what will play.
    @Test("K1 rule: re-queueing a single song as part of a collection re-applies the filter")
    func collectionRequeueReclassifies() async throws {
        let engine = Self.engine(["A", "B"])
        engine.autoAdvanceExclusion = { $0.id == "X" }

        try await engine.playNext(library: nil, track: Self.track("X"))
        try await engine.playTracksNext(library: nil, tracks: [Self.track("X"), Self.track("Y")])

        #expect(engine.queue.map(\.id) == ["A", "X", "Y", "B"])
        #expect(engine.nextAdvanceIndex() == 2)
        engine.reset()
    }

    // MARK: - K2: hand-queued songs get marked in the source playlist

    @Test("K2: a single song's hand-queued flag is still readable when it ends")
    func singleSongFlagSurvivesToTrackEnd() {
        var provenance = UserQueueProvenance()
        provenance.insert(["X"], handPicked: true)
        provenance.trackStarted(id: "X", index: 1)
        #expect(provenance.wasUserQueuedAtTrackEnd(id: "X", index: 1))
    }

    /// Collections are exempt from the *exclusion* override, not from the marking guard: any
    /// Play Next / Add to Queue insert stays unmarked, as the handlers have always documented.
    @Test("K2: a collection-queued song's flag is still readable when it ends")
    func collectionSongFlagSurvivesToTrackEnd() {
        var provenance = UserQueueProvenance()
        provenance.insert(["X", "Y"], handPicked: false)
        provenance.trackStarted(id: "X", index: 1)
        #expect(provenance.wasUserQueuedAtTrackEnd(id: "X", index: 1))
    }

    /// Repeat-one restarts the same row; the second pass is still the hand-queued song.
    @Test("K2: replaying the same row keeps its flag")
    func sameRowReplayKeepsFlag() {
        var provenance = UserQueueProvenance()
        provenance.insert(["X"], handPicked: true)
        provenance.trackStarted(id: "X", index: 1)
        provenance.trackStarted(id: "X", index: 1)
        #expect(provenance.wasUserQueuedAtTrackEnd(id: "X", index: 1))
    }

    /// A rapid second skip lands on a row that never started. Its flag is still the queued set.
    @Test("K2: skipping a queued row that never started still reads as hand-queued")
    func neverStartedQueuedRowIsHandQueued() {
        var provenance = UserQueueProvenance()
        provenance.insert(["X", "Y"], handPicked: true)
        provenance.trackStarted(id: "X", index: 1)
        #expect(provenance.wasUserQueuedAtTrackEnd(id: "Y", index: 2))
    }

    @Test("K2: a hand-queued song is never marked")
    func handQueuedIsNotMarked() {
        let mark = AppModel.killModeMarkPlaylistId(
            source: .playlist(Self.playlist),
            enabledPlaylistIds: ["kill"],
            wasUserQueued: true,
            isInSourceQueueOrder: true
        )
        #expect(mark == nil)
    }

    /// The flag can still be lost — skip back onto a hand-queued song that already played, or a
    /// snapshot from before the flag existed — so membership is checked independently of it.
    @Test("K2: a song outside the playlist run is never marked, even when not flagged")
    func nonMemberIsNotMarked() {
        let mark = AppModel.killModeMarkPlaylistId(
            source: .playlist(Self.playlist),
            enabledPlaylistIds: ["kill"],
            wasUserQueued: false,
            isInSourceQueueOrder: false
        )
        #expect(mark == nil)
    }

    @Test("K2: the playlist's own unqueued song is still marked")
    func memberIsMarked() {
        let mark = AppModel.killModeMarkPlaylistId(
            source: .playlist(Self.playlist),
            enabledPlaylistIds: ["kill"],
            wasUserQueued: false,
            isInSourceQueueOrder: true
        )
        #expect(mark == "kill")
    }

    @Test("K2: a Play Next insert is not part of the source order")
    func playNextInsertIsNotSourceMember() async throws {
        let engine = Self.engine(["A", "B"])
        try await engine.playNext(library: nil, track: Self.track("X"))
        #expect(engine.isInSourceQueueOrder(trackId: "A"))
        #expect(!engine.isInSourceQueueOrder(trackId: "X"))
        engine.reset()
    }

    // MARK: - c4: the start-time removal is load-bearing

    /// Without the removal the id lingers all session — and in the saved snapshot — so the
    /// playlist's own copy of that song reads as hand-queued: never marked, listed under Queue, and
    /// mis-positioning Add to Queue.
    @Test("c4: starting a hand-queued song still clears its id from the queued set")
    func startStillClearsQueuedId() {
        var provenance = UserQueueProvenance()
        provenance.insert(["X"], handPicked: true)
        provenance.trackStarted(id: "X", index: 1)
        #expect(!provenance.queuedIds.contains("X"))
        #expect(!provenance.handPickedIds.contains("X"))
        #expect(!provenance.isExemptFromKillModeFilter("X"))
    }

    /// Repeat-all wrap, shuffle, or restore of natural order: a different row with the same id.
    @Test("c4: the playlist's own copy of a hand-queued song is not hand-queued")
    func laterNaturalCopyIsNotHandQueued() {
        var provenance = UserQueueProvenance()
        provenance.insert(["X"], handPicked: true)
        provenance.trackStarted(id: "X", index: 1)
        provenance.trackStarted(id: "B", index: 2)
        provenance.trackStarted(id: "X", index: 4)
        #expect(!provenance.wasUserQueuedAtTrackEnd(id: "X", index: 4))
    }

    /// The persisted path: a snapshot taken after X started, restored, then the queue wraps back to
    /// the playlist's own X. The id must not have ridden the snapshot across.
    @Test("c4: a snapshot taken after the start does not carry the id across a restore")
    func snapshotAfterStartDoesNotCarryId() async throws {
        let engine = Self.engine(["A", "X", "B"])
        try await engine.playNext(library: nil, track: Self.track("Y"))
        // Stands in for Y's start; `advance()` cannot run without a player.
        var provenance = engine.userQueue
        provenance.trackStarted(id: "Y", index: 1)
        let restored = UserQueueProvenance(
            queuedIds: provenance.queuedIds,
            handPickedIds: provenance.handPickedIds,
            activeTrackWasUserQueued: provenance.activeTrackWasUserQueued,
            activeIndex: provenance.activeIndex,
            activeTrackId: provenance.activeTrackId
        )
        #expect(restored.queuedIds.isEmpty)
        #expect(!restored.isExemptFromKillModeFilter("Y"))
        #expect(!restored.wasUserQueuedAtTrackEnd(id: "Y", index: 5))
        engine.reset()
    }

    // MARK: - K3: an unlocked playlist stops after one song

    @Test("K3: an unlocked run auto-advances into kept songs")
    func unlockedRunPlaysKeptSongs() {
        #expect(!AppModel.killModeAutoAdvanceExcludes(isListened: true, isPending: false, runUnlocked: true))
    }

    @Test("K3: an unlocked run still skips songs marked for removal")
    func unlockedRunSkipsRed() {
        #expect(AppModel.killModeAutoAdvanceExcludes(isListened: true, isPending: true, runUnlocked: true))
    }

    @Test("K3: a locked run skips everything listened")
    func lockedRunSkipsListened() {
        #expect(AppModel.killModeAutoAdvanceExcludes(isListened: true, isPending: false, runUnlocked: false))
        #expect(!AppModel.killModeAutoAdvanceExcludes(isListened: false, isPending: false, runUnlocked: false))
    }

    /// The symptom end to end on an engine: every song green, run unlocked, natural end of the first.
    @Test("K3: an unlocked three-song run moves on to the second song")
    func unlockedRunAdvances() {
        let engine = Self.engine(["A", "B", "C"])
        let passed: Set<String> = ["A", "B", "C"]
        let unlocked = AppModel.killModeUnlocked(trackIds: ["A", "B", "C"], pending: [], passed: passed)
        #expect(unlocked)
        engine.autoAdvanceExclusion = { track in
            AppModel.killModeAutoAdvanceExcludes(
                isListened: passed.contains(track.id),
                isPending: false,
                runUnlocked: unlocked
            )
        }
        #expect(engine.nextAdvanceIndex() == 1)
        #expect(engine.upcomingQueueIndices(limit: 1) == [1])
        engine.reset()
    }

    @Test("K3: unlock is still integers-only and ignores songs marked for removal")
    func unlockCounting() {
        #expect(!AppModel.killModeUnlocked(trackIds: ["A", "B"], pending: [], passed: ["A"]))
        #expect(AppModel.killModeUnlocked(trackIds: ["A", "B"], pending: ["B"], passed: ["A"]))
        #expect(!AppModel.killModeUnlocked(trackIds: ["A"], pending: ["A"], passed: []))
    }

    // MARK: - K6: two songs play twice

    private final class Marks {
        var listened: Set<String>
        /// Ids the exclusion was asked about while the just-ended song's mark had not landed yet.
        var askedBeforeMarked: [String] = []
        init(listened: Set<String>) { self.listened = listened }
    }

    /// Wires a real engine through the app's own installer, so the hop — or its absence — is the
    /// app's, not the test's.
    private static func wire(_ engine: PlaybackEngine, marks: Marks, endedId: String) {
        AppModel.wireKillModeHooks(
            on: engine,
            skipped: { _, _, _ in },
            completed: { track, _, _ in marks.listened.insert(track.id) },
            excludes: { track in
                let excluded = marks.listened.contains(track.id)
                if track.id == endedId, !excluded { marks.askedBeforeMarked.append(track.id) }
                return excluded
            }
        )
    }

    @Test("K6: under repeat-all the song that just ended is not chosen again")
    func repeatAllDoesNotReplayEndedSong() {
        let engine = Self.engine(["A", "B"], current: 0, repeatMode: "all")
        let marks = Marks(listened: ["B"])
        Self.wire(engine, marks: marks, endedId: "A")

        engine.handleEnded()

        #expect(marks.askedBeforeMarked.isEmpty, "the advance consulted A before A's green mark landed")
        #expect(marks.listened.contains("A"))
        #expect(!engine.isPlaying)
        engine.reset()
    }

    @Test("K6: a back-to-back duplicate of the song that just ended is skipped")
    func backToBackDuplicateSkipped() {
        let engine = Self.engine(["A", "A", "C"], current: 0)
        let marks = Marks(listened: [])
        Self.wire(engine, marks: marks, endedId: "A")

        engine.handleEnded()

        #expect(engine.currentIndex == 2, "advanced into the duplicate of the song that just ended")
        #expect(marks.askedBeforeMarked.isEmpty)
        engine.reset()
    }
}
