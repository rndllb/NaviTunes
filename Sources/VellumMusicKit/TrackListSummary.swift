import Foundation

/// The "N songs, 1 hour 5 minutes" line under a track list.
///
/// One formatter for every surface that shows it — playlist detail, album detail, home mixes, and
/// the browse/chart album page. It existed as three separate copies, which is how two bugs
/// survived in all of them at once: the total was rendered as raw minutes (so a long playlist read
/// "3120 minutes" rather than "52 hours"), and "minutes" was hardcoded, so a one-minute track read
/// "1 song, 1 minutes".
enum TrackListSummary {
    /// The full line. Returns "No songs" for an empty list, and omits the duration clause
    /// entirely when the durations are unknown or zero rather than printing "0 minutes".
    static func text(songCount: Int, totalSeconds: TimeInterval) -> String {
        guard songCount > 0 else { return "No songs" }
        let songs = songPhrase(songCount)
        guard let duration = durationPhrase(totalSeconds) else { return songs }
        return "\(songs), \(duration)"
    }

    static func songPhrase(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    /// The date line above the summary: when an album came out, or when a playlist was made.
    ///
    /// Both are **labelled**. The album line used to render a bare date ("14 March 2019"), which
    /// was unambiguous only because albums were the sole surface that had one. Now that a
    /// playlist shows a date in the same position, an unlabelled date could mean either thing,
    /// so both say which they are.
    ///
    /// Returns `nil` when the date is unknown, and callers render nothing — no placeholder, no
    /// empty row. That is the common case on a real library, where plenty of albums carry no
    /// release metadata at all.
    static func releasedLine(for album: AlbumSummary) -> String? {
        // Reuses `releaseFooterDisplayString`, which already prefers a full date and falls back
        // to a bare year, rejecting implausible ones (before 1900 or more than two years out).
        album.releaseFooterDisplayString.map { "Released \($0)" }
    }

    /// Navidrome returns `created` on every playlist, but `PlaylistSummary.libraryAddedDate` was
    /// always nil until this shipped: the field was wired end to end, and only the date *parser*
    /// rejected Navidrome's ISO-8601 format. See `parsePlaylistDictSummary` in `NavidromeClient`.
    static func createdLine(_ created: Date?) -> String? {
        guard let created else { return nil }
        return "Created \(created.formatted(date: .long, time: .omitted))"
    }

    /// Hours then minutes, each singularised, with the empty unit dropped:
    ///
    /// - `0` (or unknown) → `nil`, so the caller omits the clause
    /// - under a minute → `"1 minute"` — a real track is never "0 minutes"
    /// - `59 min` → `"59 minutes"`
    /// - **exactly `60 min` → `"1 hour"`**, not "1 hour 0 minutes"
    /// - `61 min` → `"1 hour 1 minute"`
    /// - `3133 min` → `"52 hours 13 minutes"`
    static func durationPhrase(_ totalSeconds: TimeInterval) -> String? {
        guard totalSeconds > 0 else { return nil }
        // Round rather than ceil: at album and playlist scale, rounding to the nearest minute is
        // closer to the truth than always rounding up, and `max(1,…)` keeps a very short list
        // from reading as zero.
        let totalMinutes = max(1, Int((totalSeconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hourPhrase = hours == 1 ? "1 hour" : "\(hours) hours"
        let minutePhrase = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if hours == 0 { return minutePhrase }
        if minutes == 0 { return hourPhrase }
        return "\(hourPhrase) \(minutePhrase)"
    }
}
