import Foundation
import Testing

@testable import VellumMusicKit

/// The transition-style guard and the scheduling arithmetic, exercised on synthetic analysis that
/// mirrors the shapes the evaluation produced: a 123 BPM dance track, a 128 BPM one, an 85 BPM
/// rock track, and a quiet rubato acoustic song.
@Suite("TransitionPlanner")
struct TransitionPlannerTests {
    /// A steady 4/4 grid with the given tempo and length, plus loudness and sections.
    static func track(
        id: String,
        tempo: Double,
        duration: TimeInterval = 240,
        integrated: Double = -9,
        confidence: Double = 0.95,
        intro: TimeInterval = 8,
        outro: TimeInterval = 16,
    ) -> TransitionMetadata {
        let beat = 60 / tempo
        let count = Int(duration / beat)
        let beats = (0 ..< count).map { Double($0) * beat + 0.05 }
        let downbeats = stride(from: 0, to: count, by: 4).map { beats[$0] }
        let bar = beat * 4
        let mixIn = downbeats.first { $0 >= max(0, intro - 8 * bar) } ?? downbeats[0]
        let outroStart = duration - outro
        let mixOut = downbeats.last { $0 <= outroStart } ?? downbeats[downbeats.count - 8]
        return TransitionMetadata(
            version: 1,
            trackId: id,
            duration: duration,
            tempo: tempo,
            beats: beats,
            downbeats: downbeats,
            beatConfidence: confidence,
            key: TransitionMetadata.Key(tonic: "A", mode: "minor", camelot: "8A"),
            loudness: TransitionMetadata.Loudness(integrated: integrated, range: 6, intro: integrated - 3, outro: integrated - 2),
            sections: [
                TransitionMetadata.Section(start: 0, end: intro, label: "intro"),
                TransitionMetadata.Section(start: intro, end: outroStart, label: "body"),
                TransitionMetadata.Section(start: outroStart, end: duration, label: "outro"),
            ],
            cues: TransitionMetadata.Cues(mixIn: mixIn, mixOut: mixOut),
            analyzer: "test",
        )
    }

    static let dance123 = track(id: "dance123", tempo: 123)
    static let dance128 = track(id: "dance128", tempo: 128)
    static let rock85 = track(id: "rock85", tempo: 85)
    static let acoustic = track(id: "acoustic", tempo: 72, integrated: -19, confidence: 0.3)
    static let loudRap = track(id: "rap", tempo: 140, integrated: -7)

    // MARK: Compatible → beat-matched blend

    @Test("123 → 128 BPM, both loud: beat-matched with a 4 % stretch")
    func nearTemposBlend() throws {
        let plan = try #require(TransitionPlanner.plan(from: Self.dance123, to: Self.dance128).blendPlan)
        #expect(abs(Double(plan.incomingRate) - 123.0 / 128.0) < 0.001)
        #expect(plan.overlapBars == 8)
        #expect(plan.sectionAligned)
        // The overlap starts on the outgoing track's outro downbeat and is 8 of its bars long.
        #expect(plan.outgoingMixOut == Self.dance123.cues.mixOut)
        #expect(abs(plan.overlapDuration - 8 * Self.dance123.barDuration) < 0.001)
        #expect(abs(plan.incomingGainDB) < 0.01)
        // Steady synthetic grids: every bar of the schedule is the mean rate.
        #expect(plan.rateSchedule.count == 8)
        for seg in plan.rateSchedule {
            #expect(abs(Double(seg.rate) - 123.0 / 128.0) < 0.002)
            #expect(abs(seg.outputDuration - Self.dance123.barDuration) < 0.001)
        }
    }

    @Test("a drifting incoming grid gets a per-bar schedule that lands each bar on the outgoing one")
    func barLockFollowsDrift() throws {
        // B is nominally 125 BPM but speeds up 1 % per bar through its first 10 bars.
        let a = Self.track(id: "a125", tempo: 125)
        var beats: [TimeInterval] = []
        var t = 0.05
        for i in 0 ..< 500 {
            beats.append(t)
            let bar = i / 4
            t += 0.48 / (1 + 0.01 * Double(min(bar, 10)))
        }
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        let b = TransitionMetadata(
            version: 1, trackId: "drift", duration: 240, tempo: 125, beats: beats, downbeats: downbeats,
            beatConfidence: 0.95, key: nil,
            loudness: .init(integrated: -9, range: 6, intro: -12, outro: -11),
            sections: [.init(start: 0, end: 240, label: "body")],
            cues: .init(mixIn: beats[0], mixOut: beats[beats.count - 40]), analyzer: "test",
        )
        let plan = try #require(TransitionPlanner.plan(from: a, to: b).blendPlan)
        #expect(plan.rateSchedule.count == plan.overlapBars)
        // Bars get progressively faster in B, so the rate (B seconds per A second) falls bar by bar.
        let rates = plan.rateSchedule.map(\.rate)
        #expect(rates.first! > rates.last!)
        // Each scheduled bar maps B's downbeat onto A's: integrate and compare.
        var outT: TimeInterval = 0
        for (k, seg) in plan.rateSchedule.enumerated() {
            outT += seg.outputDuration
            let filePos = AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: outT)
            let expected = b.beats[4 * (k + 1)]
            #expect(abs(filePos - expected) < 0.002, "bar \(k + 1): \(filePos) vs \(expected)")
        }
    }

    @Test("half-time reading: 85 BPM rock into a 170 BPM track blends at ×1")
    func halfTimeMatches() throws {
        let fast = Self.track(id: "fast170", tempo: 170)
        let plan = try #require(TransitionPlanner.plan(from: Self.rock85, to: fast).blendPlan)
        #expect(abs(Double(plan.incomingRate) - 1) < 0.001)
    }

    // MARK: Incompatible → smooth crossfade (never a refusal)

    @Test("123 → 85 BPM: tempo mismatch gets the smooth crossfade, no stretch, timed to the cues")
    func farTemposCrossfade() throws {
        let decision = TransitionPlanner.plan(from: Self.dance123, to: Self.rock85)
        let plan = try #require(decision.crossfadePlan)
        #expect(plan.reason == .tempoMismatch)
        #expect(plan.duration == 8)
        #expect(plan.outgoingMixOut == Self.dance123.cues.mixOut)
        #expect(plan.incomingMixIn == Self.rock85.cues.mixIn)
        #expect(plan.filterSweep)
        // 85×2 = 170 is 38 % away; 85 is 31 % away. Neither fits an 8 % budget.
        let rate = TransitionPlanner.tempoMatchRate(outgoingTempo: 123, incomingTempo: 85)!
        #expect(abs(rate - 1) > 0.08)
    }

    @Test("quiet rubato acoustic into loud rap: crossfade, loudness-matched up to the +6 dB cap")
    func acousticIntoRapCrossfade() throws {
        // Low beat confidence is checked before energy — a rubato song cannot be beat-matched
        // whatever its loudness.
        let plan = try #require(TransitionPlanner.plan(from: Self.acoustic, to: Self.loudRap).crossfadePlan)
        #expect(plan.reason == .lowBeatConfidence)
        // −19 → −7: the rap is 12 LU louder, so it is trimmed by the full 6 dB.
        #expect(plan.incomingGainDB == -6)
        // With confidence forced high, the 12 LU energy gap still picks the crossfade.
        let confidentAcoustic = Self.track(id: "acoustic2", tempo: 140, integrated: -19, confidence: 0.9)
        #expect(TransitionPlanner.plan(from: confidentAcoustic, to: Self.loudRap).crossfadePlan?.reason == .energyMismatch)
    }

    @Test("an interlude shorter than 45 s gets the crossfade, not the bar-aligned blend")
    func shortTrackCrossfade() throws {
        let skit = Self.track(id: "skit", tempo: 123, duration: 30, intro: 2, outro: 4)
        let plan = try #require(TransitionPlanner.plan(from: Self.dance123, to: skit).crossfadePlan)
        #expect(plan.reason == .trackTooShort)
        #expect(plan.duration >= 3)
        #expect(plan.incomingMixIn + plan.duration <= skit.duration + 0.001)
    }

    @Test("too little material after the incoming cue for the minimum overlap falls back to the crossfade")
    func insufficientMaterialCrossfade() {
        let base = Self.dance128
        let bar = base.barDuration
        // The incoming track's mix-in cue sits 1.5 bars before its end: whichever downbeat it
        // snaps to, under 2 bars remain.
        let lateCue = TransitionMetadata.Cues(mixIn: base.duration - bar * 1.5, mixOut: base.cues.mixOut)
        let late = TransitionMetadata(
            version: 1, trackId: "late", duration: base.duration, tempo: base.tempo, beats: base.beats,
            downbeats: base.downbeats, beatConfidence: base.beatConfidence, key: base.key,
            loudness: base.loudness, sections: base.sections, cues: lateCue, analyzer: nil,
        )
        let decision = TransitionPlanner.plan(from: Self.dance123, to: late)
        #expect(decision.crossfadePlan?.reason == .insufficientMaterial)
        // The fade still fits inside what is left of the incoming track.
        let plan = decision.crossfadePlan!
        #expect(plan.incomingMixIn + plan.duration <= late.duration + 0.001)
        #expect(plan.duration >= 3)
    }

    @Test("the planner never returns a default transition when both analyses exist")
    func alwaysTransitionsWithAnalysis() {
        let pairs: [(TransitionMetadata, TransitionMetadata)] = [
            (Self.dance123, Self.dance128), (Self.dance123, Self.rock85), (Self.acoustic, Self.loudRap),
            (Self.loudRap, Self.acoustic), (Self.rock85, Self.dance128),
        ]
        for (a, b) in pairs {
            let d = TransitionPlanner.plan(from: a, to: b)
            if case .defaultTransition = d { Issue.record("\(a.trackId) → \(b.trackId) fell to the default") }
        }
    }

    // MARK: Missing or late analysis → the app's existing transition

    @Test("missing analysis on either side is the default transition, never a guess")
    func missingMetadataDefault() {
        #expect(TransitionPlanner.plan(from: nil, to: Self.dance128).reason == .metadataMissing)
        #expect(TransitionPlanner.plan(from: Self.dance123, to: nil).reason == .metadataMissing)
    }

    @Test("analysis that cannot land before the cue point is the default transition, never a wait")
    func lateAnalysisIsDefault() {
        let a = Self.dance123
        let cue = a.downbeat(atOrBefore: a.cues.mixOut)!
        // Expected back 1 s before the cue — inside the 2 s handoff lead: too late.
        let late = PendingAnalysis(expectedReadyAtOutgoingPosition: cue - 1)
        let decision = TransitionPlanner.plan(from: a, to: nil, pending: late, outgoingPosition: cue - 30)
        #expect(decision == .defaultTransition(.analysisLate))
        // Expected back 10 s before the cue: not a stall either — still the default *now*, with
        // the "ask again" reason; the plan can only be made once the analysis actually exists.
        let inTime = PendingAnalysis(expectedReadyAtOutgoingPosition: cue - 10)
        #expect(TransitionPlanner.plan(from: a, to: nil, pending: inTime, outgoingPosition: cue - 30) == .defaultTransition(.metadataMissing))
        // Nothing in flight at all: plain missing metadata.
        #expect(TransitionPlanner.plan(from: a, to: nil, pending: nil, outgoingPosition: 0) == .defaultTransition(.metadataMissing))
    }

    @Test("analysis that arrives after the window has opened cannot be armed behind the playhead")
    func analysisArrivingTooLateIsDefault() throws {
        let a = Self.dance123
        let plan = try #require(TransitionPlanner.plan(from: a, to: Self.dance128).blendPlan)
        let justInTime = TransitionPlanner.plan(from: a, to: Self.dance128, pending: nil, outgoingPosition: plan.outgoingMixOut - 5)
        #expect(justInTime.blendPlan == plan)
        let tooLate = TransitionPlanner.plan(from: a, to: Self.dance128, pending: nil, outgoingPosition: plan.outgoingMixOut - 1)
        #expect(tooLate == .defaultTransition(.analysisLate))
        // The same rule protects the crossfade style.
        let cross = TransitionPlanner.plan(from: a, to: Self.rock85).crossfadePlan!
        let lateCross = TransitionPlanner.plan(from: a, to: Self.rock85, pending: nil, outgoingPosition: cross.outgoingMixOut - 0.5)
        #expect(lateCross == .defaultTransition(.analysisLate))
    }

    // MARK: Seeking (T633 c2)

    @Test("a seek to before the cue still blends; a seek past the cue gets the default transition")
    func seekRePlans() throws {
        let a = Self.dance123
        let plan = try #require(TransitionPlanner.plan(from: a, to: Self.dance128).blendPlan)
        // Dragged back to 30 s: well before the cue, the same blend is armed again.
        let early = TransitionPlanner.plan(from: a, to: Self.dance128, pending: nil, outgoingPosition: 30)
        #expect(early.blendPlan == plan)
        // Dragged to 10 s before the cue: still inside the plannable window.
        let close = TransitionPlanner.plan(from: a, to: Self.dance128, pending: nil, outgoingPosition: plan.outgoingMixOut - 10)
        #expect(close.blendPlan == plan)
        // Dragged past the cue (or inside the 2 s handoff lead): the default transition, no blend.
        for position in [plan.outgoingMixOut - 1, plan.outgoingMixOut + 3, a.duration - 1] {
            let late = TransitionPlanner.plan(from: a, to: Self.dance128, pending: nil, outgoingPosition: position)
            #expect(late == .defaultTransition(.analysisLate), "position \(position)")
        }
    }

    // MARK: Thresholds and trims

    @Test("stretch budget is a threshold, not a constant")
    func stretchBudgetIsConfigurable() {
        var loose = TransitionGuardThresholds.default
        loose.maxTempoDeviation = 0.35
        #expect(TransitionPlanner.plan(from: Self.dance123, to: Self.rock85, thresholds: loose).blendPlan != nil)
    }

    @Test("loudness-match gain is clamped to ±6 dB")
    func gainClamp() throws {
        let quieter = Self.track(id: "quiet", tempo: 123, integrated: -16.5)
        let plan = try #require(TransitionPlanner.plan(from: Self.dance123, to: quieter).blendPlan)
        #expect(plan.incomingGainDB == 6)
        let louder = Self.track(id: "loud", tempo: 123, integrated: -1.5)
        let plan2 = try #require(TransitionPlanner.plan(from: Self.dance123, to: louder).blendPlan)
        #expect(plan2.incomingGainDB == -6)
    }

    // MARK: Metadata derivations

    @Test("beats per bar and bar duration come from the grid")
    func gridDerivations() {
        let t = Self.dance123
        #expect(t.beatsPerBar == 4)
        #expect(abs(t.beatDuration - 60.0 / 123.0) < 0.001)
        #expect(abs(t.barDuration - 4 * 60.0 / 123.0) < 0.001)
        #expect(t.downbeat(atOrAfter: 10)! >= 10)
        #expect(t.downbeat(atOrBefore: 10)! <= 10)
    }

    @Test("analyzer JSON decodes, and a newer schema is refused")
    func decoding() throws {
        let json = """
        {"version":1,"trackId":"x","duration":200,"tempo":120,"beats":[0.5,1,1.5,2],"downbeats":[0.5],
         "beatConfidence":0.9,"key":{"tonic":"C","mode":"major","camelot":"8B"},
         "loudness":{"integrated":-9,"range":5,"intro":-12,"outro":-11},
         "sections":[{"start":0,"end":10,"label":"intro"}],"cues":{"mixIn":0.5,"mixOut":180},"analyzer":"beat_this:final0"}
        """
        let meta = try TransitionMetadata.decode(Data(json.utf8))
        #expect(meta.tempo == 120)
        #expect(meta.section(labelled: "Intro")?.end == 10)
        let newer = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        #expect(throws: TransitionMetadata.DecodeError.unsupportedVersion(99)) {
            try TransitionMetadata.decode(Data(newer.utf8))
        }
    }
}

@Suite("AutoMixAutomation")
struct AutoMixAutomationTests {
    static let plan = BlendPlan(
        outgoingMixOut: 200, incomingMixIn: 8, overlapDuration: 16, overlapBars: 8, incomingRate: 0.96,
        rateSchedule: [], rateGlideDuration: 8, incomingGainDB: -3, bassSwapFraction: 0.5, sectionAligned: true,
    )
    static let crossfade = CrossfadePlan(
        outgoingMixOut: 200, incomingMixIn: 4, duration: 8, incomingGainDB: 2, filterSweep: true, reason: .tempoMismatch,
    )

    @Test("equal-power crossfade keeps constant power and hits the endpoints")
    func equalPower() {
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let g = AutoMixAutomation.equalPowerGains(progress: p)
            #expect(abs(g.outgoing * g.outgoing + g.incoming * g.incoming - 1) < 1e-5)
        }
        #expect(AutoMixAutomation.equalPowerGains(progress: 0).outgoing == 1)
        #expect(AutoMixAutomation.equalPowerGains(progress: 1).incoming == 1)
    }

    @Test("before the overlap: outgoing full, incoming silent and bass-ducked")
    func beforeOverlap() {
        let f = AutoMixAutomation(plan: Self.plan).frame(at: -2)
        #expect(f.outgoingGain == 1)
        #expect(f.incomingGain == 0)
        #expect(f.outgoingBassDB == 0)
        #expect(f.incomingBassDB == -18)
        #expect(f.incomingRate == 0.96)
        #expect(f.outgoingLowPassHz == nil && f.incomingLowPassHz == nil)
    }

    @Test("bass hands over at the swap fraction")
    func bassSwap() {
        let a = AutoMixAutomation(plan: Self.plan)
        let before = a.frame(at: 16 * 0.3)
        let after = a.frame(at: 16 * 0.7)
        #expect(before.outgoingBassDB == 0 && before.incomingBassDB == -18)
        #expect(after.outgoingBassDB == -18 && after.incomingBassDB == 0)
        let mid = a.frame(at: 16 * 0.5)
        #expect(abs(mid.outgoingBassDB - (-9)) < 0.01)
        #expect(abs(mid.incomingBassDB - (-9)) < 0.01)
    }

    @Test("rate is locked through the overlap and glides back to 1.0 afterwards")
    func rateGlide() {
        let a = AutoMixAutomation(plan: Self.plan)
        #expect(a.frame(at: 15.9).incomingRate == 0.96)
        #expect(abs(a.frame(at: 16 + 4).incomingRate - 0.98) < 0.001)
        #expect(a.frame(at: 16 + 8).incomingRate == 1)
        #expect(a.frame(at: 60).incomingRate == 1)
        #expect(a.totalDuration == 24)
    }

    @Test("crossfade style: no stretch, no bass swap, filter sweep closes on A and opens on B")
    func crossfadeFrames() {
        let a = AutoMixAutomation(crossfade: Self.crossfade)
        // +2 dB of loudness trim: the settle is the 2 s trim glide (T673); untrimmed it is 0.
        #expect(a.settleDuration == 2)
        #expect(a.totalDuration == 10)
        let flat = CrossfadePlan(outgoingMixOut: 200, incomingMixIn: 4, duration: 8, incomingGainDB: 0, filterSweep: true, reason: .tempoMismatch)
        #expect(AutoMixAutomation(crossfade: flat).settleDuration == 0)
        #expect(AutoMixAutomation(crossfade: flat).totalDuration == 8)
        let start = a.frame(at: 0)
        let mid = a.frame(at: 4)
        let end = a.frame(at: 8)
        for f in [start, mid, end] {
            #expect(f.incomingRate == 1)
            #expect(f.outgoingBassDB == 0 && f.incomingBassDB == 0)
        }
        #expect(abs(start.outgoingLowPassHz! - 20_000) < 1)
        #expect(abs(start.incomingLowPassHz! - 800) < 1)
        // Log-frequency midpoint of 800…20 000 Hz = 4 000 Hz, both decks.
        #expect(abs(mid.outgoingLowPassHz! - 4000) < 1)
        #expect(abs(mid.incomingLowPassHz! - 4000) < 1)
        #expect(abs(end.outgoingLowPassHz! - 800) < 1)
        #expect(abs(end.incomingLowPassHz! - 20_000) < 1)
        #expect(end.outgoingGain == 0 || end.outgoingGain < 1e-6)
        #expect(abs(end.incomingGain - 1) < 1e-6)
        // Outside the fade the filters are bypassed.
        #expect(a.frame(at: -1).outgoingLowPassHz == nil)
        #expect(a.frame(at: 9).incomingLowPassHz == nil)
        #expect(abs(a.incomingTrimLinear - 1.2589) < 0.001)
    }

    @Test("incoming trim converts dB to linear")
    func trim() {
        #expect(abs(AutoMixAutomation(plan: Self.plan).incomingTrimLinear - 0.7079) < 0.001)
    }

    /// T673: the loudness-match trim held the incoming track below (or above) its own level for
    /// the rest of the song. It now rides the frame: the match gain through the overlap, then a
    /// glide, linear in dB, back to unity over the settle, so the handback to the queue player
    /// (which plays at unity) is a level the ear has already arrived at.
    @Test("the trim is the match gain through the overlap and glides to unity over the settle")
    func trimGlide() {
        // Beat-matched, −3 dB, 16 s overlap, 8 s rate glide: the trim glides over the same 8 s.
        let a = AutoMixAutomation(plan: Self.plan)
        #expect(abs(a.frame(at: -1).incomingTrim - 0.7079) < 0.001)
        #expect(abs(a.frame(at: 8).incomingTrim - 0.7079) < 0.001)
        #expect(abs(a.frame(at: 16).incomingTrim - 0.7079) < 0.001)
        #expect(abs(a.frame(at: 20).incomingTrim - 0.8414) < 0.001)   // −1.5 dB, halfway in dB
        #expect(a.frame(at: 24).incomingTrim == 1)
        #expect(a.frame(at: 60).incomingTrim == 1)
        // Crossfade, +2 dB, 8 s fade: a 2 s glide after it.
        let c = AutoMixAutomation(crossfade: Self.crossfade)
        #expect(abs(c.frame(at: 8).incomingTrim - 1.2589) < 0.001)
        #expect(abs(c.frame(at: 9).incomingTrim - 1.1220) < 0.001)    // +1 dB
        #expect(c.frame(at: 10).incomingTrim == 1)
        // Untrimmed: unity throughout, and the rate glide alone decides the settle.
        let flat = CrossfadePlan(outgoingMixOut: 200, incomingMixIn: 4, duration: 8, incomingGainDB: 0, filterSweep: false, reason: .tempoMismatch)
        #expect(AutoMixAutomation(crossfade: flat).frame(at: 4).incomingTrim == 1)
        #expect(AutoMixAutomation(crossfade: flat).frame(at: 8.5).incomingTrim == 1)
    }
}

@Suite("AutoMixScheduler")
struct AutoMixSchedulerTests {
    static let plan = AutoMixAutomationTests.plan

    @Test("samples until overlap is the gap to the mix-out at the output rate")
    func samplesUntilOverlap() {
        #expect(AutoMixScheduler.samplesUntilOverlap(outgoingMixOut: 200, outgoingPosition: 190, sampleRate: 44_100) == 441_000)
        #expect(AutoMixScheduler.samplesUntilOverlap(outgoingMixOut: 200, outgoingPosition: 201, sampleRate: 48_000) < 0)
    }

    @Test("arm position leads the mix-out and never goes negative")
    func armPosition() {
        #expect(AutoMixScheduler.armPosition(outgoingMixOut: 200, lead: 5) == 195)
        #expect(AutoMixScheduler.armPosition(outgoingMixOut: 2, lead: 5) == 0)
    }

    @Test("a schedule is integrated bar by bar, then the glide starts from the last bar's rate")
    func scheduledPosition() {
        let plan = BlendPlan(
            outgoingMixOut: 100, incomingMixIn: 10, overlapDuration: 4, overlapBars: 2, incomingRate: 0.97,
            rateSchedule: [RateSegment(outputDuration: 2, rate: 0.95), RateSegment(outputDuration: 2, rate: 0.99)],
            rateGlideDuration: 2, incomingGainDB: 0, bassSwapFraction: 0.5, sectionAligned: false,
        )
        #expect(abs(AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: 1) - 10.95) < 1e-6)
        #expect(abs(AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: 2) - 11.9) < 1e-6)
        #expect(abs(AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: 4) - 13.88) < 1e-6)
        // Glide from 0.99 to 1 over 2 s: average 0.995 → 1.99 s of file.
        #expect(abs(AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: 6) - 15.87) < 1e-6)
        let a = AutoMixAutomation(plan: plan)
        #expect(a.frame(at: 1).incomingRate == 0.95)
        #expect(a.frame(at: 3).incomingRate == 0.99)
        #expect(abs(a.frame(at: 5).incomingRate - 0.995) < 1e-6)
    }

    @Test("incoming file position integrates the stretch and the glide")
    func incomingPosition() {
        let p = Self.plan
        #expect(abs(AutoMixScheduler.incomingFilePosition(plan: p, outputSecondsSinceOverlap: 10) - (8 + 9.6)) < 1e-6)
        let endOfOverlap = AutoMixScheduler.incomingFilePosition(plan: p, outputSecondsSinceOverlap: 16)
        #expect(abs(endOfOverlap - 23.36) < 1e-6)
        let endOfGlide = AutoMixScheduler.incomingFilePosition(plan: p, outputSecondsSinceOverlap: 24)
        #expect(abs(endOfGlide - (23.36 + 7.84)) < 1e-6)
        #expect(abs(AutoMixScheduler.incomingFilePosition(plan: p, outputSecondsSinceOverlap: 34) - (23.36 + 7.84 + 10)) < 1e-6)
        var last = -1.0
        for t in stride(from: 0.0, through: 40.0, by: 0.5) {
            let v = AutoMixScheduler.incomingFilePosition(plan: p, outputSecondsSinceOverlap: t)
            #expect(v > last)
            last = v
        }
    }
}
