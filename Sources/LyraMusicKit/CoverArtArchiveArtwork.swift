import CoreGraphics
import Foundation

/// Cover Art Archive front images for MusicBrainz release-groups (404 is common for some ids).
enum CoverArtArchiveArtwork {
    static func loadReleaseGroupFront(releaseGroupId: String, maxPixelSize: CGFloat) async -> CGImage? {
        let trimmed = releaseGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // CAA serves all sizes or none for a given release-group — waterfall is wasteful.
        // Pick size that matches the display requirement so art isn't upscaled.
        let sizeParam = maxPixelSize <= 250 ? 250 : (maxPixelSize <= 500 ? 500 : 1200)
        guard let url = URL(string: "https://coverartarchive.org/release-group/\(trimmed)/front-\(sizeParam)") else {
            return nil
        }
        return await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: maxPixelSize)
    }
}
