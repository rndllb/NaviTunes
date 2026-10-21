import Foundation

/// What AutoMix should be doing for the boundary between the playing song and the next one:
/// which work to start (fetch the next stream, analyse either file) and what the transition is.
enum AutoMixPreparation {
    /// One song's analysis, as the planner sees it.
    enum Analysis: Equatable {
        case notRequested
        case inFlight(remaining: TimeInterval)
        case ready(TransitionMetadata)
        case failed
    }

    struct Input: Equatable {
        /// Playhead in the outgoing song, after any seek.
        var position: TimeInterval
        var currentDuration: TimeInterval
        var nextDuration: TimeInterval
        /// The playing song is a local file (download or stream cache).
        var currentIsLocal: Bool
        /// The next song is a local file.
        var nextIsLocal: Bool
        /// The playing song is actually playing, not loading or stalled.
        var playingSteadily: Bool
        /// Fetching over the network is allowed right now ("No streaming over cellular").
        var streamingAllowed: Bool
        var current: Analysis = .notRequested
        var next: Analysis = .notRequested
    }

    struct Requests: Equatable {
        var fetchNext: Bool
        var analyseCurrent: Bool
        var analyseNext: Bool
    }

    struct Outcome: Equatable {
        /// `nil`: nothing to decide yet (the next song is not a file).
        var decision: TransitionDecision?
        /// A line for the perf log when the outcome is a fallback.
        var note: String?
    }

    /// Work to start now. Position plays no part: whatever the listener does with the timeline,
    /// the next song is fetched and both songs are analysed as early as possible (T791 c5).
    ///
    /// - The next stream is fetched once the playing song **plays steadily** — not before, so the
    ///   fetch does not compete with the playing song's own start on a slow link, and not later
    ///   (it used to be fetched only at the first planning pass, before audio had even started).
    /// - The next song is analysed the moment it is a file, even while the playing song is still
    ///   a stream. It used to wait until it became the playing song, which put both analyses of a
    ///   boundary into the song's own first minutes, where a seek could outrun them.
    /// - An analysis that failed for a file is not asked for again.
    static func requests(_ input: Input) -> Requests {
        Requests(
            fetchNext: !input.nextIsLocal && input.streamingAllowed && input.playingSteadily,
            analyseCurrent: input.currentIsLocal && input.current != .failed,
            analyseNext: input.nextIsLocal && input.next != .failed
        )
    }

    /// What plays at the boundary. Never silence about it: when the beat-matched blend is not
    /// possible the outcome is a plain crossfade at the end of the song, and when not even that
    /// can be staged (the playhead is in the last seconds) it is the normal transition — each with
    /// a `note` for the perf log, because a transition that quietly did not happen is
    /// indistinguishable from a bug.
    static func outcome(_ input: Input) -> Outcome {
        guard input.nextIsLocal else { return Outcome(decision: nil, note: nil) }

        if input.currentIsLocal, case let .ready(a) = input.current, case let .ready(b) = input.next {
            let planned = TransitionPlanner.plan(from: a, to: b)
            if let mixOut = planned.outgoingMixOut, input.position <= mixOut - TransitionPlanner.handoffLead {
                return Outcome(decision: planned, note: nil)
            }
            return fallback(input, reason: .analysisLate, why: "the playhead is past the analysed cue")
        }
        if !input.currentIsLocal {
            return fallback(input, reason: .metadataMissing, why: "the playing song is streamed, so it cannot be analysed")
        }
        if input.current == .failed || input.next == .failed {
            return fallback(input, reason: .analysisFailed, why: "the analysis of \(input.current == .failed ? "the playing" : "the next") song failed")
        }
        // Analysis still running (or not started): a plain crossfade stands in, and the planner
        // re-runs and upgrades it the moment the analysis lands.
        return fallback(input, reason: .metadataMissing, why: "analysis not ready yet")
    }

    /// A plain crossfade into the next song's start, ending a second before the playing song does.
    /// Needs no analysis — only the two durations.
    static func plainCrossfade(currentDuration: TimeInterval, nextDuration: TimeInterval, reason: TransitionStyleReason, thresholds: TransitionGuardThresholds = .default) -> CrossfadePlan? {
        guard currentDuration > 0 else { return nil }
        let room = nextDuration > 0 ? min(currentDuration, nextDuration) : currentDuration
        let length = min(thresholds.crossfadeDuration, room * 0.25)
        guard length >= thresholds.minimumCrossfadeDuration else { return nil }
        return CrossfadePlan(
            outgoingMixOut: currentDuration - length - endMargin,
            incomingMixIn: 0,
            duration: length,
            incomingGainDB: 0,
            filterSweep: false,
            reason: reason
        )
    }

    /// The fade finishes this long before the playing song's end, so the end-of-item notification
    /// can never race the hand-over.
    static let endMargin: TimeInterval = 1

    private static func fallback(_ input: Input, reason: TransitionStyleReason, why: String) -> Outcome {
        guard let plan = plainCrossfade(currentDuration: input.currentDuration, nextDuration: input.nextDuration, reason: reason) else {
            return Outcome(decision: .defaultTransition(reason), note: "normal transition: \(why), and the songs are too short to crossfade")
        }
        guard input.position <= plan.outgoingMixOut - TransitionPlanner.handoffLead else {
            return Outcome(decision: .defaultTransition(.noTimeToPrepare), note: "normal transition: \(why), and too little of the song is left to stage a crossfade")
        }
        return Outcome(decision: .crossfade(plan), note: "plain crossfade: \(why)")
    }
}
