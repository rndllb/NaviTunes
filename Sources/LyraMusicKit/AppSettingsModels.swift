import Foundation
import SwiftUI

// MARK: - Theme

enum AppThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Value for SwiftUI `.preferredColorScheme`; nil means follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Stream / download quality

/// Wi‑Fi / cellular streaming (320 capped vs server original).
enum StreamQualityTier: String, CaseIterable, Identifiable {
    case capped320
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capped320: return "320 kbps"
        case .original: return "Original"
        }
    }

    /// Navidrome `maxBitRate` in bits/sec (`0` = unlimited).
    var navidromeMaxBitRate: Int {
        switch self {
        case .capped320: return 320_000
        case .original: return 0
        }
    }

    /// Jellyfin `audioBitRate` param in bits/sec; nil = omit (original).
    var jellyfinAudioBitRate: Int? {
        switch self {
        case .capped320: return 320_000
        case .original: return nil
        }
    }
}

/// Offline download transcoding cap.
enum DownloadQualityTier: String, CaseIterable, Identifiable {
    case original
    case kbps320
    case kbps256
    case kbps192
    case kbps128
    case kbps64

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .kbps320: return "320 kbps"
        case .kbps256: return "256 kbps"
        case .kbps192: return "192 kbps"
        case .kbps128: return "128 kbps"
        case .kbps64: return "64 kbps"
        }
    }

    var navidromeMaxBitRate: Int {
        switch self {
        case .original: return 0
        case .kbps320: return 320_000
        case .kbps256: return 256_000
        case .kbps192: return 192_000
        case .kbps128: return 128_000
        case .kbps64: return 64_000
        }
    }

    var jellyfinAudioBitRate: Int? {
        switch self {
        case .original: return nil
        case .kbps320: return 320_000
        case .kbps256: return 256_000
        case .kbps192: return 192_000
        case .kbps128: return 128_000
        case .kbps64: return 64_000
        }
    }
}

// MARK: - Playback settings (Substreamer parity)

/// Stream max bitrate; `none` = no limit (server original / preset HIGH default for lossy formats).
enum StreamBitRateOption: Int, CaseIterable, Identifiable, Codable {
    case kbps64 = 64
    case kbps128 = 128
    case kbps192 = 192
    case kbps256 = 256
    case kbps320 = 320
    case none = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "No limit"
        default: return "\(rawValue) kbps"
        }
    }

    var kbps: Int? {
        rawValue == 0 ? nil : rawValue
    }

    /// Navidrome `maxBitRate` in bits/sec; `0` = omit / unlimited.
    func navidromeMaxBitRate(for format: StreamFormatOption) -> Int {
        if format.isLossless { return 0 }
        if let kbps { return kbps * 1000 }
        return format.highDefaultBitRateBps
    }

    var jellyfinAudioBitRate: Int? {
        guard let kbps else { return nil }
        return kbps * 1000
    }
}

/// Subsonic stream `format=` presets (Navidrome). Jellyfin maps to container choices.
enum StreamFormatOption: String, CaseIterable, Identifiable, Codable {
    case raw
    case mp3
    case mp3Rg = "mp3_rg"
    case mp3Car = "mp3_car"
    case aac
    case m4a
    case opus
    case opusRg = "opus_rg"
    case opusCar = "opus_car"
    case ogg
    case flac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: return "Original"
        case .mp3: return "MP3"
        case .mp3Rg: return "MP3 (ReplayGain)"
        case .mp3Car: return "MP3 (Car mode)"
        case .aac: return "AAC"
        case .m4a: return "M4A"
        case .opus: return "Opus"
        case .opusRg: return "Opus (ReplayGain)"
        case .opusCar: return "Opus (Car mode)"
        case .ogg: return "OGG Vorbis"
        case .flac: return "FLAC"
        }
    }

    var isLossless: Bool { self == .raw || self == .flac }

    /// Subsonic `format` query value; nil for raw/original.
    var navidromeFormatParam: String? {
        self == .raw ? nil : rawValue
    }

    /// Default max bitrate when user picks "No limit" on a lossy format.
    var highDefaultBitRateBps: Int {
        switch self {
        case .opusCar: return 192_000
        case .raw, .flac: return 0
        default: return 320_000
        }
    }

    /// Formats exposed in Settings when backend is Jellyfin (Subsonic-only variants hidden).
    static var jellyfinCases: [StreamFormatOption] {
        [.raw, .mp3, .aac, .m4a, .flac]
    }

    var jellyfinPrimaryContainer: String? {
        switch self {
        case .raw: return nil
        case .mp3, .mp3Rg, .mp3Car, .opus, .opusRg, .opusCar, .ogg: return "mp3"
        case .aac, .m4a: return "m4a"
        case .flac: return "flac"
        }
    }
}

enum DownloadFormatOption: String, CaseIterable, Identifiable, Codable {
    case mp3
    case aac
    case opus
    case flac
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        case .raw: return "Original"
        }
    }

    var navidromeFormatParam: String? {
        self == .raw ? nil : rawValue
    }

    var jellyfinContainer: String {
        switch self {
        case .mp3, .opus: return "mp3"
        case .aac: return "m4a"
        case .flac, .raw: return "flac"
        }
    }

    var asStreamFormat: StreamFormatOption {
        switch self {
        case .mp3: return .mp3
        case .aac: return .aac
        case .opus: return .opus
        case .flac: return .flac
        case .raw: return .raw
        }
    }
}

enum SkipIntervalOption: Int, CaseIterable, Identifiable, Codable {
    case s5 = 5
    case s10 = 10
    case s15 = 15
    case s30 = 30
    case s45 = 45
    case s60 = 60

    var id: Int { rawValue }

    var title: String { "\(rawValue) seconds" }

    var seconds: TimeInterval { TimeInterval(rawValue) }
}

enum RemoteControlMode: String, CaseIterable, Identifiable, Codable {
    case skipTrack
    case skipInterval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skipTrack: return "Skip track"
        case .skipInterval: return "Skip interval"
        }
    }
}

enum PlaybackRateOption: Float, CaseIterable, Identifiable, Codable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1.0
    case oneAndQuarter = 1.25
    case oneAndHalf = 1.5
    case double = 2.0

    var id: Float { rawValue }

    var title: String {
        switch self {
        case .half: return "0.5×"
        case .threeQuarters: return "0.75×"
        case .normal: return "1×"
        case .oneAndQuarter: return "1.25×"
        case .oneAndHalf: return "1.5×"
        case .double: return "2×"
        }
    }

    static func nearest(to rate: Float) -> PlaybackRateOption {
        allCases.min(by: { abs($0.rawValue - rate) < abs($1.rawValue - rate) }) ?? .normal
    }
}

enum ArtistPlayMode: String, CaseIterable, Identifiable, Codable {
    case topSongs
    case fullCatalog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topSongs: return "Top songs"
        case .fullCatalog: return "Full catalog"
        }
    }

    var playMenuTitle: String {
        switch self {
        case .topSongs: return "Play Top Songs"
        case .fullCatalog: return "Play Full Catalog"
        }
    }
}

enum ServerFailoverMode: String, CaseIterable, Identifiable, Codable {
    case disabled
    case automatic
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Primary only"
        case .automatic: return "Automatic failover"
        case .manual: return "Manual switch"
        }
    }
}

enum MetadataRefreshThreshold: String, CaseIterable, Identifiable, Codable {
    case always
    case oneDay = "1day"
    case oneWeek = "1week"
    case oneMonth = "1month"
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Always"
        case .oneDay: return "After 1 day"
        case .oneWeek: return "After 1 week"
        case .oneMonth: return "After 1 month"
        case .never: return "Never"
        }
    }

    func isStale(retrievedAt: Date, now: Date = Date()) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .oneDay: return now.timeIntervalSince(retrievedAt) > 86_400
        case .oneWeek: return now.timeIntervalSince(retrievedAt) > 604_800
        case .oneMonth: return now.timeIntervalSince(retrievedAt) > 2_592_000
        }
    }
}

// MARK: - Song list item size

enum SongListItemSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var artworkSide: CGFloat {
        switch self {
        case .small: return 44
        case .medium: return 52
        case .large: return 62
        }
    }

    var libraryVerticalPadding: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 3
        case .large: return 5
        }
    }

    var albumVerticalPadding: CGFloat {
        switch self {
        case .small: return 5
        case .medium: return 8
        case .large: return 12
        }
    }

    var titleFont: Font {
        switch self {
        case .small: return .subheadline.weight(.semibold)
        case .medium: return .body.weight(.semibold)
        case .large: return .title3.weight(.semibold)
        }
    }

    var subtitleFont: Font {
        switch self {
        case .small: return .caption
        case .medium: return .subheadline
        case .large: return .body
        }
    }

    var albumTitleFont: Font {
        switch self {
        case .small: return .caption.weight(.semibold)
        case .medium: return .subheadline.weight(.semibold)
        case .large: return .body.weight(.semibold)
        }
    }

    var albumSubtitleFont: Font {
        switch self {
        case .small: return .caption2
        case .medium: return .caption
        case .large: return .subheadline
        }
    }
}

// MARK: - Library statistics

struct LibraryStatistics: Equatable {
    var artistCount: Int?
    var albumCount: Int?
    var songCount: Int?
    var playlistCount: Int?
    /// Navidrome song totals sum per-album ``trackCount``; may be partial when the fetch cap is hit.
    var songsMayBeApproximate: Bool = false

    static let empty = LibraryStatistics(
        artistCount: nil,
        albumCount: nil,
        songCount: nil,
        playlistCount: nil,
        songsMayBeApproximate: false,
    )
}

// MARK: - Server connection (Settings)

enum ServerConnectionHealth: Equatable {
    case unknown
    case checking
    case noNetwork
    case connected
    case unreachable(String)

    var statusTitle: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking…"
        case .noNetwork: return "No internet"
        case .connected: return "Connected"
        case .unreachable: return "Unreachable"
        }
    }

    func detailText(serverName: String) -> String {
        switch self {
        case .unknown:
            return "Connection status will appear after you sign in."
        case .checking:
            return "Checking reachability to your \(serverName) server…"
        case .noNetwork:
            return "This device is offline. Downloads and your cached library still work."
        case .connected:
            return "\(serverName) is reachable."
        case .unreachable(let message):
            return message
        }
    }

    var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}
