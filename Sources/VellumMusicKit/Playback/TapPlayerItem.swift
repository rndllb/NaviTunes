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
        volumeRamps: [AutoMixVolumeRamp] = [],
    ) async -> (item: AVPlayerItem, tap: EqualizerAudioTap?) {
        let (item, tap, _) = await make(asset: asset, track: track, gains: gains, bypassed: bypassed, eligibleForEqualizer: eligibleForEqualizer, volumeRamps: volumeRamps, keepPlainMix: false)
        return (item, tap)
    }

    /// As `make`, also returning the same tap's mix *without* the ramps, for `AutoMixPlayerBlend`
    /// to swap in once its transition has settled (T677).
    static func make(
        asset: AVAsset,
        track: Track,
        gains: [Float],
        bypassed: Bool,
        eligibleForEqualizer: Bool,
        volumeRamps: [AutoMixVolumeRamp],
        keepPlainMix: Bool,
    ) async -> (item: AVPlayerItem, tap: EqualizerAudioTap?, plainMix: AVAudioMix?) {
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
            return (item, nil, nil)
        }

        // Internet radio is HLS-shaped and taps do not work with HLS; those items get no tap at
        // all rather than a silently dead one.
        guard eligibleForEqualizer else {
            PlaybackTapLog.tap("no-tap track=\(track.id) title=\"\(track.title)\" reason=not-eligible")
            return (item, nil, nil)
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            PlaybackTapLog.tap(
                "no-tap track=\(track.id) title=\"\(track.title)\" reason=loadTracks-failed "
                    + "error=\(error.localizedDescription)"
            )
            return (item, nil, nil)
        }
        guard let audioTrack = audioTracks.first else {
            PlaybackTapLog.tap("no-tap track=\(track.id) title=\"\(track.title)\" reason=no-audio-track")
            return (item, nil, nil)
        }

        let tap = EqualizerAudioTap(
            trackId: track.id,
            trackTitle: track.title,
            gains: gains,
            bypassed: bypassed,
        )
        guard let parameters = tap.makeAudioMixInputParameters(for: audioTrack) else {
            // Mix creation failed, so no tap took ownership and freeing here is safe. Once a tap
            // exists this call refuses — see `disposeBeforeAttachment`.
            tap.disposeBeforeAttachment()
            return (item, nil, nil)
        }
        // The blend's gain curve, sample-accurate in the item's own timeline (T677).
        var plainMix: AVAudioMix?
        if keepPlainMix, let copy = parameters.mutableCopy() as? AVMutableAudioMixInputParameters {
            let plain = AVMutableAudioMix()
            plain.inputParameters = [copy]
            plainMix = plain
        }
        if !volumeRamps.isEmpty {
            parameters.setVolume(volumeRamps[0].from, at: .zero)
            for ramp in volumeRamps {
                parameters.setVolumeRamp(
                    fromStartVolume: ramp.from, toEndVolume: ramp.to,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: ramp.start, preferredTimescale: 44_100),
                        end: CMTime(seconds: ramp.end, preferredTimescale: 44_100),
                    ),
                )
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        EqualizerTapRegistry.shared.adopt(tap)
        return (item, tap, plainMix)
    }
}
