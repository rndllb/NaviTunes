import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// T960. The owner: "sometimes automix fails and the song still cuts off early but doesn't
/// autofade into the next one. it just stops early and the new song starts from 0."
/// When a blend cannot run, the outgoing song must play to its real end and the next song start
/// the ordinary way; it must never be silenced or cut at the planned mix point. Real audio on the
/// simulator through the real `PlaybackEngine` paths (`AutoMixSingleTransportTests.start`:
/// a = 8 s playing, b = 12 s next, a crossfade a → b pending).
@MainActor
@Suite("AutoMix blend failures (T960)")
struct AutoMixBlendFailureTests {
    typealias Harness = AutoMixSingleTransportTests

    /// Keeps `player` from producing audio from the moment its scheduled start comes due: what a
    /// stalled or failed incoming item looks like to the engine.
    static func holdSilent(_ player: AVQueuePlayer, while condition: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled, condition() {
                if player.rate != 0 { player.pause() }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test("the incoming player never starts: the outgoing is not faded or cut, stays the current song and plays to its own end")
    func incomingNeverStarts() async throws {
        let f = try await Harness.start(mixOut: 3.0, overlap: 2.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        let incoming = blend.incoming
        // From the scheduled start on, the incoming player makes no sound.
        try await Harness.waitUntil(6) { blend.outputSecondsSinceOverlap() >= -0.01 }
        let silencer = Self.holdSilent(incoming) { f.outgoingPlayer.currentTime().seconds < 7.5 }
        defer { silencer.cancel() }

        // Past the planned overlap (3.0–5.0 s): the outgoing is still the song, at full level.
        try await Harness.waitUntil(8) { f.outgoingPlayer.currentTime().seconds > 5.6 }
        print("T960 incoming-never-starts: outgoing at \(f.outgoingPlayer.currentTime().seconds) s volume \(f.outgoingPlayer.volume) rate \(f.outgoingPlayer.rate); index \(player.currentIndex); log \(player.autoMix.decisionLog.suffix(3))")
        #expect(player.autoMix.blend == nil, "the blend stayed armed with a silent incoming player")
        #expect(f.outgoingPlayer.volume == 1, "the outgoing was faded into silence")
        #expect(f.outgoingPlayer.rate > 0 && player.isPlaying)
        #expect(player.transportPlayerItem === f.outgoingItem, "the outgoing was cut at the mix point")
        #expect(player.currentIndex == 0, "the queue moved to b while b made no sound")
        #expect(incoming.currentItem == nil, "the failed incoming player was kept")
        #expect(player.autoMix.failedBoundary == "a→b")
        #expect(player.autoMix.pending == nil, "the failed boundary was planned again")

        // At the outgoing's own end the engine moves on to b the normal way.
        try await Harness.waitUntil(6) { player.currentIndex != 0 }
        #expect(player.activeTrack?.id == "b")
    }

    @Test("the outgoing file is shorter than planned (it ends before the mix-out): normal transition at its real end, no silent wait for the blend")
    func outgoingEndsBeforeMixOut() async throws {
        // Planned as if the song were 3 s longer than its 8 s file: the blend is armed at 5 s
        // (6 s ahead) and its incoming is scheduled for 11 s, after the file has ended.
        let f = try await Harness.start(mixOut: 11.0, overlap: 1.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(8) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        let incoming = blend.incoming
        #expect(blend.outputSecondsSinceOverlap() < -2)

        // The file ends at 8 s; well before the planned 11 s the engine has moved on.
        try await Harness.waitUntil(8) { player.currentIndex != 0 }
        let endedAt = Date()
        try await Task.sleep(for: .milliseconds(400))
        print("T960 short-file: index \(player.currentIndex) blend \(player.autoMix.blend == nil ? "gone" : "armed") incoming rate \(incoming.rate) item \(incoming.currentItem == nil ? "nil" : "set"); log \(player.autoMix.decisionLog.suffix(3))")
        #expect(player.activeTrack?.id == "b")
        #expect(player.autoMix.blend == nil, "the engine waited in silence for a blend whose outgoing had already ended")
        #expect(incoming.currentItem == nil, "the blend's incoming player was adopted to start late, after a silent gap")
        #expect(player.transportPlayer !== incoming)
        #expect(Date().timeIntervalSince(endedAt) < 2)
    }

    @Test("the incoming file cannot be loaded: nothing is armed and the outgoing plays through the planned mix point at full level")
    func incomingUnreadable() async throws {
        let f = try await Harness.start(mixOut: 3.0, overlap: 1.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        // Replace the pending blend's file with one AVFoundation cannot open.
        let broken = f.dir.appendingPathComponent("broken").appendingPathExtension("caf")
        try Data(repeating: 0x42, count: 4096).write(to: broken)
        let pending = try #require(player.autoMix.pending)
        player.autoMix.pending = (pending.decision, pending.index, pending.track, broken)

        try await Harness.waitUntil(8) { f.outgoingPlayer.currentTime().seconds > 4.5 }
        print("T960 unreadable incoming: log \(player.autoMix.decisionLog.suffix(3))")
        #expect(player.autoMix.blend == nil)
        #expect(f.outgoingPlayer.volume == 1 && f.outgoingPlayer.rate > 0)
        #expect(player.transportPlayerItem === f.outgoingItem && player.currentIndex == 0 && player.isPlaying)
        #expect(player.autoMix.decisionLog.contains { $0.contains("not armed") })
    }

    @Test("a stall of the outgoing player during the overlap hands over to the playing incoming instead of reloading the new song from its start")
    func stallDuringOverlap() async throws {
        let f = try await Harness.start(mixOut: 3.0, overlap: 3.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        try await Harness.waitUntil(8) { player.currentIndex == 1 }   // promoted: b is the current song
        #expect(!player.autoMix.incomingAdopted)
        let before = blend.incoming.currentTime().seconds

        player.recoverFromPlaybackStall(requireStall: false)   // the stall watchdog fires on the outgoing player

        print("T960 stall in overlap: adopted \(player.autoMix.incomingAdopted) transport is incoming \(player.transportPlayer === blend.incoming); log \(player.autoMix.decisionLog.suffix(2))")
        #expect(player.transportPlayer === blend.incoming, "the new song was reloaded instead of handed over")
        #expect(player.transportPlayerItem === blend.incomingItem)
        #expect(player.currentIndex == 1)
        try await Task.sleep(for: .milliseconds(500))
        #expect((player.transportPlayerTime ?? 0) > before + 0.3, "the incoming did not keep playing from where it was")
        #expect(player.isPlaying)
    }

    @Test("rules: the incoming must be heard within the grace; promotion waits for it; planning uses the shorter of reported and decoded lengths")
    func rules() {
        #expect(!AutoMixPlayerBlend.incomingHasStarted(itemTime: 0.5, mixIn: 0.5))
        #expect(AutoMixPlayerBlend.incomingHasStarted(itemTime: 0.53, mixIn: 0.5))
        #expect(!AutoMixPlayerBlend.incomingHasStarted(itemTime: .nan, mixIn: 0.5))
        #expect(!AutoMixPlayerBlend.incomingFailedToStart(secondsSinceOverlap: 0.39, confirmed: false))
        #expect(AutoMixPlayerBlend.incomingFailedToStart(secondsSinceOverlap: 0.4, confirmed: false))
        #expect(!AutoMixPlayerBlend.incomingFailedToStart(secondsSinceOverlap: 5, confirmed: true))
        #expect(!PlaybackEngine.shouldPromote(overlapProgress: 0.2, incomingConfirmed: false))
        #expect(PlaybackEngine.shouldPromote(overlapProgress: 0.2, incomingConfirmed: true))
        // A decoded file shorter than its reported length plans from the real end…
        #expect(PlaybackEngine.autoMixPlanningDuration(reported: 240, decoded: 236.5) == 236.5)
        // …and server lengths (whole seconds, at most 1 s under the file) plan exactly as before.
        #expect(PlaybackEngine.autoMixPlanningDuration(reported: 240, decoded: 240.9) == 240)
        #expect(PlaybackEngine.autoMixPlanningDuration(reported: 0, decoded: 236.5) == 236.5)
        #expect(PlaybackEngine.autoMixPlanningDuration(reported: 240, decoded: 0) == 240)
        let a = AutoMixSingleTransportTests.track("a", duration: 8), b = AutoMixSingleTransportTests.track("b", duration: 12)
        #expect(PlaybackEngine.autoMixBoundaryKey(current: a, next: b) == "a→b")
        #expect(PlaybackEngine.autoMixBoundaryKey(current: a, next: nil) == nil)
    }
}
