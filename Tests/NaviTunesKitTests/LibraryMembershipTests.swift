import Foundation
import Testing

@testable import NaviTunesKit

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

    @Test("generated names are __navitunes_ plus exactly 12 hex characters")
    func nameShape() {
        let name = LibraryMembership.magicPlaylistName(backend: .navidrome, serverKey: Self.server, userKey: Self.user)
        #expect(name.hasPrefix("__navitunes_"))
        let suffix = name.dropFirst("__navitunes_".count)
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
            "__navitunes_",                 // prefix only
            "__navitunes_abc",              // too short
            "__navitunes_0123456789abc",    // too long
            "__navitunes_zzzzzzzzzzzz",     // not hex
            "__navitunes_0123456789ab extra",
            "navitunes_0123456789ab",       // missing leading underscores
            " __navitunes_0123456789ab",    // leading space
        ],
    )
    func rejectsNonMagicNames(name: String) {
        #expect(!LibraryMembership.isMagicPlaylistName(name))
    }

    /// Pre-rebrand `__lyra_<hash12>` playlists can still be on a server, and the playlist editor must
    /// not be able to reach them, so they count as magic names. They are renamed to the current prefix.
    @Test("legacy __lyra_ and __vellum_ names are recognised and map to the current name")
    func legacyNamesAreRecognised() {
        let legacy = LibraryMembership.legacyLyraMagicPlaylistNames(
            backend: .navidrome, serverKey: Self.server, userKey: Self.user,
            baseURLString: "https://\(Self.server)",
        )
        #expect(!legacy.isEmpty)
        for name in legacy {
            #expect(name.hasPrefix("__lyra_"))
            #expect(LibraryMembership.isMagicPlaylistName(name))
            #expect(LibraryMembership.currentName(forLegacy: name)?.hasPrefix("__navitunes_") == true)
        }
        #expect(LibraryMembership.currentName(forLegacy: "__vellum_0123456789ab") == "__navitunes_0123456789ab")
        #expect(LibraryMembership.currentName(forLegacy: "__navitunes_0123456789ab") == nil)
        #expect(LibraryMembership.isMagicPlaylistName("__vellum_0123456789ab"))
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
        // Only the canonical-prefix candidates have a pre-rebrand `__lyra_` counterpart.
        let canonical = current.filter { $0.hasPrefix("__navitunes_") }
        #expect(canonical.count == legacy.count)
        for (new, old) in zip(canonical, legacy) {
            #expect(new.dropFirst("__navitunes_".count) == old.dropFirst("__lyra_".count))
        }
    }

    /// Servers can hold the same playlist under `__vellum_`. It must still be found and recognised as the
    /// magic playlist, or it would leak into user-facing playlist lists.
    @Test("__vellum_ names are candidates and are recognised as magic")
    func vellumNamesAreRecognised() {
        let candidates = LibraryMembership.candidateMagicPlaylistNames(
            backend: .navidrome, serverKey: Self.server, userKey: Self.user,
            baseURLString: "https://\(Self.server)",
        )
        let vellum = candidates.filter { $0.hasPrefix("__vellum_") }
        #expect(!vellum.isEmpty)
        for name in vellum {
            #expect(LibraryMembership.isMagicPlaylistName(name), "\(name) was not recognised")
        }
        // The current name still leads, so it is what a fresh install creates.
        #expect(candidates.first?.hasPrefix("__navitunes_") == true)
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
        // One current name, plus its `__vellum_` twin; the identical legacy hash adds nothing.
        let canonical = candidates.filter { $0.hasPrefix(LibraryMembership.magicPlaylistPrefix) }
        #expect(canonical.count == 1)
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
        let canonical = candidates.filter { $0.hasPrefix(LibraryMembership.magicPlaylistPrefix) }
        #expect(canonical.count == 2)
        #expect(Set(candidates).count == candidates.count)
        // The canonical (port-aware) name is probed first.
        #expect(canonical.first == LibraryMembership.magicPlaylistName(
            backend: .navidrome, serverKey: "music.example.com:4533", userKey: Self.user,
        ))
        #expect(canonical.last == LibraryMembership.magicPlaylistName(
            backend: .navidrome, serverKey: Self.server, userKey: Self.user,
        ))
    }
}
