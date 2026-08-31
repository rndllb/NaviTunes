import Foundation

/// Device-retrievable diagnostics for the tap playback path.
///
/// **DEBUG only, by Ethan's decision on 2026-08-30.** This was originally written *un*-gated, and
/// the argument for that is still on the record: the playback bug it exists to diagnose reproduces
/// in Release, and a diagnostic that switches itself off in the configuration being diagnosed is
/// not a diagnostic. He was shown that tradeoff and chose the gate anyway — a Release build of his
/// daily install should not be writing a log file from ~20 playback call sites. So the
/// file-writing code below is compiled out of Release entirely.
///
/// **The consequence is real and deliberate: this log can no longer observe a Release-only
/// playback bug.** If that need returns, the answer is a runtime switch that is off by default,
/// not the removal of this gate. See the OPTIMIZATIONS.md entry for this change.
///
/// The call sites do not change shape: the `#else` branch below is API-compatible and does
/// nothing, so no `#if DEBUG` is smeared across the ~20 places that log.
///
/// Both streams go into **one file**, distinguished by prefix:
///
/// - `EQ ` — is the equalizer in the audio being heard right now.
/// - `TAP` — tap lifecycle: prepare, unprepare, first/last process.
///
/// One file rather than two on purpose. Almost every question here is about *ordering* between the
/// streams — "was the next item's tap prepared before the current item finished" cannot be answered
/// from two files whose clocks have to be reconciled afterwards.
///
/// Retrieve with:
///
///     xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
///         --domain-identifier com.randll.vellum --source Documents/vellum-tap.log --destination .
///
/// The file is append-only across installs, so start reading at the last `===== LAUNCH` marker.
enum PlaybackTapLog {
#if DEBUG
    static let fileName = "vellum-tap.log"

    /// Serial, off the caller's thread. Never call this from an audio render callback — see
    /// `EqualizerAudioTap` for the ring buffer that exists precisely so the render thread never
    /// reaches a file handle.
    private static let queue = DispatchQueue(label: "vellum.tap.log", qos: .utility)

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    /// Equalizer-activity stream: what is true of the audio currently being produced.
    static func eq(_ message: @autoclosure () -> String) {
        write(prefix: "EQ ", message())
    }

    /// Tap-lifecycle stream: prepare / unprepare / process boundaries, always with item identity.
    static func tap(_ message: @autoclosure () -> String) {
        write(prefix: "TAP", message())
    }

    /// Marks a run boundary. The log survives reinstalls, so without this a reader cannot tell
    /// which lines belong to the build they are reasoning about.
    static func launchMarker(_ detail: @autoclosure () -> String) {
        write(prefix: "===", "== LAUNCH \(detail())")
    }

    private static func write(prefix: String, _ message: String) {
        // The timestamp is taken on the calling thread, so ordering reflects when the event
        // happened rather than when the queue got round to writing it.
        let stamp = CFAbsoluteTimeGetCurrent()
        queue.async {
            let line = String(format: "%.4f %@ %@\n", stamp, prefix, message)
            guard let url = fileURL else { return }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
#else
    // Release: no file, no queue, no formatting, and nothing reachable that could write one.
    // The parameters are `@autoclosure` so the string interpolation at each call site is never
    // evaluated either — the arguments cost nothing, not merely the writes.
    @inline(__always) static func eq(_ message: @autoclosure () -> String) {}
    @inline(__always) static func tap(_ message: @autoclosure () -> String) {}
    @inline(__always) static func launchMarker(_ detail: @autoclosure () -> String) {}
#endif
}
