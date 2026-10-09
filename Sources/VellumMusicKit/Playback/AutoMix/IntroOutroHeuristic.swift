import Foundation

/// The lightweight, phone-runnable section detector. No model: an RMS level per bar, a reference
/// level, and two runs — the leading bars under the threshold are the intro, the trailing ones the
/// outro. Ported 1:1 from `heuristic_sections` in the evaluation harness so the Linux scores
/// apply to what ships.
///
/// Pure over an array of per-bar RMS values, so it is tested without audio.
enum IntroOutroHeuristic {
    /// Fraction of the reference level below which a bar counts as "not the body".
    static let quietFraction = 0.7
    /// Percentile of bar RMS used as the reference level — robust to one loud hit.
    static let referencePercentile = 0.9
    /// Longest intro or outro, bars. Longer quiet runs are the song, not a lead-in.
    static let maxRunBars = 32

    struct Result: Equatable {
        /// Bars in the intro (0 when the song starts at full level).
        let introBars: Int
        /// Bars in the outro.
        let outroBars: Int
    }

    static func analyze(barRMS rms: [Double]) -> Result {
        let n = rms.count
        guard n >= 4 else { return Result(introBars: 0, outroBars: 0) }
        let reference = percentile(rms, referencePercentile)
        let threshold = quietFraction * reference
        var intro = 0
        while intro < min(maxRunBars, n - 1), rms[intro] < threshold { intro += 1 }
        var outro = 0
        while outro < min(maxRunBars, n - 1 - intro), rms[n - 1 - outro] < threshold { outro += 1 }
        return Result(introBars: intro, outroBars: outro)
    }

    /// Turns a result into labelled sections over downbeat edges (`edges` must start at 0 and end
    /// at the track duration, with one entry per bar boundary in between).
    static func sections(from result: Result, edges: [TimeInterval]) -> [TransitionMetadata.Section] {
        guard edges.count >= 2 else { return [] }
        let n = edges.count - 1
        let duration = edges[edges.count - 1]
        var out: [TransitionMetadata.Section] = []
        let introEnd = edges[min(result.introBars, n)]
        if result.introBars > 0 {
            out.append(.init(start: 0, end: introEnd, label: "intro"))
        }
        let bodyEnd = result.outroBars > 0 ? edges[max(0, n - result.outroBars)] : duration
        out.append(.init(start: introEnd, end: bodyEnd, label: "body"))
        if result.outroBars > 0 {
            out.append(.init(start: bodyEnd, end: duration, label: "outro"))
        }
        return out
    }

    /// Nearest-rank percentile (NumPy's default `linear` for the sizes involved differs by under a
    /// bar's RMS jitter; the threshold has a 30 % margin, so the two agree on every run length in
    /// the evaluation set).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}
