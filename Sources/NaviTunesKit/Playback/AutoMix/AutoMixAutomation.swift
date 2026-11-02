import Foundation

/// The automation curves for one transition, evaluated at an output time. Pure arithmetic over
/// a plan, so the audio engine only ever asks "what should every knob be *now*?" and the answers
/// are unit-tested without an engine.
struct AutoMixAutomation: Equatable {
    /// Gain values are linear (0…1 for the crossfade, dB for the shelf, Hz for the low-pass).
    struct Frame: Equatable {
        /// Equal-power crossfade gain on the outgoing deck.
        let outgoingGain: Float
        /// Equal-power crossfade gain on the incoming deck, before the loudness trim.
        let incomingGain: Float
        /// Time-pitch rate on the incoming deck (always 1 for a crossfade).
        let incomingRate: Float
        /// Low-shelf gain on the outgoing deck, dB (0 = bass present, negative = bass ducked).
        let outgoingBassDB: Float
        /// Low-shelf gain on the incoming deck, dB.
        let incomingBassDB: Float
        /// Low-pass cutoff on the outgoing deck, Hz (`nil` = filter bypassed).
        let outgoingLowPassHz: Float?
        /// Low-pass cutoff on the incoming deck, Hz (`nil` = filter bypassed).
        let incomingLowPassHz: Float?
        /// Linear loudness-match trim on the incoming deck: the plan's match gain through the
        /// overlap, then a glide (linear in dB) back to unity over the settle, so that by the time
        /// the queue player takes the track back it plays at its own level, exactly as the first
        /// song did (T673). Multiplied with `incomingGain`.
        var incomingTrim: Float = 1
    }

    enum Style: Equatable {
        case beatMatched(BlendPlan)
        case crossfade(CrossfadePlan)
    }

    let style: Style
    /// Depth of the low-shelf cut on whichever deck does not own the bass, dB.
    var bassCutDB: Float = -18
    /// How long the bass handover ramps, as a fraction of the overlap. One bar of eight.
    var bassSwapRampFraction: Double = 0.125
    /// Filter sweep range for the crossfade: the outgoing deck closes from open to this floor,
    /// the incoming opens from this floor to open. Gentle: 2 octaves above the mud.
    var sweepFloorHz: Float = 800
    var sweepOpenHz: Float = 20_000

    init(plan: BlendPlan) { style = .beatMatched(plan) }
    init(crossfade plan: CrossfadePlan) { style = .crossfade(plan) }

    /// Output seconds the transition's mixing lasts: the overlap (or the fade).
    var overlapDuration: TimeInterval {
        switch style {
        case let .beatMatched(p): return p.overlapDuration
        case let .crossfade(p): return p.duration
        }
    }

    /// Seconds after the overlap ends until the incoming deck is back at rate 1.0 **and** at unity
    /// trim, so the outgoing deck can be released and the track handed back to the queue player:
    /// the rate glide of a beat-matched blend, and at least `trimGlideDuration` whenever the
    /// incoming track was loudness-trimmed (T673). Zero for an untrimmed crossfade.
    var settleDuration: TimeInterval {
        var settle: TimeInterval = 0
        if case let .beatMatched(p) = style { settle = p.rateGlideDuration }
        if abs(incomingGainDB) >= 0.05 { settle = max(settle, trimGlideDuration) }
        return settle
    }

    /// Shortest glide from the loudness-match trim back to 0 dB after the overlap.
    var trimGlideDuration: TimeInterval = 2

    /// The incoming deck's trim at output time `t`: the plan's match gain through the overlap,
    /// then linear in dB back to unity across the settle.
    func incomingTrim(at t: TimeInterval) -> Float {
        guard t > overlapDuration else { return incomingTrimLinear }
        let settle = settleDuration
        guard settle > 0 else { return 1 }
        let g = min(1, max(0, (t - overlapDuration) / settle))
        return pow(10, incomingGainDB * Float(1 - g) / 20)
    }

    /// Total time this automation is live: overlap plus the rate glide.
    var totalDuration: TimeInterval { overlapDuration + settleDuration }

    /// Whether the incoming deck ever runs at a rate other than 1.0 — only a beat-matched blend.
    var stretchesIncoming: Bool {
        if case .beatMatched = style { return true }
        return false
    }

    var incomingGainDB: Float {
        switch style {
        case let .beatMatched(p): return p.incomingGainDB
        case let .crossfade(p): return p.incomingGainDB
        }
    }

    /// Linear multiplier for the incoming deck's loudness-match trim.
    var incomingTrimLinear: Float { pow(10, incomingGainDB / 20) }

    /// Equal-power crossfade. `progress` 0 → outgoing only, 1 → incoming only.
    static func equalPowerGains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let angle = p * Double.pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// `t` is output seconds since the overlap began (negative before it, past `overlapDuration`
    /// during the settle).
    func frame(at t: TimeInterval) -> Frame {
        var frame: Frame
        switch style {
        case let .beatMatched(plan): frame = blendFrame(at: t, plan: plan)
        case let .crossfade(plan): frame = crossfadeFrame(at: t, plan: plan)
        }
        frame.incomingTrim = incomingTrim(at: t)
        return frame
    }

    private func blendFrame(at t: TimeInterval, plan: BlendPlan) -> Frame {
        let overlap = plan.overlapDuration
        guard overlap > 0 else {
            return Frame(outgoingGain: 0, incomingGain: 1, incomingRate: 1, outgoingBassDB: bassCutDB, incomingBassDB: 0, outgoingLowPassHz: nil, incomingLowPassHz: nil)
        }
        let progress = min(1, max(0, t / overlap))
        let (outGain, inGain) = Self.equalPowerGains(progress: progress)

        // Rate: the bar's scheduled rate during the overlap (or the mean rate when there is no
        // schedule), then a linear glide from the last bar's rate back to 1.0.
        let rate: Float
        if t <= overlap {
            rate = Self.scheduledRate(plan: plan, at: t)
        } else if plan.rateGlideDuration > 0 {
            let from = plan.rateSchedule.last?.rate ?? plan.incomingRate
            let g = min(1, max(0, (t - overlap) / plan.rateGlideDuration))
            rate = from + (1 - from) * Float(g)
        } else {
            rate = 1
        }

        // Bass swap: outgoing owns the lows until `bassSwapFraction`, then a short ramp hands them
        // to the incoming deck. Two basslines at once is the muddiest a blend can sound.
        let ramp = max(0.001, bassSwapRampFraction)
        let swapStart = plan.bassSwapFraction - ramp / 2
        let swapProgress = min(1, max(0, (progress - swapStart) / ramp))
        let outgoingBass = bassCutDB * Float(swapProgress)
        let incomingBass = bassCutDB * Float(1 - swapProgress)

        return Frame(
            outgoingGain: t < 0 ? 1 : outGain,
            incomingGain: t < 0 ? 0 : inGain,
            incomingRate: rate,
            outgoingBassDB: t < 0 ? 0 : outgoingBass,
            incomingBassDB: t < 0 ? bassCutDB : incomingBass,
            outgoingLowPassHz: nil,
            incomingLowPassHz: nil,
        )
    }

    /// The incoming rate at output time `t` into the overlap, from the per-bar schedule.
    static func scheduledRate(plan: BlendPlan, at t: TimeInterval) -> Float {
        guard !plan.rateSchedule.isEmpty else { return plan.incomingRate }
        var start: TimeInterval = 0
        for segment in plan.rateSchedule {
            if t < start + segment.outputDuration { return segment.rate }
            start += segment.outputDuration
        }
        return plan.rateSchedule[plan.rateSchedule.count - 1].rate
    }

    private func crossfadeFrame(at t: TimeInterval, plan: CrossfadePlan) -> Frame {
        let duration = plan.duration
        guard duration > 0 else {
            return Frame(outgoingGain: 0, incomingGain: 1, incomingRate: 1, outgoingBassDB: 0, incomingBassDB: 0, outgoingLowPassHz: nil, incomingLowPassHz: nil)
        }
        let progress = min(1, max(0, t / duration))
        let (outGain, inGain) = Self.equalPowerGains(progress: progress)
        // Sweep in log-frequency so it sounds linear: outgoing closes, incoming opens.
        var outLP: Float? = nil
        var inLP: Float? = nil
        if plan.filterSweep, t >= 0, t <= duration {
            let lo = log2(sweepFloorHz), hi = log2(sweepOpenHz)
            outLP = pow(2, hi - (hi - lo) * Float(progress))
            inLP = pow(2, lo + (hi - lo) * Float(progress))
        }
        return Frame(
            outgoingGain: t < 0 ? 1 : outGain,
            incomingGain: t < 0 ? 0 : inGain,
            incomingRate: 1,
            outgoingBassDB: 0,
            incomingBassDB: 0,
            outgoingLowPassHz: outLP,
            incomingLowPassHz: inLP,
        )
    }
}

/// Sample-accurate scheduling arithmetic for the engine. Kept apart from the engine so the maths
/// is testable: when, in output samples from "now", must the incoming deck start so that its
/// mix-in lands on the outgoing deck's mix-out?
enum AutoMixScheduler {
    /// Samples from `now` until the overlap starts, given the outgoing deck's current file
    /// position. Negative means the mix-out point is already behind us and the transition must be
    /// skipped (a late handoff is worse than the default).
    static func samplesUntilOverlap(
        outgoingMixOut: TimeInterval,
        outgoingPosition: TimeInterval,
        sampleRate: Double,
    ) -> Int64 {
        let seconds = outgoingMixOut - outgoingPosition
        return Int64((seconds * sampleRate).rounded())
    }

    /// The earliest outgoing position at which a handoff should be armed: `lead` seconds before
    /// the mix-out, so the engine graph has time to spin up and the incoming file to pre-roll.
    static func armPosition(outgoingMixOut: TimeInterval, lead: TimeInterval) -> TimeInterval {
        max(0, outgoingMixOut - lead)
    }

    /// Where the incoming track's *file* position is at output time `t` since the overlap began,
    /// accounting for the stretch. Used to report `currentTime` for the new track while the
    /// blend is in flight.
    static func incomingFilePosition(plan: BlendPlan, outputSecondsSinceOverlap t: TimeInterval) -> TimeInterval {
        let overlap = plan.overlapDuration
        // Through the overlap: integrate the per-bar schedule (or the constant rate).
        var fileAtOverlapEnd = plan.incomingMixIn
        var rate = Double(plan.incomingRate)
        if plan.rateSchedule.isEmpty {
            if t <= overlap { return plan.incomingMixIn + max(0, t) * rate }
            fileAtOverlapEnd += overlap * rate
        } else {
            // The schedule's bars are the beat grid's real spans and need not add up to the overlap
            // (median bar × bars): integrate them only up to the overlap and run any remainder at the
            // last rate, as `scheduledRate` does, so item time never steps backwards at the glide.
            var start: TimeInterval = 0
            for segment in plan.rateSchedule where start < overlap {
                let end = min(start + segment.outputDuration, overlap)
                if t <= end { return fileAtOverlapEnd + max(0, t - start) * Double(segment.rate) }
                fileAtOverlapEnd += (end - start) * Double(segment.rate)
                start = end
            }
            rate = Double(plan.rateSchedule[plan.rateSchedule.count - 1].rate)
            if t <= overlap { return fileAtOverlapEnd + (t - start) * rate }
            fileAtOverlapEnd += (overlap - start) * rate
        }
        // Linear glide from `rate` to 1 over `rateGlideDuration`: integrate the ramp.
        let glide = plan.rateGlideDuration
        let afterOverlap = t - overlap
        let base = fileAtOverlapEnd
        if glide <= 0 { return base + afterOverlap }
        if afterOverlap >= glide {
            let rampDistance = glide * (rate + 1) / 2
            return base + rampDistance + (afterOverlap - glide)
        }
        let g = afterOverlap / glide
        let rateNow = rate + (1 - rate) * g
        return base + afterOverlap * (rate + rateNow) / 2
    }
}
