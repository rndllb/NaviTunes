import Foundation
import Testing

@testable import VellumMusicKit

@MainActor
@Suite("AutoMix playback handoff")
struct AutoMixPlaybackHandoffTests {
    @Test("visuals and promotion flip at the START of the overlap, never the midpoint or the outgoing end", arguments: [3.0, 8.0, 24.0])
    func visualTiming(overlap: Double) {
        // Before the incoming deck is audible: outgoing visuals, no promotion.
        #expect(AutoMixVisualState.progress(overlapProgress: 0) == 0)
        #expect(!PlaybackEngine.shouldPromote(overlapProgress: 0))
        // From the first audible moment on — one timer tick (0.35 s) into any overlap length:
        for elapsed in [0.35, overlap * 0.25, overlap * 0.5, overlap * 0.75, overlap] {
            #expect(AutoMixVisualState.progress(overlapProgress: elapsed / overlap) == 1)
            #expect(PlaybackEngine.shouldPromote(overlapProgress: elapsed / overlap))
        }
        #expect(AutoMixVisualState.crossfadeDuration == 0.5)
    }
}
