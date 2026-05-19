import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Decode remote artwork off SwiftUI’s `AsyncImage` pipeline to avoid ImageIO asserts on some 24‑bpp
/// JPEGs (console: `kCGImageBlockFormatBGRx8` / rdar://143602439).
enum ArtworkImageDecoder {
    /// Produces a bitmap via ImageIO thumbnail generation (typically 32‑bpp), capped for memory.
    static func cgImage(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let px = max(64, maxPixelSize)
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            return thumb
        }
        let fullOpts: [CFString: Any] = [
            kCGImageSourceShouldAllowFloat: false,
        ]
        return CGImageSourceCreateImageAtIndex(src, 0, fullOpts as CFDictionary)
    }
}

enum RemoteArtworkLoad {
    static func cgImage(from url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            // ArtworkURLCache injects per-host auth headers from MediaAuthHeaderRegistry
            // so Jellyfin artwork loads without the access token appearing in the URL.
            data = await ArtworkURLCache.data(for: url)
        }
        guard let data, !data.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            ArtworkImageDecoder.cgImage(from: data, maxPixelSize: maxPixelSize)
        }.value
    }
}

enum ArtworkPlatformImage {
    static func swiftUIImage(cgImage: CGImage) -> Image {
        #if os(iOS)
        Image(uiImage: UIImage(cgImage: cgImage))
        #elseif os(macOS)
        Image(
            nsImage: NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)),
            ),
        )
        #else
        Image(systemName: "photo")
        #endif
    }
}

/// Remote artwork as `scaledToFill` without SwiftUI `AsyncImage` (avoids ImageIO / BGRx8 noise on some 24‑bpp sources).
struct RemoteArtworkScaledFill<Placeholder: View>: View {
    let url: URL?
    var maxPixelSize: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var decoded: CGImage?

    var body: some View {
        ZStack {
            placeholder()
            if let cg = decoded {
                ArtworkPlatformImage.swiftUIImage(cgImage: cg)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transaction { $0.animation = nil }
            }
        }
        .task(id: url?.absoluteString ?? "") {
            guard let url else {
                decoded = nil
                return
            }
            decoded = nil
            let cg = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: maxPixelSize)
            await MainActor.run {
                decoded = cg
            }
        }
    }
}
