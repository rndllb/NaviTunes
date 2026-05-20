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
    case kbps128

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .kbps320: return "320 kbps"
        case .kbps256: return "256 kbps"
        case .kbps128: return "128 kbps"
        }
    }

    var navidromeMaxBitRate: Int {
        switch self {
        case .original: return 0
        case .kbps320: return 320_000
        case .kbps256: return 256_000
        case .kbps128: return 128_000
        }
    }

    var jellyfinAudioBitRate: Int? {
        switch self {
        case .original: return nil
        case .kbps320: return 320_000
        case .kbps256: return 256_000
        case .kbps128: return 128_000
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
        case .small: return 6
        case .medium: return 9
        case .large: return 12
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

    static let empty = LibraryStatistics(artistCount: nil, albumCount: nil, songCount: nil, playlistCount: nil)
}

// MARK: - EQ

struct EQPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Six gains in dB matching ``PlaybackEQBandHz``.
    var gainsDb: [Float]

    init(id: UUID = UUID(), name: String, gainsDb: [Float]) {
        self.id = id
        self.name = name
        self.gainsDb = gainsDb
    }
}

/// Canonical graphic EQ bands (Hz).
enum PlaybackEQBandHz: CaseIterable {
    case hz60, hz150, hz400, hz1k, hz4k, hz15k

    static let frequencies: [Float] = [60, 150, 400, 1000, 4000, 15_000]

    var label: String {
        switch self {
        case .hz60: return "60 Hz"
        case .hz150: return "150 Hz"
        case .hz400: return "400 Hz"
        case .hz1k: return "1 kHz"
        case .hz4k: return "4 kHz"
        case .hz15k: return "15 kHz"
        }
    }

    var index: Int {
        switch self {
        case .hz60: return 0
        case .hz150: return 1
        case .hz400: return 2
        case .hz1k: return 3
        case .hz4k: return 4
        case .hz15k: return 5
        }
    }
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
