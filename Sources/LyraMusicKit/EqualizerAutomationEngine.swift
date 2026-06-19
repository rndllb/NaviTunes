import Foundation

/// Resolves which EQ gains to apply from saved profiles, device route, and enhancement layers.
struct EqualizerAutomationEngine {
    var profiles: [EqualizerProfile]

    func resolvedGains(
        baseGains: [Float],
        track: Track?,
        routeKey: String?,
        routeDisplayName: String?,
        vintageMode: EqualizerVintageMode,
        stereoWidth: EqualizerStereoWidth,
        hearingOffset: [Float],
        adaptiveEnabled: Bool,
        adaptiveStrength: EqualizerAdaptiveStrength,
        headphoneProfileId: String?,
        frequencyToolMode: EqualizerFrequencyToolMode,
        frequencyToolBand: Int?,
    ) -> [Float] {
        var gains = EqualizerPreset.normalizedGains(baseGains)

        if let routeKey, let device = profile(kind: .device, key: routeKey) {
            gains = blend(gains, with: device.gains, mix: 0.85)
        } else if let routeDisplayName,
                  let seedId = EqualizerDeviceRoute.seedPresetId(forRouteName: routeDisplayName),
                  let seed = EqualizerPreset.catalog.first(where: { $0.id == seedId }) {
            gains = blend(gains, with: seed.gains, mix: 0.5)
        }

        if let headphoneProfileId,
           let headphone = HeadphoneCompensationCatalog.profiles.first(where: { $0.id == headphoneProfileId }) {
            gains = blend(gains, with: headphone.gains, mix: 0.75)
        }

        if vintageMode != .off {
            gains = zip(gains, vintageMode.gains).map { lhs, rhs in
                min(max(lhs + rhs, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound)
            }
        }

        if stereoWidth != .normal {
            gains = applyStereoTilt(gains, tilt: stereoWidth.bandTilt)
        }

        if adaptiveEnabled, let track {
            gains = applyAdaptiveTilt(gains, track: track, strength: adaptiveStrength)
        }

        if hearingOffset.contains(where: { abs($0) > 0.01 }) {
            gains = zip(gains, hearingOffset).map { min(max($0 + $1, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound) }
        }

        gains = applyFrequencyTool(
            gains,
            mode: frequencyToolMode,
            band: frequencyToolBand,
        )

        return EqualizerPreset.normalizedGains(gains)
    }

    private func profile(kind: EqualizerProfileKind, key: String) -> EqualizerProfile? {
        profiles.first { $0.kind == kind && $0.key == key }
    }

    private func blend(_ base: [Float], with overlay: [Float], mix: Float) -> [Float] {
        let a = EqualizerPreset.normalizedGains(base)
        let b = EqualizerPreset.normalizedGains(overlay)
        return zip(a, b).map { lhs, rhs in
            lhs * (1 - mix) + rhs * mix
        }
    }

    private func applyStereoTilt(_ gains: [Float], tilt: [Float]) -> [Float] {
        zip(EqualizerPreset.normalizedGains(gains), tilt).map { $0 + $1 }
    }

    private func applyAdaptiveTilt(_ gains: [Float], track: Track, strength: EqualizerAdaptiveStrength) -> [Float] {
        var tilt = EqualizerBand.flatGains
        let duration = track.duration
        if duration > 360 {
            tilt = [0.5, 0.5, 0, 0, 0, 0, 0.5, 1, 1, 0.5]
        } else if duration < 120 {
            tilt = [1, 1.5, 1, 0.5, 0, 0, 0, 0, 0, 0]
        }
        if track.genres.contains(where: { $0.localizedCaseInsensitiveContains("podcast") || $0.localizedCaseInsensitiveContains("spoken") }) {
            tilt = [-1, -0.5, 0, 1.5, 2.5, 3, 2, 1, 0, -1]
        }
        return blend(gains, with: tilt, mix: strength.mix)
    }

    private func applyFrequencyTool(
        _ gains: [Float],
        mode: EqualizerFrequencyToolMode,
        band: Int?,
    ) -> [Float] {
        guard let band, band >= 0, band < EqualizerBand.count else { return gains }
        var next = EqualizerPreset.normalizedGains(gains)
        switch mode {
        case .off:
            return next
        case .solo:
            for index in next.indices where index != band {
                next[index] = EqualizerBand.gainRange.lowerBound
            }
        case .mute:
            next[band] = EqualizerBand.gainRange.lowerBound
        }
        return next
    }
}
