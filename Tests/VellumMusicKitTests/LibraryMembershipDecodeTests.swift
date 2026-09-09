import Foundation
import Testing

@testable import VellumMusicKit

/// C15 — the magic playlist's membership payload must never let "we could not read it" pass as
/// "there is nothing there".
///
/// The two are different facts and collapsing them destroys libraries: a truncated comment
/// decoded to an empty payload, a truncated read usually loses the track ids too, so the caller
/// took its "library is genuinely empty" branch and cleared the entries — and the next mutation
/// wrote that emptiness back to the server, permanently.
@Suite("LibraryMembershipPayload decoding")
struct LibraryMembershipDecodeTests {
    private static func sample() -> LibraryMembershipPayload {
        LibraryMembershipPayload(
            albums: [
                .init(id: "album-1", added: Date(timeIntervalSince1970: 1_700_000_000)),
                .init(id: "album-2", added: Date(timeIntervalSince1970: 1_700_000_100)),
            ],
            playlists: [.init(id: "pl-1", added: Date(timeIntervalSince1970: 1_700_000_200))],
        )
    }

    // MARK: - The reproduction

    /// The exact C15 shape: a payload cut short mid-JSON.
    @Test("a truncated payload reports malformed, not empty")
    func truncatedIsMalformed() {
        let json = Self.sample().encoded()
        // Every cut length, not just one — a short read can land anywhere.
        for drop in 1..<min(json.count, 60) {
            let truncated = String(json.dropLast(drop))
            let outcome = LibraryMembershipPayload.decodeOutcome(truncated)
            #expect(outcome != .valid(.empty), "dropLast(\(drop)) decoded as a valid empty payload")
            if case .absent = outcome {
                Issue.record("dropLast(\(drop)) reported absent; truncated content is not absence")
            }
        }
    }

    @Test(
        "content that cannot be parsed reports malformed",
        arguments: [
            "{",
            "not json at all",
            #"{"albums":"#,
            #"{"albums":[{"id":"a","added":"#,
            #"{"albums":[],"playlists":[],"v":"#,
            "\u{FFFD}\u{FFFD}\u{FFFD}",
        ],
    )
    func garbageIsMalformed(raw: String) {
        #expect(LibraryMembershipPayload.decodeOutcome(raw) == .malformed)
    }

    // MARK: - The cases that must still work

    /// Absence is a real answer: a freshly created magic playlist has no comment yet, and that
    /// legitimately means "no membership recorded". It must not be mistaken for damage.
    @Test("an absent or blank comment reports absent", arguments: [nil, "", "   ", "\n\t "])
    func absentIsAbsent(raw: String?) {
        #expect(LibraryMembershipPayload.decodeOutcome(raw) == .absent)
    }

    /// A server that genuinely says "empty" is trusted — that is a readable answer.
    @Test("an explicitly empty payload is valid, not malformed")
    func explicitEmptyIsValid() {
        let outcome = LibraryMembershipPayload.decodeOutcome(#"{"albums":[],"playlists":[],"v":1}"#)
        #expect(outcome == .valid(.empty))
    }

    @Test("a well-formed payload round-trips through encode and decode")
    func roundTrip() {
        let original = Self.sample()
        #expect(LibraryMembershipPayload.decodeOutcome(original.encoded()) == .valid(original))
    }

    /// The distinction the whole fix rests on: these two inputs must not produce the same value.
    @Test("truncated and genuinely empty are distinguishable")
    func truncatedIsNotEmpty() {
        let truncated = String(Self.sample().encoded().dropLast(25))
        let genuine = #"{"albums":[],"playlists":[],"v":1}"#
        #expect(LibraryMembershipPayload.decodeOutcome(truncated)
                != LibraryMembershipPayload.decodeOutcome(genuine))
    }

    // MARK: - The lossy helper

    /// `decode` still collapses everything to a payload, which is why it must not be used on a
    /// path that can write. Pinned so the hazard stays visible rather than being rediscovered.
    @Test("the lossy decode still cannot tell malformed from empty")
    func lossyDecodeIsStillLossy() {
        let truncated = String(Self.sample().encoded().dropLast(25))
        #expect(LibraryMembershipPayload.decode(truncated) == .empty)
        #expect(LibraryMembershipPayload.decode(#"{"albums":[],"playlists":[],"v":1}"#) == .empty)
    }

    @Test("the lossy decode still returns real content for a good payload")
    func lossyDecodeStillWorks() {
        #expect(LibraryMembershipPayload.decode(Self.sample().encoded()) == Self.sample())
    }
}
