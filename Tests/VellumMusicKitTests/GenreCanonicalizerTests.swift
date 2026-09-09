import Testing

@testable import VellumMusicKit

/// `GenreCanonicalizer` is first-match-wins over an ordered keyword table, so its behaviour is
/// entirely a function of rule *order*. Reordering the table to fix one genre silently rehomes
/// others, and nothing in the type itself would complain. These tests pin the orderings that
/// were chosen deliberately.
@Suite("GenreCanonicalizer")
struct GenreCanonicalizerTests {
    // MARK: - Order-sensitive rules

    /// Lo-Fi sits above Hip-Hop precisely so boom bap / chillhop don't land in Hip-Hop.
    /// CLAUDE.md calls this out as an intentional split; if Hip-Hop ever moves above Lo-Fi
    /// these are the cases that regress.
    @Test(
        "boom bap and chillhop roll up to Lo-Fi, not Hip-Hop",
        arguments: ["Boom Bap", "boom-bap", "boombap", "Chillhop", "chill hop", "Lo-Fi", "lofi"],
    )
    func lofiWinsOverHipHop(genre: String) {
        #expect(GenreCanonicalizer.canonical(for: genre) == "Lo-Fi")
    }

    @Test("plain hip-hop spellings still roll up to Hip-Hop", arguments: ["Hip Hop", "hip-hop", "HipHop", "Rap", "Trap", "Drill", "Grime"])
    func hipHopSpellings(genre: String) {
        #expect(GenreCanonicalizer.canonical(for: genre) == "Hip-Hop")
    }

    /// Documents (rather than endorses) the collisions the current ordering produces. Each of
    /// these reads like it "should" match the second genre; the table's order decides otherwise.
    /// If one of these starts failing, someone reordered the table — check it was on purpose.
    @Test(
        "order-driven collisions are stable",
        arguments: [
            ("Gospel Rap", "Hip-Hop"),      // Hip-Hop precedes Gospel
            ("Folk Punk", "Punk"),          // Punk precedes Folk
            ("Neo Soul", "R&B"),            // R&B precedes Funk/Soul-adjacent rules
            ("Bossa Nova", "Jazz"),         // Jazz's "bossa" precedes Latin's "bossa nova"
            ("Metalcore", "Metal"),         // Metal precedes Punk's "hardcore"
            ("Reggaeton", "Reggae"),        // Reggae's "reggae" precedes Latin's "reggaeton"
        ],
    )
    func collisions(genre: String, expected: String) {
        #expect(GenreCanonicalizer.canonical(for: genre) == expected)
    }

    // MARK: - Representative rollups

    @Test(
        "subgenres roll up to their main genre",
        arguments: [
            ("Acid Jazz", "Jazz"),
            ("Alternative & Indie", "Alternative"),
            ("Progressive House", "Electronic"),
            ("Drum & Bass", "Electronic"),
            ("Shoegaze", "Rock"),
            ("K-Pop", "Pop"),
            ("Bachata", "Latin"),
            ("Baroque", "Classical"),
            ("Stage & Screen", "Soundtrack"),
            ("Christmas", "Holiday"),
            ("Bluegrass", "Country"),
            ("Disco", "Funk"),
            ("Afrobeat", "World"),
        ],
    )
    func rollups(genre: String, expected: String) {
        #expect(GenreCanonicalizer.canonical(for: genre) == expected)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(GenreCanonicalizer.canonical(for: "ACID JAZZ") == "Jazz")
        #expect(GenreCanonicalizer.canonical(for: "aCiD jAzZ") == "Jazz")
    }

    // MARK: - Fallback behaviour

    /// Unknown genres are kept (tidied) rather than dropped, so a server's odd tags still
    /// produce a browsable row instead of vanishing from Library → Genres.
    @Test("unknown genres pass through, trimmed")
    func unknownPassthrough() {
        #expect(GenreCanonicalizer.canonical(for: "  Vaporwave  ") == "Vaporwave")
        #expect(GenreCanonicalizer.canonical(for: "Zeuhl") == "Zeuhl")
    }

    /// An all-whitespace genre returns the *original* string untouched (not a trimmed empty),
    /// because the guard fires before trimming is applied to the return value.
    @Test("blank input returns the original string")
    func blankInput() {
        #expect(GenreCanonicalizer.canonical(for: "") == "")
        #expect(GenreCanonicalizer.canonical(for: "   ") == "   ")
    }

    /// Canonical names must themselves be stable under a second pass, otherwise repeated
    /// canonicalisation (e.g. re-canonicalising an already-merged row) would drift.
    @Test("canonicalisation is idempotent for every canonical name")
    func idempotent() {
        let canonicalNames = [
            "Lo-Fi", "Hip-Hop", "R&B", "Electronic", "Metal", "Punk", "Jazz", "Blues",
            "Country", "Folk", "Reggae", "Latin", "Classical", "Gospel", "Funk",
            "Alternative", "Pop", "Rock", "Soundtrack", "World", "Holiday",
        ]
        for name in canonicalNames {
            let once = GenreCanonicalizer.canonical(for: name)
            #expect(once == name, "\(name) did not canonicalise to itself, got \(once)")
            #expect(GenreCanonicalizer.canonical(for: once) == once)
        }
    }
}
