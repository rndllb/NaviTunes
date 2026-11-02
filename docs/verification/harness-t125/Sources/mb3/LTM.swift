import Foundation

/// Fuzzy title / artist matching between external metadata (the request backend, chart browse, …) and Jellyfin/Navidrome `Track` rows.
enum LibraryTrackMatcher {
    /// Split on punctuation while keeping words with apostrophes / hyphens intact.
    private static let tokenBoundary =
        CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’-"))
            .inverted

    /// Lowercase, strip diacritics, drop apostrophes inside tokens (so "Whats" and
    /// "What's" collapse to the same key — the request backend and the server frequently disagree
    /// on apostrophes), drop other punctuation, collapse whitespace. Hyphens inside
    /// tokens stay so "well-known" remains a single token.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current)
        let replacedAmpersand = folded.replacingOccurrences(of: "&", with: " and ")
        let tokens = replacedAmpersand
            .components(separatedBy: tokenBoundary)
            .map {
                $0.lowercased()
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\u{2019}", with: "")  // U+2019 (’) smart apostrophe
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }
}
