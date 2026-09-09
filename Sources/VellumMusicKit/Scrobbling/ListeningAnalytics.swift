import Foundation

struct ListeningDayStat: Identifiable, Hashable {
    var id: String { dayKey }
    let dayKey: String
    let date: Date
    let playCount: Int
}

struct ListeningAnalyticsSummary {
    let totalPlays: Int
    let uniqueTracks: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let topArtists: [(name: String, count: Int)]
    let topTracks: [(title: String, artist: String, count: Int)]
    let dailyHeatmap: [ListeningDayStat]
}

enum ListeningAnalytics {
    static func summarize(completed: [CompletedScrobble], calendar: Calendar = .current) -> ListeningAnalyticsSummary {
        let plays = completed
        let totalPlays = plays.count
        let uniqueTracks = Set(plays.map(\.trackId)).count

        let dayKeys = plays.map { dayKey(for: $0.timestamp, calendar: calendar) }
        let uniqueDays = Set(dayKeys)
        let streaks = computeStreaks(dayKeys: uniqueDays, calendar: calendar)
        let heatmap = dailyCounts(from: plays, calendar: calendar)

        var artistCounts: [String: Int] = [:]
        var trackCounts: [String: (title: String, artist: String, count: Int)] = [:]
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
                trackCounts[key] = (scrobble.title, scrobble.artist, 1)
            }
        }

        let topArtists = artistCounts
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending) }
            .prefix(10)
            .map { ($0.key, $0.value) }

        let topTracks = trackCounts.values
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending) }
            .prefix(10)
            .map { ($0.title, $0.artist, $0.count) }

        return ListeningAnalyticsSummary(
            totalPlays: totalPlays,
            uniqueTracks: uniqueTracks,
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest,
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

    private static func computeStreaks(dayKeys: Set<String>, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !dayKeys.isEmpty else { return (0, 0) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let sortedDays = dayKeys.compactMap { formatter.date(from: $0) }.sorted()
        guard !sortedDays.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for i in 1..<sortedDays.count {
            let prev = calendar.startOfDay(for: sortedDays[i - 1])
            let cur = calendar.startOfDay(for: sortedDays[i])
            if let next = calendar.date(byAdding: .day, value: 1, to: prev), calendar.isDate(next, inSameDayAs: cur) {
                run += 1
            } else {
                longest = max(longest, run)
                run = 1
            }
        }
        longest = max(longest, run)

        let today = calendar.startOfDay(for: Date())
        var current = 0
        var cursor = today
        while dayKeys.contains(dayKey(for: cursor, calendar: calendar)) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return (current, longest)
    }
}
