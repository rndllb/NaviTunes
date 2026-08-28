import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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

private final class CachedArtworkImage: NSObject {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

enum DecodedArtworkCache {
    // Without a limit `NSCache` grows until the system posts a memory-pressure warning, and then
    // dumps everything at once — one big unpredictable purge that is as likely to land in the
    // middle of a zoom as anywhere else. A cost limit turns that into steady, boring eviction.
    // `store` has always computed a per-entry cost; it was simply inert with no limit set.
    // 64MB is roughly 27 covers at the 768px hero size (768 * 768 * 4 ≈ 2.3MB each).
    private static let memory: NSCache<NSString, CachedArtworkImage> = {
        let cache = NSCache<NSString, CachedArtworkImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func clearAll() {
        memory.removeAllObjects()
    }

    static func image(for url: URL, maxPixelSize: CGFloat) -> CGImage? {
        memory.object(forKey: cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)?.cgImage
    }

    static func store(_ image: CGImage, for url: URL, maxPixelSize: CGFloat) {
        let cost = max(1, image.width * image.height * 4)
        memory.setObject(
            CachedArtworkImage(image),
            forKey: cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString,
            cost: cost,
        )
    }

    static func stableID(for url: URL, maxPixelSize: CGFloat) -> String {
        cacheKey(for: url, maxPixelSize: maxPixelSize)
    }

    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        "\(normalizedCacheURLString(for: url))|\(Int(maxPixelSize.rounded(.up)))"
    }

    /// Cache key for an artwork URL, independent of how the request happened to be spelled.
    ///
    /// **Sorted, not just filtered.** Subsonic URLs are built by iterating a Swift `Dictionary`
    /// (`NavidromeClient.buildRESTURL`), and dictionary order is unspecified — so the same cover
    /// is spelled `…&id=X&size=400` on one call and `…&size=400&id=X` on the next, within one
    /// process run. Filtering alone left those as two different keys for one image, which missed
    /// in memory *and* on disk and made an on-screen cover reload: `AlbumArtworkView.load` clears
    /// `decoded` on a miss, so the image was replaced by a shimmer and then faded back in. That
    /// was the reported album-cover flicker. Sorting makes the key depend on the request's
    /// content rather than its spelling.
    private static func normalizedCacheURLString(for url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return url.absoluteString }
        comps.queryItems = items
            .filter { $0.name != "t" && $0.name != "s" }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return comps.url?.absoluteString ?? url.absoluteString
    }
}

enum RemoteArtworkLoad {
    static func cgImage(from url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        if let cached = DecodedArtworkCache.image(for: url, maxPixelSize: maxPixelSize) {
            return cached
        }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            // ArtworkURLCache injects per-host auth headers from MediaAuthHeaderRegistry
            // so Jellyfin artwork loads without the access token appearing in the URL.
            data = await ArtworkURLCache.data(for: url)
        }
        guard let data, !data.isEmpty else { return nil }
        let decoded = await Task.detached(priority: .utility) {
            ArtworkImageDecoder.cgImage(from: data, maxPixelSize: maxPixelSize)
        }.value
        if let decoded {
            DecodedArtworkCache.store(decoded, for: url, maxPixelSize: maxPixelSize)
        }
        return decoded
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

// MARK: - Vertical color bleed (Apple Music Top Picks shelf)

enum ArtworkVerticalBleed {
    /// Stretches the bottom edge strip of cover art vertically; optional light blur applied in ``HomeTopPickArtworkBleed``.
    static func cgImage(
        from source: CGImage,
        pixelWidth: Int,
        pixelHeight: Int,
        stripHeightRatio: CGFloat = 0.05
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let sw = source.width
        let sh = source.height
        guard sw > 0, sh > 0 else { return nil }

        let stripH = max(1, Int(round(CGFloat(sh) * stripHeightRatio)))
        let cropY = sh - stripH
        guard let strip = source.cropping(to: CGRect(x: 0, y: cropY, width: sw, height: stripH)) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.setAllowsAntialiasing(false)
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return ctx.makeImage()
    }
}

/// Pre-renders SwiftUI-equivalent Gaussian blur so hero / shelf washes don't
/// re-blur on every frame (mini-player transitions, stretchy headers).
enum ArtworkGaussianBlur {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func cgImage(from source: CGImage, radius: CGFloat) -> CGImage? {
        guard radius > 0.5 else { return source }
        let extent = CIImage(cgImage: source).extent
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = CIImage(cgImage: source).clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return context.createCGImage(output, from: extent)
    }

    /// CI pixel radius that matches SwiftUI `blur(radius:)` in **points** when
    /// `source` is later `scaledToFill` into `displayedWidth` points.
    static func matchingSwiftUIRadius(_ pointRadius: CGFloat, sourceWidth: Int, displayedWidth: CGFloat) -> CGFloat {
        guard sourceWidth > 0, displayedWidth > 1 else { return pointRadius }
        return pointRadius * CGFloat(sourceWidth) / displayedWidth
    }
}

/// Bottom-band fill for ``HomeTopPickCard`` — pixel-stretched artwork colors with progressive blur.
struct HomeTopPickArtworkBleed: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var fallbackColor: Color

    @Environment(\.displayScale) private var displayScale
    @State private var bleedImage: CGImage?

    var body: some View {
        Group {
            if let bleedImage {
                progressiveBleed(image: bleedImage)
            } else {
                fallbackColor
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: taskKey) {
            await loadBleed()
        }
    }

    private func stretchLayer(_ image: CGImage) -> some View {
        ArtworkPlatformImage.swiftUIImage(cgImage: image)
            .resizable()
            .interpolation(.none)
            .scaledToFill()
            .frame(width: width, height: height)
    }

    private func progressiveBleed(image: CGImage) -> some View {
        ZStack {
            stretchLayer(image)
                .blur(radius: MusicDesign.homeTopPickBleedBlurRadiusTop + 1.5, opaque: true)

            stretchLayer(image)
                .blur(radius: MusicDesign.homeTopPickBleedBlurRadiusBottom, opaque: true)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.34),
                            .init(color: .white.opacity(0.55), location: 0.5),
                            .init(color: .white, location: 0.68),
                            .init(color: .white, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom,
                    ),
                )
        }
        .mask(bleedSeamFadeMask)
        .clipped()
        // Flatten the two live Gaussian blurs into a bitmap so vertical Home
        // scrolling doesn't re-blur eight hero cards every frame.
        .drawingGroup(opaque: false)
    }

    /// Fades the whole bleed in from transparent so no hard line meets the cover.
    private var bleedSeamFadeMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.18), location: 0.14),
                .init(color: .white.opacity(0.52), location: 0.32),
                .init(color: .white.opacity(0.88), location: 0.5),
                .init(color: .white, location: 0.68),
            ],
            startPoint: .top,
            endPoint: .bottom,
        )
    }

    private var taskKey: String {
        "\(url?.absoluteString ?? "none")|\(width)|\(height)|\(displayScale)"
    }

    private func loadBleed() async {
        guard let url else {
            bleedImage = nil
            return
        }
        let scale = max(displayScale, 2)
        let pxW = max(1, Int((width * scale).rounded()))
        let pxH = max(1, Int((height * scale).rounded()))
        let cacheKey = "\(DecodedArtworkCache.stableID(for: url, maxPixelSize: 512))|\(pxW)x\(pxH)"
        if let cached = HomeTopPickBleedCache.image(for: cacheKey) {
            bleedImage = cached
            return
        }
        guard let source = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: 512) else { return }
        let bleed = await Task.detached(priority: .utility) {
            ArtworkVerticalBleed.cgImage(
                from: source,
                pixelWidth: pxW,
                pixelHeight: pxH,
                stripHeightRatio: MusicDesign.homeTopPickBleedSourceRatio,
            )
        }.value
        guard let bleed else { return }
        HomeTopPickBleedCache.store(bleed, for: cacheKey)
        await MainActor.run {
            bleedImage = bleed
        }
    }
}

private final class CachedBleedImage: NSObject {
    let cgImage: CGImage
    init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

enum HomeTopPickBleedCache {
    // Same reasoning as `DecodedArtworkCache` above; smaller because bleeds are only generated
    // for the Home Top Pick shelf, not for every cover the user scrolls past.
    private static let memory: NSCache<NSString, CachedBleedImage> = {
        let cache = NSCache<NSString, CachedBleedImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func image(for key: String) -> CGImage? {
        memory.object(forKey: key as NSString)?.cgImage
    }

    static func store(_ image: CGImage, for key: String) {
        let cost = max(1, image.width * image.height * 4)
        memory.setObject(CachedBleedImage(image), forKey: key as NSString, cost: cost)
    }

    static func clear() {
        memory.removeAllObjects()
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
