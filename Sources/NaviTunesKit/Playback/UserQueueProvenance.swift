import Foundation

/// Which queue rows the user put there by hand, and whether the playing one was among them.
///
/// Two questions are asked of this, at two different times, and answering both from one id set
/// was the bug:
///
/// - **Before a row plays**, auto-advance asks whether Kill Mode may skip over it
///   (``isExemptFromKillModeFilter(_:)``). A song queued **on its own** — `playNext(track:)` /
///   `addToQueue(track:)` — was picked deliberately and plays even when already listened. A
///   **collection** queued at once — `playTracksNext(tracks:)` / `addTracksToQueue(tracks:)`, which
///   is what a playlist or album hero and cell menu call — carries the same intent as pressing play
///   on it, so the filter still applies. The distinction is *which entry point the caller used*.
///   Nothing is inferred from how many tracks were passed: a one-song playlist queued from its hero
///   is still a collection.
/// - **After a row plays**, Kill Mode's marking asks whether the song that just ended was
///   hand-queued (``wasUserQueuedAtTrackEnd(id:index:)``). By then its id has already left
///   ``queuedIds`` — removed at track start, deliberately (see ``trackStarted(id:index:)``) — so the
///   answer is captured at start rather than looked up at end.
struct UserQueueProvenance: Equatable {
    /// Hand-queued ids that have not started yet. Drives Now Playing's Queue / Continue Playing
    /// split and where Add to Queue inserts.
    var queuedIds: Set<String> = [] {
        didSet { handPickedIds.formIntersection(queuedIds) }
    }

    /// The subset of ``queuedIds`` queued as a single song. Kept a subset by ``queuedIds``' observer,
    /// so every existing removal path (clear, prune, row delete) drops these too.
    private(set) var handPickedIds: Set<String> = []

    /// Whether the row that last started was hand-queued when it started.
    private(set) var activeTrackWasUserQueued = false

    /// The row that last started, so a replay of that same row (repeat-one, reload) keeps its flag
    /// while a *different* row carrying the same id does not.
    private(set) var activeIndex: Int?
    private(set) var activeTrackId: String?

    init() {}

    /// Rebuilds persisted state. `handPickedIds` is intersected with `queuedIds` here too, because the
    /// observer does not run during initialisation.
    init(
        queuedIds: Set<String>,
        handPickedIds: Set<String>,
        activeTrackWasUserQueued: Bool,
        activeIndex: Int?,
        activeTrackId: String?
    ) {
        self.queuedIds = queuedIds
        self.handPickedIds = handPickedIds.intersection(queuedIds)
        self.activeTrackWasUserQueued = activeTrackWasUserQueued
        self.activeIndex = activeIndex
        self.activeTrackId = activeTrackId
    }

    /// Records ids the user queued. `handPicked` is true only for the single-song entry points.
    /// Re-queueing an id through the other kind of entry point re-classifies it: the row it had is
    /// pulled out by `removeUpcomingOccurrences` and replaced, so the latest intent is the one that
    /// describes the row that will play.
    mutating func insert<S: Sequence>(_ ids: S, handPicked: Bool) where S.Element == String {
        let idSet = Set(ids)
        queuedIds.formUnion(idSet)
        if handPicked {
            handPickedIds.formUnion(idSet)
        } else {
            handPickedIds.subtract(idSet)
        }
    }

    /// True when Kill Mode's auto-advance filter must not skip this id.
    func isExemptFromKillModeFilter(_ id: String) -> Bool {
        handPickedIds.contains(id)
    }

    /// Bookkeeping for a row becoming the playing track.
    ///
    /// The id leaves ``queuedIds`` (and so ``handPickedIds``) **here, at start**, and that removal is
    /// load-bearing. Left in, it lingers for the session — and in the saved snapshot — so on a
    /// repeat-all wrap, a shuffle, or a restore of natural order the playlist's *own* copy of the
    /// song reads as hand-queued: never marked, listed under Queue instead of Continue Playing, and
    /// throwing off where Add to Queue inserts. What carries to track end is the captured flag, which
    /// is tied to this row and not to the id.
    mutating func trackStarted(id: String, index: Int) {
        let replayOfSameRow = activeIndex == index && activeTrackId == id
        let wasQueued = queuedIds.remove(id) != nil
        activeTrackWasUserQueued = wasQueued || (replayOfSameRow && activeTrackWasUserQueued)
        activeIndex = index
        activeTrackId = id
    }

    /// Whether the track ending at `index` was hand-queued.
    ///
    /// For the row that last started, the flag captured at its start. For a row that never started —
    /// a second skip landing before the first load finished — its id is still in ``queuedIds``.
    func wasUserQueuedAtTrackEnd(id: String, index: Int) -> Bool {
        if activeIndex == index, activeTrackId == id { return activeTrackWasUserQueued }
        return queuedIds.contains(id)
    }

    /// Follows a stale-id swap so a hand-queued song keeps its provenance under its new id.
    mutating func remap(_ swaps: [String: String]) {
        guard !swaps.isEmpty else { return }
        var nextQueued = queuedIds
        var nextHandPicked = handPickedIds
        for (oldId, newId) in swaps {
            if nextQueued.remove(oldId) != nil { nextQueued.insert(newId) }
            if nextHandPicked.remove(oldId) != nil { nextHandPicked.insert(newId) }
        }
        queuedIds = nextQueued
        handPickedIds = nextHandPicked.intersection(nextQueued)
        if let active = activeTrackId, let swapped = swaps[active] { activeTrackId = swapped }
    }
}
