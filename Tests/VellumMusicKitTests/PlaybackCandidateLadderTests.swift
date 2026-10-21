import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// T643 c2. Which stream URLs may be proxied through the custom-scheme caching loader, and the
/// order of attempts the engine makes for one track. The T638 log showed every candidate —
/// raw, mp3 and aac — going through the loader and dying within a second; transcoded Subsonic
/// streams answer `Accept-Ranges: none` with no `Content-Length`, which the loader cannot serve.
@Suite("Playback candidate ladder")
struct PlaybackCandidateLadderTests {
    static let raw = URL(string: "https://nd.example/rest/stream.view?id=abc&u=user&t=tok&s=salt&v=1.16.1&c=vellum&f=json")!
    static let rawExplicit = URL(string: "https://nd.example/rest/stream.view?id=abc&format=raw&u=user&t=tok&s=salt")!
    static let mp3 = URL(string: "https://nd.example/rest/stream.view?id=abc&format=mp3&maxBitRate=320&u=user&t=tok&s=salt")!
    static let aac = URL(string: "https://nd.example/rest/stream.view?id=abc&format=aac&maxBitRate=320&u=user&t=tok&s=salt")!
    static let capped = URL(string: "https://nd.example/rest/stream.view?id=abc&maxBitRate=128&u=user")!
    static let jellyfinStatic = URL(string: "https://jf.example/Audio/abc/stream?static=true&api_key=k")!
    static let jellyfinTranscode = URL(string: "https://jf.example/Audio/abc/stream?audioCodec=aac&audioBitRate=256000&api_key=k")!
    static let hls = URL(string: "https://nd.example/rest/hls.view?id=abc")!
    static let file = URL(fileURLWithPath: "/tmp/abc.flac")

    // MARK: servesByteRanges — the rule

    @Test("a raw stream (no format, or format=raw) is served by ServeContent and supports ranges")
    func rawServesRanges() {
        #expect(CachingResourceLoaderDelegate.servesByteRanges(Self.raw))
        #expect(CachingResourceLoaderDelegate.servesByteRanges(Self.rawExplicit))
        #expect(CachingResourceLoaderDelegate.servesByteRanges(Self.jellyfinStatic))
    }

    @Test("any transcode parameter means a chunked body with no length: never through the loader")
    func transcodesDoNot() {
        #expect(!CachingResourceLoaderDelegate.servesByteRanges(Self.mp3))
        #expect(!CachingResourceLoaderDelegate.servesByteRanges(Self.aac))
        #expect(!CachingResourceLoaderDelegate.servesByteRanges(Self.capped))
        #expect(!CachingResourceLoaderDelegate.servesByteRanges(Self.jellyfinTranscode))
    }

    @Test("the gate the engine consults: never, for any remote stream (T662)")
    func gateAgrees() {
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.raw, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.rawExplicit, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.jellyfinStatic, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.mp3, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.aac, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: false, url: Self.raw, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.hls, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: Self.file, isInternetRadio: false))
    }

    // MARK: the ladder

    private func ladder(_ urls: [URL], autoMix: Bool, radio: Bool = false) -> [PlaybackCandidateLadder.Attempt] {
        PlaybackCandidateLadder.attempts(
            candidates: urls.map { (url: $0, headers: [:]) },
            autoMixEnabled: autoMix,
            isInternetRadio: radio,
        )
    }

    @Test("AutoMix on: one plain attempt per URL, the raw primary included (T662)")
    func autoMixOnRawPrimary() {
        let attempts = ladder([Self.raw, Self.mp3, Self.aac], autoMix: true)
        #expect(attempts.map(\.url) == [Self.raw, Self.mp3, Self.aac])
        #expect(attempts.allSatisfy { !$0.viaLoader })
    }

    /// The owner's stream, shaped exactly as `NavidromeClient.buildStreamURL` builds it for the
    /// "Original" format: plain http to the server's Tailscale address, no `format`, no
    /// `maxBitRate`, salted-token auth (placeholders here). Navidrome logs it `format=raw
    /// transcoding=false` and serves it with byte ranges, so T643's gate let it through — and
    /// the player rejected it: `candidate failed [load] loader=true … NSURLErrorDomain -1002 ←
    /// CoreMediaErrorDomain -1002` (the AutoMix diagnostic row, 2026-10-12). On that gate this
    /// test fails; the loader must not be offered to it.
    @Test("the owner's raw http Navidrome stream is never proxied, even though it serves ranges (T662)")
    func ownersRawStreamIsPlain() {
        let owners = URL(string: "http://203.0.113.10:4533/rest/stream?id=TRACKID&u=user&v=1.16.1&c=VellumMusicKit&t=TOKEN&s=SALT")!
        #expect(CachingResourceLoaderDelegate.servesByteRanges(owners))
        #expect(CachingResourceLoaderDelegate.isCacheable(owners))
        #expect(!PlaybackCandidateLadder.mayUseLoader(autoMixEnabled: true, url: owners, isInternetRadio: false))
        let attempts = ladder([owners], autoMix: true)
        #expect(attempts.map(\.viaLoader) == [false])
        #expect(attempts.map(\.url) == [owners])
    }

    @Test("AutoMix off: the ladder is exactly what it was — one plain attempt per URL")
    func autoMixOff() {
        let attempts = ladder([Self.raw, Self.mp3, Self.aac], autoMix: false)
        #expect(attempts.map(\.url) == [Self.raw, Self.mp3, Self.aac])
        #expect(attempts.allSatisfy { !$0.viaLoader })
    }

    @Test("a transcoded primary (the user's streaming format is MP3): the raw fallback is plain too")
    func transcodedPrimary() {
        let attempts = ladder([Self.mp3, Self.aac, Self.raw], autoMix: true)
        #expect(attempts.map(\.url) == [Self.mp3, Self.aac, Self.raw])
        #expect(attempts.allSatisfy { !$0.viaLoader })
    }

    @Test("a local file ahead of the streams: three plain attempts, in order")
    func localFileFirst() {
        let attempts = ladder([Self.file, Self.raw, Self.rawExplicit], autoMix: true)
        #expect(attempts.map(\.url) == [Self.file, Self.raw, Self.rawExplicit])
        #expect(attempts.allSatisfy { !$0.viaLoader })
    }

    @Test("internet radio is never proxied")
    func radio() {
        let attempts = ladder([Self.raw], autoMix: true, radio: true)
        #expect(attempts.map(\.viaLoader) == [false])
    }

    @Test("headers travel with every attempt of the same URL")
    func headersKept() {
        let attempts = PlaybackCandidateLadder.attempts(
            candidates: [(url: Self.raw, headers: ["X-Token": "t"])],
            autoMixEnabled: true,
            isInternetRadio: false,
        )
        #expect(attempts.count == 1)
        #expect(attempts.allSatisfy { $0.headers == ["X-Token": "t"] })
    }

    // MARK: the failure line the device test reads

    @Test("describe: domain and code of every link in the underlying chain, outermost first")
    func describeChain() {
        let leaf = NSError(domain: NSOSStatusErrorDomain, code: -12_881, userInfo: [NSLocalizedDescriptionKey: "bad data"])
        let mid = NSError(domain: NSURLErrorDomain, code: -1011, userInfo: [NSUnderlyingErrorKey: leaf])
        let top = NSError(domain: AVFoundationErrorDomain, code: -11_828, userInfo: [NSUnderlyingErrorKey: mid, NSLocalizedDescriptionKey: "Cannot Open"])
        let line = PlaybackFailurePolicy.describe(top)
        #expect(line.contains("AVFoundationErrorDomain -11828"))
        #expect(line.contains("NSURLErrorDomain -1011"))
        #expect(line.contains("NSOSStatusErrorDomain -12881"))
        #expect(line.contains("Cannot Open"))
        let avIndex = line.range(of: "AVFoundationErrorDomain")!.lowerBound
        let osIndex = line.range(of: "NSOSStatusErrorDomain")!.lowerBound
        #expect(avIndex < osIndex)
    }

    @Test("describe: nil is said plainly, never an empty string")
    func describeNil() {
        #expect(PlaybackFailurePolicy.describe(nil) == "no error object")
    }

    @Test("describe: an error with no underlying link is one domain and code")
    func describeFlat() {
        let line = PlaybackFailurePolicy.describe(URLError(.timedOut))
        #expect(line.contains("NSURLErrorDomain -1001"))
        #expect(!line.contains("←"))
    }
}
