import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Artwork-derived backdrop palette (flat hero tint + adaptive chrome). Gradients are not used in the album UI.
enum ArtworkDynamicGradient {
    private static let fallbackHeroSolid = Color(red: 54 / 255, green: 48 / 255, blue: 62 / 255)

    /// Neutral fallback for APIs that still ask for gradient stops (two flat anchors only).
    static let fallbackStops: [Gradient.Stop] = [
        Gradient.Stop(color: fallbackHeroSolid, location: 0),
        Gradient.Stop(color: MusicDesign.background, location: 1),
    ]

    /// Result of **color extraction** + **contrast / luminance handoff** for album hero chrome (Liquid Glass–style stacks consume this).
    struct BackdropPalette: Sendable {
        /// Legacy two-stop ramp (solid hero → black); prefer ``heroSolidBackdropColor`` + flat fills in UI.
        let gradientStops: [Gradient.Stop]
        /// Flat full-screen album backdrop tint — sampled from artwork (**no** gradient).
        let heroSolidBackdropColor: Color
        /// WCAG relative luminance (0…1) of ``heroSolidBackdropColor`` (same value used for chrome inversion).
        let backdropRelativeLuminance: Double
        /// When `true`, hero + toolbar use **dark** foreground (black glyphs, dark-filled pills) because ``heroSolidBackdropColor`` reads as **light**.
        let prefersDarkHeroChrome: Bool

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
    static func analyzeBackdrop(from artworkURL: URL?) async -> BackdropPalette {
        guard let url = artworkURL else { return .fallback }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = await ArtworkURLCache.data(for: url)
        }
        guard let data, !data.isEmpty, let cgImage = cgImage(fromImageData: data) else { return .fallback }
        return await Task.detached(priority: .utility) {
            makeBackdropPalette(from: cgImage)
        }.value
    }

    static func gradientStops(from artworkURL: URL?) async -> [Gradient.Stop] {
        await analyzeBackdrop(from: artworkURL).gradientStops
    }

    private static func cgImage(fromImageData data: Data) -> CGImage? {
#if canImport(UIKit)
        return UIImage(data: data)?.cgImage
#elseif canImport(AppKit)
        guard let img = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
#else
        return nil
#endif
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

    /// Vibrant flat surface: dominant hue + lifted saturation/brightness, lightly anchored to frame-average RGB.
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

    /// Nearly-black albums (OLED-style UI): backdrop stays **almost black** with a whisper of average tint.
    private static func nearBlackHeroBackdropColor(avgR: Double, avgG: Double, avgB: Double) -> Color {
        let mix = 0.10
        let floor = 0.022
        return Color(
            red: min(0.12, floor + avgR * mix),
            green: min(0.12, floor + avgG * mix),
            blue: min(0.12, floor + avgB * mix),
        )
    }

    /// True when artwork is overwhelmingly dark — avoid hue-bucket “mud” on mostly-black covers.
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

    private static func makeBackdropPalette(from cgImage: CGImage) -> BackdropPalette {
        let maxDim: CGFloat = 120
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 1, srcH > 1 else { return .fallback }

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
        else { return .fallback }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))

        // --- Dominant hue: find the most FREQUENT hue, not the most vivid ---
        let bucketCount = 72          // 5° per bucket for finer hue precision
        let bucketCountD = Double(bucketCount)
        var bucketPixels = [Double](repeating: 0, count: bucketCount)
        var bucketHueSum = [Double](repeating: 0, count: bucketCount)
        var bucketSatSum = [Double](repeating: 0, count: bucketCount)
        var bucketBriSum = [Double](repeating: 0, count: bucketCount)
        var totalLum: Double = 0
        var pixelCount: Double = 0
        /// Whole-frame average sRGB — anchors a **muted slate** wash (Apple Music rarely shows neon saturation).
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

        // Atmospheric tint — don’t force dark covers toward mid-gray (older `max(0.36, …)` read as brown mud).
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
