import Foundation
import Testing

@testable import VellumMusicKit

/// LRC parsing decides where every lyric line sits on the playback clock, and a mistake here
/// doesn't crash or log — the words simply drift against the song, which is only visible by
/// watching a track play. That makes it exactly the kind of logic worth pinning in a test
/// rather than in a bug report (issue #2).
///
/// The offset rule is the subtle one. Navidrome copies `[offset:±ms]` out of the file verbatim
/// and LRC defines it as *added* to each line's start, so a positive offset moves lines later.
/// Getting the sign backwards desyncs every line by twice the offset.
@Suite("NavidromeLyricsParser")
struct NavidromeLyricsParserTests {
    // MARK: - Timestamp formats

    @Test(
        "leading timestamps parse in every LRC spelling",
        arguments: [
            ("[00:12]One", 12.0),
            ("[00:12.5]One", 12.5),
            ("[00:12.50]One", 12.5),
            ("[00:12.500]One", 12.5),
            ("[01:00]One", 60.0),
            ("[02:03.25]One", 123.25),
            ("[1:02:03]One", 3723.0),
            ("[00:12,50]One", 12.5),   // comma decimal separator
        ],
    )
    func timestampFormats(line: String, expected: TimeInterval) {
        let parsed = NavidromeLyricsParser.parseTimedLine(line)
        #expect(parsed != nil, "failed to parse \(line)")
        if let parsed {
            #expect(abs(parsed.start - expected) < 0.0005, "\(line) → \(parsed.start), expected \(expected)")
            #expect(parsed.text == "One")
        }
    }

    // MARK: - Offset semantics

    /// A positive offset moves lines **later**. This is the rule that is easy to invert.
    @Test("a positive offset is added to every line start")
    func positiveOffsetAdds() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [offset:500]
        [00:10.00]First
        [00:20.00]Second
        """)
        #expect(lines.count == 2)
        #expect(abs(lines[0].start - 10.5) < 0.0005)
        #expect(abs(lines[1].start - 20.5) < 0.0005)
    }

    @Test("a negative offset moves lines earlier")
    func negativeOffsetSubtracts() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [offset:-250]
        [00:10.00]First
        [00:20.00]Second
        """)
        #expect(lines.count == 2)
        #expect(abs(lines[0].start - 9.75) < 0.0005)
        #expect(abs(lines[1].start - 19.75) < 0.0005)
    }

    /// `structuredLineStart` is the structured-blocks equivalent of the same rule, and it
    /// clamps: an offset large enough to push a line before the start of the song would
    /// otherwise produce a negative timestamp that no playback position can ever match.
    @Test("structured line starts apply the same rule and clamp at zero")
    func structuredLineStart() {
        #expect(abs(NavidromeLyricsParser.structuredLineStart(lineStartMs: 10_000, offsetMs: 500) - 10.5) < 0.0005)
        #expect(abs(NavidromeLyricsParser.structuredLineStart(lineStartMs: 10_000, offsetMs: -500) - 9.5) < 0.0005)
        #expect(NavidromeLyricsParser.structuredLineStart(lineStartMs: 100, offsetMs: -5_000) == 0)
    }

    // MARK: - Metadata

    @Test("metadata tags are not rendered as lyrics")
    func metadataIgnored() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [ti:Song Title]
        [ar:Some Artist]
        [al:Some Album]
        [by:Transcriber]
        [00:10.00]First
        [00:20.00]Second
        """)
        #expect(lines.count == 2)
        #expect(lines[0].text == "First")
        #expect(lines[1].text == "Second")
    }

    // MARK: - Ordering

    @Test("lines come back in playback order regardless of file order")
    func sorted() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:30.00]Third
        [00:10.00]First
        [00:20.00]Second
        """)
        #expect(lines.map(\.text) == ["First", "Second", "Third"])
    }

    // MARK: - Unsynced text

    /// The important half of this: unsynced lyrics must NOT be given invented timestamps.
    /// Spacing them out evenly would look synced and then drift against the song, which is
    /// worse than plainly not syncing — the UI checks `lyricsAppearSynced` to decide whether
    /// to highlight and auto-scroll at all.
    @Test("plain lyrics keep a zero start and are never assigned timestamps")
    func plainLyricsNotInvented() {
        let lines = NavidromeLyricsParser.parse(plain: """
        First line
        Second line
        Third line
        """)
        #expect(lines.count == 3)
        let allZero = lines.allSatisfy { $0.start == 0 }
        #expect(allZero)
        #expect(lines.lyricsAppearSynced == false)
    }

    @Test("synced lyrics report as synced")
    func syncedDetection() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:10.00]First
        [00:20.00]Second
        """)
        #expect(lines.lyricsAppearSynced)
    }

    /// Two lines sharing one timestamp are not usable for sync — there is no second position to
    /// advance to — so they must not be treated as synced.
    @Test("identical timestamps do not count as synced")
    func duplicateTimestampsNotSynced() {
        let lines = [
            LyricLine(start: 10, text: "First"),
            LyricLine(start: 10, text: "Second"),
        ]
        #expect(lines.lyricsAppearSynced == false)
    }

    @Test("a single line is never synced")
    func singleLineNotSynced() {
        #expect([LyricLine(start: 10, text: "Only")].lyricsAppearSynced == false)
    }

    // MARK: - Enhanced LRC

    /// Word-level (enhanced) LRC puts timestamps inside the line. They must be stripped from
    /// what is displayed, or the lyric renders with the timing data visible in it.
    @Test("inline word timestamps are stripped from display text")
    func inlineTagsStripped() {
        #expect(NavidromeLyricsParser.displayText("[00:12.00]Hello [00:12.50]world") == "Hello world")
        #expect(NavidromeLyricsParser.displayText("No tags here") == "No tags here")
    }

    @Test("the earliest embedded timestamp is the line's start")
    func earliestInlineTimestamp() {
        let t = NavidromeLyricsParser.firstTimestamp(in: "[00:20.00]later [00:10.00]earlier")
        #expect(t != nil)
        if let t { #expect(abs(t - 10.0) < 0.0005) }
    }

    // MARK: - Repeated timestamps

    /// A repeated chorus is normally written once with a tag per occurrence. Keeping only the
    /// first dropped every later one, so the highlight ran out of lines to advance to and
    /// stopped tracking the song partway through — a strong candidate for issue #2.
    @Test("a line tagged several times is sung several times")
    func repeatedTimestampsExpand() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:10.00][01:40.00][03:10.00]Chorus
        [00:20.00]Verse
        """)
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus", "Chorus"])
        #expect(abs(lines[0].start - 10.0) < 0.0005)
        #expect(abs(lines[1].start - 20.0) < 0.0005)
        #expect(abs(lines[2].start - 100.0) < 0.0005)
        #expect(abs(lines[3].start - 190.0) < 0.0005)
    }

    @Test("every repeat of a line takes the global offset too")
    func repeatedTimestampsTakeOffset() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [offset:1000]
        [00:10.00][00:40.00]Chorus
        """)
        #expect(lines.count == 2)
        #expect(abs(lines[0].start - 11.0) < 0.0005)
        #expect(abs(lines[1].start - 41.0) < 0.0005)
    }

    /// A file whose only line is timed used to render as no lyrics at all: too few distinct
    /// timestamps to count as synced, and the plain-text fallback only collects lines that
    /// don't start with `[`. The words are still the lyrics.
    @Test("a single timed line still renders its text")
    func singleTimedLineStillRenders() {
        let lines = NavidromeLyricsParser.parse(plain: "[00:10.00]Only line")
        #expect(lines.map(\.text) == ["Only line"])
        #expect(lines.lyricsAppearSynced == false)
    }

    /// When there is real plain text alongside, it still wins — that path is unchanged.
    @Test("plain text is still preferred when a file mixes it with one timed line")
    func mixedFilePrefersPlainText() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:10.00]Timed line
        Plain line one
        Plain line two
        """)
        #expect(lines.map(\.text) == ["Plain line one", "Plain line two"])
    }

    @Test("empty input yields no lyrics")
    func emptyInput() {
        #expect(NavidromeLyricsParser.parse(plain: "").isEmpty)
        #expect(NavidromeLyricsParser.parse(plain: "\n\n  \n").isEmpty)
    }

    // MARK: - Row identity (T240 crash)

    /// **`LyricLine.id` is a SwiftUI identity, not a debugging aid.** The lyrics view renders
    /// `ForEach(Array(displayItems.enumerated()), id: \.element.id)`, so two lines sharing an id
    /// are duplicate identities in a `ForEach` — undefined behaviour, and it corrupts the
    /// index/identity pairing the rows are laid out from. The app crashed with "index out of
    /// range" in that view.
    ///
    /// The regression was mine: expanding repeated timestamps (issue #2) made a line tagged
    /// twice at the *same* time emit two identical lines. Measured before and after that commit
    /// on this exact input — before: 2 lines, 2 unique ids; after: 3 lines, 2 unique ids.
    @Test("a line tagged twice at the same time yields one row, not two identical ones")
    func sameTimestampTwiceIsOneRow() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:10.00][00:10.00]Chorus
        [00:20.00]Verse
        """)
        #expect(lines.map(\.text) == ["Chorus", "Verse"])
        let ids = lines.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
    }

    /// Deduplicating same-time repeats must not swallow genuine ones.
    @Test("distinct repeats survive deduplication")
    func distinctRepeatsSurvive() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:10.00][00:10.00][01:40.00][01:40.00][03:10.00]Chorus
        [00:20.00]Verse
        """)
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus", "Chorus"])
        let ids = lines.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
    }

    /// The invariant itself, over the shapes most able to collide: repeated tags, an offset that
    /// shifts every start, duplicated file rows, and a chorus written out longhand.
    @Test(
        "parsed lyrics never contain two rows with the same id",
        arguments: [
            "[00:10.00][00:10.00]Chorus\n[00:20.00]Verse",
            "[offset:500]\n[00:10.00][00:10.00]Chorus\n[00:20.00]Verse",
            "[00:10.00][01:40.00][03:10.00]Chorus\n[00:20.00]Verse\n[02:00.00]Verse",
            "[00:10.00]Chorus\n[01:40.00]Chorus\n[03:10.00]Chorus",
            "[00:05.00]La\n[00:05.50]La\n[00:06.00]La",
        ],
    )
    func idsAreUnique(source: String) {
        let ids = NavidromeLyricsParser.parse(plain: source).map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
    }

    /// Two *different* lyrics at the same timestamp are still two rows — the dedupe is per line,
    /// not global, so a genuine simultaneous pair must not collapse.
    @Test("different text at the same timestamp stays two rows")
    func differentTextSameTimeKeptSeparate() {
        let lines = NavidromeLyricsParser.parse(plain: """
        [00:10.00]First voice
        [00:10.00]Second voice
        [00:20.00]Verse
        """)
        #expect(lines.count == 3)
        let ids = lines.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
    }
}
