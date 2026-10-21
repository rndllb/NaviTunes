import Foundation

/// ISO-style 10-band EQ frequencies (matches HanSJin/AVAudio-Equalizer sample).
enum EqualizerBand {
    static let count = 10
    static let frequencies: [Float] = [32, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let gainRange: ClosedRange<Float> = -12 ... 12

    static let flatGains: [Float] = Array(repeating: 0, count: count)
}

struct EqualizerPreset: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let gains: [Float]

    static let catalog: [EqualizerPreset] = [
        .init(id: "flat", name: "Flat", gains: EqualizerBand.flatGains),
        .init(id: "dance", name: "Dance", gains: [4, 6, 5, 0, 1, 3, 5, 4.5, 3.5, 0]),
        .init(id: "jazz", name: "Jazz", gains: [4, 3, 2, 2.5, -1.5, -1.5, 0, 1, 2, 3]),
        .init(id: "bass", name: "Bass Boost", gains: [5, 4, 3.5, 3, 1, 0, 0, 0, 0, 0]),
        .init(id: "vocal", name: "Vocal", gains: [-2, -1, 0, 1, 2, 3, 2, 1, 0, -1]),
        .init(id: "rock", name: "Rock", gains: [4, 3, 2, 1, 0, 0, 1, 2, 2.5, 2]),
        .init(id: "metal", name: "Metal", gains: [5, 4, 2, 0, -1, 0, 2, 3, 3, 2]),
        .init(id: "classical", name: "Classical", gains: [0, 0, 0, 0, 0, 0, 1, 2, 2.5, 3]),
        .init(id: "edm", name: "EDM", gains: [6, 5, 3, 1, 0, 1, 2, 3, 4, 3]),
        .init(id: "hiphop", name: "Hip-Hop", gains: [6, 5, 4, 2, 0, 0, 1, 1, 1, 0]),
        .init(id: "country", name: "Country", gains: [2, 2, 1, 0.5, 0, 1, 2, 2.5, 2, 1]),
        .init(id: "podcast", name: "Podcast", gains: [-2, -1, 0, 2, 3.5, 4, 3, 1.5, 0, -1]),
        .init(id: "audiobook", name: "Audiobook", gains: [-3, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        .init(id: "car-audio", name: "Car Audio", gains: [4, 3.5, 2.5, 1.5, 1, 0.5, 1, 1.5, 2, 1.5]),
        .init(id: "wired-headphones", name: "Wired Headphones", gains: [1, 1, 0.5, 0, 0, 0, 0.5, 1, 1.5, 1]),
        .init(id: "external-dac", name: "External DAC", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ]

    static func preset(id: String) -> EqualizerPreset {
        catalog.first { $0.id == id } ?? catalog[0]
    }

    static func normalizedGains(_ raw: [Float]) -> [Float] {
        var next = Array(raw.prefix(EqualizerBand.count))
        if next.count < EqualizerBand.count {
            next.append(contentsOf: Array(repeating: 0, count: EqualizerBand.count - next.count))
        }
        return next.map { min(max($0, EqualizerBand.gainRange.lowerBound), EqualizerBand.gainRange.upperBound) }
    }
}

enum EqualizerStorage {
    static let enabledKey = "vellumEqualizerEnabled"
    /// Where the removed Bypass toggle (#14) was stored; read once by
    /// ``loadEnabledMigratingBypass(_:)`` and then deleted.
    static let legacyBypassKey = "vellumEqualizerBypass"
    static let presetIdKey = "vellumEqualizerPresetId"
    static let gainsKey = "vellumEqualizerBandGains"
    static let autoProfilesKey = "vellumEqualizerAutoProfiles"
    static let genreOverridesKey = "vellumEqualizerGenreOverrides"
    static let precisionDrawKey = "vellumEqualizerPrecisionDraw"
    static let stereoWidthKey = "vellumEqualizerStereoWidth"
    static let vintageModeKey = "vellumEqualizerVintageMode"
    static let adaptiveEnabledKey = "vellumEqualizerAdaptiveEnabled"
    static let adaptiveStrengthKey = "vellumEqualizerAdaptiveStrength"
    static let headphoneProfileKey = "vellumEqualizerHeadphoneProfile"
    static let frequencyToolModeKey = "vellumEqualizerFrequencyToolMode"
    static let frequencyToolBandKey = "vellumEqualizerFrequencyToolBand"
    static let hearingOffsetKey = "vellumEqualizerHearingOffset"
    static let bassEnhancementKey = "vellumEqualizerBassEnhancement"
    static let vocalEnhancementKey = "vellumEqualizerVocalEnhancement"
    static let loudnessCompensationKey = "vellumEqualizerLoudnessCompensation"

    /// Whether the equalizer is on, for `AppModel` to start from.
    ///
    /// The Bypass toggle is gone (#14): it was a second off switch, since the EQ path is already
    /// gated on ``enabledKey``. Someone who left Bypass on was hearing no EQ, so they come back
    /// with the EQ off rather than suddenly hearing their curve again. The old key is removed.
    static func loadEnabledMigratingBypass(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: legacyBypassKey) != nil {
            if defaults.bool(forKey: legacyBypassKey) {
                defaults.set(false, forKey: enabledKey)
            }
            defaults.removeObject(forKey: legacyBypassKey)
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func loadGains() -> [Float] {
        if let raw = UserDefaults.standard.array(forKey: gainsKey) as? [Double] {
            return EqualizerPreset.normalizedGains(raw.map(Float.init))
        }
        return EqualizerBand.flatGains
    }

    static func loadHearingOffset() -> [Float] {
        if let raw = UserDefaults.standard.array(forKey: hearingOffsetKey) as? [Double] {
            return EqualizerPreset.normalizedGains(raw.map(Float.init))
        }
        return EqualizerBand.flatGains
    }

    static func saveGains(_ gains: [Float]) {
        let normalized = EqualizerPreset.normalizedGains(gains)
        UserDefaults.standard.set(normalized.map(Double.init), forKey: gainsKey)
    }
}
