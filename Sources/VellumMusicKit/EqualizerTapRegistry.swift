import AVFoundation
import Foundation

/// Knows every live tap, and turns their render-thread counters into the two log streams.
///
/// The render thread writes plain numbers into its own `TapRenderState` and touches nothing else.
/// This object runs on a normal-priority timer, reads those numbers, and does the allocating,
/// locking and file writing that the render thread is forbidden to do. That split is the whole
/// reason the process callback can stay real-time safe while still being observable.
///
/// It also answers the question the brief puts first — *is the equalizer actually in the audio I am
/// hearing right now* — which needs three facts at once: which item is playing, whether that item's
/// tap is prepared, and whether it is still being handed audio.
final class EqualizerTapRegistry {
    static let shared = EqualizerTapRegistry()

    private let lock = NSLock()
    /// Strongly held: the tap must outlive the item's audio mix, and nothing else owns it.
    private var taps: [UInt64: EqualizerAudioTap] = [:]
    /// Item tag the transport says is currently playing, or 0.
    private var currentItemTag: UInt64 = 0
    private var currentTrackTitle = ""

    /// How much of each ring has already been written to the log.
    private var drainedCount: [UInt64: UInt64] = [:]
    /// Same, for process-callback entries, which advance even when the ring does not.
    private var drainedEntryCount: [UInt64: UInt64] = [:]

    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "vellum.tap.drain", qos: .utility)

    /// Every half second. Frequent enough that a 50 ms-scale artifact still lands in a bucket a
    /// reader can line up against the transport events, cheap enough to leave running.
    private static let drainInterval: DispatchTimeInterval = .milliseconds(500)

    private init() {
        // Runs once, the first time anything touches the registry. Both of these have to happen
        // somewhere central: `PlaybackEngine` has no initialiser of its own to hang them off.
        PlaybackTapLog.launchMarker("tap-playback branch (t073) build=\(Self.buildStamp)")
        PlaybackCPUSampler.callbackCountProvider = { EqualizerTapRegistry.shared.totalProcessCallbacks() }
    }

    /// Binary modification date. The log is append-only across installs, so a reader needs to know
    /// which build produced the lines after a given launch marker.
    private static var buildStamp: String {
        guard let path = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modified = attributes[.modificationDate] as? Date
        else { return "unknown" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: modified)
    }

    // MARK: Registration

    func adopt(_ tap: EqualizerAudioTap) {
        lock.lock()
        taps[tap.itemTag] = tap
        lock.unlock()
        startTimerIfNeeded()
    }

    /// Called from `prepare`. The tap may already be adopted; this is idempotent.
    func register(_ tap: EqualizerAudioTap) {
        adopt(tap)
    }

    /// Most recently created tap for a track id. Used at a gapless boundary, where the item the OS
    /// advanced onto was staged earlier and its tap already exists.
    func itemTag(forTrackId trackId: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return taps.values.filter { $0.trackId == trackId }.map(\.itemTag).max()
    }

    func tap(forItemTag tag: UInt64) -> EqualizerAudioTap? {
        lock.lock()
        defer { lock.unlock() }
        return taps[tag]
    }

    /// Drops a tap once its item is finished with. Emits a final summary first, so the last
    /// process records are never lost to the timer's cadence.
    func retire(itemTag: UInt64) {
        lock.lock()
        let tap = taps.removeValue(forKey: itemTag)
        drainedCount.removeValue(forKey: itemTag)
        let remaining = taps.count
        lock.unlock()
        if let tap {
            drain(tap)
            PlaybackTapLog.tap("retire item=\(itemTag) track=\(tap.trackId) liveTaps=\(remaining)")
        }
        if remaining == 0 { stopTimer() }
    }

    // MARK: Current item

    /// Told by the transport which item is actually on the speaker. Everything the EQ stream says
    /// about "right now" keys off this.
    func setCurrentItem(tag: UInt64, title: String) {
        lock.lock()
        currentItemTag = tag
        currentTrackTitle = title
        lock.unlock()
        PlaybackTapLog.eq("current-item item=\(tag) title=\"\(title)\"")
        emitCurrentActivity(reason: "item-change")
    }

    // MARK: Draining

    private func startTimerIfNeeded() {
        timerQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.timerQueue)
            source.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            self.timer = source
        }
    }

    private func stopTimer() {
        timerQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func tick() {
        lock.lock()
        let live = Array(taps.values)
        lock.unlock()
        for tap in live { drain(tap) }
        emitCurrentActivity(reason: "tick")
    }

    /// Writes out whatever the render thread has recorded since the last drain.
    ///
    /// Only the boundaries are logged — first and last process per tap, with frame counts and
    /// timestamps — which is what the brief asks for and keeps the log readable. The ring holds the
    /// individual records, and `lost` reports any that were overwritten before this ran, so a
    /// reader can tell a quiet tap from a starved drain.
    func drain(_ tap: EqualizerAudioTap) {
        let state = tap.state
        let written = state.pointee.ringWriteCount
        let entries = state.pointee.processEntryCount
        lock.lock()
        let alreadyDrained = drainedCount[tap.itemTag] ?? 0
        let alreadyDrainedEntries = drainedEntryCount[tap.itemTag] ?? 0
        drainedCount[tap.itemTag] = written
        drainedEntryCount[tap.itemTag] = entries
        lock.unlock()

        // Entries as well as ring records. A tap whose `GetSourceAudio` fails every time writes
        // nothing to the ring, so keying the log purely on ring growth would stay completely
        // silent in exactly the failure that most needs reporting.
        guard written > alreadyDrained || entries > alreadyDrainedEntries else { return }

        let capacity = UInt64(max(1, state.pointee.ringCapacity))
        let newRecords = written - alreadyDrained
        let lost = newRecords > capacity ? newRecords - capacity : 0

        let first = state.pointee.firstProcessHostTime
        let last = state.pointee.lastProcessHostTime
        PlaybackTapLog.tap(
            "process item=\(tap.itemTag) track=\(tap.trackId) "
                + "count=\(state.pointee.processCount) entries=\(state.pointee.processEntryCount) "
                + "lastSourceStatus=\(state.pointee.lastSourceAudioStatus) "
                + "new=\(newRecords) lostFromRing=\(lost) "
                + "firstFrames=\(state.pointee.firstProcessFrames) lastFrames=\(state.pointee.lastProcessFrames) "
                + "firstHost=\(first) lastHost=\(last) "
                + "spanMs=\(String(format: "%.1f", Self.millis(from: first, to: last))) "
                + "startOfStream=\(state.pointee.startOfStreamCount)"
        )
    }

    /// The EQ-activity stream. One line describing the audio being produced *now*.
    private func emitCurrentActivity(reason: String) {
        lock.lock()
        let tag = currentItemTag
        let title = currentTrackTitle
        let tap = taps[tag]
        let liveCount = taps.count
        lock.unlock()

        guard tag != 0 else { return }
        guard let tap else {
            // The distinction that matters: an item is playing and has no tap at all. On the old
            // dual-player branch this was true for the first part of every streamed song.
            PlaybackTapLog.eq(
                "active item=\(tag) title=\"\(title)\" attached=false prepared=false "
                    + "processing=false audibleCurve=false reason=\(reason) liveTaps=\(liveCount)"
            )
            return
        }

        let state = tap.state
        let prepared = state.pointee.sampleRate > 0 && state.pointee.unprepared == 0
        // "Processing" means audio moved through the tap recently, not merely that it exists.
        let sinceLast = Self.millis(from: state.pointee.lastProcessHostTime, to: mach_absolute_time())
        let processing = state.pointee.processCount > 0 && sinceLast < 1_000

        PlaybackTapLog.eq(
            "active item=\(tag) title=\"\(title)\" attached=true prepared=\(prepared) "
                + "processing=\(processing) audibleCurve=\(tap.hasAudibleCurve) "
                + "sampleRate=\(state.pointee.sampleRate) channels=\(state.pointee.channels) "
                + "processCount=\(state.pointee.processCount) msSinceLastProcess=\(String(format: "%.0f", sinceLast)) "
                + "reason=\(reason) liveTaps=\(liveCount)"
        )
    }

    /// Pushes new gains to every live tap. Both the playing item and any gapless next one, so a
    /// change made now is already in place when the next track starts.
    func updateAllTaps(gains: [Float], bypassed: Bool) {
        lock.lock()
        let live = Array(taps.values)
        lock.unlock()
        for tap in live { tap.updateSettings(gains: gains, bypassed: bypassed) }
        PlaybackTapLog.eq(
            "settings-changed taps=\(live.count) bypassed=\(bypassed) "
                + "gains=[\(gains.map { String(format: "%.1f", $0) }.joined(separator: ","))]"
        )
    }

    /// Total process callbacks across every live tap. This is the wakeup rate the CPU sampler
    /// reports — how often the render thread was handed a buffer.
    func totalProcessCallbacks() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return taps.values.reduce(0) { $0 &+ $1.state.pointee.processCount }
    }

    // MARK: Time

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func millis(from: UInt64, to: UInt64) -> Double {
        guard to > from, from != 0 else { return 0 }
        let elapsed = Double(to - from) * Double(timebase.numer) / Double(timebase.denom)
        return elapsed / 1_000_000
    }
}
