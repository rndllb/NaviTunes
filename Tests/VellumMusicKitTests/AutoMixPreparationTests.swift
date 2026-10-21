import Foundation
import Testing

@testable import VellumMusicKit

/// T791: what AutoMix prepares, and what it plays, wherever the listener puts the playhead.
/// The owner's report: after a seek past the middle of a song the next one was not ready and the
/// AutoMix transition silently did not happen.
@Suite("AutoMix preparation (T791)")
struct AutoMixPreparationTests {
    typealias P = AutoMixPreparation
    static let a = TransitionPlannerTests.track(id: "a", tempo: 123)
    static let b = TransitionPlannerTests.track(id: "b", tempo: 128)

    static func input(
        position: TimeInterval,
        currentLocal: Bool = true,
        nextLocal: Bool = true,
        steady: Bool = true,
        streaming: Bool = true,
        current: P.Analysis = .notRequested,
        next: P.Analysis = .notRequested
    ) -> P.Input {
        P.Input(position: position, currentDuration: 240, nextDuration: 240, currentIsLocal: currentLocal,
                nextIsLocal: nextLocal, playingSteadily: steady, streamingAllowed: streaming, current: current, next: next)
    }

    // MARK: Requests: early, and whatever the playhead does

    @Test("a seek past the halfway mark with the next song still streamed: the prefetch is requested at once")
    func seekPastHalfwayPrefetches() {
        let r = P.requests(Self.input(position: 150, nextLocal: false))
        #expect(r.fetchNext)
    }

    @Test("the next song is analysed as soon as it is a file, even while the playing song is streamed")
    func nextAnalysedWhileCurrentStreams() {
        let r = P.requests(Self.input(position: 150, currentLocal: false, nextLocal: true))
        #expect(r.analyseNext)
        #expect(!r.analyseCurrent)
    }

    @Test("nothing is fetched until the playing song plays steadily, and then at once, at any position")
    func fetchWaitsForSteadyPlayback() {
        #expect(!P.requests(Self.input(position: 0.5, nextLocal: false, steady: false)).fetchNext)
        #expect(P.requests(Self.input(position: 3, nextLocal: false, steady: true)).fetchNext)
    }

    @Test("No streaming over cellular, on cellular: no prefetch")
    func cellularBlocksPrefetch() {
        #expect(!P.requests(Self.input(position: 30, nextLocal: false, streaming: false)).fetchNext)
    }

    @Test("a failed analysis is not requested again")
    func failedAnalysisNotRetried() {
        let r = P.requests(Self.input(position: 30, current: .failed, next: .failed))
        #expect(!r.analyseCurrent)
        #expect(!r.analyseNext)
    }

    // MARK: Outcome: a blend, a plain crossfade, or a logged normal transition

    @Test("T633 c2: a seek before the cue, both songs analysed: still the beat-matched blend")
    func seekBeforeCueStillBlends() throws {
        let o = P.outcome(Self.input(position: 120, current: .ready(Self.a), next: .ready(Self.b)))
        #expect(o.decision?.blendPlan != nil)
    }

    @Test("past the analysed cue but with room left: a plain crossfade at the end of the song, logged")
    func pastCueGetsPlainCrossfade() throws {
        let cue = try #require(TransitionPlanner.plan(from: Self.a, to: Self.b).outgoingMixOut)
        let o = P.outcome(Self.input(position: cue + 1, current: .ready(Self.a), next: .ready(Self.b)))
        let plan = try #require(o.decision?.crossfadePlan)
        #expect(plan.outgoingMixOut > cue + 1 + TransitionPlanner.handoffLead)
        #expect(plan.outgoingMixOut + plan.duration <= 240)
        #expect(o.note != nil)
    }

    @Test("the playing song is streamed and the next is a file: a plain crossfade instead of nothing")
    func streamedCurrentGetsPlainCrossfade() throws {
        let o = P.outcome(Self.input(position: 150, currentLocal: false, nextLocal: true))
        #expect(o.decision?.crossfadePlan != nil)
        #expect(o.note != nil)
    }

    @Test("an analysis that failed: a plain crossfade, with the reason in the log")
    func failedAnalysisGetsPlainCrossfade() throws {
        let o = P.outcome(Self.input(position: 60, current: .failed, next: .ready(Self.b)))
        let plan = try #require(o.decision?.crossfadePlan)
        #expect(plan.reason == .analysisFailed)
        #expect(o.note?.contains("analysis") == true)
    }

    @Test("a seek too close to the end for anything: the normal transition, said in the log rather than silent")
    func tooCloseToTheEnd() {
        let o = P.outcome(Self.input(position: 238, current: .ready(Self.a), next: .ready(Self.b)))
        #expect(o.decision == .defaultTransition(.noTimeToPrepare))
        #expect(o.note != nil)
    }

    @Test("analysis still running and able to land in time: a plain crossfade stands in until it does")
    func provisionalCrossfadeWhileAnalysing() throws {
        let o = P.outcome(Self.input(position: 30, current: .ready(Self.a), next: .inFlight(remaining: 10)))
        #expect(o.decision?.crossfadePlan != nil)
    }

    // MARK: Coordinator: a failure is remembered

    @MainActor
    @Test("an analysis that failed reports .failed and is not run again on the next re-plan (a seek)")
    func failureIsRemembered() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("y.flac")
        try Data(repeating: 1, count: 4096).write(to: file)
        let analyzer = AutoMixAnalysisAuditTests.FailingForY()
        let coordinator = AutoMixAnalysisCoordinator(analyzer: analyzer, store: TransitionAnalysisStore(directory: dir.appendingPathComponent("cache")))
        _ = coordinator.ensure(trackId: "y", fileURL: file, duration: 200)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !coordinator.inFlightTrackIds.isEmpty || (analyzer.calls["y"] ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.status(trackId: "y", fileURL: file) == .failed)
        // What a seek does: plan again.
        #expect(coordinator.ensure(trackId: "y", fileURL: file, duration: 200) == .failed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(analyzer.calls["y"] == 1)
    }
}
