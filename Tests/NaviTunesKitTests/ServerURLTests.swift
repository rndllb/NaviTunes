import Foundation
import Testing

@testable import NaviTunesKit

@Suite("ServerURL")
struct ServerURLTests {
    @Test(
        "typed addresses normalise to a clean http(s) URL",
        arguments: [
            ("music.example.com", "https://music.example.com"),
            ("  music.example.com/  ", "https://music.example.com"),
            ("Https://music.example.com", "https://music.example.com"),
            ("https:/music.example.com", "https://music.example.com"),
            ("https//music.example.com", "https://music.example.com"),
            ("HTTP://music.example.com:4533/", "http://music.example.com:4533"),
            ("https://music.example.com/jellyfin/", "https://music.example.com/jellyfin"),
        ],
    )
    func normalises(raw: String, expected: String) {
        #expect(ServerURL.normalize(raw)?.absoluteString == expected)
    }

    @Test("empty and hostless input is rejected", arguments: ["", "   ", "https://", "ftp://example.com"])
    func rejects(raw: String) {
        #expect(ServerURL.normalize(raw) == nil)
        #expect(ServerURL.candidates(raw).isEmpty)
    }

    @Test("LAN addresses default to http, public hosts to https")
    func lanDefaults() {
        #expect(ServerURL.normalizeLanAddress("192.168.1.10:8096")?.absoluteString == "http://192.168.1.10:8096")
        #expect(ServerURL.normalizeLanAddress("navidrome.local")?.absoluteString == "http://navidrome.local")
        #expect(ServerURL.normalizeLanAddress("music.example.com")?.absoluteString == "https://music.example.com")
        #expect(ServerURL.normalizeLanAddress("https://192.168.1.10")?.absoluteString == "https://192.168.1.10")
    }

    @Test("only scheme-less LAN and Tailscale hosts get an http fallback")
    func fallback() {
        #expect(ServerURL.candidates("music.example.com").map(\.absoluteString) == ["https://music.example.com"])
        #expect(ServerURL.candidates("http://music.example.com").map(\.absoluteString) == ["http://music.example.com"])
        #expect(ServerURL.candidates("192.168.1.10:4533").map(\.absoluteString) == ["https://192.168.1.10:4533", "http://192.168.1.10:4533"])
        #expect(ServerURL.candidates("100.101.102.103:8096").count == 2)
        #expect(ServerURL.candidates("box.tail1234.ts.net").count == 2)
        #expect(ServerURL.candidates("100.200.1.1").count == 1)
    }
}
