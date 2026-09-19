import Foundation

struct ListeningDayStat: Identifiable, Hashable {
    var id: String { dayKey }
    let dayKey: String
    let date: Date
    let playCount: Int
}

struct ListeningAnalyticsSummary {
    /// Lifetime completed scrobbles. Comes from the running counter, not from the retained
    /// array, so it is not bounded by the 500-item cap the way every field below it is.
    let totalPlays: Int
    /// Number of scrobbles the detail stats below were actually computed over. Equal to
    /// ``totalPlays`` until the cap bites, lower afterwards — the view says so rather than
    /// presenting a windowed figure as a lifetime one.
    let analyzedPlays: Int
    let uniqueTracks: Int
    let topArtists: [(name: String, count: Int)]
    /// `trackId` rides along so the view can resolve each row's cover art. It is the scrobble's
    /// own id, which is what `AppModel.cachedLibraryTrack(id:)` takes.
    let topTracks: [(trackId: String, title: String, artist: String, count: Int)]
    let dailyHeatmap: [ListeningDayStat]
}

enum ListeningAnalytics {
    /// - Parameter lifetimePlays: the store's running total. Everything else here is derived
    ///   from `completed`, which is capped, so this is the one figure that survives trimming.
    ///   Passing `nil` falls back to the array's own count.
    static func summarize(
        completed: [CompletedScrobble],
        lifetimePlays: Int? = nil,
        calendar: Calendar = .current,
    ) -> ListeningAnalyticsSummary {
        let plays = completed
        let analyzedPlays = plays.count
        let totalPlays = max(lifetimePlays ?? analyzedPlays, analyzedPlays)
        let uniqueTracks = Set(plays.map(\.trackId)).count

        let heatmap = dailyCounts(from: plays, calendar: calendar)

        var artistCounts: [String: Int] = [:]
        var trackCounts: [String: (trackId: String, title: String, artist: String, count: Int)] = [:]
        for scrobble in plays {
            let artist = scrobble.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty {
                artistCounts[artist, default: 0] += 1
            }
            let key = scrobble.trackId
            if var existing = trackCounts[key] {
                existing.count += 1
                trackCounts[key] = existing
            } else {
                trackCounts[key] = (key, scrobble.title, scrobble.artist, 1)
            }
        }

        let topArtists = artistCounts
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending) }
            .prefix(10)
            .map { ($0.key, $0.value) }

        let topTracks = trackCounts.values
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending) }
            .prefix(10)
            .map { ($0.trackId, $0.title, $0.artist, $0.count) }

        return ListeningAnalyticsSummary(
            totalPlays: totalPlays,
            analyzedPlays: analyzedPlays,
            uniqueTracks: uniqueTracks,
            topArtists: Array(topArtists),
            topTracks: Array(topTracks),
            dailyHeatmap: heatmap,
        )
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func dailyCounts(from plays: [CompletedScrobble], calendar: Calendar) -> [ListeningDayStat] {
        var counts: [String: (date: Date, count: Int)] = [:]
        for scrobble in plays {
            let key = dayKey(for: scrobble.timestamp, calendar: calendar)
            if var existing = counts[key] {
                existing.count += 1
                counts[key] = existing
            } else {
                let start = calendar.startOfDay(for: scrobble.timestamp)
                counts[key] = (start, 1)
            }
        }
        return counts.values
            .map { ListeningDayStat(dayKey: dayKey(for: $0.date, calendar: calendar), date: $0.date, playCount: $0.count) }
            .sorted { $0.date > $1.date }
            .prefix(90)
            .map { $0 }
    }

    // Streaks were removed along with the section that displayed them. A streak read off the
    // capped `completed` array is wrong in a way no label can fix: once the tail is trimmed the
    // oldest retained day is not the oldest day listened to, so "longest streak" is bounded by
    // whatever survived rather than by what happened, and a long streak silently shortens as
    // history rolls off. Restoring it needs a source of truth that is not trimmed.
}
