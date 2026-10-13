import AVFoundation
import Foundation

/// Reads duration from a local audio file (offline downloads often omit server metadata).
enum LocalMediaDuration {
    static func seconds(at url: URL) async -> TimeInterval {
        guard url.isFileURL else { return 0 }
        // Same hint as playback: an extensionless stream-cache file needs its container named (T665).
        return await seconds(asset: AVURLAsset(url: url, options: PlaybackEngine.localAssetOptions(for: url)))
    }

    static func seconds(asset: AVAsset) async -> TimeInterval {
        do {
            let time = try await asset.load(.duration)
            let s = time.seconds
            if s.isFinite, s > 0 { return s }
        } catch {}
        return 0
    }
}
