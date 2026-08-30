import AVFoundation
import Foundation

/// Builds `AVPlayerItem`s that already carry their equalizer tap.
///
/// The order here is not incidental and is the part most easily got wrong:
///
/// 1. Load the asset's audible tracks. `AVMutableAudioMixInputParameters` needs a real track, and
///    a mix built before the tracks are loaded is **silently ignored** — the item plays with no
///    tap, no error is raised, and the only symptom is an equalizer that does nothing.
/// 2. Attach the mix to the item.
/// 3. Only then hand the item to the queue player.
///
/// A tap is attached to **every** item, whether or not the equalizer is on. Bypass is expressed as
/// identity coefficients inside the tap. Attaching or detaching a tap mid-playback is audible —
/// that is the failure this whole branch exists to remove, and doing it "only when the EQ is on"
/// would reintroduce it at the moment the user toggles the switch.
enum TapPlayerItem {
    /// Wraps `asset` in a player item with an equalizer tap attached.
    ///
    /// Returns the item and the tap. The tap is registered, so the caller does not have to retain
    /// it, but the caller **must** call `EqualizerTapRegistry.shared.retire(itemTag:)` when the item
    /// is finished with, or the tap leaks for the life of the process.
    static func make(
        asset: AVAsset,
        track: Track,
        gains: [Float],
        bypassed: Bool,
        eligibleForEqualizer: Bool,
    ) async -> (item: AVPlayerItem, tap: EqualizerAudioTap?) {
        let item = AVPlayerItem(asset: asset)

        // Kill switch, for isolating the tap from everything else on one build:
        //
        //     xcrun simctl spawn booted defaults write com.randll.vellum vellumTapEnabled -bool NO
        //
        // With it off the item is returned bare, so playback is exactly what it would be without
        // this branch. That makes "is the tap responsible for X" a question answerable by toggling
        // a default and relaunching, rather than by building twice — and it is the same switch a
        // tap-vs-no-tap CPU comparison needs on a single binary.
        if UserDefaults.standard.object(forKey: "vellumTapEnabled") != nil,
           !UserDefaults.standard.bool(forKey: "vellumTapEnabled") {
            PlaybackTapLog.tap("no-tap track=\(track.id) title=\"\(track.title)\" reason=kill-switch")
            return (item, nil)
        }

        // Internet radio is HLS-shaped and taps do not work with HLS; those items get no tap at
        // all rather than a silently dead one.
        guard eligibleForEqualizer else {
            PlaybackTapLog.tap("no-tap track=\(track.id) title=\"\(track.title)\" reason=not-eligible")
            return (item, nil)
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            PlaybackTapLog.tap(
                "no-tap track=\(track.id) title=\"\(track.title)\" reason=loadTracks-failed "
                    + "error=\(error.localizedDescription)"
            )
            return (item, nil)
        }
        guard let audioTrack = audioTracks.first else {
            PlaybackTapLog.tap("no-tap track=\(track.id) title=\"\(track.title)\" reason=no-audio-track")
            return (item, nil)
        }

        let tap = EqualizerAudioTap(
            trackId: track.id,
            trackTitle: track.title,
            gains: gains,
            bypassed: bypassed,
        )
        guard let mix = tap.makeAudioMix(for: audioTrack) else {
            tap.dispose()
            return (item, nil)
        }
        item.audioMix = mix
        EqualizerTapRegistry.shared.adopt(tap)
        return (item, tap)
    }
}
