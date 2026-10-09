import Foundation
import Testing

@testable import VellumMusicKit

/// The on-device analysis pipeline around the model: the forever-cache, the lazy coordinator and
/// its deadline, the intro/outro heuristic, and the chunk bookkeeping. The model itself is
/// replaced by a fake analyzer so these run on any simulator without the Core ML bundle.
@Suite("AutoMix on-device analysis")
struct AutoMixAnalysisTests {
    /// A fake analyzer: returns a fixed result after an optional delay, and counts calls.
    final class FakeAnalyzer: TransitionAnalyzing, @unchecked Sendable {
        let name = "fake"
        var isAvailable: Bool
        let delay: Duration
        let result: TransitionMetadata
        private(set) var calls = 0
        private let lock = NSLock()

        init(isAvailable: Bool = true, delay: Duration = .zero, result: TransitionMetadata) {
            self.isAvailable = isAvailable
            self.delay = delay
            self.result = result
        }

        func analyze(fileURL: URL, trackId: String) async throws -> TransitionMetadata {
            lock.lock(); calls += 1; lock.unlock()
            if delay > .zero { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            return result
        }
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("automix-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in audio file: the store fingerprints by size and mtime, not by content.
    static func fakeAudioFile(in dir: URL, name: String, bytes: Int = 4096) -> URL {
        let url = dir.appendingPathComponent("\(name).flac")
        try? Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    static let dance123 = TransitionPlannerTests.dance123
    static let dance128 = TransitionPlannerTests.dance128

    // MARK: Store

    @Test("store round-trips by id + fingerprint and misses when the file changes")
    func storeRoundTrip() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TransitionAnalysisStore(directory: dir.appendingPathComponent("cache"))
        let file = Self.fakeAudioFile(in: dir, name: "a")
        let fp = try #require(TransitionAnalysisStore.Fingerprint.of(fileURL: file))
        let key = TransitionAnalysisStore.Key(trackId: "track/with/slashes", fingerprint: fp)
        #expect(store.load(key) == nil)
        try store.save(Self.dance123, for: key)
        #expect(store.load(key) == Self.dance123)
        #expect(store.totalBytes() > 0)
        // Same id, different bytes on disk: a different key, so a miss.
        try Data(repeating: 2, count: 8192).write(to: file)
        let fp2 = try #require(TransitionAnalysisStore.Fingerprint.of(fileURL: file))
        #expect(fp2 != fp)
        #expect(store.load(TransitionAnalysisStore.Key(trackId: "track/with/slashes", fingerprint: fp2)) == nil)
    }

    // MARK: Coordinator

    @Test("cache hit: no inference runs and the plan is available immediately")
    @MainActor
    func cacheHit() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TransitionAnalysisStore(directory: dir.appendingPathComponent("cache"))
        let file = Self.fakeAudioFile(in: dir, name: "b")
        let fp = try #require(TransitionAnalysisStore.Fingerprint.of(fileURL: file))
        try store.save(Self.dance128, for: TransitionAnalysisStore.Key(trackId: "b", fingerprint: fp))
        let analyzer = FakeAnalyzer(result: Self.dance128)
        let coordinator = AutoMixAnalysisCoordinator(analyzer: analyzer, store: store)
        let status = coordinator.ensure(trackId: "b", fileURL: file, duration: 240)
        #expect(status == .ready(Self.dance128))
        #expect(analyzer.calls == 0)
        #expect(coordinator.inFlightTrackIds.isEmpty)
        let decision = TransitionPlanner.plan(from: Self.dance123, to: Self.dance128, pending: nil, outgoingPosition: 0)
        #expect(decision.blendPlan != nil)
    }

    @Test("cache miss with analysis in time: runs once, lands, is cached, and the pair blends")
    @MainActor
    func cacheMissInTime() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TransitionAnalysisStore(directory: dir.appendingPathComponent("cache"))
        let file = Self.fakeAudioFile(in: dir, name: "c")
        let analyzer = FakeAnalyzer(delay: .milliseconds(20), result: Self.dance128)
        let coordinator = AutoMixAnalysisCoordinator(analyzer: analyzer, store: store)

        var landed: [String] = []
        coordinator.onAnalysisCompleted = { landed.append($0) }

        // First ask: nothing cached, so it is in flight with an estimate — and the decision for
        // *this* moment is the default transition, because nothing is ever scheduled on a promise.
        let first = coordinator.ensure(trackId: "c", fileURL: file, duration: 240)
        guard case let .inFlight(expected) = first else { Issue.record("expected inFlight, got \(first)"); return }
        #expect(expected > 0)
        let outgoingPosition: TimeInterval = 30
        let cue = Self.dance123.cues.mixOut
        let pending = PendingAnalysis(expectedReadyAtOutgoingPosition: outgoingPosition + expected)
        let early = TransitionPlanner.plan(from: Self.dance123, to: nil, pending: pending, outgoingPosition: outgoingPosition)
        #expect(early == .defaultTransition(.metadataMissing))
        #expect(outgoingPosition + expected < cue - TransitionPlanner.handoffLead)

        // Let it land.
        for _ in 0 ..< 100 where landed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(landed == ["c"])
        #expect(analyzer.calls == 1)
        let ready = coordinator.ensure(trackId: "c", fileURL: file, duration: 240)
        #expect(ready == .ready(Self.dance128))
        #expect(analyzer.calls == 1)
        // Cached on disk under the fingerprint.
        let fp = try #require(TransitionAnalysisStore.Fingerprint.of(fileURL: file))
        #expect(store.contains(TransitionAnalysisStore.Key(trackId: "c", fingerprint: fp)))
        // And now the pair blends, well before the cue.
        let decision = TransitionPlanner.plan(from: Self.dance123, to: Self.dance128, pending: nil, outgoingPosition: outgoingPosition)
        #expect(decision.blendPlan != nil)
    }

    @Test("cache miss too late: the default transition is chosen immediately, nothing stalls")
    @MainActor
    func cacheMissTooLate() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TransitionAnalysisStore(directory: dir.appendingPathComponent("cache"))
        let file = Self.fakeAudioFile(in: dir, name: "d")
        // A slow analyzer standing in for a 4-minute song on an A15.
        let analyzer = FakeAnalyzer(delay: .seconds(30), result: Self.dance128)
        let coordinator = AutoMixAnalysisCoordinator(
            analyzer: analyzer, store: store,
            estimate: .init(secondsPerAudioSecond: 0.125), // 30 s for 240 s of audio
        )
        // The user queued this song 10 s before the cue point.
        let cue = Self.dance123.downbeat(atOrBefore: Self.dance123.cues.mixOut)!
        let outgoingPosition = cue - 10
        let started = ContinuousClock.now
        let status = coordinator.ensure(trackId: "d", fileURL: file, duration: 240)
        guard case let .inFlight(expected) = status else { Issue.record("expected inFlight"); return }
        let pending = PendingAnalysis(expectedReadyAtOutgoingPosition: outgoingPosition + expected)
        let decision = TransitionPlanner.plan(from: Self.dance123, to: nil, pending: pending, outgoingPosition: outgoingPosition)
        #expect(decision == .defaultTransition(.analysisLate))
        // Decided without waiting on the analyzer.
        #expect(ContinuousClock.now - started < .seconds(1))
        // And the engine would drop it: retaining only the current track cancels the work.
        coordinator.retainOnly(trackIds: ["current"])
        #expect(coordinator.inFlightTrackIds.isEmpty)
    }

    @Test("an unavailable analyzer (no model in the bundle) never schedules work")
    @MainActor
    func unavailableAnalyzer() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let analyzer = FakeAnalyzer(isAvailable: false, result: Self.dance128)
        let coordinator = AutoMixAnalysisCoordinator(analyzer: analyzer, store: TransitionAnalysisStore(directory: dir))
        let file = Self.fakeAudioFile(in: dir, name: "e")
        #expect(coordinator.ensure(trackId: "e", fileURL: file, duration: 240) == .unavailable)
        #expect(analyzer.calls == 0)
        #expect(TransitionPlanner.plan(from: Self.dance123, to: nil, pending: nil, outgoingPosition: 0) == .defaultTransition(.metadataMissing))
    }

    @Test("throughput estimate learns from observations")
    func throughputEstimate() {
        var e = AutoMixAnalysisCoordinator.ThroughputEstimate(secondsPerAudioSecond: 0.1, smoothing: 0.5)
        e.observe(analysisSeconds: 48, audioSeconds: 240) // 0.2
        #expect(abs(e.secondsPerAudioSecond - 0.15) < 1e-9)
        #expect(abs(e.expectedSeconds(forAudioSeconds: 200) - 30) < 1e-9)
        #expect(e.expectedSeconds(forAudioSeconds: 0) == 0.5)
    }

    // MARK: Heuristic

    @Test("intro/outro heuristic: quiet lead-in and fade-out bars, capped at 32")
    func heuristicRuns() {
        var rms = [Double](repeating: 0.2, count: 60)
        for i in 0 ..< 4 { rms[i] = 0.05 }
        for i in 52 ..< 60 { rms[i] = 0.08 }
        let r = IntroOutroHeuristic.analyze(barRMS: rms)
        #expect(r == .init(introBars: 4, outroBars: 8))
        // A song that starts at full level has no intro.
        #expect(IntroOutroHeuristic.analyze(barRMS: [Double](repeating: 0.2, count: 20)) == .init(introBars: 0, outroBars: 0))
        // A 40-bar quiet opening is the song, not an intro: capped at 32.
        var long = [Double](repeating: 0.2, count: 80)
        for i in 0 ..< 40 { long[i] = 0.05 }
        #expect(IntroOutroHeuristic.analyze(barRMS: long).introBars == 32)
        // Too few bars: nothing.
        #expect(IntroOutroHeuristic.analyze(barRMS: [0.1, 0.2]) == .init(introBars: 0, outroBars: 0))
    }

    @Test("heuristic sections cover the track with contiguous labels")
    func heuristicSections() {
        let edges: [TimeInterval] = (0 ... 10).map { Double($0) * 2 }
        let s = IntroOutroHeuristic.sections(from: .init(introBars: 2, outroBars: 3), edges: edges)
        #expect(s.map(\.label) == ["intro", "body", "outro"])
        #expect(s[0].start == 0 && s[0].end == 4)
        #expect(s[1].start == 4 && s[1].end == 14)
        #expect(s[2].start == 14 && s[2].end == 20)
    }

    // MARK: Model chunking and peak picking

    @Test("chunk plan mirrors the reference split: overlapping, border-padded, last chunk shifted left")
    func chunkPlan() {
        let plan = CoreMLChunkRunner.chunkPlan(frameCount: 12_000, chunk: 1500, border: 6)
        #expect(plan.first?.start == -6)
        #expect(plan.first?.padLeft == 6)
        #expect(plan.last?.start == 12_000 - 1494)
        // Consecutive chunks overlap by 2 × border.
        #expect(plan[1].start - plan[0].start == 1500 - 12)
        // Every frame is covered by some chunk's interior.
        var covered = [Bool](repeating: false, count: 12_000)
        for c in plan {
            for row in 6 ..< 1494 where c.start + row >= 0 && c.start + row < 12_000 { covered[c.start + row] = true }
        }
        #expect(!covered.contains(false))
        // A short piece is a single run.
        #expect(CoreMLChunkRunner.chunkPlan(frameCount: 900, chunk: 1500, border: 6).count == 1)
    }

    @Test("peak picking keeps local maxima above probability 0.5 and snaps downbeats to beats")
    func peakPicking() {
        var beat = [Float](repeating: -5, count: 200)
        var down = [Float](repeating: -5, count: 200)
        for i in stride(from: 10, to: 200, by: 25) { beat[i] = 3; beat[i + 1] = 2 } // 0.5 s apart at 50 fps
        down[10] = 2; down[111] = 1 // 111 is one frame off beat 110: snaps
        down[60] = -1 // below 0.5: ignored
        let (b, d) = BeatThisFeatures.pickPeaks(beat: beat, downbeat: down, fps: 50)
        #expect(b.count == 8)
        #expect(abs(b[1] - b[0] - 0.5) < 1e-9)
        #expect(d == [0.2, 2.2])
    }

    @Test("beat confidence: steady grid ≈ 1, jittered grid lower, too few beats 0")
    func beatConfidence() {
        let steady = (0 ..< 400).map { Double($0) * 0.5 }
        #expect(BeatThisFeatures.beatConfidence(beats: steady, duration: 200) > 0.98)
        // Smoothly varying jitter: a strictly alternating offset would cancel in the median
        // absolute deviation (which is the point of using it), so vary it with the index.
        let jitter = steady.enumerated().map { i, t in t + 0.12 * sin(Double(i)) }
        #expect(BeatThisFeatures.beatConfidence(beats: jitter, duration: 200) < 0.3)
        #expect(BeatThisFeatures.beatConfidence(beats: [0, 1, 2], duration: 200) == 0)
    }
}
