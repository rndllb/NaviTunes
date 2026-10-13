import AVFoundation
import Foundation

/// Host-clock arithmetic shared by the blend transport and its tests. Pure.
enum AutoMixHostClock {
    /// Host ticks → seconds, signed.
    nonisolated static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        if end >= start { return AVAudioTime.seconds(forHostTime: end - start) }
        return -AVAudioTime.seconds(forHostTime: start - end)
    }

    nonisolated static func hostTime(adding seconds: TimeInterval, to host: UInt64) -> UInt64 {
        host + AVAudioTime.hostTime(forSeconds: max(0, seconds))
    }

    /// An anchor pushed forward by the paused interval. An unset anchor (0) stays unset and a
    /// clock that did not advance leaves it alone (T643 c3).
    nonisolated static func resumedAnchor(_ anchor: UInt64, pausedAt: UInt64, resumedAt: UInt64) -> UInt64 {
        guard anchor > 0, resumedAt > pausedAt else { return anchor }
        return anchor &+ (resumedAt - pausedAt)
    }
}

/// One linear gain ramp in an item's own timeline, for `AVMutableAudioMixInputParameters`.
struct AutoMixVolumeRamp: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let from: Float
    let to: Float
}

/// One AutoMix transition on two `AVPlayer`s — and no second audio engine (T677).
///
/// The outgoing song stays on the queue player it has been playing on all along; its fade,
/// bass hand-over and filter sweep are driven on that player (`volume`) and on its equalizer
/// tap's two transition bands. The incoming song starts on a second `AVQueuePlayer` at the
/// host time the outgoing reaches its mix-out (`setRate(_:time:atHostTime:)`, measured to start
/// within 2–4 ms and to agree with a second player to 0.0 ms), with its whole gain curve —
/// equal-power fade, loudness trim, trim glide — baked into its audio mix as sample-accurate
/// volume ramps, its time-stretch as the player's `rate` (`.spectral`), and its bass/filter on
/// its own tap. When the outgoing has faded to silence, `PlaybackEngine` makes the incoming
/// player *the* queue player. Nothing audible ever changes hands: the two 80 ms transport
/// crossings this replaces (queue player → engine at the handoff, engine → queue player at the
/// handback) were each a measurable gap, and the engine's cold start alone put the deck 47 ms
/// behind the player it was supposed to continue.
@MainActor
final class AutoMixPlayerBlend {
    enum Failure: Error {
        case mixOutAlreadyPassed
        case notArmed
    }

    let automation: AutoMixAutomation
    /// The queue player carrying the outgoing song. Released at adoption (`releaseOutgoing`).
    private(set) var outgoing: AVPlayer?
    private(set) var outgoingTap: EqualizerAudioTap?
    let incoming: AVQueuePlayer
    let incomingItem: AVPlayerItem
    let incomingTap: EqualizerAudioTap?
    /// The incoming item's audio mix without the blend's volume ramps: swapped in once the
    /// transition has settled, so a later seek back into the song's first seconds plays it at
    /// full level. Same tap, same input parameters otherwise.
    let incomingPlainMix: AVAudioMix?

    /// Fired once when the overlap has completed: the outgoing song is silent, the incoming is
    /// all there is. `PlaybackEngine` adopts the incoming player here.
    var onOverlapCompleted: (() -> Void)?
    /// Fired once when the transition has settled (rate back at 1.0, trim at unity).
    var onSettled: (() -> Void)?

    private var tick: Timer?
    /// Host time at which the overlap starts: the incoming player's scheduled start.
    private(set) var overlapStartHostTime: UInt64 = 0
    private var pausedAtHostTime: UInt64 = 0
    private(set) var isArmed = false
    private(set) var isPaused = false
    private(set) var overlapCompleted = false
    private(set) var isSettled = false
    private var appliedRate: Float = 0
    private var appliedOutgoingVolume: Float = 1
    private var incomingStarted = false
    private var lastOutgoingPosition: TimeInterval = -1
    /// Drifts (seconds, outgoing minus plan) the lead-in correction has re-scheduled for.
    private(set) var leadInCorrections: [TimeInterval] = []

    init(
        automation: AutoMixAutomation,
        outgoing: AVPlayer,
        outgoingTap: EqualizerAudioTap?,
        incoming: AVQueuePlayer,
        incomingItem: AVPlayerItem,
        incomingTap: EqualizerAudioTap?,
        incomingPlainMix: AVAudioMix?,
    ) {
        self.automation = automation
        self.outgoing = outgoing
        self.outgoingTap = outgoingTap
        self.incoming = incoming
        self.incomingItem = incomingItem
        self.incomingTap = incomingTap
        self.incomingPlainMix = incomingPlainMix
    }

    deinit {
        tick?.invalidate()
    }

    // MARK: - Plan arithmetic (pure)

    var mixOut: TimeInterval {
        switch automation.style {
        case let .beatMatched(p): return p.outgoingMixOut
        case let .crossfade(p): return p.outgoingMixOut
        }
    }

    var mixIn: TimeInterval {
        switch automation.style {
        case let .beatMatched(p): return p.incomingMixIn
        case let .crossfade(p): return p.incomingMixIn
        }
    }

    /// The incoming player's rate at the overlap start.
    nonisolated static func initialRate(_ automation: AutoMixAutomation) -> Float {
        automation.frame(at: 0).incomingRate
    }

    /// Item time of the incoming song at output time `t` since the overlap began: through the
    /// per-bar schedule and the glide for a beat-matched blend, mix-in plus `t` for a crossfade.
    nonisolated static func incomingItemTime(_ automation: AutoMixAutomation, at t: TimeInterval) -> TimeInterval {
        switch automation.style {
        case let .beatMatched(plan): return AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: max(0, t))
        case let .crossfade(plan): return plan.incomingMixIn + max(0, t)
        }
    }

    /// The incoming song's gain curve as ramps in its own timeline: `incomingGain × incomingTrim`
    /// sampled every `step` output seconds from the overlap start to the end of the settle. The
    /// first ramp starts at mix-in from 0, the last ends at unity. Piecewise linear on a sine is
    /// within 0.1 dB at a 100 ms step on an 8 s fade.
    nonisolated static func incomingVolumeRamps(_ automation: AutoMixAutomation, step: TimeInterval = 0.1) -> [AutoMixVolumeRamp] {
        let total = automation.totalDuration
        guard total > 0, step > 0 else { return [] }
        let count = max(1, Int((total / step).rounded(.up)))
        var ramps: [AutoMixVolumeRamp] = []
        var tPrev: TimeInterval = 0
        var gPrev = gain(automation, at: 0)
        for k in 1 ... count {
            let t = min(total, Double(k) * step)
            let g = gain(automation, at: t)
            let start = incomingItemTime(automation, at: tPrev)
            let end = incomingItemTime(automation, at: t)
            if end > start { ramps.append(AutoMixVolumeRamp(start: start, end: end, from: gPrev, to: g)) }
            tPrev = t
            gPrev = g
        }
        return ramps
    }

    nonisolated static func gain(_ automation: AutoMixAutomation, at t: TimeInterval) -> Float {
        let frame = automation.frame(at: t)
        return frame.incomingGain * frame.incomingTrim
    }

    /// Host time at which the outgoing player, now at `position`, reaches the mix-out — the
    /// incoming player's start. `nil` when the mix-out is already behind.
    nonisolated static func overlapStart(outgoingPosition: TimeInterval, mixOut: TimeInterval, now: UInt64) -> UInt64? {
        let secondsUntil = mixOut - outgoingPosition
        guard secondsUntil > 0.05 else { return nil }
        return AutoMixHostClock.hostTime(adding: secondsUntil, to: now)
    }

    // MARK: - Lifecycle

    /// Schedule the incoming player to start exactly when the outgoing reaches its mix-out, and
    /// start driving the automation. The incoming item must be ready, seeked to mix-in and
    /// pre-rolled at the initial rate.
    func arm(outgoingPosition: TimeInterval, now: UInt64 = mach_absolute_time()) throws {
        guard let start = Self.overlapStart(outgoingPosition: outgoingPosition, mixOut: mixOut, now: now) else {
            throw Failure.mixOutAlreadyPassed
        }
        overlapStartHostTime = start
        let rate = Self.initialRate(automation)
        appliedRate = rate
        incoming.setRate(rate, time: CMTime(seconds: mixIn, preferredTimescale: 44_100), atHostTime: CMClockMakeHostTimeFromSystemUnits(start))
        incomingStarted = true
        isArmed = true
        isPaused = false
        apply(automation.frame(at: -1))
        armTick()
    }

    /// Output seconds since the overlap began on the host clock (negative before it). While
    /// paused the clock stands at the pause: the overlap is as far along as the audio is.
    func outputSecondsSinceOverlap(now: UInt64 = mach_absolute_time()) -> TimeInterval {
        guard overlapStartHostTime > 0 else { return 0 }
        let at = isPaused && pausedAtHostTime > 0 ? pausedAtHostTime : now
        return AutoMixHostClock.seconds(from: overlapStartHostTime, to: at)
    }

    /// 0…1 through the overlap for the Now Playing visual crossfade; `nil` outside a transition.
    var overlapProgress: Double? {
        guard isArmed, !isSettled, automation.overlapDuration > 0 else { return nil }
        let t = outputSecondsSinceOverlap()
        guard t >= 0 else { return 0 }
        return min(1, t / automation.overlapDuration)
    }

    var overlapSecondsRemaining: TimeInterval {
        guard isArmed, !overlapCompleted else { return 0 }
        return max(0, automation.overlapDuration - outputSecondsSinceOverlap())
    }

    var incomingPosition: TimeInterval? {
        guard isArmed else { return nil }
        let t = incoming.currentTime().seconds
        return t.isFinite ? t : nil
    }

    var outgoingPosition: TimeInterval? {
        guard let outgoing else { return nil }
        let t = outgoing.currentTime().seconds
        return t.isFinite ? t : nil
    }

    var incomingDuration: TimeInterval {
        let d = incomingItem.duration.seconds
        return d.isFinite && d > 0 ? d : 0
    }

    /// The outgoing song is done with: its player is `PlaybackEngine`'s to stop and its tap is
    /// retired there. The automation stops touching either.
    func releaseOutgoing() {
        outgoingTap?.setTransition(bassDB: 0, lowPassHz: nil)
        outgoing = nil
        outgoingTap = nil
    }

    func pause() {
        guard isArmed, !isPaused else { return }
        pausedAtHostTime = mach_absolute_time()
        outgoing?.pause()
        incoming.pause()
        isPaused = true
    }

    /// Both players restart together at one host time a moment from now, from where they stand;
    /// if the overlap had not begun, the incoming start is re-scheduled against the outgoing's
    /// position, so a pause in the lead-in still lands the downbeat.
    func resume(lead: TimeInterval = 0.15) throws {
        guard isArmed, isPaused else { return }
        let now = mach_absolute_time()
        let resumeAt = AutoMixHostClock.hostTime(adding: lead, to: now)
        let elapsed = outputSecondsSinceOverlap(now: pausedAtHostTime)
        if elapsed < 0 || !incomingStarted {
            // Lead-in: the outgoing resumes at `resumeAt`; the overlap starts when it reaches
            // the mix-out from there.
            let position = outgoingPosition ?? (mixOut + elapsed)
            overlapStartHostTime = AutoMixHostClock.hostTime(adding: max(0, mixOut - position), to: resumeAt)
            let rate = Self.initialRate(automation)
            appliedRate = rate
            incoming.setRate(rate, time: CMTime(seconds: mixIn, preferredTimescale: 44_100), atHostTime: CMClockMakeHostTimeFromSystemUnits(overlapStartHostTime))
        } else {
            overlapStartHostTime = AutoMixHostClock.resumedAnchor(overlapStartHostTime, pausedAt: pausedAtHostTime, resumedAt: resumeAt)
            incoming.setRate(appliedRate, time: incoming.currentTime(), atHostTime: CMClockMakeHostTimeFromSystemUnits(resumeAt))
        }
        if let outgoing { outgoing.setRate(1, time: outgoing.currentTime(), atHostTime: CMClockMakeHostTimeFromSystemUnits(resumeAt)) }
        pausedAtHostTime = 0
        lastOutgoingPosition = -1
        isPaused = false
    }

    /// Abandon the transition. The incoming player is stopped unless it has been adopted (then
    /// it is the queue player and not ours to stop); the outgoing, if still ours, goes back to
    /// full level with its tap flat.
    func abort(incomingAdopted: Bool) {
        tick?.invalidate()
        tick = nil
        if let outgoing {
            outgoing.volume = 1
            outgoingTap?.setTransition(bassDB: 0, lowPassHz: nil)
        }
        incomingTap?.setTransition(bassDB: 0, lowPassHz: nil)
        if !incomingAdopted {
            incoming.pause()
            incoming.removeAllItems()
        } else if incoming.rate != 0, incoming.rate != 1 {
            incoming.rate = 1
        }
        isArmed = false
        isSettled = true
    }

    // MARK: - Automation

    private func armTick() {
        tick?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isArmed, !self.isPaused, !self.isSettled else { return }
                let now = mach_absolute_time()
                if self.outputSecondsSinceOverlap(now: now) < 0 { self.correctLeadIn(now: now) }
                let t = self.outputSecondsSinceOverlap(now: now)
                self.apply(self.automation.frame(at: t))
                if !self.overlapCompleted, t >= self.automation.overlapDuration {
                    self.overlapCompleted = true
                    self.onOverlapCompleted?()
                }
                if t >= self.automation.totalDuration {
                    self.settle()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// Lead-in drift. The overlap start is computed once, from where the outgoing stood when
    /// the blend was armed. If that player then stalls — buffering, or the few hundred ms right
    /// after `play()` during which `AVPlayer` reports rate 1 before its timebase advances — the
    /// incoming would still start at the planned host time and the two would play that far
    /// apart for the whole overlap (measured: 300 ms, armed at position 0 on the simulator).
    /// So every tick before the overlap, once the outgoing is seen advancing, its position is
    /// checked against the one the plan implies and the incoming start is re-scheduled on any
    /// drift beyond 5 ms. A player that is not advancing (stalled, or not yet restarted after a
    /// resume) is left alone: its drift is only known once it moves.
    private func correctLeadIn(now: UInt64) {
        guard let outgoing, incomingStarted else { return }
        let position = outgoing.currentTime().seconds
        guard position.isFinite else { return }
        defer { lastOutgoingPosition = position }
        guard lastOutgoingPosition >= 0, position > lastOutgoingPosition else { return }
        let drift = position - (mixOut + outputSecondsSinceOverlap(now: now))
        guard abs(drift) > 0.005,
              let start = Self.overlapStart(outgoingPosition: position, mixOut: mixOut, now: now) else { return }
        overlapStartHostTime = start
        incoming.setRate(appliedRate, time: CMTime(seconds: mixIn, preferredTimescale: 44_100), atHostTime: CMClockMakeHostTimeFromSystemUnits(start))
        leadInCorrections.append(drift)
    }

    private func settle() {
        tick?.invalidate()
        tick = nil
        if incoming.rate != 1 { incoming.rate = 1 }
        appliedRate = 1
        incomingTap?.setTransition(bassDB: 0, lowPassHz: nil)
        if let incomingPlainMix { incomingItem.audioMix = incomingPlainMix }
        isSettled = true
        onSettled?()
    }

    private func apply(_ frame: AutoMixAutomation.Frame) {
        if let outgoing, abs(frame.outgoingGain - appliedOutgoingVolume) >= 0.004 || (frame.outgoingGain == 0 && appliedOutgoingVolume != 0) {
            appliedOutgoingVolume = frame.outgoingGain
            outgoing.volume = frame.outgoingGain
        }
        outgoingTap?.setTransition(bassDB: frame.outgoingBassDB, lowPassHz: frame.outgoingLowPassHz)
        incomingTap?.setTransition(bassDB: frame.incomingBassDB, lowPassHz: frame.incomingLowPassHz)
        // The rate only once the incoming is playing (setting it earlier would start it at once),
        // and only on a real change: a `rate` set takes ~170 ms to land (measured), so the glide
        // is stepped in 0.5 % increments rather than re-sent 50 times a second.
        let t = outputSecondsSinceOverlap()
        if t >= 0 {
            let stepped = (frame.incomingRate * 200).rounded() / 200
            if stepped != appliedRate {
                appliedRate = stepped
                incoming.rate = stepped
            }
        }
    }
}
