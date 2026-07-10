import Foundation

// MARK: - Advanced modes

enum EqualizerStereoWidth: String, CaseIterable, Identifiable, Codable {
    case mono
    case narrow
    case normal
    case wide
    case extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mono: return "Mono"
        case .narrow: return "Narrow"
        case .normal: return "Normal"
        case .wide: return "Wide"
        case .extreme: return "Extreme"
        }
    }

    /// Approximate width via per-band tilt applied on top of user gains.
    var bandTilt: [Float] {
        switch self {
        case .mono: return [-4, -3, -2, -1, 0, 0, -1, -2, -3, -4]
        case .narrow: return [-2, -1, -0.5, 0, 0, 0, 0, -0.5, -1, -2]
        case .normal: return Array(repeating: 0, count: EqualizerBand.count)
        case .wide: return [0, 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4]
        case .extreme: return [0, 0.5, 1, 2, 3, 4, 5, 6, 7, 8]
        }
    }
}

enum EqualizerVintageMode: String, CaseIterable, Identifiable, Codable {
    case off
    case tube
    case vinyl
    case cassette
    case receiver1970s
    case studioMonitor
    case radioBroadcast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .tube: return "Tube Amp"
        case .vinyl: return "Vinyl Warmth"
        case .cassette: return "Cassette"
        case .receiver1970s: return "1970s Receiver"
        case .studioMonitor: return "Studio Monitor"
        case .radioBroadcast: return "Radio Broadcast"
        }
    }

    var gains: [Float] {
        switch self {
        case .off: return EqualizerBand.flatGains
        case .tube: return [2, 2.5, 2, 1, 0.5, 0, -0.5, -1, -1.5, -2]
        case .vinyl: return [3, 2.5, 1.5, 0.5, 0, -0.5, -1, -1.5, -2, -3]
        case .cassette: return [2, 1.5, 1, 0.5, 0, 0, -1, -2, -3, -4]
        case .receiver1970s: return [4, 3, 2, 1, 0, 0, 1, 2, 2.5, 1.5]
        case .studioMonitor: return [-1, -0.5, 0, 0.5, 1, 1, 0.5, 0, -0.5, -1]
        case .radioBroadcast: return [1, 1.5, 2, 2.5, 2, 1.5, 1, 0.5, 0, -1]
        }
    }
}

enum EqualizerAdaptiveStrength: String, CaseIterable, Identifiable, Codable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var mix: Float {
        switch self {
        case .conservative: return 0.35
        case .balanced: return 0.6
        case .aggressive: return 0.85
        }
    }
}

enum EqualizerFrequencyToolMode: String, CaseIterable, Identifiable, Codable {
    case off
    case solo
    case mute

    var id: String { rawValue }
}

// MARK: - Export bundle

struct EqualizerPresetExport: Codable, Identifiable {
    var id: String { name }
    var name: String
    var gains: [Float]
    var createdAt: Date

    static let fileExtension = "vellumeq"
}

// MARK: - Profile kinds

enum EqualizerProfileKind: String, Codable, CaseIterable, Identifiable {
    case artist
    case album
    case genre
    case device
    case headphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .device: return "Device"
        case .headphone: return "Headphone"
        }
    }
}

struct EqualizerProfile: Codable, Identifiable, Hashable, Sendable {
    var kind: EqualizerProfileKind
    var key: String
    var displayName: String
    var gains: [Float]
    var dateModified: Date

    var id: String { "\(kind.rawValue):\(key)" }

    init(
        kind: EqualizerProfileKind,
        key: String,
        displayName: String,
        gains: [Float],
        dateModified: Date = Date(),
    ) {
        self.kind = kind
        self.key = key
        self.displayName = displayName
        self.gains = EqualizerPreset.normalizedGains(gains)
        self.dateModified = dateModified
    }
}

// MARK: - Headphone compensation seeds

struct HeadphoneCompensationProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let gains: [Float]
}

enum HeadphoneCompensationCatalog {
    static let profiles: [HeadphoneCompensationProfile] = [
        .init(id: "airpods-pro", name: "AirPods Pro", gains: [2, 1.5, 0.5, 0, -0.5, 0, 1, 2, 2.5, 1]),
        .init(id: "sony-xm5", name: "Sony WH-1000XM5", gains: [3, 2, 1, 0, -0.5, 0, 1, 1.5, 2, 1.5]),
        .init(id: "bose-qc", name: "Bose QuietComfort", gains: [2.5, 2, 1, 0.5, 0, 0, 0.5, 1, 1.5, 1]),
        .init(id: "senn-hd600", name: "Sennheiser HD 600", gains: [-1, 0, 1, 1.5, 2, 2, 1.5, 1, 0, -1]),
        .init(id: "ath-m50x", name: "Audio-Technica ATH-M50x", gains: [2, 2.5, 1.5, 0, -1, 0, 1.5, 2.5, 3, 2]),
    ]
}

// MARK: - Genre mapping

enum EqualizerGenreMapping {
    static let table: [String: String] = [
        "rock": "rock",
        "metal": "metal",
        "classical": "classical",
        "jazz": "jazz",
        "electronic": "edm",
        "edm": "edm",
        "dance": "edm",
        "hip hop": "hiphop",
        "hip-hop": "hiphop",
        "rap": "hiphop",
        "country": "country",
        "pop": "vocal",
        "podcast": "podcast",
        "podcasts": "podcast",
        "audiobook": "audiobook",
        "audiobooks": "audiobook",
        "spoken word": "podcast",
    ]

    static func presetId(forGenre raw: String) -> String? {
        let normalized = LibraryTrackMatcher.normalize(raw)
        if let direct = table[normalized] { return direct }
        for (key, value) in table where normalized.contains(key) {
            return value
        }
        return nil
    }
}
