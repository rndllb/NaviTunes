import AVFoundation
import Foundation
import MediaToolbox

// MARK: - Render-thread state
//
// Everything the process callback touches lives in plain C memory reached through a raw pointer.
// Nothing here is a Swift class or array, so the render thread never triggers ARC, never takes an
// exclusivity check, and never allocates. That constraint is the reason this file looks like C.

/// Direct-form-I biquad coefficients for one band, normalised by a0.
struct TapBiquadCoefficients {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    /// Passes audio through untouched. **This is how the EQ is bypassed** — by making every band
    /// an identity filter, never by detaching the tap. Detaching mid-playback is what produced an
    /// audible stutter in the client we studied, and is the same failure class as the bug this
    /// branch replaces.
    static let identity = TapBiquadCoefficients()
}

/// Per-channel, per-band delay line.
struct TapBiquadState {
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0
}

/// One fixed-size record of a process call, written from the render thread into a preallocated
/// ring. No strings, no references — 40 bytes of POD.
struct TapProcessRecord {
    var sequence: UInt64 = 0
    var hostTime: UInt64 = 0
    var frames: Int32 = 0
    var flags: UInt32 = 0
}

/// Everything the render thread reads or writes for one tap.
///
/// Allocated once per tap and handed to `MTAudioProcessingTap` as its `clientInfo`. One tap owns
/// exactly one of these, so there is a **single writer** on the render side and the summary
/// counters and ring need no atomics: the only other reader is the drain timer, which reads
/// word-sized POD fields for diagnostics.
///
/// Two taps can legitimately be live at once (the current item and the gapless next one), which is
/// precisely why filter state is per-tap and never shared.
struct TapRenderState {
    /// Identity, echoed into every log record. Without it "late prepare", "mix silently ignored"
    /// and "overlapping process" are indistinguishable in the log.
    var itemTag: UInt64 = 0

    var sampleRate: Double = 0
    var channels: Int32 = 0
    var maxFrames: Int32 = 0
    var bandCount: Int32 = 0

    /// Which of the two coefficient sets the render thread should read: 0 or 1.
    ///
    /// The lock-free publish. A gain change computes a complete new set into the *inactive* slot
    /// and then stores this index. The render thread reads the index once per process call and
    /// uses that slot throughout, so it always sees a coherent set — never half of an old one and
    /// half of a new one. A 32-bit aligned store is atomic on every platform this ships to, and no
    /// lock is taken on either side.
    var activeCoefficientSet: Int32 = 0

    /// `2 * bandCount` coefficient structs: set 0 then set 1.
    var coefficients: UnsafeMutablePointer<TapBiquadCoefficients>?
    /// `channels * bandCount` filter states, channel-major.
    var filterState: UnsafeMutablePointer<TapBiquadState>?

    // Summary counters, written only by the render thread, read only by the drain timer.
    var prepareCount: Int32 = 0
    /// Incremented on **entry** to the process callback, before anything can fail.
    ///
    /// Separate from `processCount`, which counts calls that successfully pulled audio. Without
    /// both, "the render thread never called us" and "it called us and the pull failed every time"
    /// produce an identical log — a zero — and they have completely different causes.
    var processEntryCount: UInt64 = 0
    /// `OSStatus` from the most recent `MTAudioProcessingTapGetSourceAudio`.
    var lastSourceAudioStatus: Int32 = 0
    var processCount: UInt64 = 0
    var firstProcessHostTime: UInt64 = 0
    var lastProcessHostTime: UInt64 = 0
    var firstProcessFrames: Int32 = 0
    var lastProcessFrames: Int32 = 0
    var startOfStreamCount: Int32 = 0
    /// Set when the tap has been asked to stop; the drain timer uses it to emit a final summary.
    var unprepared: Int32 = 0

    // Preallocated ring of process records.
    var ring: UnsafeMutablePointer<TapProcessRecord>?
    var ringCapacity: Int32 = 0
    /// Monotonic; the reader derives how many were lost from the gap to what it last drained.
    var ringWriteCount: UInt64 = 0
}

// MARK: - Coefficient maths (never runs on the render thread)

enum TapBiquad {
    /// RBJ cookbook peaking EQ.
    ///
    /// **Computed from the sample rate handed to `prepare`, never once at init.** `prepare` can
    /// fire more than once for the same item if the audio machinery is torn down and rebuilt — a
    /// route change, say — and it can come back at a *different* sample rate. Coefficients baked
    /// at init silently detune the whole EQ on an AirPods disconnect, with no other symptom.
    static func peaking(frequency: Double, gainDB: Float, q: Double, sampleRate: Double) -> TapBiquadCoefficients {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2 else {
            return .identity
        }
        if abs(gainDB) < 0.01 { return .identity }

        let a = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosOmega
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha / a

        guard a0 != 0 else { return .identity }
        return TapBiquadCoefficients(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0),
        )
    }
}

// MARK: - The tap

/// An `MTAudioProcessingTap` that applies the app equalizer to one `AVPlayerItem`.
///
/// The shape of this is dictated by two documented facts and one measured one:
///
/// - `process` is only ever called after `prepare` returns and before `unprepare`, so the tap can
///   never be handed audio it was not prepared for. That is what makes it safe for the render
///   thread to assume the coefficient and state buffers exist.
/// - `prepare` may fire more than once, at a new sample rate. Coefficients are therefore built
///   there, from the format it supplies.
/// - A tap is attached to **every** item, always, and bypass is expressed as identity
///   coefficients. Attaching or detaching mid-playback is audible.
///
/// Taps do not work with HLS. Vellum is progressive-only, but internet radio must stay excluded
/// from EQ eligibility for that reason — see `PlaybackEngine.isEqualizerEligible(for:)`.
final class EqualizerAudioTap {
    /// Stable per-item identity used in every log line.
    let itemTag: UInt64
    let trackId: String
    let trackTitle: String

    /// The render-thread state. Owned here, freed in `dispose()`.
    private(set) var state: UnsafeMutablePointer<TapRenderState>
    private let bandCount: Int
    private let maxChannels = 8

    /// Snapshot of the settings this tap should apply, read off the render thread only.
    /// One gain per `EqualizerBand.frequencies`, in dB.
    private var gains: [Float]
    private var bypassed: Bool

    /// The band spacing here is one octave (32, 63, 125, …), and Q ≈ 1.414 is the standard
    /// one-octave bandwidth. Keeping it constant means a gain change only recomputes coefficients,
    /// never re-plans the filter bank.
    private static let bandQ = 1.414

    private static var nextTag: UInt64 = 0
    private static let tagLock = NSLock()

    private static func makeTag() -> UInt64 {
        tagLock.lock()
        defer { tagLock.unlock() }
        nextTag += 1
        return nextTag
    }

    init(trackId: String, trackTitle: String, gains: [Float], bypassed: Bool) {
        self.itemTag = Self.makeTag()
        self.trackId = trackId
        self.trackTitle = trackTitle
        self.gains = EqualizerPreset.normalizedGains(gains)
        self.bypassed = bypassed
        self.bandCount = EqualizerBand.count

        state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
        state.initialize(to: TapRenderState())
        state.pointee.itemTag = itemTag
        state.pointee.bandCount = Int32(bandCount)

        // Two coefficient sets so a gain change can be published without a lock.
        let coefficients = UnsafeMutablePointer<TapBiquadCoefficients>.allocate(capacity: max(1, bandCount * 2))
        coefficients.initialize(repeating: .identity, count: max(1, bandCount * 2))
        state.pointee.coefficients = coefficients

        let filterState = UnsafeMutablePointer<TapBiquadState>.allocate(capacity: max(1, bandCount * maxChannels))
        filterState.initialize(repeating: TapBiquadState(), count: max(1, bandCount * maxChannels))
        state.pointee.filterState = filterState

        let ring = UnsafeMutablePointer<TapProcessRecord>.allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: TapProcessRecord(), count: Self.ringCapacity)
        state.pointee.ring = ring
        state.pointee.ringCapacity = Int32(Self.ringCapacity)
    }

    static let ringCapacity = 512

    // No `deinit { dispose() }`.
    //
    // That is what produced this, on device:
    //
    //     TAP retire item=1 … / TAP retire item=2 …
    //     TAP prepare ORPHAN item=15785850001729508719
    //
    // Retiring a tap dropped the last Swift reference, `deinit` freed the render state, and 120 ms
    // later AVFoundation called `prepare` on a tap whose storage no longer existed — the garbage
    // item tag is a read of freed memory. A use-after-free on the audio path.
    //
    // The lifetime is not ours to decide. Once the storage has been handed to an
    // `MTAudioProcessingTap`, only the framework knows when the last callback has been made, and it
    // says so by calling `finalize`. So the storage is freed **there** and nowhere else, and this
    // object dying simply stops us tracking the tap — it does not free anything the framework may
    // still touch.

    /// Frees the render state. **Only** legitimate from the tap's `finalize` callback, or from
    /// `makeAudioMix` when no tap was ever created and nothing else can reference it.
    fileprivate func releaseRenderState() {
        guard !renderStateReleased else { return }
        renderStateReleased = true
        state.pointee.coefficients?.deallocate()
        state.pointee.filterState?.deallocate()
        state.pointee.ring?.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    private var renderStateReleased = false

    /// Frees the render state when creation failed and **no tap ever took ownership**, so nothing
    /// else can reference it. Refuses once the state has been handed to a tap, because from that
    /// moment only `finalize` may free it.
    func disposeBeforeAttachment() {
        guard !attachedToTap else { return }
        releaseRenderState()
    }

    /// True once an `MTAudioProcessingTap` owns the render state.
    fileprivate var attachedToTap = false

    // MARK: Coefficients

    /// Recomputes into the inactive slot and publishes it with one store. Safe to call while audio
    /// is running; the render thread will pick the new set up on its next process call.
    func updateSettings(gains: [Float], bypassed: Bool) {
        self.gains = EqualizerPreset.normalizedGains(gains)
        self.bypassed = bypassed
        publishCoefficients()
    }

    /// Recomputes from the sample rate the tap is currently prepared at. A no-op before the first
    /// `prepare`, because there is no format to compute against yet.
    private func publishCoefficients() {
        let sampleRate = state.pointee.sampleRate
        guard sampleRate > 0, let coefficients = state.pointee.coefficients, bandCount > 0 else { return }

        let inactive = state.pointee.activeCoefficientSet == 0 ? 1 : 0
        let base = inactive * bandCount
        for index in 0 ..< bandCount {
            coefficients[base + index] = bypassed
                ? .identity
                : TapBiquad.peaking(
                    frequency: Double(EqualizerBand.frequencies[index]),
                    gainDB: gains[index],
                    q: Self.bandQ,
                    sampleRate: sampleRate,
                )
        }
        // The publish. Everything above wrote to the slot the render thread is not reading.
        state.pointee.activeCoefficientSet = Int32(inactive)
    }

    /// True when at least one band is doing something. This is the "are the coefficients non-zero"
    /// half of the EQ-activity question the brief asks for.
    var hasAudibleCurve: Bool {
        guard !bypassed else { return false }
        return gains.contains { abs($0) >= 0.01 }
    }

    // MARK: Audio mix

    /// Builds an `AVAudioMix` carrying this tap, for `item.audioMix`.
    ///
    /// The asset's tracks must already be loaded: the input parameters need a real track id, and a
    /// mix built against a track that has not loaded is silently ignored — the item plays with no
    /// tap and nothing reports an error. That is why the caller awaits `loadTracks` first, and why
    /// the mix is attached **before** the item is inserted into the queue player.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess,
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap,
        )
        guard status == noErr, let tap else {
            PlaybackTapLog.tap("create FAILED item=\(itemTag) track=\(trackId) status=\(status)")
            return nil
        }

        // From here the tap owns the render state; only `finalize` may free it.
        attachedToTap = true

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        PlaybackTapLog.tap(
            "mix-attached item=\(itemTag) track=\(trackId) title=\"\(trackTitle)\" "
                + "trackID=\(track.trackID) bypassed=\(bypassed) audibleCurve=\(hasAudibleCurve)"
        )
        return mix
    }

    // MARK: Called from the tap callbacks (not the render thread)

    fileprivate func didPrepare(sampleRate: Double, channels: Int, maxFrames: Int) {
        state.pointee.sampleRate = sampleRate
        state.pointee.channels = Int32(min(channels, maxChannels))
        state.pointee.maxFrames = Int32(maxFrames)
        state.pointee.prepareCount += 1
        state.pointee.unprepared = 0

        // Reset the delay lines: this is a new stream, or the same one at a new format. Carrying
        // state across would ring.
        if let filterState = state.pointee.filterState {
            for index in 0 ..< (bandCount * maxChannels) {
                filterState[index] = TapBiquadState()
            }
        }
        // Coefficients must be built here, from this format.
        publishCoefficients()

        PlaybackTapLog.tap(
            "prepare item=\(itemTag) track=\(trackId) title=\"\(trackTitle)\" "
                + "sampleRate=\(sampleRate) channels=\(channels) maxFrames=\(maxFrames) "
                + "prepareCount=\(state.pointee.prepareCount) bypassed=\(bypassed) "
                + "audibleCurve=\(hasAudibleCurve)"
        )
        EqualizerTapRegistry.shared.register(self)
    }

    fileprivate func didUnprepare() {
        state.pointee.unprepared = 1
        PlaybackTapLog.tap(
            "unprepare item=\(itemTag) track=\(trackId) processCount=\(state.pointee.processCount) "
                + "lastFrames=\(state.pointee.lastProcessFrames)"
        )
        EqualizerTapRegistry.shared.drain(self)
    }
}

// MARK: - Tap callbacks

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    // The tap's storage is the raw render state, never the Swift object: the render thread must
    // not touch anything ARC-managed.
    guard let clientInfo else { return }
    let object = Unmanaged<EqualizerAudioTap>.fromOpaque(clientInfo).takeUnretainedValue()
    tapStorageOut.pointee = UnsafeMutableRawPointer(object.state)
}

/// The only place the render state is freed.
///
/// AVFoundation calls this when it is finished with the tap and no further callback can occur, so
/// it is the one moment freeing the storage is safe. Freeing it earlier — when the Swift wrapper
/// was released — is what produced a `prepare` on freed memory 120 ms after retirement.
///
/// Frees straight from the raw storage rather than going back through the Swift object, because by
/// now that object may be long gone. It is not needed: the storage owns everything it points to.
private func tapFinalize(tap: MTAudioProcessingTap) {
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    let state = storage.assumingMemoryBound(to: TapRenderState.self)
    let itemTag = state.pointee.itemTag

    // Tell the registry to let go **before** the storage is freed.
    //
    // The registry holds this tap strongly and reads `state.pointee` twice a second from its drain
    // timer, and once more whenever the CPU sampler asks for a callback total. Freeing here while
    // leaving the tap in that dictionary left both of those reading deallocated memory — the same
    // use-after-free the comment on `EqualizerAudioTap` describes for `prepare`, on the other side
    // of the object's life. What came back was garbage counters, and the arithmetic the registry
    // does on them trapped: `EXC_BREAKPOINT` in `EqualizerTapRegistry.drain(_:)` (T264).
    //
    // `forget` removes without draining, because a drain is exactly the read that must not happen.
    EqualizerTapRegistry.shared.forget(itemTag: itemTag)

    state.pointee.coefficients?.deallocate()
    state.pointee.filterState?.deallocate()
    state.pointee.ring?.deallocate()
    state.deinitialize(count: 1)
    state.deallocate()
    PlaybackTapLog.tap("finalize item=\(itemTag) renderState=freed")
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    let state = storage.assumingMemoryBound(to: TapRenderState.self)
    let format = processingFormat.pointee
    guard let object = EqualizerTapRegistry.shared.tap(forItemTag: state.pointee.itemTag) else {
        // No owner: record the format anyway so the log still shows the prepare happened.
        state.pointee.sampleRate = format.mSampleRate
        state.pointee.channels = Int32(format.mChannelsPerFrame)
        state.pointee.maxFrames = Int32(maxFrames)
        PlaybackTapLog.tap("prepare ORPHAN item=\(state.pointee.itemTag) sampleRate=\(format.mSampleRate)")
        return
    }
    object.didPrepare(
        sampleRate: format.mSampleRate,
        channels: Int(format.mChannelsPerFrame),
        maxFrames: Int(maxFrames),
    )
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    let state = storage.assumingMemoryBound(to: TapRenderState.self)
    guard let object = EqualizerTapRegistry.shared.tap(forItemTag: state.pointee.itemTag) else { return }
    object.didUnprepare()
}

/// **The render thread.** No allocation, no locks, no logging, no Swift objects.
///
/// Records are written into the preallocated ring; a normal-priority timer drains it. Logging from
/// here would allocate and lock, which is exactly what is forbidden on this thread — and would
/// itself produce the artifacts this branch exists to measure.
private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    // Storage first, so entry can be recorded before anything is allowed to fail.
    guard let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? else { return }
    let state = storage.assumingMemoryBound(to: TapRenderState.self)
    state.pointee.processEntryCount &+= 1

    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        nil,
        numberFramesOut,
    )
    state.pointee.lastSourceAudioStatus = Int32(status)
    guard status == noErr else { return }

    let bandCount = Int(state.pointee.bandCount)
    guard bandCount > 0,
          let coefficients = state.pointee.coefficients,
          let filterState = state.pointee.filterState
    else { return }

    // Read the published set index once, and use it for the whole call.
    let setBase = Int(state.pointee.activeCoefficientSet) * bandCount

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let frames = Int(numberFramesOut.pointee)

    for (bufferIndex, buffer) in buffers.enumerated() {
        guard bufferIndex < Int(state.pointee.channels),
              let raw = buffer.mData
        else { continue }
        let samples = raw.assumingMemoryBound(to: Float.self)
        let channelBase = bufferIndex * bandCount

        for band in 0 ..< bandCount {
            let c = coefficients[setBase + band]
            // Identity band: skip the arithmetic entirely. This is the bypass path and the common
            // case for a flat EQ, so it must be cheap.
            if c.b0 == 1, c.b1 == 0, c.b2 == 0, c.a1 == 0, c.a2 == 0 { continue }
            var s = filterState[channelBase + band]
            for frame in 0 ..< frames {
                let x = samples[frame]
                let y = c.b0 * x + c.b1 * s.x1 + c.b2 * s.x2 - c.a1 * s.y1 - c.a2 * s.y2
                s.x2 = s.x1
                s.x1 = x
                s.y2 = s.y1
                s.y1 = y
                samples[frame] = y
            }
            filterState[channelBase + band] = s
        }
    }

    // Summary counters + ring record. Plain stores into memory this tap alone writes.
    let hostTime = mach_absolute_time()
    if state.pointee.processCount == 0 {
        state.pointee.firstProcessHostTime = hostTime
        state.pointee.firstProcessFrames = Int32(frames)
    }
    state.pointee.processCount &+= 1
    state.pointee.lastProcessHostTime = hostTime
    state.pointee.lastProcessFrames = Int32(frames)
    // `MTAudioProcessingTapFlags` is a plain `UInt32`, not an OptionSet — a bitwise test, not
    // `contains`. StartOfStream is the documented hook for a discontinuity, which is exactly what
    // a gapless boundary is, so it is counted rather than ignored.
    if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
        state.pointee.startOfStreamCount &+= 1
    }

    if let ring = state.pointee.ring, state.pointee.ringCapacity > 0 {
        let index = Int(state.pointee.ringWriteCount % UInt64(state.pointee.ringCapacity))
        ring[index] = TapProcessRecord(
            sequence: state.pointee.processCount,
            hostTime: hostTime,
            frames: Int32(frames),
            flags: UInt32(flags),
        )
        state.pointee.ringWriteCount &+= 1
    }
}
