import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// T677. The owner heard "a slight pause" at both transport crossings of a blend: queue player
/// → engine at the handoff, engine → queue player at the handback. There are no crossings now:
/// the outgoing song never leaves its player, the incoming song starts on its own `AVQueuePlayer`
/// at a scheduled host time and that very player becomes the queue player once the outgoing has
/// faded. Real audio on the simulator through the real `PlaybackEngine` paths (periodic observer,
/// arming, promotion, adoption, settle, pause, resume).
@MainActor
@Suite("AutoMix single transport (T677)")
struct AutoMixSingleTransportTests {
    struct Fixture {
        let player: PlaybackEngine
        let tracks: [Track]
        let a: URL
        let b: URL
        let dir: URL
        let outgoingItem: AVPlayerItem
        let outgoingPlayer: AVQueuePlayer
        /// A third song, when the test asked for one.
        let c: URL?
    }

    /// Two real files on a real tapped queue player, playing `a`, with a crossfade into `b`
    /// pending at `mixOut`. With `thirdSeconds` a third song `c` of that length follows `b`.
    static func start(mixOut: Double, overlap: Double, gainDB: Float = 0, thirdSeconds: Int? = nil) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = try audioFile(in: dir, name: "a", seconds: 8)
        let b = try audioFile(in: dir, name: "b", seconds: 12)
        var tracks = [track("a", duration: 8), track("b", duration: 12)]
        var c: URL?
        if let thirdSeconds {
            c = try audioFile(in: dir, name: "c", seconds: thirdSeconds)
            tracks.append(track("c", duration: Double(thirdSeconds)))
        }
        let player = PlaybackEngine()
        player.restore(library: nil, snapshot: PlaybackQueueSnapshot(
            queue: tracks, currentIndex: 0, position: 0, playlistSource: nil,
            shuffle: false, repeatMode: "off", savedAt: Date()
        ))
        player.equalizerEnabled = true
        player.equalizerBandGains = [6, 4, 2, 0, 0, 0, 2, 4, 6, 6]
        player.autoMixEnabled = true
        let asset = AVURLAsset(url: a, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (item, tap) = await TapPlayerItem.make(asset: asset, track: tracks[0], gains: player.equalizerBandGains, bypassed: false, eligibleForEqualizer: true)
        let outgoing = AVQueuePlayer(playerItem: item)
        for _ in 0 ..< 300 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.status == .readyToPlay)
        player.installTransportForTesting(outgoing, item: item, track: tracks[0], tap: tap, play: true)
        for _ in 0 ..< 100 where outgoing.rate == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let plan = CrossfadePlan(outgoingMixOut: mixOut, incomingMixIn: 0.5, duration: overlap, incomingGainDB: gainDB, filterSweep: true, reason: .tempoMismatch)
        player.autoMix.pending = (.crossfade(plan), 1, tracks[1], b)
        return Fixture(player: player, tracks: tracks, a: a, b: b, dir: dir, outgoingItem: item, outgoingPlayer: outgoing, c: c)
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 40) where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test("the incoming item that starts the overlap is the transport item after the blend; the two players agree to the millisecond; nothing is reloaded")
    func noCrossing() async throws {
        let f = try await Self.start(mixOut: 2.5, overlap: 1.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        // Armed in the lead-in (the periodic observer arms 6 s ahead, i.e. at once here).
        try await Self.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        let incomingItem = blend.incomingItem
        #expect(player.transportPlayerItem === f.outgoingItem)        // the outgoing never left its player
        #expect(player.currentIndex == 0)
        #expect(abs(blend.mixOut - 2.5) < 1e-9 && abs(blend.mixIn - 0.5) < 1e-9)
        // The blend's gain curve is baked into the incoming item's mix as volume ramps.
        #expect(Self.hasVolumeRamp(incomingItem, at: blend.mixIn + 0.05))

        // Through the overlap: sample the two players' positions against their cue points.
        var offsetsMs: [Double] = []
        var promotedAt: Double = -1
        try await Self.waitUntil(8) {
            if let out = blend.outgoingPosition, let inn = blend.incomingPosition, blend.outputSecondsSinceOverlap() > 0.15, !blend.overlapCompleted {
                offsetsMs.append(((inn - blend.mixIn) - (out - blend.mixOut)) * 1000)
            }
            if promotedAt < 0, player.currentIndex == 1 { promotedAt = blend.outputSecondsSinceOverlap() }
            return player.autoMix.incomingAdopted
        }
        print("T677 overlap offsets (incoming − outgoing, ms): \(offsetsMs.map { String(format: "%.1f", $0) }) promotedAt=\(String(format: "%.2f", promotedAt)) s; lead-in corrections (ms): \(blend.leadInCorrections.map { String(format: "%.1f", $0 * 1000) })")
        #expect(!offsetsMs.isEmpty)
        let worst = offsetsMs.map(abs).max() ?? 999
        #expect(worst < 15, Comment(rawValue: "worst offset \(worst) ms"))
        #expect(promotedAt >= 0 && promotedAt < 0.6, Comment(rawValue: "promoted at \(promotedAt)"))

        // Adopted: the transport is the incoming player with the item that started the overlap.
        #expect(player.transportPlayerItem === incomingItem)
        #expect(player.transportPlayer === blend.incoming)
        #expect(player.currentIndex == 1)
        #expect(player.isPlaying)
        #expect(EqualizerTapRegistry.shared.itemTag(forTrackId: "b") != nil)
        #expect(f.outgoingPlayer.currentItem == nil)                  // the old player is stopped
        let incomingTap = try #require(blend.incomingTap)
        let preparesBefore = incomingTap.state.pointee.prepareCount

        // Settled (no trim: right after the overlap): the blend is gone and the same item plays on.
        try await Self.waitUntil(4) { player.autoMix.blend == nil }
        #expect(player.autoMix.blend == nil)
        #expect(player.transportPlayerItem === incomingItem)
        #expect(player.transportPlayer === blend.incoming)
        #expect(blend.incoming.rate == 1)
        // The ramped mix was swapped for the plain one (`AVPlayerItem.audioMix` copies on
        // assignment, so this is checked by content: no ramp at mix-in any more, tap still
        // there) without re-preparing the tap.
        #expect(!Self.hasVolumeRamp(incomingItem, at: blend.mixIn + 0.05))
        #expect(incomingItem.audioMix?.inputParameters.first?.audioTapProcessor != nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(incomingTap.state.pointee.prepareCount == preparesBefore, Comment(rawValue: "prepares \(preparesBefore) → \(incomingTap.state.pointee.prepareCount)"))
        print("T677 tap prepares across the mix swap: \(preparesBefore) → \(incomingTap.state.pointee.prepareCount); position after settle \(player.transportPlayerTime ?? -1)")
        #expect(player.transportPlayerItem === incomingItem)
        #expect((player.transportPlayerTime ?? 0) > 1.0)
    }

    @Test("pause in the lead-in and resume: both players restart together and the overlap still lands")
    func pauseInLeadIn() async throws {
        let f = try await Self.start(mixOut: 3.0, overlap: 0.8)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Self.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        #expect(blend.outputSecondsSinceOverlap() < 0)
        player.pausePlayback()
        #expect(player.autoMix.blendPaused && blend.isPaused && !player.isPlaying)
        #expect(f.outgoingPlayer.rate == 0 && blend.incoming.rate == 0)
        try await Task.sleep(for: .milliseconds(700))
        #expect(player.autoMix.blend === blend)                        // still armed, not torn down
        player.resumePlaybackFromRemoteCommand()
        #expect(player.isPlaying && !blend.isPaused)
        var offsetsMs: [Double] = []
        try await Self.waitUntil(10) {
            if let out = blend.outgoingPosition, let inn = blend.incomingPosition, blend.outputSecondsSinceOverlap() > 0.15, !blend.overlapCompleted {
                offsetsMs.append(((inn - blend.mixIn) - (out - blend.mixOut)) * 1000)
            }
            return player.autoMix.incomingAdopted
        }
        print("T677 after a lead-in pause, overlap offsets (ms): \(offsetsMs.map { String(format: "%.1f", $0) }); lead-in corrections (ms): \(blend.leadInCorrections.map { String(format: "%.1f", $0 * 1000) })")
        #expect(!offsetsMs.isEmpty)
        #expect((offsetsMs.map(abs).max() ?? 999) < 15)
        #expect(player.transportPlayerItem === blend.incomingItem)
        #expect(player.currentIndex == 1)
    }

    @Test("pause inside the overlap and resume: the overlap continues from where it stopped")
    func pauseInOverlap() async throws {
        let f = try await Self.start(mixOut: 2.0, overlap: 2.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Self.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend)
        try await Self.waitUntil(6) { blend.outputSecondsSinceOverlap() > 0.5 }
        #expect(player.currentIndex == 1)                             // promoted at the overlap start
        #expect(player.togglePlayPauseRoutesToEngine())               // pause
        let remaining = blend.overlapSecondsRemaining
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(blend.overlapSecondsRemaining - remaining) < 0.05) // the clock stopped with the audio
        #expect(player.togglePlayPauseRoutesToEngine())               // resume
        #expect(player.isPlaying)
        try await Self.waitUntil(8) { player.autoMix.incomingAdopted }
        #expect(player.transportPlayerItem === blend.incomingItem)
        try await Self.waitUntil(4) { player.autoMix.blend == nil }
        #expect(player.autoMix.blend == nil && player.isPlaying)
    }

    /// T677 c5, "sometimes the automixer kills the song stream after its transition is over".
    /// A crossfade planned to a short outro runs to the outgoing song's last sample, so the
    /// outgoing item ends at the very moment the overlap completes. When the blend's tick adopts
    /// first, the item's end notification — already posted, its observer removed by the adoption
    /// — still arrives, and used to be read as the *incoming* song's natural end: the queue
    /// advanced off the song that had just blended in. Here the outgoing songs end on their
    /// overlaps' last sample, the stale notifications are delivered by hand after each adoption
    /// (deterministically, in both the live-item and the released-item form), three songs chain
    /// through two blends, and the last one must still be playing 30 s after the second settle.
    @Test("a stale end notification from the outgoing item never touches the adopted song; three songs chain and the last keeps playing 30 s after settle")
    func staleEndAndChain() async throws {
        let f = try await Self.start(mixOut: 6.0, overlap: 2.0, thirdSeconds: 45)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Self.waitUntil(6) { player.autoMix.blend != nil }
        let first = try #require(player.autoMix.blend, "not armed: \(player.autoMix.decisionLog)")
        try await Self.waitUntil(12) { player.autoMix.incomingAdopted || player.autoMix.blend == nil }
        #expect(player.transportPlayerItem === first.incomingItem)
        player.handleEnded(endedItem: f.outgoingItem)   // the old item's end, delivered after adoption
        player.handleEnded(endedItem: nil)              // the same, once the old item has been released
        #expect(player.transportPlayerItem === first.incomingItem)
        #expect(player.currentIndex == 1)
        #expect(player.isPlaying)
        try await Self.waitUntil(6) { player.autoMix.blend == nil }
        #expect(player.transportPlayerItem === first.incomingItem)
        #expect(player.transportPlayer === first.incoming)

        // b → c, again ending on b's last sample (b is 12 s: mix-out 10 + 2 s overlap).
        let plan = CrossfadePlan(outgoingMixOut: 10.0, incomingMixIn: 0.5, duration: 2.0, incomingGainDB: 0, filterSweep: true, reason: .tempoMismatch)
        player.autoMix.pending = (.crossfade(plan), 2, f.tracks[2], try #require(f.c))
        try await Self.waitUntil(10) { player.autoMix.blend != nil }
        let second = try #require(player.autoMix.blend, "second blend not armed: \(player.autoMix.decisionLog)")
        #expect(second.incomingItem !== first.incomingItem)
        try await Self.waitUntil(14) { player.autoMix.incomingAdopted || player.autoMix.blend == nil }
        #expect(player.transportPlayerItem === second.incomingItem)
        player.handleEnded(endedItem: first.incomingItem)
        player.handleEnded(endedItem: nil)
        try await Self.waitUntil(6) { player.autoMix.blend == nil }
        #expect(player.transportPlayerItem === second.incomingItem)
        #expect(player.currentIndex == 2)

        // 30 s after the settle: same item on the same player, playing, time advancing.
        var samples: [Double] = []
        for _ in 0 ..< 30 {
            try await Task.sleep(for: .seconds(1))
            samples.append(player.transportPlayerTime ?? -1)
            guard player.transportPlayerItem === second.incomingItem, player.isPlaying else { break }
        }
        print("T677 c5 positions after settle (s): \(samples.map { String(format: "%.1f", $0) })")
        #expect(samples.count == 30)
        #expect(player.transportPlayerItem === second.incomingItem)
        #expect(player.transportPlayer === second.incoming)
        #expect(player.isPlaying && (player.transportPlayer?.rate ?? 0) == 1)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1 > $0 + 0.5 })
        #expect((samples.last ?? 0) > 30)
    }

    @Test("a seek during the overlap adopts the incoming song and seeks it on the queue player")
    func seekDuringOverlap() async throws {
        let f = try await Self.start(mixOut: 2.0, overlap: 2.0)
        defer { try? FileManager.default.removeItem(at: f.dir); f.player.reset() }
        let player = f.player
        try await Self.waitUntil(6) { player.autoMix.blend != nil }
        let blend = try #require(player.autoMix.blend)
        try await Self.waitUntil(6) { blend.outputSecondsSinceOverlap() > 0.4 }
        player.seek(toSeconds: 6)
        try await Self.waitUntil(4) { player.autoMix.blend == nil && (player.transportPlayerTime ?? 0) > 5.5 }
        #expect(player.autoMix.blend == nil)
        #expect(player.currentIndex == 1)
        #expect(player.transportPlayerItem === blend.incomingItem)
        #expect((player.transportPlayerTime ?? 0) > 5.5)
        #expect(f.outgoingPlayer.currentItem == nil)
    }

    /// Whether the item's audio mix carries a volume ramp covering item time `seconds`.
    static func hasVolumeRamp(_ item: AVPlayerItem, at seconds: TimeInterval) -> Bool {
        guard let parameters = item.audioMix?.inputParameters.first else { return false }
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        return parameters.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 44_100), startVolume: &start, endVolume: &end, timeRange: &range)
    }

    static func track(_ id: String, duration: Double) -> Track {
        Track(id: id, title: id, albumId: "album", albumTitle: "Album", artist: "Artist",
              duration: duration, discNumber: 1, indexNumber: 1, artworkURL: nil)
    }

    /// A quiet 220 Hz tone, so the players have real audio to render.
    static func audioFile(in dir: URL, name: String, seconds: Int) throws -> URL {
        let url = dir.appendingPathComponent(name).appendingPathExtension("caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0 ..< Int(frames) { buffer.floatChannelData![0][i] = 0.1 * sinf(Float(i) * 2 * .pi * 220 / 44_100) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
