import Foundation

/// Rolls noisy server subgenres up into a small set of main genres so the Library → Genres
/// list isn't cluttered (e.g. "Acid Jazz" → Jazz, "Alternative & Indie" → Alternative).
///
/// Matching is substring-based and first-rule-wins, so the order below is the priority.
/// It's intentionally easy to tweak — add keywords or reorder to taste.
enum GenreCanonicalizer {
    /// (canonical name, lowercase keywords that roll up into it). First match wins.
    private static let rules: [(canonical: String, keywords: [String])] = [
        ("Lo-Fi",       ["lofi", "lo-fi", "lo fi", "boom bap", "boom-bap", "boombap", "chillhop", "chill hop"]),
        ("Hip-Hop",     ["hip hop", "hip-hop", "hiphop", "rap", "trap", "drill", "grime"]),
        ("R&B",         ["r&b", "rnb", "rhythm and blues", "soul", "motown", "neo soul", "neo-soul"]),
        ("Electronic",  ["electronic", "electronica", "edm", "house", "techno", "trance", "dubstep",
                         "drum and bass", "drum & bass", "dnb", "electro", "synthwave", "ambient",
                         "idm", "breakbeat", "garage", "hardstyle"]),
        ("Metal",       ["metal", "metalcore", "djent", "grindcore"]),
        ("Punk",        ["punk", "hardcore", "emo", "screamo"]),
        ("Jazz",        ["jazz", "bebop", "swing", "bossa"]),
        ("Blues",       ["blues"]),
        ("Country",     ["country", "bluegrass", "americana", "honky", "western"]),
        ("Folk",        ["folk", "singer-songwriter", "singer/songwriter", "acoustic"]),
        ("Reggae",      ["reggae", "ska", "dancehall", "dub", "roots"]),
        ("Latin",       ["latin", "reggaeton", "salsa", "bachata", "merengue", "cumbia", "tango", "bossa nova"]),
        ("Classical",   ["classical", "orchestra", "orchestral", "symphony", "baroque", "opera", "chamber", "choral"]),
        ("Gospel",      ["gospel", "christian", "worship", "praise", "spiritual"]),
        ("Funk",        ["funk", "disco"]),
        ("Alternative", ["alternative", "indie"]),
        ("Pop",         ["pop", "k-pop", "kpop", "j-pop", "jpop"]),
        ("Rock",        ["rock", "grunge", "britpop", "psychedelic", "shoegaze"]),
        ("Soundtrack",  ["soundtrack", "score", "film", "stage & screen", "musical"]),
        ("World",       ["world", "afrobeat", "afro", "celtic", "flamenco", "klezmer"]),
        ("Holiday",     ["holiday", "christmas"]),
    ]

    /// Returns the canonical main genre for `genre`, or a cleaned version of the original
    /// when nothing matches (so unknown genres still appear, just tidied).
    static func canonical(for genre: String) -> String {
        let lower = genre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return genre }
        for rule in rules {
            if rule.keywords.contains(where: { lower.contains($0) }) {
                return rule.canonical
            }
        }
        return genre.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
