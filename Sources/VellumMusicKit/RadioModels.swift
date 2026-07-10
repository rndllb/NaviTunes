import Foundation

/// Internet radio entry from Subsonic ``getInternetRadioStations`` (Navidrome)
/// or a user-added station stored locally in Vellum.
struct InternetRadioStation: Identifiable, Hashable {
    let id: String
    let name: String
    let streamURL: URL
    let homepageURL: URL?
    /// Local or remote artwork; nil → deterministic mesh tile.
    var artworkURL: URL? = nil
    /// Stations added in Vellum (editable/removable); server entries are false.
    var isUserAdded: Bool = false
}

/// Live internet stations grouped by genre words in the station title.
struct LiveRadioGroup: Identifiable, Hashable {
    let id: String
    /// Empty when the group is the only block and needs no sub-heading.
    let title: String
    let stations: [InternetRadioStation]
}

enum LiveRadioGrouping {
    /// Common radio genre words when library tags do not match station names.
    private static let fallbackGenreKeywords: [String] = [
        "hip hop", "hip-hop", "r&b", "classic rock", "hard rock", "alternative rock",
        "rock", "jazz", "country", "classical", "pop", "electronic", "edm",
        "dance", "metal", "blues", "folk", "reggae", "latin", "soul",
        "funk", "punk", "indie", "alternative", "chill", "ambient",
        "news", "talk", "sports", "christian", "gospel", "world",
    ]

    /// Buckets ``stations`` by matching genre strings found in each station name.
    static func group(
        stations: [InternetRadioStation],
        libraryGenreNames: [String],
    ) -> [LiveRadioGroup] {
        guard !stations.isEmpty else { return [] }

        var keywords: [(label: String, pattern: String)] = []
        var seenPatterns = Set<String>()

        for name in libraryGenreNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let pattern = trimmed.lowercased()
            guard seenPatterns.insert(pattern).inserted else { continue }
            keywords.append((trimmed, pattern))
        }

        for fallback in fallbackGenreKeywords {
            guard seenPatterns.insert(fallback).inserted else { continue }
            let label = fallback.split(separator: " ").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
            keywords.append((label, fallback))
        }

        keywords.sort { $0.pattern.count > $1.pattern.count }

        var buckets: [String: [InternetRadioStation]] = [:]
        var bucketOrder: [String] = []
        var unmatched: [InternetRadioStation] = []

        let sortedStations = stations.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        for station in sortedStations {
            let haystack = station.name.lowercased()
            if let match = keywords.first(where: { haystack.contains($0.pattern) }) {
                if buckets[match.label] == nil {
                    bucketOrder.append(match.label)
                }
                buckets[match.label, default: []].append(station)
            } else {
                unmatched.append(station)
            }
        }

        var groups: [LiveRadioGroup] = bucketOrder.map { title in
            LiveRadioGroup(
                id: "live-genre-\(title)",
                title: title,
                stations: buckets[title] ?? [],
            )
        }

        if !unmatched.isEmpty {
            groups.append(
                LiveRadioGroup(id: "live-other", title: "More Stations", stations: unmatched),
            )
        }

        // No keyword hits — show one flat list under the main "Live Radio" heading.
        if groups.count == 1, groups[0].id == "live-other" {
            return [LiveRadioGroup(id: "live-all", title: "", stations: sortedStations)]
        }

        return groups
    }
}
