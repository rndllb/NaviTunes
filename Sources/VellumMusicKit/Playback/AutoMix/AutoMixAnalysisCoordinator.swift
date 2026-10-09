import Foundation

/// Lazy, next-track-only analysis scheduling for AutoMix.
///
/// Rules, all of which the tests pin down:
/// - **Nothing runs while idle.** Work starts only when `PlaybackEngine` asks for a specific
///   track (the one playing and the one queued after it), and only when the toggle is on.
/// - **Cache first, forever.** A hit in `TransitionAnalysisStore` (keyed by id + file fingerprint)
///   never re-runs the model.
/// - **Low priority, bounded.** One analysis at a time, on a `.utility` task, so a scrub or a
///   screen draw is never behind inference.
/// - **Never waited for.** Callers get a status *now*; if the result is not in, they get an
///   estimate of when it will be and decide (through `TransitionPlanner`) whether a blend is still
///   possible. If it is not, the default transition plays.
@MainActor
final class AutoMixAnalysisCoordinator {
    enum Status: Equatable {
        case ready(TransitionMetadata)
        /// Analysis is running; `expectedRemaining` is the coordinator's best estimate in seconds.
        case inFlight(expectedRemaining: TimeInterval)
        /// Nothing cached and nothing running: either the analyzer is unavailable (no model in the
        /// bundle) or the caller has not asked for this track yet.
        case unavailable
    }

    /// Throughput model: analysis seconds per second of audio, learned on the device as an
    /// exponential moving average. Seeded from the CPU proxy measured for Beat This small in the
    /// T630 evaluation so the first estimate is not a guess of zero.
    struct ThroughputEstimate: Equatable {
        var secondsPerAudioSecond: Double
        var smoothing: Double = 0.3

        static let seed = ThroughputEstimate(secondsPerAudioSecond: 0.06)

        mutating func observe(analysisSeconds: TimeInterval, audioSeconds: TimeInterval) {
            guard audioSeconds > 0 else { return }
            let sample = analysisSeconds / audioSeconds
            secondsPerAudioSecond = secondsPerAudioSecond * (1 - smoothing) + sample * smoothing
        }

        func expectedSeconds(forAudioSeconds audio: TimeInterval) -> TimeInterval {
            max(0.5, secondsPerAudioSecond * audio)
        }
    }

    private struct InFlight {
        let task: Task<Void, Never>
        let startedAt: ContinuousClock.Instant
        let expected: TimeInterval
    }

    let analyzer: any TransitionAnalyzing
    let store: TransitionAnalysisStore
    private(set) var estimate: ThroughputEstimate
    private var memory: [TransitionAnalysisStore.Key: TransitionMetadata] = [:]
    private var inFlight: [String: InFlight] = [:]
    private var queued: [(trackId: String, fileURL: URL, duration: TimeInterval)] = []
    /// Fires on the main actor when an analysis lands, so the engine can re-plan.
    var onAnalysisCompleted: ((String) -> Void)?
    /// Last few decisions, for the debug UI and for tests.
    private(set) var log: [String] = []

    init(analyzer: any TransitionAnalyzing, store: TransitionAnalysisStore = TransitionAnalysisStore(), estimate: ThroughputEstimate = .seed) {
        self.analyzer = analyzer
        self.store = store
        self.estimate = estimate
    }

    var isAvailable: Bool { analyzer.isAvailable }

    /// Cache lookup only — never starts work.
    func cached(trackId: String, fileURL: URL) -> TransitionMetadata? {
        guard let fp = TransitionAnalysisStore.Fingerprint.of(fileURL: fileURL) else { return nil }
        let key = TransitionAnalysisStore.Key(trackId: trackId, fingerprint: fp)
        if let hit = memory[key] { return hit }
        if let hit = store.load(key) {
            memory[key] = hit
            return hit
        }
        return nil
    }

    /// Current status, starting an analysis if there is none and the analyzer is available.
    @discardableResult
    func ensure(trackId: String, fileURL: URL, duration: TimeInterval) -> Status {
        if let hit = cached(trackId: trackId, fileURL: fileURL) { return .ready(hit) }
        guard analyzer.isAvailable else { return .unavailable }
        if let running = inFlight[trackId] {
            let elapsed = (ContinuousClock.now - running.startedAt).seconds
            return .inFlight(expectedRemaining: max(0, running.expected - elapsed))
        }
        let expected = estimate.expectedSeconds(forAudioSeconds: duration)
        if inFlight.isEmpty {
            start(trackId: trackId, fileURL: fileURL, duration: duration, expected: expected)
            return .inFlight(expectedRemaining: expected)
        }
        // One at a time: queue behind the running one and report the summed wait.
        if !queued.contains(where: { $0.trackId == trackId }) {
            queued.append((trackId, fileURL, duration))
        }
        let ahead = inFlight.values.map(\.expected).reduce(0, +)
        return .inFlight(expectedRemaining: ahead + expected)
    }

    /// Drop every analysis (running or queued) for tracks not in `trackIds` — the queue changed
    /// and whatever was next is not next any more.
    func retainOnly(trackIds: Set<String>) {
        for (id, running) in inFlight where !trackIds.contains(id) {
            running.task.cancel()
            inFlight[id] = nil
            log.append("cancelled \(id)")
        }
        queued.removeAll { !trackIds.contains($0.trackId) }
    }

    func cancelAll() {
        retainOnly(trackIds: [])
    }

    var inFlightTrackIds: Set<String> { Set(inFlight.keys) }

    private func start(trackId: String, fileURL: URL, duration: TimeInterval, expected: TimeInterval) {
        let analyzer = self.analyzer
        let startedAt = ContinuousClock.now
        let task = Task(priority: .utility) { [weak self] in
            let result: Result<TransitionMetadata, Error>
            do {
                result = .success(try await PerfLog.measureAsync("automix.analyze", context: .background, details: trackId) {
                    try await analyzer.analyze(fileURL: fileURL, trackId: trackId)
                })
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            await self?.finish(trackId: trackId, fileURL: fileURL, duration: duration, startedAt: startedAt, result: result)
        }
        inFlight[trackId] = InFlight(task: task, startedAt: startedAt, expected: expected)
        log.append("started \(trackId) expected \(Int(expected))s")
    }

    private func finish(
        trackId: String,
        fileURL: URL,
        duration: TimeInterval,
        startedAt: ContinuousClock.Instant,
        result: Result<TransitionMetadata, Error>,
    ) {
        inFlight[trackId] = nil
        let elapsed = (ContinuousClock.now - startedAt).seconds
        switch result {
        case let .success(meta):
            estimate.observe(analysisSeconds: elapsed, audioSeconds: duration)
            if let fp = TransitionAnalysisStore.Fingerprint.of(fileURL: fileURL) {
                let key = TransitionAnalysisStore.Key(trackId: trackId, fingerprint: fp)
                memory[key] = meta
                try? store.save(meta, for: key)
            }
            log.append("finished \(trackId) in \(String(format: "%.1f", elapsed))s")
            onAnalysisCompleted?(trackId)
        case let .failure(error):
            log.append("failed \(trackId): \(error)")
        }
        if let next = queued.first {
            queued.removeFirst()
            _ = ensure(trackId: next.trackId, fileURL: next.fileURL, duration: next.duration)
        }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
