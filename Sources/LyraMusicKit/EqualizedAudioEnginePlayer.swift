import AVFoundation
import Foundation

/// AVAudioEngine + AVAudioUnitEQ playback path (HanSJin/AVAudio-Equalizer pattern).
/// Used when the user enables the equalizer — AVPlayer cannot host real-time EQ units.
@MainActor
final class EqualizedAudioEnginePlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: EqualizerBand.count)
    /// Playback-speed support. `AVAudioPlayerNode.rate` is the AVAudio3DMixing
    /// property — a no-op outside 3D environments — so rate must be applied by
    /// a time-pitch unit in the chain (pitch-preserving, matching AVPlayer).
    private let timePitchNode = AVAudioUnitTimePitch()

    private var streamTask: Task<Void, Never>?
    private var streamPrepareContinuation: CheckedContinuation<Void, Error>?
    private var timeObserver: Timer?
    private var playbackStartOffset: TimeInterval = 0
    private var trackedDuration: TimeInterval = 0
    private var isConfigured = false
    private var finishedNotified = false
    private var reloadToken = UUID()
    private var didScheduleAudio = false
    private var connectedFormat: AVAudioFormat?

    var onTimeUpdate: ((TimeInterval) -> Void)?
    /// Fires only after real audio reaches the end — never on decode/setup failures.
    var onFinished: (() -> Void)?
    /// Fires when playback stalls or decode fails after load (must not advance the queue).
    var onPlaybackFailed: (() -> Void)?
    /// The system stopped this engine because the audio route/hardware format
    /// changed (AirPods connected, CarPlay, …). The graph must be rebuilt —
    /// the owner should reload at ``currentPlaybackTime()``. AVPlayer survives
    /// these without help; AVAudioEngine does not.
    var onConfigurationChange: (() -> Void)?
    private var configChangeObserver: NSObjectProtocol?

    var isPlaying: Bool { playerNode.isPlaying }

    init() {
        configureBands()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.onConfigurationChange?() }
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    func applyGains(_ gains: [Float], bypass: Bool) {
        let normalized = EqualizerPreset.normalizedGains(gains)
        for (index, band) in eqNode.bands.enumerated() where index < normalized.count {
            band.gain = normalized[index]
            band.bypass = bypass
        }
        eqNode.bypass = bypass
        // Advanced enhancement (bass/vocal/loudness/stereo/vintage) is composed upstream
        // in AppModel.effectiveEqualizerBandGains before gains reach this node.
    }

    func load(
        asset: AVURLAsset,
        fileURL: URL?,
        startSeconds: TimeInterval,
        gains: [Float],
        bypass: Bool,
    ) async throws {
        stopInternal(notifyFinished: false)
        reloadToken = UUID()
        let token = reloadToken
        playbackStartOffset = max(0, startSeconds)
        finishedNotified = false
        didScheduleAudio = false

        applyGains(gains, bypass: bypass)

        if let fileURL, fileURL.isFileURL {
            try await loadFile(url: fileURL, startSeconds: startSeconds, token: token)
        } else {
            try await loadStream(asset: asset, startSeconds: startSeconds, token: token)
        }

        guard token == reloadToken else { return }
        try startEngineIfNeeded()
    }

    func play(rate: Float) {
        guard isConfigured, didScheduleAudio else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        timePitchNode.rate = rate
        if !playerNode.isPlaying {
            playerNode.play()
        }
        startTimeObserver()
    }

    func pause() {
        playerNode.pause()
        stopTimeObserver()
    }

    func stop() {
        stopInternal(notifyFinished: false)
    }

    func seek(to seconds: TimeInterval, asset: AVURLAsset, fileURL: URL?, gains: [Float], bypass: Bool, autoPlay: Bool, rate: Float) async throws {
        let wasPlaying = playerNode.isPlaying
        try await load(
            asset: asset,
            fileURL: fileURL,
            startSeconds: seconds,
            gains: gains,
            bypass: bypass,
        )
        if autoPlay || wasPlaying {
            play(rate: rate)
        }
    }

    func currentPlaybackTime() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else {
            return playbackStartOffset
        }
        return playbackStartOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    // MARK: - Graph

    private func configureBands() {
        eqNode.globalGain = 0
        for (index, frequency) in EqualizerBand.frequencies.enumerated() where index < eqNode.bands.count {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
    }

    private func attachGraph(format: AVAudioFormat) throws {
        if isConfigured {
            engine.stop()
            engine.disconnectNodeInput(timePitchNode)
            engine.disconnectNodeInput(eqNode)
            engine.disconnectNodeInput(engine.mainMixerNode)
            engine.detach(playerNode)
            engine.detach(timePitchNode)
            engine.detach(eqNode)
            isConfigured = false
        }
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.attach(eqNode)
        engine.connect(playerNode, to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: eqNode, format: format)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        isConfigured = true
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: - File playback

    private func loadFile(url: URL, startSeconds: TimeInterval, token: UUID) async throws {
        let file = try AVAudioFile(forReading: url)
        try attachGraph(format: file.processingFormat)
        trackedDuration = Double(file.length) / file.processingFormat.sampleRate

        let startFrame = AVAudioFramePosition(startSeconds * file.processingFormat.sampleRate)
        let clampedStart = max(0, min(startFrame, file.length))
        let remaining = file.length - clampedStart
        guard remaining > 0 else { throw URLError(.cannotDecodeContentData) }

        didScheduleAudio = true
        playerNode.scheduleSegment(
            file,
            startingFrame: clampedStart,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack,
        ) { [weak self] _ in
            // .dataPlayedBack also fires when the node is STOPPED — every
            // seek/reload stops the node, so without the token guard the old
            // segment's completion lands after the new schedule and reports a
            // bogus "finished", skipping the song (seen on every EQ-path seek).
            Task { @MainActor in
                guard let self, self.reloadToken == token else { return }
                self.notifyFinishedIfNeeded()
            }
        }
    }

    // MARK: - Stream playback (AVAssetReader → PCM buffers)

    private func loadStream(asset: AVURLAsset, startSeconds: TimeInterval, token: UUID) async throws {
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        if durationSeconds.isFinite, durationSeconds > 0 {
            trackedDuration = durationSeconds
        }

        let playable = try await asset.load(.isPlayable)
        guard playable else { throw URLError(.cannotDecodeContentData) }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw URLError(.cannotDecodeContentData)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            streamPrepareContinuation = continuation
            streamTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.pumpStream(
                    asset: asset,
                    audioTrack: audioTrack,
                    startSeconds: startSeconds,
                    token: token,
                )
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard let self, self.streamPrepareContinuation != nil else { return }
                self.streamPrepareContinuation?.resume(throwing: URLError(.timedOut))
                self.streamPrepareContinuation = nil
                self.streamTask?.cancel()
            }
        }
    }

    private func pumpStream(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        startSeconds: TimeInterval,
        token: UUID,
    ) async {
        do {
            let reader = try AVAssetReader(asset: asset)
            if startSeconds > 0.05 {
                let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
                let assetDuration = try await asset.load(.duration)
                reader.timeRange = CMTimeRange(start: start, end: assetDuration)
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? URLError(.cannotDecodeContentData)
            }

            var scheduledFormat: AVAudioFormat?
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { break }
                defer { CMSampleBufferInvalidate(sample) }

                guard let pcm = Self.makePCMBuffer(from: sample) else { continue }
                let scheduleToken = token
                await MainActor.run {
                    guard scheduleToken == self.reloadToken else { return }
                    do {
                        if scheduledFormat == nil {
                            try self.attachGraph(format: pcm.format)
                            scheduledFormat = pcm.format
                        }
                        self.playerNode.scheduleBuffer(pcm, completionHandler: nil)
                        if !self.didScheduleAudio {
                            self.didScheduleAudio = true
                            self.streamPrepareContinuation?.resume()
                            self.streamPrepareContinuation = nil
                        }
                    } catch {
                        self.streamPrepareContinuation?.resume(throwing: error)
                        self.streamPrepareContinuation = nil
                    }
                }
            }

            if reader.status == .failed {
                throw reader.error ?? URLError(.cannotDecodeContentData)
            }

            await MainActor.run {
                guard token == self.reloadToken else { return }
                guard self.didScheduleAudio, let format = scheduledFormat ?? self.connectedFormat else {
                    if let continuation = self.streamPrepareContinuation {
                        continuation.resume(throwing: URLError(.cannotDecodeContentData))
                        self.streamPrepareContinuation = nil
                    }
                    return
                }
                self.playerNode.scheduleBuffer(
                    Self.silentBuffer(format: format),
                    completionCallbackType: .dataPlayedBack,
                ) { [weak self] _ in
                    // Same stop-fires-completion trap as the file path — only
                    // the schedule that is still current may report "finished".
                    Task { @MainActor in
                        guard let self, self.reloadToken == token else { return }
                        self.notifyFinishedIfNeeded()
                    }
                }
            }
        } catch {
            await MainActor.run {
                guard token == self.reloadToken else { return }
                if let continuation = self.streamPrepareContinuation {
                    continuation.resume(throwing: error)
                    self.streamPrepareContinuation = nil
                } else {
                    self.notifyPlaybackFailed()
                }
            }
        }
    }

    // MARK: - Time + teardown

    private func startTimeObserver() {
        stopTimeObserver()
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onTimeUpdate?(self.currentPlaybackTime())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeObserver = timer
    }

    private func stopTimeObserver() {
        timeObserver?.invalidate()
        timeObserver = nil
    }

    private func notifyFinishedIfNeeded() {
        guard didScheduleAudio, !finishedNotified else { return }
        finishedNotified = true
        onFinished?()
    }

    private func notifyPlaybackFailed() {
        guard !finishedNotified else { return }
        finishedNotified = true
        onPlaybackFailed?()
    }

    private func stopInternal(notifyFinished: Bool) {
        reloadToken = UUID()
        streamTask?.cancel()
        streamTask = nil
        if let continuation = streamPrepareContinuation {
            continuation.resume(throwing: CancellationError())
            streamPrepareContinuation = nil
        }
        stopTimeObserver()
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        if isConfigured {
            engine.detach(playerNode)
            engine.detach(timePitchNode)
            engine.detach(eqNode)
            isConfigured = false
            connectedFormat = nil
        }
        didScheduleAudio = false
        if notifyFinished {
            notifyFinishedIfNeeded()
        }
    }

    // MARK: - PCM helpers

    private static func silentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        return buffer
    }

    private static func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        let sourceFormat = AVAudioFormat(streamDescription: asbdPtr)
        guard let sourceFormat else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return nil }
        sourceBuffer.frameLength = frameCount

        let audioBufferList = sourceBuffer.mutableAudioBufferList
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frameCount),
            into: audioBufferList,
        ) == noErr else { return nil }

        return sourceBuffer
    }
}
