import Foundation
import Testing

@testable import VellumMusicKit

/// #12: "No streaming over cellular" stops streams on cellular while offline copies still play.
@Suite("No streaming over cellular (#12)")
struct CellularStreamingTests {
    static let download = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/VellumMusic/downloads/song-1.flac")
    static let cached = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/Caches/VellumMusic/stream-cache/ab12.cache")
    static let stream = URL(string: "https://music.example/rest/stream.view?id=song-1&u=x&t=y&s=z")!
    static let fallback = URL(string: "https://music.example/rest/download.view?id=song-1")!

    @Test("the switch only bites on a working cellular connection")
    func policy() {
        #expect(CellularStreamingPolicy.blocksStreaming(settingOn: true, online: true, wifiLike: false))
        #expect(!CellularStreamingPolicy.blocksStreaming(settingOn: true, online: true, wifiLike: true))
        #expect(!CellularStreamingPolicy.blocksStreaming(settingOn: false, online: true, wifiLike: false))
        // No network at all: nothing streams anyway, and "cellular is off" would be the wrong reason.
        #expect(!CellularStreamingPolicy.blocksStreaming(settingOn: true, online: false, wifiLike: false))
    }

    @Test("blocked: downloads and stream-cache files still play, network streams are dropped")
    func blockedKeepsLocalCopies() {
        let candidates: [(url: URL, headers: [String: String])] = [
            (Self.download, [:]), (Self.cached, [:]), (Self.stream, ["X": "y"]), (Self.fallback, [:]),
        ]
        let allowed = PlaybackCandidateLadder.allowedCandidates(candidates, streamingBlocked: true)
        #expect(allowed.map(\.url) == [Self.download, Self.cached])
    }

    @Test("blocked with no local copy: nothing may be tried")
    func blockedWithoutLocalCopy() {
        let allowed = PlaybackCandidateLadder.allowedCandidates([(Self.stream, [:]), (Self.fallback, [:])], streamingBlocked: true)
        #expect(allowed.isEmpty)
    }

    @Test("not blocked: every candidate is kept, in order")
    func notBlockedKeepsAll() {
        let candidates: [(url: URL, headers: [String: String])] = [(Self.download, [:]), (Self.stream, [:])]
        #expect(PlaybackCandidateLadder.allowedCandidates(candidates, streamingBlocked: false).map(\.url) == [Self.download, Self.stream])
    }

    @Test("a blocked track is skipped with its own reason, never retried, never blamed on the server")
    func blockedTrackReason() {
        let reason = PlaybackFailurePolicy.classify(CellularStreamingBlockedError())
        #expect(reason == .cellularStreamingOff)
        #expect(!reason.isTransient)
        #expect(!reason.isServerSide)
        #expect(reason.skipClause.contains("cellular"))
    }

    @Test("skipping blocked tracks never trips the 'playback stopped' guard")
    func blockedTracksDoNotHalt() {
        var streak = PlaybackFailureStreak()
        for _ in 0 ..< 10 {
            #expect(streak.recordFailure(.cellularStreamingOff) == nil)
        }
    }
}
