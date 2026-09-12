import Foundation
import Testing

@testable import VellumMusicKit

/// `Track.withArtworkURL` and `withDuration` are hand-rolled copy constructors: they rebuild the
/// struct by listing every field at the call site. That shape has no compiler backstop — a field
/// added to `init` with a default value is silently omitted by both, and the copy comes back with
/// the default instead of the original's value.
///
/// That is exactly what happened to `artistId` (C10). Both methods sit on the playback path
/// (`AppModel.trackWithResolvedArtwork`, `PlaybackEngine.tracksWithResolvedArtwork`), so every
/// enqueued track lost its artist id and "Go to Artist" quietly fell back to the by-name lookup the
/// field exists to avoid. Nothing broke, which is why it survived a user test.
///
/// These tests therefore do **not** check `artistId` by name. They reflect over every stored
/// property and assert that a copy differs in exactly the one field the method is named for. A
/// field added to `Track` tomorrow and forgotten in these constructors fails this test without
/// anyone remembering to update it — which is the only property worth pinning here.
@Suite("Track copy constructors")
struct TrackCopyConstructorTests {
    /// Every field non-nil and distinguishable, so an omitted one cannot coincidentally match the
    /// default it would revert to.
    private static func fullyPopulated() -> Track {
        Track(
            id: "track-1",
            title: "Title",
            albumId: "album-1",
            albumTitle: "Album",
            artist: "Artist",
            duration: 123.5,
            discNumber: 2,
            indexNumber: 7,
            artworkURL: URL(string: "https://example.invalid/art.jpg"),
            libraryAddedDate: Date(timeIntervalSince1970: 1_600_000_000),
            genres: ["Lo-Fi", "Jazz"],
            releaseYear: 1999,
            sampleRateHz: 44_100,
            audioChannels: 2,
            audioCodec: "flac",
            audioBitDepth: 24,
            audioBitRateKbps: 1_411,
            streamOverrideURL: URL(string: "https://example.invalid/stream"),
            artistId: "artist-42",
        )
    }

    /// Stored properties as `label -> description`. Reflection rather than a hand-written list,
    /// because a hand-written list is the same failure mode this test exists to catch.
    private static func fields(_ track: Track) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: track).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            }
        )
    }

    /// Guards the reflection itself: if `Mirror` ever returns nothing the comparisons below would
    /// pass vacuously.
    @Test("reflection sees every stored property")
    func reflectionCoversAllFields() {
        let names = Set(Self.fields(Self.fullyPopulated()).keys)
        #expect(names.count == 19)
        #expect(names.contains("artistId"))
        #expect(names.contains("streamOverrideURL"))
    }

    @Test("withArtworkURL changes the artwork URL and nothing else")
    func withArtworkURLPreservesEveryOtherField() {
        let original = Self.fullyPopulated()
        let newURL = URL(string: "https://example.invalid/new-art.jpg")
        let copy = original.withArtworkURL(newURL)

        #expect(copy.artworkURL == newURL)

        let before = Self.fields(original)
        let after = Self.fields(copy)
        let changed = before.keys.filter { before[$0] != after[$0] }.sorted()
        #expect(changed == ["artworkURL"])
    }

    @Test("withDuration changes the duration and nothing else")
    func withDurationPreservesEveryOtherField() {
        let original = Self.fullyPopulated()
        let copy = original.withDuration(987.0)

        #expect(copy.duration == 987.0)

        let before = Self.fields(original)
        let after = Self.fields(copy)
        let changed = before.keys.filter { before[$0] != after[$0] }.sorted()
        #expect(changed == ["duration"])
    }

    /// The two methods are chained on the playback path (resolve artwork, then correct duration
    /// from the decoded asset), so a field dropped by either survives as dropped.
    @Test("chaining both copy constructors still preserves identity fields")
    func chainedCopiesPreserveIdentity() {
        let original = Self.fullyPopulated()
        let copy = original
            .withArtworkURL(URL(string: "https://example.invalid/other.jpg"))
            .withDuration(42)

        let before = Self.fields(original)
        let after = Self.fields(copy)
        let changed = before.keys.filter { before[$0] != after[$0] }.sorted()
        #expect(changed == ["artworkURL", "duration"])
    }
}
