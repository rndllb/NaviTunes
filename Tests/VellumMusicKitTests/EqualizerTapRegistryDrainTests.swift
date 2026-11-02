import Testing

@testable import VellumMusicKit

/// Pins the arithmetic in `EqualizerTapRegistry.drain(_:)` and `PlaybackCPUSampler`'s callback
/// delta against the crash recorded as T264.
///
/// Both crashing frames (`EqualizerTapRegistry.drain(_:)`, four of five reports; and
/// `closure #1 in PlaybackCPUSampler.sample(reason:)`, the fifth) were `EXC_BREAKPOINT` —
/// a Swift runtime trap, not a nil deref. In each case the trapping instruction is an unsigned
/// arithmetic operation on a counter the registry read out of a tap's render state:
///
/// - `drain`: `written - alreadyDrained`, which underflows the moment `written` comes back
///   *below* the high-water mark the registry recorded on a previous drain.
/// - the sampler: `Int64(someUInt64)`, which traps on any value above `Int64.max`.
///
/// Neither can happen while the render state is alive and its counters only ever move forward.
/// Both happen immediately once the registry reads a tap whose storage has been freed —
/// `tapFinalize` deallocates the render state, and before this fix it did so while leaving the
/// tap in the registry's `taps` dictionary for the half-second drain timer to keep reading.
///
/// These tests do not simulate the use-after-free (that is undefined behaviour, not something to
/// pin in a test). They pin the weaker, sufficient property: **a counter that regresses, or one
/// larger than `Int64.max`, must not trap.** That is what turns the residual race — which the
/// registry cannot fully close while it reads a raw pointer outside its lock — from a process
/// kill into a wrong number in a diagnostic log.
@Suite("EqualizerTapRegistry drain arithmetic")
struct EqualizerTapRegistryDrainTests {
    private func makeTap() -> EqualizerAudioTap {
        EqualizerAudioTap(
            trackId: "t264",
            trackTitle: "Regressed Counters",
            gains: [Float](repeating: 0, count: EqualizerBand.count),
            bypassed: false,
        )
    }

    /// The exact shape of the four-of-five crash.
    ///
    /// The guard in `drain` is `written > alreadyDrained || entries > alreadyDrainedEntries`, and
    /// the subtraction below it uses only the first pair. So the *entries* half can wave through a
    /// call whose *ring* counter has gone backwards — which is precisely the freed-memory read,
    /// where the two counters are unrelated garbage rather than a matched pair.
    @Test("a ring counter that went backwards does not trap the drain")
    func regressedRingCounterDoesNotTrap() {
        let tap = makeTap()
        defer { tap.disposeBeforeAttachment() }

        // A healthy drain first, so the registry records a high-water mark to underflow against.
        tap.state.pointee.ringWriteCount = 400
        tap.state.pointee.processEntryCount = 400
        EqualizerTapRegistry.shared.drain(tap)

        // Now the ring counter comes back below the mark while entries run past it. Before the
        // fix this reached `written - alreadyDrained` as `12 - 400` and trapped.
        tap.state.pointee.ringWriteCount = 12
        tap.state.pointee.processEntryCount = 900
        EqualizerTapRegistry.shared.drain(tap)
    }

    /// The same regression with no entry growth must stay silent rather than trap — the guard
    /// should simply decline the call.
    @Test("a fully regressed pair is declined, not underflowed")
    func fullyRegressedCountersAreDeclined() {
        let tap = makeTap()
        defer { tap.disposeBeforeAttachment() }

        tap.state.pointee.ringWriteCount = 400
        tap.state.pointee.processEntryCount = 400
        EqualizerTapRegistry.shared.drain(tap)

        tap.state.pointee.ringWriteCount = 1
        tap.state.pointee.processEntryCount = 1
        EqualizerTapRegistry.shared.drain(tap)
    }

    /// `ringCapacity` is read from the same freed storage, and a zero or negative value would
    /// trap the `UInt64(_:)` conversion on the line that computes `lost`.
    @Test("a garbage ring capacity does not trap the drain", arguments: [Int32(0), -1, Int32.min])
    func garbageRingCapacityDoesNotTrap(capacity: Int32) {
        let tap = makeTap()
        defer { tap.disposeBeforeAttachment() }

        tap.state.pointee.ringCapacity = capacity
        tap.state.pointee.ringWriteCount = 50
        tap.state.pointee.processEntryCount = 50
        EqualizerTapRegistry.shared.drain(tap)
    }

    // MARK: - PlaybackCPUSampler

    /// The fifth crash. `callbackCountProvider` is `EqualizerTapRegistry.totalProcessCallbacks()`,
    /// which sums `processCount` across live taps with wrapping addition — so a freed tap's
    /// garbage count propagates straight into `Int64(_:)`, which traps above `Int64.max`.
    @Test("a callback count above Int64.max saturates instead of trapping")
    func hugeCallbackCountSaturates() {
        #expect(PlaybackCPUSampler.callbackDelta(current: .max, previous: 0) == .max)
    }

    @Test("a callback count that went backwards reports no progress, not a negative delta")
    func regressedCallbackCountClamps() {
        #expect(PlaybackCPUSampler.callbackDelta(current: 5, previous: 900) == 0)
    }

    @Test("an ordinary advance is still reported verbatim")
    func ordinaryCallbackDeltaIsUnchanged() {
        #expect(PlaybackCPUSampler.callbackDelta(current: 1_500, previous: 1_000) == 500)
    }
}
