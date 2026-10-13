import Foundation

/// Why a pair did not get the beat-matched blend. Every one of these still transitions — the
/// style changes, never whether. Surfaced in logs and tests; never shown raw.
enum TransitionStyleReason: String, Codable, Equatable {
    /// No analysis for one of the tracks and none expected in time: the app's existing gapless
    /// transition plays, untouched.
    case metadataMissing
    /// The incoming track's analysis is in flight but cannot be ready before the blend window
    /// opens (a song queued or reordered near the end of the current one). Default transition.
    case analysisLate
    /// Tempos differ by more than the stretch budget even after half/double-time matching.
    case tempoMismatch
    /// Integrated loudness differs by more than the energy budget (quiet acoustic into loud rap).
    case energyMismatch
    /// Either track's beat tracking is too unsure (rubato, ambient, spoken word) to beat-match.
    case lowBeatConfidence
    /// Not enough material after the mix-out cue (or before the mix-in cue) for a bar-aligned
    /// overlap, so the shorter smooth crossfade is used instead.
    case insufficientMaterial
    /// Either track is too short for a bar-aligned overlap (interludes, skits).
    case trackTooShort
}

/// Guard thresholds. Defaults are what the evaluation in T630 settled on; they are a struct so a
/// test (or a future setting) can tighten or loosen one without touching the planner.
struct TransitionGuardThresholds: Equatable {
    /// Maximum |rate − 1| applied to the incoming track. 8 % is the audible ceiling for pitched
    /// material even through a time-pitch unit that preserves pitch.
    var maxTempoDeviation: Double = 0.08
    /// Maximum difference in integrated loudness, LU, before two songs are called different energies.
    var maxLoudnessDeltaLU: Double = 8
    /// Minimum beat-tracker confidence for *both* tracks.
    var minBeatConfidence: Double = 0.5
    /// Overlap length in bars when both tracks have the material.
    var preferredOverlapBars: Int = 8
    /// Smallest bar-aligned overlap worth doing; below this the smooth crossfade is used.
    var minimumOverlapBars: Int = 2
    /// Gain applied to the incoming track to match the outgoing one is clamped to this many dB.
    var maxMatchGainDB: Float = 6
    /// Tracks shorter than this never get the bar-aligned blend (interludes, skits).
    var minimumTrackDuration: TimeInterval = 45
    /// Length of the smooth crossfade used for incompatible pairs, seconds.
    var crossfadeDuration: TimeInterval = 8
    /// Floor for the smooth crossfade when material is scarce, seconds.
    var minimumCrossfadeDuration: TimeInterval = 3

    static let `default` = TransitionGuardThresholds()
}

/// Everything the playback engine needs to execute one beat-matched blend. All times are seconds
/// in each track's own file clock except `overlapDuration`, which is wall-clock output time.
struct BlendPlan: Equatable {
    /// Position in the outgoing track where the overlap begins (a downbeat).
    let outgoingMixOut: TimeInterval
    /// Position in the incoming track that is scheduled to land exactly on `outgoingMixOut`.
    let incomingMixIn: TimeInterval
    /// Overlap length in output seconds. The outgoing track plays at 1.0 throughout.
    let overlapDuration: TimeInterval
    /// Bars of overlap, in the outgoing track's meter.
    let overlapBars: Int
    /// Mean playback rate applied to the incoming track so its tempo matches the outgoing one's.
    /// The per-bar `rateSchedule` refines it; this is the value the glide returns from when the
    /// schedule is empty.
    let incomingRate: Float
    /// Per-bar rates so each of the incoming track's bars lands on the outgoing one's: a constant
    /// stretch drifts by the tempo error × overlap (90 ms over 8 bars in the evaluation); locking
    /// bar by bar removes the drift. Each entry is one bar of output time. Empty when either grid
    /// was too sparse to lock, in which case `incomingRate` applies throughout.
    let rateSchedule: [RateSegment]
    /// After the overlap, seconds over which the incoming rate glides back to 1.0.
    let rateGlideDuration: TimeInterval
    /// Gain on the incoming track so its loudness matches the outgoing one, dB, already clamped.
    let incomingGainDB: Float
    /// Fraction of the overlap at which the low end hands over from outgoing to incoming.
    let bassSwapFraction: Double
    /// Whether the mix-out was placed at a labelled outro / the mix-in after a labelled intro.
    let sectionAligned: Bool
}

/// The smooth crossfade for pairs that cannot be beat-matched: no time-stretch, equal-power fade,
/// loudness-matched, with a gentle low-pass sweep closing on the outgoing track and opening on
/// the incoming one. Timed to the outgoing outro and incoming intro when the analysis found them.
struct CrossfadePlan: Equatable {
    /// Position in the outgoing track where the fade begins.
    let outgoingMixOut: TimeInterval
    /// Position in the incoming track at which it starts, landing on `outgoingMixOut`.
    let incomingMixIn: TimeInterval
    /// Fade length, output seconds (both decks at rate 1.0).
    let duration: TimeInterval
    /// Gain on the incoming track so its loudness matches the outgoing one, dB, already clamped.
    let incomingGainDB: Float
    /// Whether the filter sweep is applied (off when either side is already very quiet).
    let filterSweep: Bool
    /// Why this pair got the crossfade rather than the blend.
    let reason: TransitionStyleReason
}

/// One bar of the overlap: how long it lasts in output seconds and the incoming rate during it.
struct RateSegment: Equatable {
    let outputDuration: TimeInterval
    let rate: Float
}

enum TransitionDecision: Equatable {
    /// Compatible: full beat-matched blend with bass swap.
    case beatMatched(BlendPlan)
    /// Incompatible: smooth crossfade, no stretch.
    case crossfade(CrossfadePlan)
    /// Analysis missing or late: the app's existing transition, untouched.
    case defaultTransition(TransitionStyleReason)

    var blendPlan: BlendPlan? {
        if case let .beatMatched(plan) = self { return plan }
        return nil
    }

    var crossfadePlan: CrossfadePlan? {
        if case let .crossfade(plan) = self { return plan }
        return nil
    }

    var reason: TransitionStyleReason? {
        switch self {
        case .beatMatched: return nil
        case let .crossfade(plan): return plan.reason
        case let .defaultTransition(reason): return reason
        }
    }

    /// Where the outgoing track hands over, whichever style. `nil` for the default transition.
    var outgoingMixOut: TimeInterval? {
        switch self {
        case let .beatMatched(p): return p.outgoingMixOut
        case let .crossfade(p): return p.outgoingMixOut
        case .defaultTransition: return nil
        }
    }
}

/// Where an in-flight analysis for the incoming track stands, in the *outgoing* track's clock.
struct PendingAnalysis: Equatable {
    /// Outgoing-track position at which the incoming analysis is expected to be usable.
    let expectedReadyAtOutgoingPosition: TimeInterval
}

/// Pure decision logic: two tracks' analysis in, a transition style with its plan out. No audio,
/// no clocks, no I/O — so it is unit-tested directly and shared verbatim with the evaluation
/// harness (`render.py` implements the same rules and thresholds).
enum TransitionPlanner {
    /// Seconds before the mix-out at which the engine must already hold a plan: the handoff
    /// pre-rolls both files and spins the graph up in this window.
    static let handoffLead: TimeInterval = 2

    /// The rate the incoming track must play at for its tempo to match the outgoing one, after
    /// choosing whichever of ×½, ×1, ×2 tempo reading is nearest. Returns `nil` if either tempo is
    /// unusable.
    static func tempoMatchRate(outgoingTempo: Double, incomingTempo: Double) -> Double? {
        guard outgoingTempo > 0, incomingTempo > 0 else { return nil }
        let candidates = [incomingTempo / 2, incomingTempo, incomingTempo * 2]
        let best = candidates.min { abs(outgoingTempo / $0 - 1) < abs(outgoingTempo / $1 - 1) }!
        return outgoingTempo / best
    }

    /// The deadline rule. Given what is known *now* — the outgoing analysis, the incoming analysis
    /// if it has arrived, and otherwise when it is expected — decide without ever waiting.
    static func plan(
        from outgoing: TransitionMetadata?,
        to incoming: TransitionMetadata?,
        pending: PendingAnalysis?,
        outgoingPosition: TimeInterval,
        thresholds: TransitionGuardThresholds = .default,
    ) -> TransitionDecision {
        if let incoming {
            let decision = plan(from: outgoing, to: incoming, thresholds: thresholds)
            // Analysis that arrived after the window opened is as good as none: the handoff
            // cannot be armed behind the playhead.
            if let mixOut = decision.outgoingMixOut, outgoingPosition > mixOut - handoffLead {
                return .defaultTransition(.analysisLate)
            }
            return decision
        }
        guard let a = outgoing else { return .defaultTransition(.metadataMissing) }
        guard let pending else { return .defaultTransition(.metadataMissing) }
        let cue = a.downbeat(atOrBefore: a.cues.mixOut) ?? a.cues.mixOut
        if pending.expectedReadyAtOutgoingPosition > cue - handoffLead || outgoingPosition > cue - handoffLead {
            return .defaultTransition(.analysisLate)
        }
        // Not ready yet, but it can make it. Still the default *right now* — the caller re-plans
        // when the analysis lands, and if that never happens the default transition plays.
        return .defaultTransition(.metadataMissing)
    }

    static func plan(
        from outgoing: TransitionMetadata?,
        to incoming: TransitionMetadata?,
        thresholds: TransitionGuardThresholds = .default,
    ) -> TransitionDecision {
        guard let a = outgoing, let b = incoming else { return .defaultTransition(.metadataMissing) }

        if a.duration < thresholds.minimumTrackDuration || b.duration < thresholds.minimumTrackDuration {
            return .crossfade(crossfade(from: a, to: b, reason: .trackTooShort, thresholds: thresholds))
        }
        if a.beatConfidence < thresholds.minBeatConfidence || b.beatConfidence < thresholds.minBeatConfidence {
            return .crossfade(crossfade(from: a, to: b, reason: .lowBeatConfidence, thresholds: thresholds))
        }
        guard let rate = tempoMatchRate(outgoingTempo: a.tempo, incomingTempo: b.tempo), abs(rate - 1) <= thresholds.maxTempoDeviation else {
            return .crossfade(crossfade(from: a, to: b, reason: .tempoMismatch, thresholds: thresholds))
        }
        if abs(a.loudness.integrated - b.loudness.integrated) > thresholds.maxLoudnessDeltaLU {
            return .crossfade(crossfade(from: a, to: b, reason: .energyMismatch, thresholds: thresholds))
        }

        // Mix-out: the cue the analyzer chose, snapped to a downbeat, as long as it leaves material.
        let bar = a.barDuration
        guard bar > 0, b.barDuration > 0 else {
            return .crossfade(crossfade(from: a, to: b, reason: .lowBeatConfidence, thresholds: thresholds))
        }
        // The overlap must end where the outgoing track still has beats: no later than its last
        // downbeat. The outro cue can only pull the mix-out earlier.
        let lastDownbeat = a.downbeats.last ?? a.duration
        let latestMixOut = lastDownbeat - Double(thresholds.preferredOverlapBars) * bar
        let outroStart = a.downbeat(atOrBefore: min(a.cues.mixOut, latestMixOut)) ?? a.cues.mixOut
        let availableOutgoing = lastDownbeat - outroStart
        // Mix-in: the analyzer's cue, snapped to a downbeat. Material after it (in output time,
        // i.e. divided by the rate) must cover the overlap too.
        let mixIn = b.downbeat(atOrAfter: b.cues.mixIn) ?? b.cues.mixIn
        let availableIncoming = (b.duration - mixIn) / rate

        // The epsilon keeps an overlap that is exactly N bars from rounding down to N − 1.
        let maxBars = Int(floor(min(availableOutgoing, availableIncoming) / bar + 1e-6))
        let bars = min(thresholds.preferredOverlapBars, maxBars)
        if bars < thresholds.minimumOverlapBars {
            return .crossfade(crossfade(from: a, to: b, reason: .insufficientMaterial, thresholds: thresholds))
        }

        let sectionAligned = a.section(labelled: "outro") != nil || b.section(labelled: "intro") != nil
        let schedule = rateSchedule(from: a, to: b, mixOut: outroStart, mixIn: mixIn, bars: bars, meanRate: rate, thresholds: thresholds)

        return .beatMatched(BlendPlan(
            outgoingMixOut: outroStart,
            incomingMixIn: mixIn,
            overlapDuration: Double(bars) * bar,
            overlapBars: bars,
            incomingRate: Float(rate),
            rateSchedule: schedule,
            rateGlideDuration: min(8, 4 * b.barDuration),
            incomingGainDB: matchGain(from: a, to: b, thresholds: thresholds),
            bassSwapFraction: 0.5,
            sectionAligned: sectionAligned,
        ))
    }

    /// Per-bar rates from the two beat grids: walk `beatsPerBar` beats at a time from the mix-out
    /// beat in A and the mix-in beat in B (stepping B's grid by two when it was read at half time);
    /// each bar's rate is B's bar length over A's, clamped to the stretch cap. A bar where one grid
    /// skipped a beat (ratio far outside the cap) takes the mean rate instead of chasing it.
    /// Returns `[]` when either cue is not on its grid or a grid runs out, and the constant rate
    /// applies.
    static func rateSchedule(
        from a: TransitionMetadata,
        to b: TransitionMetadata,
        mixOut: TimeInterval,
        mixIn: TimeInterval,
        bars: Int,
        meanRate: Double,
        thresholds: TransitionGuardThresholds,
    ) -> [RateSegment] {
        guard let ia = a.beats.firstIndex(where: { $0 >= mixOut - 0.001 }), abs(a.beats[ia] - mixOut) <= 0.05,
              let ib = b.beats.firstIndex(where: { $0 >= mixIn - 0.001 }), abs(b.beats[ib] - mixIn) <= 0.05
        else { return [] }
        let bpb = a.beatsPerBar
        // B beats per A bar. `octave` is B's grid relative to A's after the ½/×1/×2 fold: 2 when
        // B's tracker counted double time (one A bar spans two B bars, 2·bpb beats), 0.5 when it
        // counted half time (one A bar spans half a B bar, bpb/2 beats), 1 otherwise. The old
        // `stepB = octave == 0.5 ? 2 : 1` had both octave cases inverted, so every half/double-time
        // pair fell back to the constant rate — the drift this lock exists to remove (T643 c3).
        let octave = (meanRate * b.tempo / a.tempo * 2).rounded() / 2
        let stepBeats = Double(bpb) * octave
        guard octave > 0, stepBeats >= 1, stepBeats == stepBeats.rounded() else { return [] }
        let stepB = Int(stepBeats)
        let cap = thresholds.maxTempoDeviation
        var schedule: [RateSegment] = []
        for k in 0 ..< bars {
            let a0 = ia + k * bpb, a1 = ia + (k + 1) * bpb
            let b0 = ib + k * stepB, b1 = ib + (k + 1) * stepB
            guard a1 < a.beats.count, b1 < b.beats.count else { return [] }
            let la = a.beats[a1] - a.beats[a0], lb = b.beats[b1] - b.beats[b0]
            guard la > 0, lb > 0 else { return [] }
            var r = lb / la
            if abs(r - 1) > cap * 1.5 { r = meanRate }
            schedule.append(RateSegment(outputDuration: la, rate: Float(min(1 + cap, max(1 - cap, r)))))
        }
        return schedule
    }

    static func matchGain(from a: TransitionMetadata, to b: TransitionMetadata, thresholds: TransitionGuardThresholds) -> Float {
        let gain = Float(a.loudness.integrated - b.loudness.integrated)
        return max(-thresholds.maxMatchGainDB, min(thresholds.maxMatchGainDB, gain))
    }

    /// The smooth crossfade. Timed to the outgoing outro (`cues.mixOut`) and the incoming intro
    /// (`cues.mixIn`) — those cues are defined even without labelled sections (8 bars before the
    /// last downbeat; the first downbeat), so the fade always starts on a beat where one exists.
    /// When a cue leaves less than a full fade of material, that side slides toward its own end
    /// (incoming) or start of the tail (outgoing) so the fade fits; it is never longer than what
    /// either track has.
    static func crossfade(
        from a: TransitionMetadata,
        to b: TransitionMetadata,
        reason: TransitionStyleReason,
        thresholds: TransitionGuardThresholds,
    ) -> CrossfadePlan {
        let want = thresholds.crossfadeDuration
        var mixOut = a.downbeat(atOrBefore: a.cues.mixOut) ?? a.cues.mixOut
        var mixIn = b.downbeat(atOrAfter: b.cues.mixIn) ?? b.cues.mixIn
        if b.duration - mixIn < want {
            let target = max(0, b.duration - want)
            mixIn = b.downbeat(atOrBefore: min(mixIn, target)) ?? min(mixIn, target)
        }
        if a.duration - mixOut < thresholds.minimumCrossfadeDuration {
            let target = max(0, a.duration - want)
            mixOut = a.downbeat(atOrBefore: target) ?? target
        }
        let available = min(a.duration - mixOut, b.duration - mixIn)
        let duration = max(0.5, min(want, available))
        // A sweep on top of a very quiet side only takes away what little is there.
        let sweep = a.loudness.outro > -30 && b.loudness.intro > -30
        return CrossfadePlan(
            outgoingMixOut: mixOut,
            incomingMixIn: mixIn,
            duration: duration,
            incomingGainDB: matchGain(from: a, to: b, thresholds: thresholds),
            filterSweep: sweep,
            reason: reason,
        )
    }
}
