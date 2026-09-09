import Testing

@testable import VellumMusicKit

/// `LibraryTrackMatcher` decides whether two free-text artist strings refer to the same act.
/// It is the last name-based comparison left under artist navigation, so its false positives
/// are the "someone else's albums on this artist's page" class of bug (issue #28).
///
/// The substring rule in ``LibraryTrackMatcher/artistsOverlap(_:_:)`` is the dangerous part:
/// it exists so "Tyler, The Creator" still matches "Tyler The Creator", and it is fenced by a
/// four-character minimum on *both* sides so short names can't swallow long ones. These tests
/// pin that fence, because widening it is a one-character edit with a large blast radius.
@Suite("LibraryTrackMatcher")
struct LibraryTrackMatcherTests {
    private func overlaps(_ a: String, _ b: String) -> Bool {
        LibraryTrackMatcher.artistsOverlap(
            LibraryTrackMatcher.normalizedChartArtistTokens(a),
            LibraryTrackMatcher.normalizedChartArtistTokens(b),
        )
    }

    // MARK: - Issue #28: short names must not match long ones

    /// The reported shape: an artist page for "otuka" pulling in albums credited to "K".
    /// A one-character name is below the substring fence on its side, so it can only ever
    /// match by exact equality.
    @Test(
        "a one- to three-character artist never substring-matches a longer name",
        arguments: [
            ("otuka", "K"),
            ("otuka", "k"),
            ("Kaytranada", "K"),
            ("Radiohead", "Rad"),
            ("Aphex Twin", "Ap"),
            ("Foo Fighters", "Foo"),
        ],
    )
    func shortNamesDoNotContaminate(long: String, short: String) {
        #expect(overlaps(long, short) == false, "\(short) must not match \(long)")
        #expect(overlaps(short, long) == false, "\(long) must not match \(short)")
    }

    /// The fence cuts both ways: a short name still matches *itself*, so guarding against
    /// contamination must not make single-letter artists unfindable.
    @Test("a short artist still matches itself exactly")
    func shortNamesMatchThemselves() {
        #expect(overlaps("K", "K"))
        #expect(overlaps("K", "k"))
        #expect(overlaps("MF DOOM", "mf doom"))
    }

    // MARK: - What the substring rule is actually for

    /// Real punctuation variants across servers and metadata sources. These are the matches
    /// the substring rule exists to keep, and the reason it can't simply be deleted.
    @Test(
        "punctuation and case variants of the same act still match",
        arguments: [
            ("Tyler, The Creator", "Tyler The Creator"),
            ("Beyoncé", "Beyonce"),
            ("Sigur Rós", "Sigur Ros"),
            ("Anderson .Paak", "Anderson Paak"),
        ],
    )
    func variantsMatch(a: String, b: String) {
        #expect(overlaps(a, b))
    }

    /// Unrelated acts of a similar length must stay separate — the rule is substring, not fuzzy.
    @Test(
        "different artists of comparable length do not match",
        arguments: [
            ("Radiohead", "Portishead"),
            ("Kendrick Lamar", "Kanye West"),
            ("The Beatles", "The Beach Boys"),
        ],
    )
    func differentArtistsDoNotMatch(a: String, b: String) {
        #expect(overlaps(a, b) == false)
    }

    // MARK: - Credit-line splitting

    /// A credit line names several artists; each is a separate token, so a page for any one of
    /// them matches the line. This is what lets a featured credit resolve at all.
    @Test(
        "credit lines split into their individual artists",
        arguments: [" & ", " + ", "/", ", "],
    )
    func creditLinesSplit(separator: String) {
        let line = "Rich Brian\(separator)Charlotte Day Wilson"
        let tokens = LibraryTrackMatcher.normalizedChartArtistTokens(line)
        #expect(tokens.contains("rich brian"))
        #expect(tokens.contains("charlotte day wilson"))
        #expect(overlaps(line, "Rich Brian"))
        #expect(overlaps(line, "Charlotte Day Wilson"))
    }

    /// The whole credit line is not itself an artist. Navigating by it opens a page belonging
    /// to nobody — the bug fixed alongside #28 — so it must not match any single act.
    @Test("a full credit line does not match an unrelated artist")
    func creditLineIsNotAnArtist() {
        let line = "Rich Brian feat. Charlotte Day Wilson & DAISY WORLD"
        #expect(overlaps(line, "Kendrick Lamar") == false)
    }

    // MARK: - Normalisation

    @Test("normalisation folds case, diacritics, apostrophes and ampersands")
    func normalisation() {
        #expect(LibraryTrackMatcher.normalize("Beyoncé") == LibraryTrackMatcher.normalize("beyonce"))
        #expect(LibraryTrackMatcher.normalize("Guns N' Roses") == LibraryTrackMatcher.normalize("Guns N\u{2019} Roses"))
        #expect(LibraryTrackMatcher.normalize("Hall & Oates") == LibraryTrackMatcher.normalize("Hall and Oates"))
    }

    @Test("normalisation collapses whitespace rather than preserving it")
    func whitespaceCollapsed() {
        #expect(LibraryTrackMatcher.normalize("  The   National  ") == LibraryTrackMatcher.normalize("The National"))
    }

    @Test("an empty or whitespace-only credit yields no tokens")
    func emptyCredit() {
        #expect(LibraryTrackMatcher.normalizedChartArtistTokens("").isEmpty)
        #expect(LibraryTrackMatcher.normalizedChartArtistTokens("   ").isEmpty)
    }

    /// An empty token set must never match anything, or a track with no credited artist would
    /// match every artist page on the server.
    @Test("an empty token set matches nothing")
    func emptyMatchesNothing() {
        #expect(LibraryTrackMatcher.artistsOverlap([], ["radiohead"]) == false)
        #expect(LibraryTrackMatcher.artistsOverlap(["radiohead"], []) == false)
        #expect(LibraryTrackMatcher.artistsOverlap([], []) == false)
    }
}
