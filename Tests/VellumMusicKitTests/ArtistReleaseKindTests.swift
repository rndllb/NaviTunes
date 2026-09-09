import Testing

@testable import VellumMusicKit

/// Singles and EPs share one shelf on the artist page, so the card's caption is the only place
/// the two are told apart. It used to be derived from the shelf, which meant every EP read
/// "Single" — while a second screen captioned the same bucket "EP", so the app disagreed with
/// itself about one release (issue #29).
@Suite("ArtistReleaseKind")
struct ArtistReleaseKindTests {
    // MARK: - Catalogue types win

    @Test(
        "the catalogue's primary type decides the kind",
        arguments: [
            ("Album", ArtistReleaseKind.album),
            ("album", ArtistReleaseKind.album),
            ("EP", ArtistReleaseKind.ep),
            ("ep", ArtistReleaseKind.ep),
            ("Single", ArtistReleaseKind.single),
            ("single", ArtistReleaseKind.single),
        ],
    )
    func primaryType(raw: String, expected: ArtistReleaseKind) {
        #expect(ArtistReleaseKind.from(albumType: raw, secondaryTypes: [], trackCount: nil) == expected)
    }

    /// An EP must not be reported as a single. This is the exact defect in #29.
    @Test("a four-track EP is an EP, not a single")
    func epIsNotSingle() {
        let kind = ArtistReleaseKind.from(albumType: "EP", secondaryTypes: [], trackCount: 4)
        #expect(kind == .ep)
        #expect(kind.label == "EP")
    }

    @Test("secondary types outrank the primary type")
    func secondaryTypes() {
        #expect(ArtistReleaseKind.from(albumType: "Album", secondaryTypes: ["Live"], trackCount: 12) == .live)
        #expect(ArtistReleaseKind.from(albumType: "Album", secondaryTypes: ["Compilation"], trackCount: 20) == .compilation)
    }

    /// A live EP is live — the shelf it lands on and the caption both follow the secondary type,
    /// so they can't disagree.
    @Test("a live EP reports as live")
    func liveEP() {
        #expect(ArtistReleaseKind.from(albumType: "EP", secondaryTypes: ["Live"], trackCount: 5) == .live)
    }

    /// Track count must not override a type the catalogue actually stated. A three-track release
    /// explicitly typed "Album" is an album, however short it is.
    @Test("a stated type beats the track-count heuristic")
    func statedTypeWins() {
        #expect(ArtistReleaseKind.from(albumType: "Album", secondaryTypes: [], trackCount: 2) == .album)
        #expect(ArtistReleaseKind.from(albumType: "Single", secondaryTypes: [], trackCount: 30) == .single)
    }

    // MARK: - Fallback

    /// Only for releases the catalogue never described — a bootleg, a local rip, or an album the
    /// server has and MusicBrainz doesn't.
    @Test(
        "track count is the last resort",
        arguments: [
            (1, ArtistReleaseKind.single),
            (3, ArtistReleaseKind.single),
            (4, ArtistReleaseKind.ep),
            (6, ArtistReleaseKind.ep),
            (7, ArtistReleaseKind.album),
            (12, ArtistReleaseKind.album),
        ],
    )
    func trackCountFallback(count: Int, expected: ArtistReleaseKind) {
        #expect(ArtistReleaseKind.fromTrackCount(count) == expected)
        #expect(ArtistReleaseKind.from(albumType: nil, secondaryTypes: [], trackCount: count) == expected)
    }

    /// Nothing known at all: call it an album rather than guessing "Single", which is the
    /// caption most likely to be wrong and the one users noticed.
    @Test("an unknown release with no track count is an album")
    func unknownDefaultsToAlbum() {
        #expect(ArtistReleaseKind.fromTrackCount(nil) == .album)
        #expect(ArtistReleaseKind.from(albumType: nil, secondaryTypes: [], trackCount: nil) == .album)
        #expect(ArtistReleaseKind.from(albumType: "", secondaryTypes: [], trackCount: nil) == .album)
    }

    // MARK: - Labels

    @Test("every kind has a distinct human label")
    func labels() {
        let kinds: [ArtistReleaseKind] = [.album, .ep, .single, .live, .compilation]
        let labels = kinds.map(\.label)
        #expect(labels == ["Album", "EP", "Single", "Live", "Compilation"])
        #expect(Set(labels).count == labels.count)
    }
}
