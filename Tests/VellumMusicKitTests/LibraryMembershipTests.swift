import Foundation
import Testing

@testable import VellumMusicKit

/// `LibraryMembership` decides two things that are easy to break and expensive to break:
///
///  1. **Convergence** — `magicPlaylistName` must be a pure function of
///     (backend, server, user), or the same account on a second device creates a *second*
///     library playlist and the two silently diverge.
///  2. **Containment** — `isMagicPlaylistName` is what keeps the magic playlist out of
///     `libraryPlaylists`, and therefore out of `PlaylistEditSheet`, whose row removal commits
///     an unconfirmed, un-undoable multi-row delete to the server. If the predicate stops
///     matching a name the generator produces, "edit a playlist" becomes "delete my library".
@Suite("LibraryMembership")
struct LibraryMembershipTests {
    private static let user = "listener"
    private static let server = "music.example.com"

    // MARK: - Name generation is deterministic

    @Test("same inputs always produce the same name")
    func deterministic() {
        let a = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        let b = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        #expect(a == b)
    }

    /// Login forms differ in case and stray whitespace across devices; if those leaked into the
    /// hash, the same account would land on two different playlists.
    @Test(
        "user key is normalised for case and whitespace",
        arguments: ["listener", "Listener", "LISTENER", "  listener  ", "\tlistener\n"],
    )
    func userKeyNormalised(userKey: String) {
        let expected = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: "listener")
        #expect(LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: userKey) == expected)
    }

    @Test("server key is normalised for case")
    func serverKeyNormalised() {
        let expected = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        let upper = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: "MUSIC.EXAMPLE.COM", userKey: Self.user)
        #expect(upper == expected)
    }

    /// The same username on a Jellyfin and a Navidrome server must not collide — they are
    /// different libraries with different track ids.
    @Test("backend is part of the identity")
    func backendSeparatesNames() {
        let jellyfin = LibraryMembership.magicPlaylistName(backend: .jellyfin, serverKey: Self.server, userKey: Self.user)
        let navidrome = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        #expect(jellyfin != navidrome)
    }

    @Test("different servers and users produce different names")
    func inputsSeparateNames() {
        let base = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        let otherServer = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: "other.example.com", userKey: Self.user)
        let otherUser = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: "someone-else")
        #expect(base != otherServer)
        #expect(base != otherUser)
    }

    @Test("a nil server key is treated as empty, not as a random value")
    func nilServerKeyIsStable() {
        let a = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: nil, userKey: Self.user)
        let b = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: "", userKey: Self.user)
        #expect(a == b)
    }

    // MARK: - Name shape

    @Test("generated names are __vellum_ plus exactly 12 hex characters")
    func nameShape() {
        let name = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        #expect(name.hasPrefix("__vellum_"))
        let suffix = name.dropFirst("__vellum_".count)
        // `allSatisfy` is `rethrows`, which the #expect macro can't hoist — evaluate it first.
        let isAllHex = suffix.allSatisfy(\.isHexDigit)
        #expect(suffix.count == 12)
        #expect(isAllHex)
    }

    // MARK: - Containment: the generator and the predicate must never disagree

    /// The load-bearing invariant. Every name the app can create must be recognised by the
    /// filter that hides it from the playlist editor.
    @Test("every generated name is recognised as a magic playlist name")
    func generatorAndPredicateAgree() {
        for backend in BackendKind.allCases {
            for server in [Self.server, "other.example.com:4533", ""] {
                for user in ["listener", "a", "user with spaces", "ünïcøde"] {
                    let name = LibraryMembership.magicPlaylistName(backend: backend, serverKey: server, userKey: user)
                    #expect(
                        LibraryMembership.isMagicPlaylistName(name),
                        "generated \(name) was not recognised by isMagicPlaylistName",
                    )
                }
            }
        }
    }

    @Test("every candidate name is recognised as a magic playlist name")
    func candidatesAreRecognised() {
        let candidates = LibraryMembership.candidateMagicPlaylistNames(
            backend: .navidrome,
            serverKey: "music.example.com:4533",
            userKey: Self.user,
            baseURLString: "https://music.example.com:4533",
        )
        #expect(!candidates.isEmpty)
        for name in candidates {
            #expect(LibraryMembership.isMagicPlaylistName(name), "candidate \(name) was not recognised")
        }
    }

    @Test(
        "ordinary playlist names are not mistaken for the magic playlist",
        arguments: [
            "Road Trip",
            "__vellum_",                 // prefix only
            "__vellum_abc",              // too short
            "__vellum_0123456789abc",    // too long
            "__vellum_zzzzzzzzzzzz",     // not hex
            "__vellum_0123456789ab extra",
            "vellum_0123456789ab",       // missing leading underscores
            " __vellum_0123456789ab",    // leading space
        ],
    )
    func rejectsNonMagicNames(name: String) {
        #expect(!LibraryMembership.isMagicPlaylistName(name))
    }

    /// **Documented gap, not endorsed behaviour.** CLAUDE.md records that pre-rebrand users can
    /// still hold a `__lyra_<hash12>` playlist until the one-time rename migration runs, and that
    /// `isMagicPlaylistName` does not match it — meaning such a playlist is still reachable from
    /// `PlaylistEditSheet`. This test pins the current behaviour so the gap is visible in the
    /// suite rather than only in prose. **When the prefix check is widened to cover `__lyra_`,
    /// this test should be inverted, not deleted.**
    @Test("known gap: legacy __lyra_ names are NOT filtered out")
    func legacyLyraNamesAreNotRecognised() {
        let legacy = LibraryMembership.legacyLyraMagicPlaylistNames(
            backend: .navidrome,
            serverKey: Self.server,
            userKey: Self.user,
            baseURLString: "https://\(Self.server)",
        )
        #expect(!legacy.isEmpty)
        for name in legacy {
            #expect(name.hasPrefix("__lyra_"))
            #expect(
                !LibraryMembership.isMagicPlaylistName(name),
                "if this now passes, the prefix check was widened — invert this test",
            )
        }
    }

    /// The rename migration only works if the hash half is untouched by the rebrand.
    @Test("legacy names share the hash of their current counterpart")
    func legacyNamesShareHash() {
        let current = LibraryMembership.candidateMagicPlaylistNames(
            backend: .navidrome, serverKey: Self.server, userKey: Self.user,
            baseURLString: "https://\(Self.server)",
        )
        let legacy = LibraryMembership.legacyLyraMagicPlaylistNames(
            backend: .navidrome, serverKey: Self.server, userKey: Self.user,
            baseURLString: "https://\(Self.server)",
        )
        #expect(current.count == legacy.count)
        for (new, old) in zip(current, legacy) {
            #expect(new.dropFirst("__vellum_".count) == old.dropFirst("__lyra_".count))
        }
    }

    // MARK: - Server key normalisation

    @Test(
        "default ports are dropped so the same instance hashes the same",
        arguments: [
            ("https://music.example.com", "music.example.com"),
            ("https://music.example.com:443", "music.example.com"),
            ("http://music.example.com:80", "music.example.com"),
            ("https://MUSIC.example.com", "music.example.com"),
            ("https://music.example.com/subpath", "music.example.com"),
        ],
    )
    func defaultPortsDropped(urlString: String, expected: String) {
        #expect(LibraryMembership.normalizedServerKey(from: urlString) == expected)
    }

    @Test("non-default ports are kept, since they identify a different instance")
    func customPortKept() {
        #expect(LibraryMembership.normalizedServerKey(from: "https://music.example.com:4533") == "music.example.com:4533")
        #expect(LibraryMembership.normalizedServerKey(from: "http://192.168.1.10:8096") == "192.168.1.10:8096")
    }

    @Test("surrounding whitespace in a base URL does not change the key")
    func whitespaceTolerated() {
        #expect(LibraryMembership.normalizedServerKey(from: "  https://music.example.com  ") == "music.example.com")
    }

    @Test("an empty base URL yields no key")
    func emptyBaseURL() {
        #expect(LibraryMembership.normalizedServerKey(from: "") == nil)
        #expect(LibraryMembership.normalizedServerKey(from: "   ") == nil)
    }

    // MARK: - Candidate probing

    /// When the base URL carries no non-default port, the host-only legacy hash is identical to
    /// the canonical one — the list must dedupe rather than probe the server twice.
    @Test("candidates dedupe when the legacy hash matches the canonical one")
    func candidatesDedupe() {
        let candidates = LibraryMembership.candidateMagicPlaylistNames(
            backend: .navidrome,
            serverKey: Self.server,
            userKey: Self.user,
            baseURLString: "https://\(Self.server)",
        )
        #expect(candidates.count == 1)
        #expect(Set(candidates).count == candidates.count)
    }

    /// With a non-default port the two hashes differ, and both must be probed or a device that
    /// signed in on an older build would create a duplicate library playlist.
    @Test("a ported server offers both the canonical and the legacy host-only name")
    func candidatesIncludeLegacyHostOnly() {
        let candidates = LibraryMembership.candidateMagicPlaylistNames(
            backend: .navidrome,
            serverKey: "music.example.com:4533",
            userKey: Self.user,
            baseURLString: "https://music.example.com:4533",
        )
        #expect(candidates.count == 2)
        #expect(Set(candidates).count == candidates.count)
        // The canonical (port-aware) name is probed first.
        #expect(candidates.first == LibraryMembership.magicPlaylistName(
            backend: .navidrome, serverKey: "music.example.com:4533", userKey: Self.user,
        ))
        #expect(candidates.last == LibraryMembership.magicPlaylistName(
            backend: .navidrome, serverKey: Self.server, userKey: Self.user,
        ))
    }
}
