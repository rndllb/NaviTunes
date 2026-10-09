import AVFoundation
import Foundation

/// The two-deck transition transport. Lives only from one handoff until the queue goes back to the
/// `AVQueuePlayer` transport (a skip, a seek, a pause, or the last blended track ending), and only
/// when `PlaybackEngine.autoMixEnabled` is on and both songs are local files with analysis.
/// Streams without a local file, radio, and the EQ tap path stay on `AVQueuePlayer`.
///
/// Graph, per deck:
///
///     AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ(lowShelf, lowPass) → mainMixerNode
///
/// Beat-matched style: the outgoing deck runs at 1.0 for its whole life; the incoming deck starts
/// at the plan's `incomingRate` so its beats sit on the outgoing deck's, then glides back to 1.0
/// after the overlap; the low shelves do the bass swap.
/// Crossfade style: both decks at 1.0, equal-power gains, the low-pass bands sweep.
///
/// The knobs are driven from `AutoMixAutomation` on a 50 Hz main-actor timer. Scheduling is
/// sample-accurate: the incoming file is scheduled with an `AVAudioTime` computed from the
/// outgoing node's render clock, so the downbeat lands where the planner said it would.
///
/// Decks are symmetric, so once a transition has settled the incoming deck becomes the outgoing
/// deck for the next one (`chain`) without the audio ever leaving this engine.
@MainActor
final class AutoMixAudioEnginePlayer {
    final class Deck {
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        var file: AVAudioFile?
        var startFrame: AVAudioFramePosition = 0
        var trim: Float = 1

        init() {
            let shelf = eq.bands[0]
            shelf.filterType = .lowShelf
            shelf.frequency = 150
            shelf.bandwidth = 1
            shelf.gain = 0
            shelf.bypass = false
            let lowPass = eq.bands[1]
            lowPass.filterType = .lowPass
            lowPass.frequency = 20_000
            lowPass.bandwidth = 0.5
            lowPass.bypass = true
            eq.globalGain = 0
            timePitch.rate = 1
            timePitch.pitch = 0
            timePitch.overlap = 8
        }

        var sampleRate: Double { file?.processingFormat.sampleRate ?? 44_100 }

        /// File position in seconds, from the node's own render clock, mapped through the
        /// *file's* sample rate and clamped to the file — see `filePosition(...)`.
        var position: TimeInterval? {
            guard let file, let renderTime = player.lastRenderTime,
                  let nodeTime = player.playerTime(forNodeTime: renderTime), nodeTime.isSampleTimeValid else { return nil }
            return AutoMixAudioEnginePlayer.filePosition(
                startFrame: startFrame,
                playerSampleTime: nodeTime.sampleTime,
                fileSampleRate: file.processingFormat.sampleRate,
                fileLength: file.length,
            )
        }
    }

    /// The one place engine frames become track seconds. A deck's player time counts the frames
    /// it has rendered since it started, in the file's rate (the time-pitch unit downstream does
    /// not change what the player node consumes); add the frame the segment started at and divide
    /// by the file's rate. Clamped to the file, and `nil` for anything that cannot be a position,
    /// so a bad clock can never reach the UI as a raw frame count.
    nonisolated static func filePosition(
        startFrame: AVAudioFramePosition,
        playerSampleTime: AVAudioFramePosition,
        fileSampleRate: Double,
        fileLength: AVAudioFramePosition,
    ) -> TimeInterval? {
        guard fileSampleRate > 1000, fileLength > 0, playerSampleTime >= 0 else { return nil }
        let frame = min(max(0, startFrame + playerSampleTime), fileLength)
        return Double(frame) / fileSampleRate
    }

    enum Failure: Error {
        case fileUnreadable(URL)
        case engineStartFailed(Error)
        case mixOutAlreadyPassed
        case notSettled
    }

    /// Fired on the main actor when the deck currently carrying the queue's track plays to its
    /// end with no further transition scheduled — the engine hands the queue back here.
    var onDeckFinished: (() -> Void)?
    /// Fired once per transition when the overlap has completed and the incoming track is the
    /// only thing audible. `PlaybackEngine` promotes its queue cursor at this moment.
    var onOverlapCompleted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var outgoing = Deck()
    private var incoming = Deck()
    private var automation: AutoMixAutomation?
    private var tick: Timer?
    /// Host time (mach ticks) at which the overlap starts. The transition clock runs on host time
    /// because a player node's own clock is not valid until its first render cycle: reading it
    /// synchronously right after `play()` gave a time with no valid sample time, the overlap was
    /// scheduled against garbage, and the completion never fired — the old song's clock kept
    /// driving the UI (device report, 2026-10-09).
    private var overlapStartHostTime: UInt64 = 0
    /// Where the outgoing file was, and when, at the moment its deck started — the fallback
    /// position estimate while its node clock is not valid yet.
    private var outgoingStartPosition: TimeInterval = 0
    private var outgoingStartHostTime: UInt64 = 0
    private var overlapCompletedFired = false
    private var settled = true
    private var scheduleGeneration: UInt = 0
    private(set) var isRunning = false
    private(set) var isPaused = false

    init() {
        for deck in [outgoing, incoming] {
            engine.attach(deck.player)
            engine.attach(deck.timePitch)
            engine.attach(deck.eq)
        }
    }

    deinit {
        tick?.invalidate()
        engine.stop()
    }

    // MARK: - Lifecycle

    /// Prepare the first transition: the outgoing file picked up at `outgoingPosition` (where
    /// `AVQueuePlayer` was when it handed over) and the incoming file scheduled per the automation.
    /// Throws if the mix-out is already behind the handoff position.
    func prepare(
        outgoingURL: URL,
        outgoingPosition: TimeInterval,
        incomingURL: URL,
        automation: AutoMixAutomation,
    ) throws {
        guard outgoingPosition < mixOut(of: automation) else { throw Failure.mixOutAlreadyPassed }
        guard let outFile = try? AVAudioFile(forReading: outgoingURL) else { throw Failure.fileUnreadable(outgoingURL) }
        guard let inFile = try? AVAudioFile(forReading: incomingURL) else { throw Failure.fileUnreadable(incomingURL) }

        outgoing.file = outFile
        outgoing.trim = 1
        incoming.file = inFile
        incoming.trim = automation.incomingTrimLinear
        self.automation = automation
        overlapCompletedFired = false
        settled = false

        connect(outgoing)
        connect(incoming)

        // Outgoing: from the handoff position to the end of file, at 1.0.
        let outStart = AVAudioFramePosition(outgoingPosition * outFile.processingFormat.sampleRate)
        outgoing.startFrame = outStart
        outgoingStartPosition = outgoingPosition
        scheduleDeck(outgoing, from: outStart, at: nil)
        incoming.startFrame = AVAudioFramePosition(mixIn(of: automation) * inFile.processingFormat.sampleRate)

        apply(automation.frame(at: -1))
        engine.prepare()
    }

    /// Starts audio. The outgoing deck plays immediately; the incoming deck is scheduled
    /// sample-accurately for the mix-out point.
    func start() throws {
        guard let automation else { return }
        do {
            try engine.start()
        } catch {
            throw Failure.engineStartFailed(error)
        }
        outgoing.player.play()
        outgoingStartHostTime = mach_absolute_time()
        isRunning = true
        isPaused = false
        scheduleIncoming(automation: automation)
    }

    /// Chain the next transition onto the deck that is now playing. Only valid once the previous
    /// transition has settled (rate back at 1.0, outgoing deck released).
    func chain(incomingURL: URL, automation: AutoMixAutomation) throws {
        guard isRunning, settled else { throw Failure.notSettled }
        guard let position = incoming.position, position < mixOut(of: automation) else { throw Failure.mixOutAlreadyPassed }
        guard let inFile = try? AVAudioFile(forReading: incomingURL) else { throw Failure.fileUnreadable(incomingURL) }
        // Roles swap: the deck carrying the current track becomes the outgoing deck.
        swap(&outgoing, &incoming)
        outgoingStartPosition = position
        outgoingStartHostTime = mach_absolute_time()
        incoming.player.stop()
        incoming.file = inFile
        incoming.trim = automation.incomingTrimLinear
        incoming.startFrame = AVAudioFramePosition(mixIn(of: automation) * inFile.processingFormat.sampleRate)
        connect(incoming)
        self.automation = automation
        overlapCompletedFired = false
        settled = false
        apply(automation.frame(at: -1))
        scheduleIncoming(automation: automation)
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        outgoing.player.pause()
        incoming.player.pause()
        engine.pause()
        isPaused = true
    }

    func resume() throws {
        guard isRunning, isPaused else { return }
        try engine.start()
        outgoing.player.play()
        incoming.player.play()
        isPaused = false
    }

    func stop() {
        tick?.invalidate()
        tick = nil
        scheduleGeneration &+= 1
        outgoing.player.stop()
        incoming.player.stop()
        engine.stop()
        isRunning = false
        isPaused = false
        settled = true
    }

    /// Whether the last transition has fully settled, so the next can be chained.
    var isSettled: Bool { settled }

    /// Current file position of the track the queue considers current. Before the overlap
    /// completes that is the outgoing deck; after, the incoming one.
    var currentTrackPosition: TimeInterval? {
        guard isRunning, let automation else { return nil }
        if overlapCompletedFired {
            let t = outputSecondsSinceOverlap()
            switch automation.style {
            case let .beatMatched(plan):
                if !settled { return AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: t) }
                return incoming.position ?? AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: t)
            case let .crossfade(plan):
                return incoming.position ?? (plan.incomingMixIn + max(0, t))
            }
        }
        return outgoingEstimatedPosition()
    }

    // MARK: - Internals

    private func mixOut(of automation: AutoMixAutomation) -> TimeInterval {
        switch automation.style {
        case let .beatMatched(p): return p.outgoingMixOut
        case let .crossfade(p): return p.outgoingMixOut
        }
    }

    private func mixIn(of automation: AutoMixAutomation) -> TimeInterval {
        switch automation.style {
        case let .beatMatched(p): return p.incomingMixIn
        case let .crossfade(p): return p.incomingMixIn
        }
    }

    private func connect(_ deck: Deck) {
        guard let format = deck.file?.processingFormat else { return }
        engine.disconnectNodeOutput(deck.player)
        engine.disconnectNodeOutput(deck.timePitch)
        engine.disconnectNodeOutput(deck.eq)
        engine.connect(deck.player, to: deck.timePitch, format: format)
        engine.connect(deck.timePitch, to: deck.eq, format: format)
        engine.connect(deck.eq, to: engine.mainMixerNode, format: format)
    }

    private func scheduleDeck(_ deck: Deck, from frame: AVAudioFramePosition, at when: AVAudioTime?) {
        guard let file = deck.file else { return }
        let frames = AVAudioFrameCount(max(0, file.length - frame))
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        deck.player.scheduleSegment(file, startingFrame: frame, frameCount: frames, at: when, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.scheduleGeneration == generation else { return }
                // Only the deck carrying the queue's current track reports its end.
                if deck === self.incoming || (deck === self.outgoing && !self.overlapCompletedFired) {
                    self.onDeckFinished?()
                }
            }
        }
    }

    private func scheduleIncoming(automation: AutoMixAutomation) {
        // Host-time scheduling is valid from the first call, unlike the node clock.
        let secondsUntil = max(0, mixOut(of: automation) - outgoingEstimatedPosition())
        overlapStartHostTime = Self.hostTime(adding: secondsUntil, to: mach_absolute_time())
        let when = AVAudioTime(hostTime: overlapStartHostTime)
        scheduleDeck(incoming, from: incoming.startFrame, at: when)
        incoming.player.play(at: when)
        armTick(automation: automation)
    }

    /// The outgoing file's position: its node clock once that is valid, else where it started
    /// plus the host time since (it plays at 1.0).
    private func outgoingEstimatedPosition() -> TimeInterval {
        if let p = outgoing.position { return p }
        return outgoingStartPosition + Self.seconds(from: outgoingStartHostTime, to: mach_absolute_time())
    }

    /// Output seconds since the overlap began, on the host clock (negative before it).
    private func outputSecondsSinceOverlap() -> TimeInterval {
        guard overlapStartHostTime > 0 else { return 0 }
        return Self.seconds(from: overlapStartHostTime, to: mach_absolute_time())
    }

    /// Host ticks → seconds, signed. Pure, so the clock arithmetic is testable.
    nonisolated static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        if end >= start { return AVAudioTime.seconds(forHostTime: end - start) }
        return -AVAudioTime.seconds(forHostTime: start - end)
    }

    nonisolated static func hostTime(adding seconds: TimeInterval, to host: UInt64) -> UInt64 {
        host + AVAudioTime.hostTime(forSeconds: max(0, seconds))
    }

    /// Seconds of the current overlap still to play (0 outside a transition).
    var overlapSecondsRemaining: TimeInterval {
        guard isRunning, let automation, !overlapCompletedFired else { return 0 }
        return max(0, automation.overlapDuration - outputSecondsSinceOverlap())
    }

    /// 0…1 through the current overlap, for the Now Playing visual crossfade. `nil` outside a
    /// transition.
    var overlapProgress: Double? {
        guard isRunning, let automation, !settled, automation.overlapDuration > 0 else { return nil }
        let t = outputSecondsSinceOverlap()
        guard t >= 0 else { return 0 }
        return min(1, t / automation.overlapDuration)
    }

    /// The incoming track's file position, whatever stage the transition is at: through the
    /// per-bar schedule and the glide for a beat-matched blend, mix-in plus elapsed for a
    /// crossfade, the node clock once it is valid. `PlaybackEngine` reads this from the moment it
    /// promotes the incoming track, independently of this engine's own completion callback.
    var incomingTrackPosition: TimeInterval? {
        guard isRunning, let automation else { return nil }
        let t = outputSecondsSinceOverlap()
        switch automation.style {
        case let .beatMatched(plan):
            if !settled { return AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: t) }
            return incoming.position ?? AutoMixScheduler.incomingFilePosition(plan: plan, outputSecondsSinceOverlap: t)
        case let .crossfade(plan):
            return incoming.position ?? (plan.incomingMixIn + max(0, t))
        }
    }

    /// The outgoing track's file position.
    var outgoingTrackPosition: TimeInterval? {
        guard isRunning else { return nil }
        return outgoingEstimatedPosition()
    }

    private func armTick(automation: AutoMixAutomation) {
        tick?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPaused else { return }
                let t = self.outputSecondsSinceOverlap()
                self.apply(automation.frame(at: t))
                if !self.overlapCompletedFired, t >= automation.overlapDuration {
                    self.overlapCompletedFired = true
                    self.onOverlapCompleted?()
                }
                if t >= automation.totalDuration {
                    // The outgoing deck is silent and the incoming rate is back at 1.0: release
                    // the outgoing file and stop ticking. The incoming deck keeps playing.
                    self.outgoing.player.stop()
                    self.outgoing.file = nil
                    self.settled = true
                    self.tick?.invalidate()
                    self.tick = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func apply(_ frame: AutoMixAutomation.Frame) {
        outgoing.player.volume = frame.outgoingGain * outgoing.trim
        incoming.player.volume = frame.incomingGain * incoming.trim
        incoming.timePitch.rate = frame.incomingRate
        outgoing.eq.bands[0].gain = frame.outgoingBassDB
        incoming.eq.bands[0].gain = frame.incomingBassDB
        setLowPass(outgoing, hz: frame.outgoingLowPassHz)
        setLowPass(incoming, hz: frame.incomingLowPassHz)
    }

    private func setLowPass(_ deck: Deck, hz: Float?) {
        let band = deck.eq.bands[1]
        if let hz {
            band.bypass = false
            band.frequency = max(20, min(20_000, hz))
        } else {
            band.bypass = true
        }
    }
}
