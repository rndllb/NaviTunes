import Foundation

/// Device-retrievable diagnostics for the tap playback path.
///
/// **Deliberately not wrapped in `#if DEBUG`.** The whole of `DebugUIRemote.swift` is, which is
/// why the existing `vellum-hangwatch.log` records nothing in a Release build on a device — the
/// only configuration in which the playback bug this branch exists to fix actually reproduces.
/// A diagnostic that switches itself off in the situation being diagnosed is not a diagnostic.
///
/// Both streams the brief asks for go into **one file**, distinguished by prefix:
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
    static func eq(_ message: String) {
        write(prefix: "EQ ", message)
    }

    /// Tap-lifecycle stream: prepare / unprepare / process boundaries, always with item identity.
    static func tap(_ message: String) {
        write(prefix: "TAP", message)
    }

    /// Marks a run boundary. The log survives reinstalls, so without this a reader cannot tell
    /// which lines belong to the build they are reasoning about.
    static func launchMarker(_ detail: String) {
        write(prefix: "===", "== LAUNCH \(detail)")
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
}
