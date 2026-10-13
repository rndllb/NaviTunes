import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// T643 c3. Pure pieces of the two transport defects found in the AutoMix audit.
///
/// 1. The transition clock runs on host time, and host time does not stop for a pause. A pause
///    during the arm lead or the overlap therefore made the automation believe the overlap had
///    advanced by the length of the pause, and `resume()` started a not-yet-started incoming deck
///    immediately instead of at its scheduled host time. (The pause/resume of a live blend is in
///    `AutoMixSingleTransportTests` since T677.)
/// 2. A queue edit between planning and the hand-off (Play Next, a removal) left `autoMix.pending`
///    pointing at an index whose track had changed; the hand-off did not check, so the engine
///    blended into the wrong file and promotion then refused to move the cursor.
@Suite("AutoMix audit fixes")
struct AutoMixAuditFixesTests {
    // MARK: 1. the clock survives a pause

    @Test("an anchor is pushed forward by exactly the paused interval")
    func anchorShift() {
        let anchor: UInt64 = 1_000_000
        #expect(AutoMixHostClock.resumedAnchor(anchor, pausedAt: 1_500_000, resumedAt: 1_900_000) == 1_400_000)
    }

    @Test("a zero-length pause leaves the anchor alone")
    func zeroPause() {
        #expect(AutoMixHostClock.resumedAnchor(42, pausedAt: 100, resumedAt: 100) == 42)
    }

    @Test("a clock that went backwards never pulls the anchor back")
    func monotonic() {
        #expect(AutoMixHostClock.resumedAnchor(42, pausedAt: 100, resumedAt: 90) == 42)
    }

    @Test("an unset anchor (0) stays unset: the overlap has not been scheduled yet")
    func unsetAnchor() {
        #expect(AutoMixHostClock.resumedAnchor(0, pausedAt: 100, resumedAt: 500) == 0)
    }

    // MARK: 2. a stale pending target is never handed off

    @Test("the pending target matches when the queue still holds that track at that index")
    func pendingMatches() {
        let queue = [Self.track("a"), Self.track("b"), Self.track("c")]
        #expect(PlaybackEngine.pendingTargetMatches(queue: queue, index: 1, trackId: "b"))
    }

    @Test("a Play Next insert that moved the target off its index invalidates it")
    func pendingMovedByInsert() {
        let queue = [Self.track("a"), Self.track("x"), Self.track("b")]
        #expect(!PlaybackEngine.pendingTargetMatches(queue: queue, index: 1, trackId: "b"))
    }

    @Test("an index past the end of a shortened queue invalidates it")
    func pendingPastEnd() {
        let queue = [Self.track("a")]
        #expect(!PlaybackEngine.pendingTargetMatches(queue: queue, index: 1, trackId: "b"))
        #expect(!PlaybackEngine.pendingTargetMatches(queue: [], index: 0, trackId: "a"))
    }

    // MARK: helpers

    private static func track(_ id: String) -> Track {
        Track(id: id, title: id, albumId: "album", albumTitle: "Album", artist: "Artist",
              duration: 200, discNumber: 1, indexNumber: 1, artworkURL: nil)
    }

    private static func audioFile(in dir: URL, name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }
}
