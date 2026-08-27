import Foundation

/// A browsable genre, backed by one or more Radio Browser tags.
struct RadioDirectoryGenre: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbolName: String
    /// Directory tag spellings that feed this genre.
    let tags: [String]
}

/// Curated front end for the directory's ~12,000 user-supplied tags.
///
/// The raw vocabulary is unusable as a browse surface: the global top tags include
/// "entretenimiento", "estación", and "moi merino" alongside pop and rock, and a
/// single genre is split across spellings ("hip hop" and "hiphop" are separate tags
/// holding different stations). This is the same problem `GenreCanonicalizer` solves
/// for noisy server subgenres, applied to the radio directory — first match wins,
/// and the table is meant to be edited.
enum RadioDirectoryCatalog {
    /// Ordered roughly by how many US stations carry each genre.
    static let genres: [RadioDirectoryGenre] = [
        RadioDirectoryGenre(id: "rock", title: "Rock", symbolName: "guitars", tags: ["rock", "classic rock", "alternative rock"]),
        RadioDirectoryGenre(id: "pop", title: "Pop", symbolName: "music.note", tags: ["pop", "top 40", "hits"]),
        RadioDirectoryGenre(id: "country", title: "Country", symbolName: "hat.cap", tags: ["country", "americana"]),
        RadioDirectoryGenre(id: "jazz", title: "Jazz", symbolName: "music.quarternote.3", tags: ["jazz", "smooth jazz"]),
        RadioDirectoryGenre(id: "classical", title: "Classical", symbolName: "pianokeys", tags: ["classical", "opera"]),
        RadioDirectoryGenre(id: "oldies", title: "Oldies", symbolName: "radio", tags: ["oldies", "50s", "60s", "70s"]),
        RadioDirectoryGenre(id: "eighties", title: "80s", symbolName: "boombox", tags: ["80s"]),
        RadioDirectoryGenre(id: "nineties", title: "90s", symbolName: "boombox", tags: ["90s"]),
        RadioDirectoryGenre(id: "electronic", title: "Electronic", symbolName: "waveform", tags: ["electronic", "edm", "house", "techno", "trance"]),
        RadioDirectoryGenre(id: "dance", title: "Dance", symbolName: "figure.dance", tags: ["dance", "disco"]),
        RadioDirectoryGenre(id: "indie", title: "Indie", symbolName: "music.mic", tags: ["indie", "alternative"]),
        RadioDirectoryGenre(id: "hiphop", title: "Hip-Hop", symbolName: "music.mic", tags: ["hip hop", "hiphop", "rap"]),
        RadioDirectoryGenre(id: "rnb", title: "R&B & Soul", symbolName: "heart.text.square", tags: ["r&b", "rnb", "soul", "motown"]),
        RadioDirectoryGenre(id: "chill", title: "Chill", symbolName: "moon.stars", tags: ["chillout", "ambient", "lounge", "downtempo"]),
        RadioDirectoryGenre(id: "gospel", title: "Gospel", symbolName: "hands.clap", tags: ["gospel", "christian"]),
        RadioDirectoryGenre(id: "blues", title: "Blues", symbolName: "guitars", tags: ["blues"]),
        RadioDirectoryGenre(id: "metal", title: "Metal", symbolName: "bolt", tags: ["metal", "heavy metal"]),
        RadioDirectoryGenre(id: "folk", title: "Folk", symbolName: "leaf", tags: ["folk", "bluegrass"]),
        RadioDirectoryGenre(id: "funk", title: "Funk", symbolName: "music.note", tags: ["funk"]),
        RadioDirectoryGenre(id: "punk", title: "Punk", symbolName: "bolt.horizontal", tags: ["punk", "hardcore"]),
        RadioDirectoryGenre(id: "reggae", title: "Reggae", symbolName: "sun.max", tags: ["reggae", "ska", "dancehall"]),
        RadioDirectoryGenre(id: "latin", title: "Latin", symbolName: "globe.americas", tags: ["latin", "salsa", "reggaeton", "cumbia"]),
        RadioDirectoryGenre(id: "news", title: "News", symbolName: "newspaper", tags: ["news"]),
        RadioDirectoryGenre(id: "talk", title: "Talk", symbolName: "text.bubble", tags: ["talk", "public radio"]),
        RadioDirectoryGenre(id: "sports", title: "Sports", symbolName: "sportscourt", tags: ["sports"]),
    ]

    /// Tag → curated genre title, so a station's raw first tag renders as something
    /// presentable instead of "moi merino".
    private static let labelsByTag: [String: String] = {
        var map: [String: String] = [:]
        for genre in genres {
            for tag in genre.tags where map[tag] == nil {
                map[tag] = genre.title
            }
        }
        return map
    }()

    /// Best genre label for a station's tag list.
    ///
    /// A station's *first* tag is frequently not a genre — real examples from the
    /// directory are "1930", "78", and "california" — so prefer the first tag that
    /// maps to a curated genre and only fall back to raw text when none do.
    static func genreLabel(forTags tags: [String]) -> String {
        for tag in tags {
            let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let mapped = labelsByTag[key] { return mapped }
        }
        // Nothing mapped. Skip tags that open with a digit ("78", "1930", "78-rpm")
        // before falling back to raw text. Real decade genres like "80s" never reach
        // here — they're in the curated table above.
        let fallback = tags.first { tag in
            guard let first = tag.unicodeScalars.first else { return false }
            return !CharacterSet.decimalDigits.contains(first)
        }
        guard let label = fallback ?? tags.first(where: { !$0.isEmpty }) else { return "" }
        return displayLabel(forTag: label)
    }

    static func displayLabel(forTag tag: String) -> String {
        let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = labelsByTag[key] { return mapped }
        guard !key.isEmpty else { return "" }
        return key
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func genre(id: String) -> RadioDirectoryGenre? {
        genres.first { $0.id == id }
    }

    /// Region used for "Popular Near You" and the default country filter. Falls back
    /// to the US, which is also the directory's largest country (7,830 stations).
    static var preferredCountryCode: String {
        let code = Locale.current.region?.identifier.uppercased() ?? ""
        return code.count == 2 ? code : "US"
    }

    static func countryDisplayName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
