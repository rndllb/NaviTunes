import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Artwork-derived backdrop palette + adaptive chrome for hero / Now Playing surfaces.
enum ArtworkDynamicGradient {
    /// How the flat backdrop tint is sampled from cover art.
    enum BackdropAnalysisStyle: Sendable {
        /// Album / playlist detail + Now Playing — literal most frequent sRGB on the cover.
        case detail
        /// Legacy atmospheric hue wash (unused; kept for cache-key compatibility).
        case nowPlaying
        /// Artist page — dark charcoal tint from lower image rows (Apple Music artist hero).
        case artistPage
    }

    // MARK: - Palette cache

    private final class PaletteBox { let palette: BackdropPalette; init(_ p: BackdropPalette) { palette = p } }
    /// Memoizes computed palettes per (artwork URL, style) so reopening an album shows its
    /// backdrop instantly instead of re-downloading + re-analyzing the cover every time.
    /// Bounded by count rather than cost: a palette is a handful of colours, so the memory here
    /// is trivial and the only real reason for a limit is the same one as the image caches — an
    /// uncapped `NSCache` is emptied in a single purge on a system memory warning, which can
    /// land mid-transition. 512 is far more albums than a session realistically visits.
    private static let paletteCache: NSCache<NSString, PaletteBox> = {
        let cache = NSCache<NSString, PaletteBox>()
        cache.countLimit = 512
        return cache
    }()

    static func clearPaletteCache() {
        paletteCache.removeAllObjects()
    }

    /// Stable cache key: artwork URLs carry volatile auth (Subsonic salted `u`/`t`/`s`, Jellyfin
    /// `api_key`) that changes every request, so keying by the full URL never hits. Key by the
    /// path plus only the identity params (cover id / size / tag) instead.
    private static func cacheKey(_ url: URL, _ style: BackdropAnalysisStyle) -> NSString {
        if url.isFileURL { return "\(url.path)|\(style)" as NSString }
        var parts = [url.path]
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems {
            let identityNames: Set<String> = ["id", "coverart", "size", "tag"]
            for item in items where identityNames.contains(item.name.lowercased()) {
                parts.append("\(item.name.lowercased())=\(item.value ?? "")")
            }
        }
        return "\(parts.joined(separator: "&"))|\(style)" as NSString
    }

    /// Synchronous cache lookup so a view can seed its backdrop with no async hop / no pop-in
    /// when the artwork has been analyzed before this session.
    static func cachedBackdrop(for artworkURL: URL?, style: BackdropAnalysisStyle = .detail) -> BackdropPalette? {
        guard let artworkURL else { return nil }
        return paletteCache.object(forKey: cacheKey(artworkURL, style))?.palette
    }

    /// First paint value for detail heroes — uses the memoized palette when available.
    static func seededBackdrop(for artworkURL: URL?, style: BackdropAnalysisStyle = .detail) -> BackdropPalette {
        cachedBackdrop(for: artworkURL, style: style) ?? .fallback
    }

    /// Warms the palette cache while cover art is on screen so the pushed detail can
    /// show its backdrop on frame one instead of after decode + analysis.
    static func prefetchBackdrop(for artworkURL: URL?, style: BackdropAnalysisStyle = .detail) {
        guard let artworkURL else { return }
        if cachedBackdrop(for: artworkURL, style: style) != nil { return }
        Task(priority: .utility) {
            _ = await analyzeBackdrop(from: artworkURL, style: style)
        }
    }
    private static let fallbackHeroSolid = Color(red: 54 / 255, green: 48 / 255, blue: 62 / 255)

    /// Neutral fallback for APIs that still ask for gradient stops (single flat color).
    static let fallbackStops: [Gradient.Stop] = [
        Gradient.Stop(color: fallbackHeroSolid, location: 0),
        Gradient.Stop(color: fallbackHeroSolid, location: 1),
    ]

    /// Result of **color extraction** + **contrast / luminance handoff** for album hero chrome (Liquid Glass–style stacks consume this).
    struct BackdropPalette: Sendable {
        /// Legacy two-stop ramp (same color twice); prefer ``heroSolidBackdropColor`` + flat fills in UI.
        let gradientStops: [Gradient.Stop]
        /// Flat full-screen album backdrop tint — sampled from artwork (**no** gradient).
        let heroSolidBackdropColor: Color
        /// WCAG relative luminance (0…1) of ``heroSolidBackdropColor`` (same value used for chrome inversion).
        let backdropRelativeLuminance: Double
        /// When `true`, hero + toolbar use **dark** foreground (black glyphs, dark-filled pills) because ``heroSolidBackdropColor`` reads as **light**.
        let prefersDarkHeroChrome: Bool
        /// True for the artwork-less ``listSurface(colorScheme:)`` palette (player
        /// color backdrop off). Now Playing dims its scrubber/volume fills to
        /// Apple Music's plain-black levels in this mode — full-strength white
        /// fills only read correctly over colored artwork backdrops.
        var isPlainSurface: Bool = false

        /// If ``heroSolidBackdropColor``’s WCAG relative luminance is **≥** this value, the surface is treated as **light** → dark chrome (black text / buttons).
        static let backdropLuminanceDarkChromeThreshold: Double = 0.43

        static let fallback: BackdropPalette = {
            let lum = ArtworkDynamicGradient.relativeLuminance(of: ArtworkDynamicGradient.fallbackHeroSolid)
            return BackdropPalette(
                gradientStops: ArtworkDynamicGradient.fallbackStops,
                heroSolidBackdropColor: ArtworkDynamicGradient.fallbackHeroSolid,
                backdropRelativeLuminance: lum,
                prefersDarkHeroChrome: lum >= backdropLuminanceDarkChromeThreshold,
            )
        }()

    }

    /// Decode artwork → flat backdrop tint + WCAG luminance for adaptive hero chrome.
    static func analyzeBackdrop(
        from artworkURL: URL?,
        style: BackdropAnalysisStyle = .detail,
    ) async -> BackdropPalette {
        guard let url = artworkURL else { return .fallback }
        if let cached = paletteCache.object(forKey: cacheKey(url, style))?.palette { return cached }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            // ArtworkURLCache injects per-host auth headers from MediaAuthHeaderRegistry
            // so Jellyfin artwork loads without the access token appearing in the URL.
            data = await ArtworkURLCache.data(for: url)
        }
        guard let data, !data.isEmpty, let cgImage = cgImage(fromImageData: data) else { return .fallback }
        let palette = await analyzeBackdrop(from: cgImage, style: style)
        paletteCache.setObject(PaletteBox(palette), forKey: cacheKey(url, style))
        return palette
    }

    /// Internet radio mesh artwork → same backdrop analysis path as cover art.
    static func analyzeBackdrop(
        fromMeshSeedKey seedKey: String,
        style: BackdropAnalysisStyle = .detail,
    ) async -> BackdropPalette {
        #if os(iOS)
        let cgImage = await MainActor.run { RadioStationMeshArtwork.renderCGImage(seedKey: seedKey) }
        guard let cgImage else { return .fallback }
        return await analyzeBackdrop(from: cgImage, style: style)
        #else
        return .fallback
        #endif
    }

    private static func analyzeBackdrop(
        from cgImage: CGImage,
        style: BackdropAnalysisStyle,
    ) async -> BackdropPalette {
        await Task.detached(priority: .utility) {
            switch style {
            case .detail:
                makeDetailBackdropPalette(from: cgImage)
            case .nowPlaying:
                makeNowPlayingBackdropPalette(from: cgImage)
            case .artistPage:
                makeArtistPageBackdropPalette(from: cgImage)
            }
        }.value
    }

    static func gradientStops(from artworkURL: URL?) async -> [Gradient.Stop] {
        await analyzeBackdrop(from: artworkURL).gradientStops
    }

    /// Decode target for backdrop analysis.
    ///
    /// The only consumer of this bitmap is ``downsampleArtworkPixels``, which immediately caps
    /// the longest side at 120px — so decoding the cover at its full size (`UIImage(data:)`
    /// decodes everything) was producing a multi-megapixel bitmap to read a 120px sample from.
    /// Every track change did that twice over the same bytes, once from the pill and once from
    /// the hero, off-main but competing for the same CPU as the zoom. 160 leaves the downsampler
    /// a comfortable margin over the 120 it wants.
    private static let backdropAnalysisDecodePixels: CGFloat = 160

    private static func cgImage(fromImageData data: Data) -> CGImage? {
        // ImageIO thumbnail generation, which is also what the rest of the artwork pipeline
        // uses — and it is cross-platform, so the UIKit/AppKit split this replaced is no longer
        // needed here.
        ArtworkImageDecoder.cgImage(from: data, maxPixelSize: backdropAnalysisDecodePixels)
    }

    /// WCAG relative luminance for **linear** sRGB channels in 0…1.
    private static func relativeLuminanceSRGB(r: Double, g: Double, b: Double) -> Double {
        func lin(_ u: Double) -> Double {
            u <= 0.03928 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
        }
        let R = lin(r), G = lin(g), B = lin(b)
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }

    /// WCAG relative luminance (0…1) of a SwiftUI **sRGB** color — drives luminance handoff (light backdrop → dark chrome).
    private static func relativeLuminance(of color: Color) -> Double {
        guard let rgba = rgbaComponents(color) else { return 0.08 }
        return relativeLuminanceSRGB(r: Double(rgba.r), g: Double(rgba.g), b: Double(rgba.b))
    }

    private struct RGBA { let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat }

    private static func rgbaComponents(_ color: Color) -> RGBA? {
#if canImport(UIKit)
        let u = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard u.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return RGBA(r: r, g: g, b: b, a: a)
#elseif canImport(AppKit)
        let u = NSColor(color)
        guard let rgb = u.usingColorSpace(.deviceRGB) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: r, g: g, b: b, a: a)
#else
        nil
#endif
    }

    // MARK: - Detail (dominant cover color)

    private static func makeDetailBackdropPalette(from cgImage: CGImage) -> BackdropPalette {
        guard let sample = downsampleArtworkPixels(from: cgImage) else { return .fallback }
        let (pixels, tw, th) = sample
        let bytesPerPixel = 4

        // Most apparent color = most frequent quantized sRGB bucket (literal average RGB in that bucket).
        let quantLevels = 10
        let bucketCount = quantLevels * quantLevels * quantLevels
        var bucketPixels = [Int](repeating: 0, count: bucketCount)
        var bucketSumR = [Double](repeating: 0, count: bucketCount)
        var bucketSumG = [Double](repeating: 0, count: bucketCount)
        var bucketSumB = [Double](repeating: 0, count: bucketCount)
        var frameSumR = 0.0, frameSumG = 0.0, frameSumB = 0.0
        var framePixelCount = 0

        for i in 0 ..< tw * th {
            let o = i * bytesPerPixel
            let pa = Double(pixels[o + 3]) / 255.0
            guard pa > 0.1 else { continue }
            let r = min(1, Double(pixels[o]) / 255.0 / pa)
            let g = min(1, Double(pixels[o + 1]) / 255.0 / pa)
            let b = min(1, Double(pixels[o + 2]) / 255.0 / pa)

            frameSumR += r
            frameSumG += g
            frameSumB += b
            framePixelCount += 1

            let qr = min(quantLevels - 1, Int(r * Double(quantLevels)))
            let qg = min(quantLevels - 1, Int(g * Double(quantLevels)))
            let qb = min(quantLevels - 1, Int(b * Double(quantLevels)))
            let bucket = qr * quantLevels * quantLevels + qg * quantLevels + qb

            bucketPixels[bucket] += 1
            bucketSumR[bucket] += r
            bucketSumG[bucket] += g
            bucketSumB[bucket] += b
        }

        func finalizeSolid(_ solid: Color) -> BackdropPalette {
            let stops: [Gradient.Stop] = [
                Gradient.Stop(color: solid, location: 0),
                Gradient.Stop(color: solid, location: 1),
            ]
            let backdropLum = relativeLuminance(of: solid)
            let prefersDarkChrome = backdropLum >= BackdropPalette.backdropLuminanceDarkChromeThreshold
            return BackdropPalette(
                gradientStops: stops,
                heroSolidBackdropColor: solid,
                backdropRelativeLuminance: backdropLum,
                prefersDarkHeroChrome: prefersDarkChrome,
            )
        }

        guard framePixelCount > 0 else { return .fallback }

        guard let (winIdx, winPx) = bucketPixels.enumerated().max(by: { $0.element < $1.element }),
              winPx > 0
        else {
            let n = Double(framePixelCount)
            return finalizeSolid(Color(red: frameSumR / n, green: frameSumG / n, blue: frameSumB / n))
        }

        let n = Double(winPx)
        let solid = Color(
            red: bucketSumR[winIdx] / n,
            green: bucketSumG[winIdx] / n,
            blue: bucketSumB[winIdx] / n,
        )
        return finalizeSolid(solid)
    }

    // MARK: - Artist page (dark charcoal + subtle image tint; ignores white studio backgrounds)

    private static func makeArtistPageBackdropPalette(from cgImage: CGImage) -> BackdropPalette {
        guard let sample = downsampleArtworkPixels(from: cgImage) else { return .fallback }
        let (pixels, tw, th) = sample
        let bytesPerPixel = 4

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var weightSum = 0.0

        for y in 0 ..< th {
            let rowT = Double(y) / Double(max(th - 1, 1))
            let rowWeight = 0.12 + rowT * 0.88

            for x in 0 ..< tw {
                let o = (y * tw + x) * bytesPerPixel
                let pa = Double(pixels[o + 3]) / 255.0
                guard pa > 0.12 else { continue }
                let r = min(1, Double(pixels[o]) / 255.0 / pa)
                let g = min(1, Double(pixels[o + 1]) / 255.0 / pa)
                let b = min(1, Double(pixels[o + 2]) / 255.0 / pa)

                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                guard lum < 0.93 else { continue }
                let lumWeight = lum > 0.72 ? max(0.08, (0.93 - lum) / 0.21) : 1.0
                let w = rowWeight * lumWeight

                sumR += r * w
                sumG += g * w
                sumB += b * w
                weightSum += w
            }
        }

        let avgR = weightSum > 0 ? sumR / weightSum : 0.28
        let avgG = weightSum > 0 ? sumG / weightSum : 0.27
        let avgB = weightSum > 0 ? sumB / weightSum : 0.29

        let baseR = 0.109, baseG = 0.109, baseB = 0.114
        // Carry more of the artwork's actual hue into the backdrop (was a near-black 0.24 mix
        // clamped to ~0.22, which flattened everything to grey) while staying dark enough for
        // legible chrome and a clean melt.
        let tint = 0.5
        let solid = Color(
            red: min(0.34, baseR + (avgR - baseR) * tint),
            green: min(0.34, baseG + (avgG - baseG) * tint),
            blue: min(0.36, baseB + (avgB - baseB) * tint),
        )

        let stops: [Gradient.Stop] = [
            Gradient.Stop(color: solid, location: 0),
            Gradient.Stop(color: solid, location: 1),
        ]
        let backdropLum = relativeLuminance(of: solid)
        return BackdropPalette(
            gradientStops: stops,
            heroSolidBackdropColor: solid,
            backdropRelativeLuminance: backdropLum,
            prefersDarkHeroChrome: backdropLum >= BackdropPalette.backdropLuminanceDarkChromeThreshold,
        )
    }

    // MARK: - Now Playing (atmospheric hue wash)

    private static func solidHeroBackdropColor(
        hue: Double,
        washSat: Double,
        airyTopB: Double,
        avgR: Double,
        avgG: Double,
        avgB: Double,
    ) -> Color {
        let bri = max(0.10, min(0.98, airyTopB * 1.16))
        let sat = max(0.05, min(0.68, washSat * 1.5 + 0.08))
        let hueTint = Color(hue: hue, saturation: sat, brightness: bri)
        let avgTint = Color(red: avgR, green: avgG, blue: avgB)
        return blendSRGB(hueTint, avgTint, amount: 0.12)
    }

    private static func nearBlackHeroBackdropColor(avgR: Double, avgG: Double, avgB: Double) -> Color {
        let mix = 0.10
        let floor = 0.022
        return Color(
            red: min(0.12, floor + avgR * mix),
            green: min(0.12, floor + avgG * mix),
            blue: min(0.12, floor + avgB * mix),
        )
    }

    private static func shouldUseNearBlackBackdrop(
        avgLum: Double,
        avgR: Double,
        avgG: Double,
        avgB: Double,
        darkFraction: Double,
    ) -> Bool {
        let avgWCAG = relativeLuminanceSRGB(r: avgR, g: avgG, b: avgB)
        if avgWCAG <= 0.03 { return true }
        if avgLum <= 0.115 { return true }
        if darkFraction >= 0.62 && avgLum <= 0.24 { return true }
        if darkFraction >= 0.52 && avgLum <= 0.17, max(avgR, max(avgG, avgB)) <= 0.30 { return true }
        return false
    }

    private static func makeNowPlayingBackdropPalette(from cgImage: CGImage) -> BackdropPalette {
        guard let sample = downsampleArtworkPixels(from: cgImage) else { return .fallback }
        let (pixels, tw, th) = sample
        let bytesPerPixel = 4

        let bucketCount = 72
        let bucketCountD = Double(bucketCount)
        var bucketPixels = [Double](repeating: 0, count: bucketCount)
        var bucketHueSum = [Double](repeating: 0, count: bucketCount)
        var bucketSatSum = [Double](repeating: 0, count: bucketCount)
        var bucketBriSum = [Double](repeating: 0, count: bucketCount)
        var totalLum: Double = 0
        var pixelCount: Double = 0
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var darkCount = 0.0

        for i in 0 ..< tw * th {
            let o = i * bytesPerPixel
            let pa = Double(pixels[o + 3]) / 255.0
            guard pa > 0.1 else { continue }
            let r = min(1, Double(pixels[o]) / 255.0 / pa)
            let g = min(1, Double(pixels[o + 1]) / 255.0 / pa)
            let b = min(1, Double(pixels[o + 2]) / 255.0 / pa)

            let (hue, sat, bri) = rgbToHSB(RGB(r: r, g: g, b: b))
            let quickLum = 0.299 * r + 0.587 * g + 0.114 * b
            if quickLum < 0.125 { darkCount += 1 }
            totalLum += quickLum
            pixelCount += 1
            sumR += r
            sumG += g
            sumB += b

            guard sat > 0.06, bri > 0.08, bri < 0.97 else { continue }

            let bucket = min(bucketCount - 1, Int(hue * bucketCountD))
            bucketPixels[bucket] += 1
            bucketHueSum[bucket] += hue
            bucketSatSum[bucket] += sat
            bucketBriSum[bucket] += bri
        }

        let avgLum = pixelCount > 0 ? totalLum / pixelCount : 0.3
        let avgR = pixelCount > 0 ? sumR / pixelCount : 0.25
        let avgG = pixelCount > 0 ? sumG / pixelCount : 0.24
        let avgB = pixelCount > 0 ? sumB / pixelCount : 0.28
        let darkFraction = pixelCount > 0 ? darkCount / pixelCount : 0

        func finalizeSolid(_ solid: Color) -> BackdropPalette {
            let stops: [Gradient.Stop] = [
                Gradient.Stop(color: solid, location: 0),
                Gradient.Stop(color: MusicDesign.background, location: 1),
            ]
            let backdropLum = relativeLuminance(of: solid)
            let prefersDarkChrome = backdropLum >= BackdropPalette.backdropLuminanceDarkChromeThreshold
            return BackdropPalette(
                gradientStops: stops,
                heroSolidBackdropColor: solid,
                backdropRelativeLuminance: backdropLum,
                prefersDarkHeroChrome: prefersDarkChrome,
            )
        }

        let snapBlack = shouldUseNearBlackBackdrop(
            avgLum: avgLum,
            avgR: avgR,
            avgG: avgG,
            avgB: avgB,
            darkFraction: darkFraction,
        )

        guard let (winIdx, winPx) = bucketPixels.enumerated().max(by: { $0.element < $1.element }),
              winPx > 0
        else {
            if snapBlack {
                return finalizeSolid(nearBlackHeroBackdropColor(avgR: avgR, avgG: avgG, avgB: avgB))
            }
            let airyFallback = max(0.22, min(0.54, avgLum * 0.55 + 0.12))
            let solid = solidHeroBackdropColor(
                hue: 0.62,
                washSat: 0.07,
                airyTopB: airyFallback,
                avgR: avgR,
                avgG: avgG,
                avgB: avgB,
            )
            return finalizeSolid(solid)
        }

        let h = bucketHueSum[winIdx] / winPx
        let s = bucketSatSum[winIdx] / winPx
        let dominantBri = bucketBriSum[winIdx] / winPx

        let effectiveH = winPx > 2 ? h : 0.62
        let effectiveSat = winPx > 2 ? s : 0.06

        if snapBlack {
            return finalizeSolid(nearBlackHeroBackdropColor(avgR: avgR, avgG: avgG, avgB: avgB))
        }

        let washSat = min(0.28, max(0.07, effectiveSat * 0.34 + 0.055))
        let airyTopB = max(0.22, min(0.58, avgLum * 0.55 + dominantBri * 0.24 + 0.12))

        let solid = solidHeroBackdropColor(
            hue: effectiveH,
            washSat: washSat,
            airyTopB: airyTopB,
            avgR: avgR,
            avgG: avgG,
            avgB: avgB,
        )
        return finalizeSolid(solid)
    }

    // MARK: - Shared sampling

    private static func downsampleArtworkPixels(from cgImage: CGImage) -> (pixels: [UInt8], tw: Int, th: Int)? {
        let maxDim: CGFloat = 120
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 1, srcH > 1 else { return nil }

        let scale = min(maxDim / srcW, maxDim / srcH, 1)
        let tw = max(8, Int(srcW * scale))
        let th = max(8, Int(srcH * scale))

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * tw
        var pixels = [UInt8](repeating: 0, count: tw * th * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &pixels,
                  width: tw,
                  height: th,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return (pixels, tw, th)
    }

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    private static func rgbToHSB(_ rgb: RGB) -> (h: Double, s: Double, b: Double) {
        let r = rgb.r
        let g = rgb.g
        let b = rgb.b
        let mx = max(r, max(g, b))
        let mn = min(r, min(g, b))
        let d = mx - mn
        let bright = mx
        let sat = mx > 1e-9 ? d / mx : 0
        let hue: Double
        if d < 1e-9 {
            hue = 0
        } else if mx == r {
            var hh = (g - b) / d
            if g < b { hh += 6 }
            hue = hh / 6
        } else if mx == g {
            hue = ((b - r) / d + 2) / 6
        } else {
            hue = ((r - g) / d + 4) / 6
        }
        return (hue, sat, bright)
    }

    private static func blendSRGB(_ a: Color, _ b: Color, amount: Double) -> Color {
        let t = CGFloat(min(1, max(0, amount)))
        guard let u1 = rgbaComponents(a), let u2 = rgbaComponents(b) else { return a }
        return Color(
            red: Double(u1.r + (u2.r - u1.r) * t),
            green: Double(u1.g + (u2.g - u1.g) * t),
            blue: Double(u1.b + (u2.b - u1.b) * t),
        )
    }

}
