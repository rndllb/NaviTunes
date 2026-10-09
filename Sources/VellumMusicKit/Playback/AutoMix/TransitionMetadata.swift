import Foundation

/// Per-track analysis produced **once, on the server** by `scripts/automix/analyze.py` and fetched
/// by the phone as JSON. The phone never runs beat tracking: everything the transition planner
/// needs to decide *whether* and *where* to blend two songs is in here.
///
/// Times are seconds from the start of the file. Loudness values are LUFS (integrated / windowed)
/// and LU (range), as measured by ITU-R BS.1770 on the server.
struct TransitionMetadata: Codable, Equatable {
    /// Schema version written by the analyzer. Readers reject anything newer than they know.
    static let supportedVersion = 1

    struct Section: Codable, Equatable {
        let start: TimeInterval
        let end: TimeInterval
        /// Analyzer label, e.g. `intro`, `verse`, `chorus`, `bridge`, `outro`, `break`.
        let label: String
    }

    struct Loudness: Codable, Equatable {
        /// Integrated loudness of the whole track, LUFS.
        let integrated: Double
        /// Loudness range, LU.
        let range: Double
        /// Short-term loudness over the first ~10 s of beat-tracked material, LUFS.
        let intro: Double
        /// Short-term loudness over the last ~10 s before the mix-out cue, LUFS.
        let outro: Double
    }

    struct Key: Codable, Equatable {
        let tonic: String
        let mode: String
        /// Camelot wheel code (`8A`, `11B`, …) so harmonic compatibility is a string compare.
        let camelot: String
    }

    struct Cues: Codable, Equatable {
        /// A downbeat where the *incoming* song should land under the outgoing one — the first
        /// downbeat after the intro section, or the first downbeat if there is no intro.
        let mixIn: TimeInterval
        /// A downbeat where the *outgoing* song should start handing over — the outro's first
        /// downbeat, or eight bars before the last downbeat when there is no outro.
        let mixOut: TimeInterval
    }

    let version: Int
    let trackId: String
    let duration: TimeInterval
    /// Beats per minute from the median beat interval.
    let tempo: Double
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    /// 0…1. Low for rubato or beatless material; the planner refuses to beat-match below a floor.
    let beatConfidence: Double
    let key: Key?
    let loudness: Loudness
    let sections: [Section]
    let cues: Cues
    /// Which model produced the beats, for provenance (`beat_this:final0`, `allin1:harmonix-all`).
    let analyzer: String?

    // MARK: - Derived

    /// Median beat spacing, seconds. Falls back to the tempo when fewer than two beats exist.
    var beatDuration: TimeInterval {
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }
        if let median = Self.median(intervals) { return median }
        return tempo > 0 ? 60 / tempo : 0.5
    }

    /// Beats per bar, inferred from downbeat spacing against beat spacing. Defaults to 4.
    var beatsPerBar: Int {
        let bd = beatDuration
        guard bd > 0 else { return 4 }
        let intervals = zip(downbeats.dropFirst(), downbeats).map { $0 - $1 }.filter { $0 > 0 }
        guard let median = Self.median(intervals) else { return 4 }
        let n = Int((median / bd).rounded())
        return (2 ... 7).contains(n) ? n : 4
    }

    var barDuration: TimeInterval { beatDuration * Double(beatsPerBar) }

    /// First downbeat at or after `time`, or `nil` if the track has none there.
    func downbeat(atOrAfter time: TimeInterval) -> TimeInterval? {
        downbeats.first { $0 >= time - 0.001 }
    }

    /// Last downbeat at or before `time`.
    func downbeat(atOrBefore time: TimeInterval) -> TimeInterval? {
        downbeats.last { $0 <= time + 0.001 }
    }

    /// Nearest beat to `time`.
    func nearestBeat(to time: TimeInterval) -> TimeInterval? {
        beats.min { abs($0 - time) < abs($1 - time) }
    }

    func section(labelled label: String) -> Section? {
        sections.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Decoding

    enum DecodeError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    /// Decodes analyzer JSON, rejecting a schema newer than this build understands.
    static func decode(_ data: Data) throws -> TransitionMetadata {
        let meta = try JSONDecoder().decode(TransitionMetadata.self, from: data)
        guard meta.version <= supportedVersion else { throw DecodeError.unsupportedVersion(meta.version) }
        return meta
    }
}
