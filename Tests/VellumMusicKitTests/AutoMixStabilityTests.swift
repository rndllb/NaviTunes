import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// T696. The owner: "lot of instability with vellum now with automix". Every test here fails on
/// d007856 and pins one way a blend could leave the song silent, misreport play/pause, keep a
/// blend's gain curve on a song after the blend was gone, or take the process down. Real audio on
/// the simulator through the real `PlaybackEngine` paths, on the T677 fixture.
@MainActor
@Suite("AutoMix stability (T696)")
struct AutoMixStabilityTests {
    typealias Harness = AutoMixSingleTransportTests

    static func postInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if shouldResume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    /// Start volume of the ramp covering item time `seconds`, or nil when the mix has none there.
    static func mixVolume(_ item: AVPlayerItem, at seconds: TimeInterval) -> Float? {
        guard let parameters = item.audioMix?.inputParameters.first else { return nil }
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        guard parameters.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 44_100), startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
        return start
    }

    /// F1. A phone call in the lead-in. iOS stops every player and posts the interruption; the
    /// engine must stop the blend's clock with them, keep reporting paused, and on the call's end
    /// restart both players so the overlap still lands. On d007856 the blend's progress timer
    /// forced `isPlaying` back to true within 0.35 s, the automation ran through the silence on the
    /// host clock and adopted an incoming player that had never started.
    @Test("an audio interruption pauses the blend; when it ends both players resume and the overlap lands")
    func interruptionDuringLeadIn() async throws {
        let f = try await Harness.start(mixOut: 4.5, overlap: 1.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        player.bind()   // the audio-session observers
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        try await Task.sleep(for: .seconds(2))   // past the play-intent window; still in the lead-in
        #expect(blend.outputSecondsSinceOverlap() < 0)
        #expect(player.isPlaying)

        // What iOS does on a call: the players stop, then the notification arrives.
        f.outgoingPlayer.pause()
        blend.incoming.pause()
        Self.postInterruption(.began)
        try await Task.sleep(for: .milliseconds(900))   // more than two progress-timer ticks
        #expect(blend.isPaused, "the blend's clock did not stop with the audio")
        #expect(player.autoMix.blendPaused)
        #expect(!player.isPlaying, "reported playing while every player was stopped")
        let remaining = blend.overlapSecondsRemaining
        // Long enough that, on the host clock, the planned mix-out and overlap have both passed.
        try await Task.sleep(for: .seconds(3))
        #expect(!player.isPlaying)
        #expect(player.autoMix.blend === blend && !player.autoMix.incomingAdopted, "the blend ran on through the call")
        #expect(abs(blend.overlapSecondsRemaining - remaining) < 0.05)
        #expect(f.outgoingPlayer.rate == 0 && blend.incoming.rate == 0)

        // The call ends and the system says resume.
        Self.postInterruption(.ended, shouldResume: true)
        try await Harness.waitUntil(2) { player.isPlaying && f.outgoingPlayer.rate > 0 }
        print("T696 after .ended: isPlaying=\(player.isPlaying) blendPaused=\(blend.isPaused) outgoing rate=\(f.outgoingPlayer.rate) at \(blend.outgoingPosition ?? -1) s, incoming rate=\(blend.incoming.rate); log: \(player.autoMix.decisionLog.suffix(4))")
        #expect(player.isPlaying && f.outgoingPlayer.rate > 0 && !blend.isPaused, "the blend did not resume when the interruption ended")
        var offsetsMs: [Double] = []
        try await Harness.waitUntil(10) {
            if let out = blend.outgoingPosition, let inn = blend.incomingPosition, blend.outputSecondsSinceOverlap() > 0.15, !blend.overlapCompleted {
                offsetsMs.append(((inn - blend.mixIn) - (out - blend.mixOut)) * 1000)
            }
            return player.autoMix.incomingAdopted
        }
        print("T696 after an interruption, overlap offsets (ms): \(offsetsMs.map { String(format: "%.1f", $0) }); corrections (ms): \(blend.leadInCorrections.map { String(format: "%.1f", $0 * 1000) })")
        #expect(!offsetsMs.isEmpty, "the incoming never played after the interruption")
        #expect((offsetsMs.map(abs).max() ?? 999) < 15)
        #expect(player.transportPlayerItem === blend.incomingItem)
        #expect(player.isPlaying && (player.transportPlayer?.rate ?? 0) == 1)
        try await Harness.waitUntil(4) { player.autoMix.blend == nil }
        let t0 = player.transportPlayerTime ?? -1
        try await Task.sleep(for: .seconds(1))
        #expect((player.transportPlayerTime ?? -1) > t0 + 0.5, "the adopted song is not advancing")
    }

    /// F1, the other shape: headphones unplugged (or a Bluetooth route gone) inside the overlap.
    /// The system pauses the players; nothing posts to the engine but the player's own
    /// `timeControlStatus`. The blend must follow it, and one tap on play must bring both players
    /// back. On d007856 the tap *paused* the (already silent) blend, so it took two.
    @Test("a system pause with no notification pauses the blend; one play tap resumes it")
    func externalPauseDuringOverlap() async throws {
        let f = try await Harness.start(mixOut: 2.5, overlap: 3.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend)
        try await Harness.waitUntil(6) { blend.outputSecondsSinceOverlap() > 0.6 }
        #expect(player.currentIndex == 1)
        f.outgoingPlayer.pause()
        blend.incoming.pause()
        try await Task.sleep(for: .milliseconds(900))
        #expect(blend.isPaused && player.autoMix.blendPaused, "the blend did not notice the system pause")
        #expect(!player.isPlaying)
        player.togglePlayPause()
        try await Harness.waitUntil(2) { f.outgoingPlayer.rate > 0 && blend.incoming.rate > 0 }
        #expect(f.outgoingPlayer.rate > 0 && blend.incoming.rate > 0 && player.isPlaying, "one play tap did not resume both players")
        try await Harness.waitUntil(8) { player.autoMix.incomingAdopted }
        #expect(player.transportPlayerItem === blend.incomingItem)
        #expect(player.isPlaying && (player.transportPlayer?.rate ?? 0) == 1)
        try await Harness.waitUntil(4) { player.autoMix.blend == nil }
        #expect(player.autoMix.blend == nil && player.isPlaying)
    }

    /// F2. A streamed current song keeps `automaticallyWaitsToMinimizeStalling` at its default
    /// (`loadAVPlayerItem` clears it for file URLs only). `AutoMixPlayerBlend.resume` restarts the
    /// outgoing with `setRate(_:time:atHostTime:)`, which AVPlayer.h documents as raising
    /// `NSInvalidArgumentException` when that flag is true: pause and resume during a blend of a
    /// streamed song took the process down. The flag must be cleared on the outgoing before the
    /// blend is armed.
    @Test("the outgoing player is made safe for a host-time restart before the blend is armed; pause and resume then land the overlap")
    func resumeOnAStreamedOutgoing() async throws {
        let f = try await Harness.start(mixOut: 4.0, overlap: 1.0, waitsToMinimizeStalling: true)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        #expect(!f.outgoingPlayer.automaticallyWaitsToMinimizeStalling, "setRate(_:time:atHostTime:) on this player raises NSInvalidArgumentException")
        // On d007856 the resume below would raise and take the whole test runner down; the
        // failure is recorded above and the test stops here.
        guard !f.outgoingPlayer.automaticallyWaitsToMinimizeStalling else { return }
        try await Task.sleep(for: .seconds(2))
        #expect(blend.outputSecondsSinceOverlap() < 0)
        player.pausePlayback()
        #expect(blend.isPaused && !player.isPlaying && f.outgoingPlayer.rate == 0)
        try await Task.sleep(for: .milliseconds(500))
        player.resumePlaybackFromRemoteCommand()
        #expect(player.isPlaying && !blend.isPaused)
        var offsetsMs: [Double] = []
        try await Harness.waitUntil(10) {
            if let out = blend.outgoingPosition, let inn = blend.incomingPosition, blend.outputSecondsSinceOverlap() > 0.15, !blend.overlapCompleted {
                offsetsMs.append(((inn - blend.mixIn) - (out - blend.mixOut)) * 1000)
            }
            return player.autoMix.incomingAdopted
        }
        print("T696 streamed-outgoing pause/resume, overlap offsets (ms): \(offsetsMs.map { String(format: "%.1f", $0) })")
        #expect(!offsetsMs.isEmpty)
        #expect((offsetsMs.map(abs).max() ?? 999) < 15)
        #expect(player.transportPlayerItem === blend.incomingItem)
        try await Harness.waitUntil(4) { player.autoMix.blend == nil }
        #expect(player.isPlaying && (player.transportPlayer?.rate ?? 0) == 1)
    }

    /// F3. The incoming item carries the blend's gain curve as volume ramps, 0 from time zero up to
    /// the mix-in. Settling swaps in the plain mix; an abort (a scrub or the toggle during the
    /// overlap or the settle) did not, so the song the user kept played silence from its start to
    /// its mix-in — 8–22 s on real songs — after a seek back, or after "previous".
    @Test("a scrub during the overlap leaves the adopted song with a plain mix: a seek before the mix-in plays at full level")
    func seekBeforeMixInAfterAbort() async throws {
        let f = try await Harness.start(mixOut: 2.0, overlap: 2.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend)
        let item = blend.incomingItem
        try await Harness.waitUntil(6) { blend.outputSecondsSinceOverlap() > 0.6 }
        #expect(player.currentIndex == 1)
        #expect(Harness.hasVolumeRamp(item, at: blend.mixIn + 0.05))   // ramped while blending
        #expect(Self.mixVolume(item, at: 0.1) == 0)                      // and silent before the mix-in
        player.seek(toSeconds: 0.1)   // where "previous" lands: before the mix-in (0.5)
        try await Harness.waitUntil(4) { player.autoMix.blend == nil && (player.transportPlayerTime ?? 9) < 0.45 }
        #expect(player.autoMix.blend == nil)
        #expect(player.transportPlayerItem === item)
        #expect((player.transportPlayerTime ?? 9) < 0.45)
        #expect(!Harness.hasVolumeRamp(item, at: blend.mixIn + 0.05), "the blend's ramps outlived the blend")
        #expect(Self.mixVolume(item, at: 0.1) ?? 1 == 1, "silent before the mix-in after the blend was gone")
        #expect(item.audioMix?.inputParameters.first?.audioTapProcessor != nil)   // the tap stays
        #expect(player.isPlaying && (player.transportPlayer?.rate ?? 0) == 1)
    }

    /// F4. A queue edit in the lead-in that changes what is next (Play Next, a reorder, shuffle).
    /// The armed blend was aimed at a row that is no longer next; on d007856 it played the old
    /// song through the whole overlap anyway, failed to promote, dropped it at adoption and put
    /// the outgoing back to full level on its last seconds. The blend must be abandoned the moment
    /// the queue changes under it, leaving the outgoing untouched and the boundary to the gapless
    /// staging of the new next song.
    @Test("a queue edit in the lead-in abandons the armed blend; the outgoing plays on and the new next song follows")
    func queueEditInLeadIn() async throws {
        let f = try await Harness.start(mixOut: 4.0, overlap: 1.0, thirdSeconds: 10)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Harness.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend)
        #expect(blend.outputSecondsSinceOverlap() < 0)
        let incomingPlayer = blend.incoming
        player.moveUpNextItem(from: IndexSet(integer: 1), to: 0)   // c now plays before b
        #expect(player.queue.map(\.id) == ["a", "c", "b"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.autoMix.blend == nil, "the blend into b stayed armed after b stopped being next")
        #expect(incomingPlayer.currentItem == nil, "the staged incoming player was kept")
        #expect(f.outgoingPlayer.volume == 1 && f.outgoingPlayer.rate > 0)
        #expect(player.transportPlayerItem === f.outgoingItem && player.currentIndex == 0 && player.isPlaying)
        // Through the planned mix-out and overlap (4.0–5.0 s) the outgoing keeps playing at full
        // level on its own player and the old incoming never starts.
        try await Harness.waitUntil(8) { (f.outgoingPlayer.currentTime().seconds) > 5.3 }
        #expect(f.outgoingPlayer.volume == 1 && f.outgoingPlayer.rate > 0 && player.isPlaying)
        #expect(player.transportPlayerItem === f.outgoingItem && player.currentIndex == 0)
        #expect(incomingPlayer.currentItem == nil && incomingPlayer.rate == 0)
        #expect(player.autoMix.blend == nil)
        // At the outgoing's own end the engine moves to the new next song. (This harness has no
        // library and no offline store, so the gapless load of c itself cannot happen here; the
        // chain through real boundaries is covered by `staleEndAndChain`.)
        try await Harness.waitUntil(6) { player.currentIndex != 0 }
        #expect(player.activeTrack?.id == "c", "landed on \(player.activeTrack?.id ?? "nothing")")
    }
}
