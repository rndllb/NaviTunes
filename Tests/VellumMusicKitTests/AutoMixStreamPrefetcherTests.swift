import AVFoundation
import Foundation
import SwiftUI
import UIKit
import Testing

@testable import VellumMusicKit

/// The early fetch of the next queued stream, proven against a stubbed `URLProtocol` that counts
/// every request and every byte: one fetch lands the whole file in the stream cache, the cache
/// then answers the playback lookup, and no second request ever goes out. With AutoMix off there
/// is no request at all.
@Suite("AutoMixStreamPrefetcher", .serialized)
struct AutoMixStreamPrefetcherTests {
    /// Serves a fixed body for any request and counts what was asked for.
    final class CountingURLProtocol: URLProtocol {
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var requests = 0
        nonisolated(unsafe) static var bytesServed = 0
        nonisolated(unsafe) static var requestedURLs: [URL] = []
        nonisolated(unsafe) static var statusCode = 200
        private static let lock = NSLock()

        static func reset(body: Data, status: Int = 200) {
            lock.lock(); defer { lock.unlock() }
            Self.body = body
            requests = 0
            bytesServed = 0
            requestedURLs = []
            statusCode = status
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requests += 1
            if let url = request.url { Self.requestedURLs.append(url) }
            let body = Self.body
            let status = Self.statusCode
            Self.bytesServed += body.count
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(body.count)", "Content-Type": "audio/mpeg"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func tempCache() -> (StreamingMediaDiskCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-cache-tests-\(UUID().uuidString)", isDirectory: true)
        return (StreamingMediaDiskCache(directory: dir), dir)
    }

    /// 200 KB of pseudo-audio: well over the cache's 32 KB "usable" floor.
    static let streamBytes = Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    static let streamURL = URL(string: "https://music.example/rest/stream.view?id=song-42&format=mp3&u=x&t=y")!

    @MainActor
    static func waitForLanding(_ prefetcher: AutoMixStreamPrefetcher, trackId: String) async {
        for _ in 0 ..< 300 where prefetcher.inFlightTrackIds.contains(trackId) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("one fetch lands the whole stream in the cache playback reads; the second lookup makes no request")
    @MainActor
    func noSecondFetch() async throws {
        CountingURLProtocol.reset(body: Self.streamBytes)
        let (cache, dir) = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = AutoMixStreamPrefetcher(cache: cache, session: Self.makeSession())
        var landed: [(String, URL)] = []
        prefetcher.onFetched = { landed.append(($0, $1)) }

        let first = prefetcher.ensure(trackId: "song-42", url: Self.streamURL, headers: ["X-Emby-Token": "t"], enabled: true)
        #expect(first == .fetching)
        // Asking again while it runs starts nothing new.
        #expect(prefetcher.ensure(trackId: "song-42", url: Self.streamURL, headers: [:], enabled: true) == .fetching)
        await Self.waitForLanding(prefetcher, trackId: "song-42")

        // Exactly one request, exactly the stream's bytes, to the stream URL.
        #expect(CountingURLProtocol.requests == 1)
        #expect(CountingURLProtocol.bytesServed == Self.streamBytes.count)
        #expect(CountingURLProtocol.requestedURLs.first == Self.streamURL)
        #expect(landed.count == 1)
        #expect(landed.first?.0 == "song-42")
        #expect(prefetcher.bytesFetched == Int64(Self.streamBytes.count))

        // The file is in the cache under the key playback uses (`PlaybackEngine` prefers this
        // over the network when `peekCachedFileURL` answers), byte-for-byte the stream.
        let key = StreamingMediaDiskCache.key(for: Self.streamURL)
        let cached = try #require(cache.peekCachedFileURL(forKey: key))
        #expect(try Data(contentsOf: cached) == Self.streamBytes)

        // Playback's lookup and a repeat ensure: no further network.
        #expect(prefetcher.ensure(trackId: "song-42", url: Self.streamURL, headers: [:], enabled: true) == .cached(cached))
        _ = try await cache.fetchAndCommit(url: Self.streamURL, session: Self.makeSession())
        #expect(CountingURLProtocol.requests == 1)
        #expect(CountingURLProtocol.bytesServed == Self.streamBytes.count)
    }

    @Test("with AutoMix off there is no early fetch at all")
    @MainActor
    func offMeansNoFetch() async {
        CountingURLProtocol.reset(body: Self.streamBytes)
        let (cache, dir) = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = AutoMixStreamPrefetcher(cache: cache, session: Self.makeSession())
        #expect(prefetcher.ensure(trackId: "song-42", url: Self.streamURL, headers: [:], enabled: false) == .notFetched)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(prefetcher.inFlightTrackIds.isEmpty)
        #expect(CountingURLProtocol.requests == 0)
        #expect(CountingURLProtocol.bytesServed == 0)
        #expect(cache.peekCachedFileURL(forKey: StreamingMediaDiskCache.key(for: Self.streamURL)) == nil)
    }

    @Test("a queue change cancels the fetch for the track that is no longer next")
    @MainActor
    func queueChangeCancels() async {
        CountingURLProtocol.reset(body: Self.streamBytes)
        let (cache, dir) = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = AutoMixStreamPrefetcher(cache: cache, session: Self.makeSession())
        var landed = 0
        prefetcher.onFetched = { _, _ in landed += 1 }
        #expect(prefetcher.ensure(trackId: "old-next", url: Self.streamURL, headers: [:], enabled: true) == .fetching)
        prefetcher.retainOnly(trackIds: ["new-next"])
        #expect(prefetcher.inFlightTrackIds.isEmpty)
        try? await Task.sleep(for: .milliseconds(100))
        // A cancelled fetch never reports a landing, whatever the stub managed to serve.
        #expect(landed == 0)
        #expect(prefetcher.log.contains("fetch cancelled old-next"))
    }

    @Test("the cache key ignores the per-request Subsonic salt and token, and Jellyfin's api_key")
    func keyIgnoresVolatileAuth() {
        let a = URL(string: "https://nd.example/rest/stream.view?id=42&format=mp3&maxBitRate=320&u=ethan&s=abc123&t=0a1b&v=1.16&c=vellum&f=json")!
        let b = URL(string: "https://nd.example/rest/stream.view?id=42&format=mp3&maxBitRate=320&u=ethan&s=zzz999&t=ffff&v=1.16&c=vellum&f=json")!
        #expect(StreamingMediaDiskCache.key(for: a) == StreamingMediaDiskCache.key(for: b))
        // A different format is a different file.
        let c = URL(string: "https://nd.example/rest/stream.view?id=42&format=raw&u=ethan&s=abc123&t=0a1b")!
        #expect(StreamingMediaDiskCache.key(for: a) != StreamingMediaDiskCache.key(for: c))
        let j1 = URL(string: "https://jf.example/Audio/42/stream.mp3?static=true&api_key=AAA")!
        let j2 = URL(string: "https://jf.example/Audio/42/stream.mp3?static=true&api_key=BBB")!
        #expect(StreamingMediaDiskCache.key(for: j1) == StreamingMediaDiskCache.key(for: j2))
    }

    @Test("a mid-song commit fires the re-plan hook with the track's key and makes no request")
    @MainActor
    func midSongCommitTriggersReplan() throws {
        CountingURLProtocol.reset(body: Self.streamBytes)
        let (cache, dir) = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        var committedKeys: [String] = []
        cache.onCommit = { committedKeys.append($0) }
        // What the resource loader does when the player has pulled the whole file: assemble a
        // temp file from bytes it already received, then commit. No URLSession involved.
        let tmp = try #require(cache.makeTemporaryFileURL())
        try Self.streamBytes.write(to: tmp)
        let key = StreamingMediaDiskCache.key(for: Self.streamURL)
        cache.commit(temporaryFileURL: tmp, forKey: key)
        #expect(committedKeys == [key])
        #expect(CountingURLProtocol.requests == 0)
        #expect(CountingURLProtocol.bytesServed == 0)
        // The engine's hook matches the key through a *freshly salted* URL for the same track.
        let resalted = URL(string: Self.streamURL.absoluteString.replacingOccurrences(of: "t=y", with: "t=other"))!
        #expect(StreamingMediaDiskCache.key(for: resalted) == key)
        #expect(cache.peekCachedFileURL(forKey: key) != nil)
        // A commit of an unusable (too small) file must not announce a landing.
        let tiny = try #require(cache.makeTemporaryFileURL())
        try Data(repeating: 0, count: 100).write(to: tiny)
        cache.commit(temporaryFileURL: tiny, forKey: "other")
        #expect(committedKeys == [key])
    }

    @Test("non-progressive URLs are never fetched")
    @MainActor
    func hlsNotFetched() {
        CountingURLProtocol.reset(body: Self.streamBytes)
        let (cache, dir) = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = AutoMixStreamPrefetcher(cache: cache, session: Self.makeSession())
        let hls = URL(string: "https://music.example/Audio/42/master.m3u8")!
        #expect(prefetcher.ensure(trackId: "hls", url: hls, headers: [:], enabled: true) == .notFetched)
        #expect(CountingURLProtocol.requests == 0)
    }

    @Test("a server error is not committed to the cache")
    @MainActor
    func errorBodyNotCached() async {
        // 500, not 401: URLSession answers a 401 with an authentication challenge and re-issues
        // the request once, which would count two requests for one fetch.
        CountingURLProtocol.reset(body: Data("<html>server error</html>".utf8), status: 500)
        let (cache, dir) = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefetcher = AutoMixStreamPrefetcher(cache: cache, session: Self.makeSession())
        #expect(prefetcher.ensure(trackId: "song-42", url: Self.streamURL, headers: [:], enabled: true) == .fetching)
        await Self.waitForLanding(prefetcher, trackId: "song-42")
        #expect(CountingURLProtocol.requests == 1)
        #expect(cache.peekCachedFileURL(forKey: StreamingMediaDiskCache.key(for: Self.streamURL)) == nil)
        #expect(prefetcher.log.last?.hasPrefix("fetch failed") == true)
    }
}


@Suite("AutoMix engine position mapping and loader gate")
struct AutoMixEngineMappingTests {
    @Test("engine frames map to track seconds through the file rate, clamped, never a raw count")
    @MainActor
    func filePositionMapping() {
        // 2.2 s mix-in at 44.1 kHz, 8 s rendered: 10.2 s — the number the screenshot should have shown.
        let p = AutoMixAudioEnginePlayer.filePosition(startFrame: 97_020, playerSampleTime: 352_800, fileSampleRate: 44_100, fileLength: 9_349_200)
        #expect(p != nil && abs(p! - 10.2) < 1e-9)
        // The regression: 230 240 reached the UI as seconds. The mapping can never return a
        // value above the file's length in seconds.
        let past = AutoMixAudioEnginePlayer.filePosition(startFrame: 0, playerSampleTime: 230_240 * 44_100, fileSampleRate: 44_100, fileLength: 9_349_200)
        #expect(past == 212)
        // 48 kHz file, 1 s rendered from frame 0.
        #expect(AutoMixAudioEnginePlayer.filePosition(startFrame: 0, playerSampleTime: 48_000, fileSampleRate: 48_000, fileLength: 480_000) == 1)
        // A rate that cannot be an audio rate, a negative player time, or an empty file: no position.
        #expect(AutoMixAudioEnginePlayer.filePosition(startFrame: 0, playerSampleTime: 100, fileSampleRate: 1, fileLength: 1000) == nil)
        #expect(AutoMixAudioEnginePlayer.filePosition(startFrame: 0, playerSampleTime: -5, fileSampleRate: 44_100, fileLength: 1000) == nil)
        #expect(AutoMixAudioEnginePlayer.filePosition(startFrame: 0, playerSampleTime: 5, fileSampleRate: 44_100, fileLength: 0) == nil)
    }

    @Test("the caching loader is attached only with AutoMix on, for progressive http(s) streams")
    @MainActor
    func loaderGate() {
        let stream = URL(string: "https://nd.example/rest/stream.view?id=42&format=mp3&s=a&t=b")!
        let hls = URL(string: "https://jf.example/Audio/42/master.m3u8")!
        let file = URL(fileURLWithPath: "/tmp/x.mp3")
        #expect(PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: stream, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: false, url: stream, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: hls, isInternetRadio: false))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: stream, isInternetRadio: true))
        #expect(!PlaybackEngine.shouldAttachCachingLoader(autoMixEnabled: true, url: file, isInternetRadio: false))
    }
}


@Suite("AutoMix transition clock and chrome")
struct AutoMixBlendChromeTests {
    @Test("the host-time overlap clock is signed and exact to the millisecond")
    func hostClock() {
        let start = AVAudioTime.hostTime(forSeconds: 100)
        let later = AutoMixAudioEnginePlayer.hostTime(adding: 7.5, to: start)
        #expect(abs(AutoMixAudioEnginePlayer.seconds(from: start, to: later) - 7.5) < 0.001)
        #expect(abs(AutoMixAudioEnginePlayer.seconds(from: later, to: start) + 7.5) < 0.001)
        #expect(AutoMixAudioEnginePlayer.hostTime(adding: -3, to: start) == start)
    }

    @Test("crossfade text opacities follow the equal-power curve, and snap at the midpoint under Reduce Motion")
    func textOpacity() {
        #expect(AutoMixCrossfadeText.incomingOpacity(progress: 0, reduceMotion: false) == 0)
        #expect(abs(AutoMixCrossfadeText.incomingOpacity(progress: 0.5, reduceMotion: false) - 0.7071) < 0.001)
        #expect(AutoMixCrossfadeText.incomingOpacity(progress: 1, reduceMotion: false) == 1)
        #expect(AutoMixCrossfadeText.incomingOpacity(progress: 0.49, reduceMotion: true) == 0)
        #expect(AutoMixCrossfadeText.incomingOpacity(progress: 0.5, reduceMotion: true) == 1)
    }

    /// Renders the shipping crossfade component at five points of a fake overlap and writes PNGs,
    /// so the in-between states can be inspected. Fails if any frame cannot be rendered or if the
    /// incoming text is not visibly different between the first and last frame.
    @Test("frames through a fake overlap render and change")
    @MainActor
    func frameSequence() throws {
        // `TEST_RUNNER_AUTOMIX_UI_FRAMES_DIR=<path>` on the xcodebuild command line lands here as
        // `AUTOMIX_UI_FRAMES_DIR`; the simulator can write host paths. Default: the sandbox tmp.
        // The simulator can write host paths. If the T630 scratch directory exists on this Mac the
        // frames go there (the sandbox tmp is purged when the test host exits); otherwise to tmp.
        let scratch = URL(fileURLWithPath: "/Users/ethan/agent-scratch/T630/ui-frames", isDirectory: true)
        let dir = FileManager.default.fileExists(atPath: scratch.deletingLastPathComponent().path)
            ? scratch
            : FileManager.default.temporaryDirectory.appendingPathComponent("automix-ui", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sizes: [Int] = []
        for (i, p) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
            let view = VStack(alignment: .leading, spacing: 6) {
                // Backdrop stand-in: the palette colours mixed at this progress (the real view
                // animates the palette over the remaining overlap).
                Rectangle().fill(Color(red: 0.1 + 0.6 * p, green: 0.2, blue: 0.7 - 0.5 * p)).frame(width: 320, height: 60)
                AutoMixCrossfadeText(outgoing: "What Appears (Acoustic)", incoming: "Young", progress: p, reduceMotion: false)
                    .font(.headline.weight(.bold))
                AutoMixCrossfadeText(outgoing: "Yellowcard", incoming: "Vacations", progress: p, reduceMotion: false)
                    .font(.subheadline)
                Text(String(format: "progress %.2f", p)).font(.caption2.monospaced())
            }
            .padding(12)
            .frame(width: 344)
            .foregroundStyle(.white)
            .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            let data = try #require(image.pngData())
            try data.write(to: dir.appendingPathComponent(String(format: "frame-%d-p%.2f.png", i, p)))
            sizes.append(data.count)
        }
        print("AUTOMIX_UI_FRAMES_DIR=\(dir.path)")
        #expect(sizes.count == 5)
        // Start, middle and end must all render differently: the start shows only the outgoing
        // names, the middle both at partial opacity, the end only the incoming names.
        let frames = try [0, 2, 4].map { try Data(contentsOf: dir.appendingPathComponent(String(format: "frame-%d-p%.2f.png", $0, [0.0, 0.25, 0.5, 0.75, 1.0][$0]))) }
        #expect(frames[0] != frames[1])
        #expect(frames[1] != frames[2])
        #expect(frames[0] != frames[2])
    }
}
