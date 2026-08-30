import Foundation

/// Samples the process's own CPU consumption during playback, so the tap branch and dev can be
/// compared on cost rather than on impression.
///
/// **Deliberately standalone and dependency-free.** The whole point is an A/B, and an A/B is only
/// valid if both sides are measured by the same instrument — so this file is written to be dropped
/// into a dev build unchanged, with no reference to the tap, the registry, or anything else that
/// exists only on this branch. Its only collaborator is `PlaybackTapLog`.
///
/// The derived metric is **CPU seconds per minute of audio**, which is what makes two runs
/// comparable even if they are not the same length. Raw CPU seconds are not: a longer song burns
/// more of them for the same efficiency.
///
/// Raw compute only, on purpose. No battery percentage, no energy proxy, no estimated watts —
/// those would be a guess layered on top of a measurement, and the measurement is the thing worth
/// having. What is logged is CPU time, tap callback count, elapsed audio, and thermal state.
///
/// **This number is only meaningful on a device.** In the simulator the audio path, the codecs and
/// the scheduler are all the host Mac's, so the value measures a laptop, not a phone. Treat a
/// simulator reading purely as evidence that the plumbing emits sane records.
enum PlaybackCPUSampler {
    /// How often a sample is taken and logged. Long enough that the sampler is not itself a cost,
    /// short enough to catch a thermal change part-way through an album.
    private static let interval: TimeInterval = 10

    private static let queue = DispatchQueue(label: "vellum.cpu.sampler", qos: .utility)
    private static var timer: DispatchSourceTimer?

    /// Wall-clock seconds of audio actually played since the sampler started, accumulated across
    /// pauses so a paused stretch does not inflate the per-minute figure.
    private static var audioSecondsAccumulated: TimeInterval = 0
    private static var runningSince: CFAbsoluteTime?
    private static var lastCPUSeconds: Double = 0
    private static var lastSampleAt: CFAbsoluteTime = 0
    private static var lastCallbackCount: UInt64 = 0

    /// Supplies the total tap process-callback count. Set by the tap branch; left nil on dev, where
    /// there are no callbacks to count and the field is logged as `-1`.
    nonisolated(unsafe) static var callbackCountProvider: (() -> UInt64)?
    /// Supplies the item identity and title for the record. Set by the transport.
    nonisolated(unsafe) static var currentItemProvider: (() -> (tag: UInt64, title: String))?

    /// Call when audio starts flowing.
    static func playbackDidStart() {
        queue.async {
            guard runningSince == nil else { return }
            runningSince = CFAbsoluteTimeGetCurrent()
            if timer == nil {
                lastCPUSeconds = cpuSeconds()
                lastSampleAt = CFAbsoluteTimeGetCurrent()
                lastCallbackCount = callbackCountProvider?() ?? 0
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + interval, repeating: interval)
                source.setEventHandler { sample(reason: "tick") }
                source.resume()
                timer = source
            }
        }
    }

    /// Call when audio stops. Keeps the accumulated audio seconds so a later resume continues the
    /// same measurement rather than restarting it.
    static func playbackDidStop() {
        queue.async {
            if let since = runningSince {
                audioSecondsAccumulated += CFAbsoluteTimeGetCurrent() - since
                runningSince = nil
            }
            sample(reason: "stop")
        }
    }

    /// Ends the measurement and emits a final record.
    static func reset() {
        queue.async {
            sample(reason: "reset")
            timer?.cancel()
            timer = nil
            runningSince = nil
            audioSecondsAccumulated = 0
            lastCPUSeconds = cpuSeconds()
            lastCallbackCount = callbackCountProvider?() ?? 0
        }
    }

    private static func sample(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let cpu = cpuSeconds()
        let deltaCPU = max(0, cpu - lastCPUSeconds)
        let wallDelta = max(0.0001, now - lastSampleAt)

        var audioSeconds = audioSecondsAccumulated
        if let since = runningSince { audioSeconds += now - since }

        let callbacks = callbackCountProvider?()
        let callbackDelta: Int64 = callbacks.map { Int64($0) - Int64(lastCallbackCount) } ?? -1

        let item = currentItemProvider?() ?? (tag: 0, title: "")
        // CPU seconds per minute of audio. The headline number, and the only one comparable
        // between two runs of different lengths.
        let perMinute = audioSeconds > 0 ? cpu / (audioSeconds / 60) : 0

        PlaybackTapLog.eq(
            "cpu item=\(item.tag) title=\"\(item.title)\" reason=\(reason) "
                + "cpuSecondsTotal=\(String(format: "%.3f", cpu)) "
                + "cpuSecondsDelta=\(String(format: "%.3f", deltaCPU)) "
                + "audioSeconds=\(String(format: "%.1f", audioSeconds)) "
                + "cpuPerMinAudio=\(String(format: "%.3f", perMinute)) "
                + "tapCallbacks=\(callbacks.map(String.init) ?? "n/a") "
                + "tapCallbacksDelta=\(callbackDelta) "
                + "callbacksPerSec=\(callbackDelta >= 0 ? String(format: "%.1f", Double(callbackDelta) / wallDelta) : "n/a") "
                + "thermalState=\(thermalName)"
        )

        lastCPUSeconds = cpu
        lastSampleAt = now
        if let callbacks { lastCallbackCount = callbacks }
    }

    /// User + system CPU time consumed by this process, in seconds.
    private static func cpuSeconds() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
