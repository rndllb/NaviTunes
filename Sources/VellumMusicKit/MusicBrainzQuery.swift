import Foundation

/// Builds the Lucene query strings sent to MusicBrainz's search endpoints.
///
/// This exists because passing the user's raw text through as `query=` — which is what the
/// first version of this client did — has one specific, verified failure: **no typo tolerance
/// at all.** `radiohaed` returns zero results. `blak sabath` returns zero results. MusicBrainz's
/// relevance ranking is excellent when a name is spelled correctly and useless when it is not,
/// and `dismax=true` does not change that (measured: identical zero counts).
///
/// Field-qualified fuzzy terms do fix it — `artist:radiohaed~1` returns Radiohead at score 100,
/// `artist:blak~1 AND artist:sabath~1` returns Black Sabbath at score 100. So every query is
/// built in two halves that are OR-ed together:
///
/// 1. **A boosted exact phrase**, which keeps a correctly-typed name pinned at the top. Without
///    the boost the fuzzy half can float a shorter near-miss above the thing that was actually
///    typed.
/// 2. **Per-term fuzzy conjunction**, which is what catches the misspelling. AND-ed rather than
///    OR-ed: `blak~ OR sabath~` matches anything vaguely resembling either word and buries the
///    answer, while requiring both keeps recall wide and precision usable.
///
/// Escaping is not optional here. MusicBrainz tolerates raw punctuation on the *default* field
/// (`AC/DC` answers 200), but the moment a term is field-qualified, `/` opens a regex and `)`
/// closes a group that was never opened — `artist:AC/DC` and `artist:Sunn O)))` are parse errors,
/// not searches. Since every query this type builds is field-qualified, every user-supplied
/// character has to be escaped.
enum MusicBrainzQuery {
    /// Lucene syntax characters, per the query-parser grammar. `&` and `|` are escaped
    /// individually rather than as the `&&`/`||` pairs the grammar lists, which is stricter than
    /// required and cannot mis-fire.
    private static let luceneSpecials: Set<Character> = [
        "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]",
        "^", "\"", "~", "*", "?", ":", "\\", "/",
    ]

    /// Backslash-escapes every Lucene metacharacter in `raw`.
    static func escape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 8)
        for ch in raw {
            if luceneSpecials.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Whitespace-split terms with the metacharacters already escaped. Empty terms dropped, so a
    /// query that was nothing but punctuation yields none and the caller falls back to the phrase.
    static func terms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map { escape(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Edit distance to allow on one term.
    ///
    /// Scaled to length because a fixed distance is wrong at both ends: `~2` on a four-letter
    /// word matches most four-letter words, while `~1` on a fifteen-letter name is stingier than
    /// the typos people actually make. Terms of three characters or fewer get no fuzziness at all
    /// — at that length an edit distance of one is most of the word.
    static func fuzzDistance(forTermLength length: Int) -> Int? {
        switch length {
        case ...3: return nil
        case 4...7: return 1
        default: return 2
        }
    }

    /// One fuzzy clause for `term` on `field`, or an exact clause when the term is too short to
    /// fuzz safely.
    private static func fuzzyClause(field: String, term: String) -> String {
        guard let distance = fuzzDistance(forTermLength: term.count) else {
            return "\(field):\(term)"
        }
        return "\(field):\(term)~\(distance)"
    }

    /// Assembles the boosted-phrase half and the fuzzy-conjunction half.
    ///
    /// - Parameters:
    ///   - phraseFields: fields to match the whole query against as a phrase, with the boost to
    ///     apply to each. Ordered strongest first for readability only; Lucene does not care.
    ///   - fuzzyField: the single field the per-term fuzzy conjunction runs against. Only one,
    ///     because a fuzzy term crossed with several fields multiplies into a query that is both
    ///     slow and imprecise.
    private static func build(
        query raw: String,
        phraseFields: [(field: String, boost: Int)],
        fuzzyField: String
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = escape(trimmed)
        var clauses = phraseFields.map { "\($0.field):\"\(phrase)\"^\($0.boost)" }

        let termList = terms(trimmed)
        if !termList.isEmpty {
            let fuzzy = termList.map { fuzzyClause(field: fuzzyField, term: $0) }
            // Parenthesised so the AND binds inside this clause and does not swallow the
            // preceding OR-ed phrase clauses.
            clauses.append("(" + fuzzy.joined(separator: " AND ") + ")")
        }
        return clauses.joined(separator: " OR ")
    }

    /// Artist search.
    ///
    /// Includes `sortname` and `alias` in the phrase half, which is the difference between
    /// finding an artist and not: `†††` is indexed under sort-name "Crosses", and `Ye` under the
    /// alias "Yeezy". Both are unreachable by name alone.
    static func artists(_ raw: String) -> String {
        build(
            query: raw,
            phraseFields: [("artist", 10), ("sortname", 8), ("alias", 6)],
            fuzzyField: "artist"
        )
    }

    /// Release-group (album / EP / single) search. `releasegroup` is the title field.
    static func releaseGroups(_ raw: String) -> String {
        build(
            query: raw,
            phraseFields: [("releasegroup", 10)],
            fuzzyField: "releasegroup"
        )
    }

    /// Recording (song) search. `recording` is the title field.
    static func recordings(_ raw: String) -> String {
        build(
            query: raw,
            phraseFields: [("recording", 10)],
            fuzzyField: "recording"
        )
    }
}
