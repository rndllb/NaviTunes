import Foundation
import Testing

@testable import VellumMusicKit

/// T643 c3, analysis-side findings of the AutoMix audit.
///
/// 1. `TransitionPlanner.rateSchedule` stepped B's grid by the wrong number of beats for half-
///    and double-time pairs (85 → 170 stepped 4 B beats per A bar instead of 8; 170 → 85 stepped
///    8 instead of 2), so every such pair silently fell back to the constant rate — the 90 ms
///    drift the per-bar lock exists to remove. `halfTimeMatches` only checked the mean rate.
/// 2. `MelSpectrogram.logMelFrames` indexed `samples[-1]` on an empty input (a decodable file
///    with no frames) and crashed the analysis task.
/// 3. `AutoMixAnalysisCoordinator` never removed a started track from `queued` and popped one
///    entry per finish, so a failed analysis re-ran once more while the next track waited.
@Suite("AutoMix analysis audit")
struct AutoMixAnalysisAuditTests {
    // MARK: 1. the bar lock across an octave

    /// A grid at `tempo` that speeds up `driftPerBar` per bar through its first 10 bars — the same
    /// shape as `TransitionPlannerTests.barLockFollowsDrift`, at an arbitrary tempo.
    private static func drifting(id: String, tempo: Double, driftPerBar: Double = 0.01) -> TransitionMetadata {
        var beats: [TimeInterval] = []
        var t = 0.05
        let beat = 60 / tempo
        var i = 0
        while t < 290 {
            beats.append(t)
            let bar = i / 4
            t += beat / (1 + driftPerBar * Double(min(bar, 10)))
            i += 1
        }
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        return TransitionMetadata(
            version: 1, trackId: id, duration: 300, tempo: tempo, beats: beats, downbeats: downbeats,
            beatConfidence: 0.95, key: nil,
            loudness: .init(integrated: -9, range: 6, intro: -12, outro: -11),
            sections: [.init(start: 0, end: 300, label: "body")],
            cues: .init(mixIn: beats[0], mixOut: beats[beats.count - 40]), analyzer: "test",
        )
    }

    @Test("85 BPM into a drifting 170 BPM grid: one A bar locks onto two B bars, bar by bar")
    func doubleTimeBarLock() throws {
        let a = TransitionPlannerTests.rock85
        // One A bar spans two B bars here, so B's drift is halved to stay 1 % per *A* bar: at 1 %
        // per B bar it passes the 8 % stretch cap by A bar 6 and the planner (correctly) clamps.
        let b = Self.drifting(id: "drift170", tempo: 170, driftPerBar: 0.005)
        let plan = try #require(TransitionPlanner.plan(from: a, to: b).blendPlan)
        #expect(abs(Double(plan.incomingRate) - 1) < 0.02)
        #expect(plan.rateSchedule.count == plan.overlapBars)
        let rates = plan.rateSchedule.map(\.rate)
        #expect(rates.first! > rates.last!, "a constant-rate fallback: \(rates)")
        var outT: TimeInterval = 0
        for (k, seg) in plan.rateSchedule.enumerated() {
            outT += seg.outputDuration
            let filePos = AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: outT)
            let expected = b.beats[8 * (k + 1)]   // two B bars per A bar
            #expect(abs(filePos - expected) < 0.002, "bar \(k + 1): \(filePos) vs \(expected)")
        }
    }

    @Test("170 BPM into a drifting 85 BPM grid: one A bar locks onto half a B bar (two B beats)")
    func halfTimeBarLock() throws {
        let a = TransitionPlannerTests.track(id: "fast170", tempo: 170)
        let b = Self.drifting(id: "drift85", tempo: 85)
        let plan = try #require(TransitionPlanner.plan(from: a, to: b).blendPlan)
        #expect(abs(Double(plan.incomingRate) - 1) < 0.02)
        #expect(plan.rateSchedule.count == plan.overlapBars)
        let rates = plan.rateSchedule.map(\.rate)
        #expect(rates.first! > rates.last!, "a constant-rate fallback: \(rates)")
        var outT: TimeInterval = 0
        for (k, seg) in plan.rateSchedule.enumerated() {
            outT += seg.outputDuration
            let filePos = AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: outT)
            let expected = b.beats[2 * (k + 1)]   // two B beats per A bar
            #expect(abs(filePos - expected) < 0.002, "bar \(k + 1): \(filePos) vs \(expected)")
        }
    }

    @Test("same tempo still steps one bar for one bar (the existing drift test's contract)")
    func sameTempoUnchanged() throws {
        let a = TransitionPlannerTests.track(id: "a125", tempo: 125)
        let b = Self.drifting(id: "drift125", tempo: 125)
        let plan = try #require(TransitionPlanner.plan(from: a, to: b).blendPlan)
        #expect(plan.rateSchedule.count == plan.overlapBars)
        var outT: TimeInterval = 0
        for (k, seg) in plan.rateSchedule.enumerated() {
            outT += seg.outputDuration
            let filePos = AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: outT)
            #expect(abs(filePos - b.beats[4 * (k + 1)]) < 0.002)
        }
    }

    // MARK: 2. an empty decode must not trap

    @Test("no samples: no frames, no crash")
    func emptySamples() {
        #expect(BeatThisFeatures.logMel(samples: [], sampleRate: 22_050).isEmpty)
    }

    @Test("one sample: one centred frame")
    func oneSample() {
        #expect(BeatThisFeatures.logMel(samples: [0.5], sampleRate: 22_050).count == 1)
    }

    // MARK: 3. a failed analysis does not run twice while the next one waits

    final class FailingForY: TransitionAnalyzing, @unchecked Sendable {
        let name = "fake"
        let isAvailable = true
        private let lock = NSLock()
        private(set) var calls: [String: Int] = [:]
        func analyze(fileURL: URL, trackId: String) async throws -> TransitionMetadata {
            lock.lock(); calls[trackId, default: 0] += 1; lock.unlock()
            try await Task.sleep(for: .milliseconds(15))
            try Task.checkCancellation()
            if trackId == "y" { throw TransitionAnalysisError.noBeatsFound }
            return TransitionPlannerTests.dance128
        }
    }

    @MainActor
    @Test("x running, y and z queued, x dropped: y fails once and z runs")
    func queueAdvancesPastAFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String) throws -> URL {
            let url = dir.appendingPathComponent("\(name).flac")
            try Data(repeating: 1, count: 4096).write(to: url)
            return url
        }
        let x = try file("x"), y = try file("y"), z = try file("z")
        let analyzer = FailingForY()
        let coordinator = AutoMixAnalysisCoordinator(analyzer: analyzer, store: TransitionAnalysisStore(directory: dir.appendingPathComponent("cache")))
        _ = coordinator.ensure(trackId: "x", fileURL: x, duration: 200)
        _ = coordinator.ensure(trackId: "y", fileURL: y, duration: 200)
        _ = coordinator.ensure(trackId: "z", fileURL: z, duration: 200)
        // The queue moved on: x is gone, y is current, z is next — exactly what the planner does.
        coordinator.retainOnly(trackIds: ["y", "z"])
        _ = coordinator.ensure(trackId: "y", fileURL: y, duration: 200)
        _ = coordinator.ensure(trackId: "z", fileURL: z, duration: 200)
        // Poll rather than sleep a fixed 400 ms: the analysis tasks run on the main actor at
        // `.utility`, and a parallel test holding the main actor delayed them past that (T659).
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, (analyzer.calls["z"] ?? 0) == 0 || !coordinator.inFlightTrackIds.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(analyzer.calls["y"] == 1, "y was re-run after failing: \(analyzer.calls)")
        #expect((analyzer.calls["z"] ?? 0) >= 1, "z never ran: \(analyzer.calls)")
        #expect(coordinator.inFlightTrackIds.isEmpty)
    }
}
