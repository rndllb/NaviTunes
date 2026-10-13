import Foundation
import SwiftUI
import Testing

@testable import VellumMusicKit

/// T681. "The cover's drop shadow gets bigger during the transition phase." The Now Playing
/// cover is three layers during a blend (base, outgoing held on top, incoming fading in) and
/// `.shadow` on a layered view draws one shadow per layer, so the three added up. The cover's
/// shadow is now cast by the base layer alone, inside `AutoMixCoverCrossfade`, before the blend
/// layers are laid over it. These tests render the shipping `AutoMixCoverCrossfade` with plain
/// shapes through `ImageRenderer` and measure the shadow below the cover before, mid and after
/// a blend.
@MainActor
@Suite("AutoMix cover shadow")
struct AutoMixCoverShadowTests {
    static let side: CGFloat = 120
    static let pad: CGFloat = 80
    static let shadow = AutoMixCoverShadow(color: .black.opacity(0.45), radius: 20, y: 12)

    /// The cover stack exactly as `NowPlayingView.artworkView` composes it, with the hero's
    /// shadow (radius 20, y 12, 45 %), on a white page. `onBase: true` is the shipping code
    /// (the shadow cast by the base layer); `onBase: false` is the old code's `.shadow` on the
    /// finished stack.
    static func page(blending: Bool, progress: Double, onBase: Bool) -> some View {
        let cover = AutoMixCoverCrossfade(isBlending: blending, progress: progress, reduceMotion: true, shadow: onBase ? shadow : nil) {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.2, green: 0.4, blue: 0.9))
        } outgoing: {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.9, green: 0.3, blue: 0.2))
        } incoming: {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.2, green: 0.8, blue: 0.3))
        }
        .frame(width: side, height: side)
        return Group {
            if onBase {
                cover
            } else {
                cover.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            }
        }
        .padding(pad)
        .background(Color.white)
    }

    /// Render at 1× and read the luminance down the cover's centre column below its bottom
    /// edge: the shadow's extent (rows darker than the page by more than 1 %), its depth (the
    /// darkest row) and its summed darkness.
    struct Shadow: CustomStringConvertible {
        var extentPoints: Int
        var minLuminance: Double
        var summedDarkness: Double
        var description: String { String(format: "extent %d pt, darkest %.3f, summed %.2f", extentPoints, minLuminance, summedDarkness) }
    }

    static func measure(_ view: some View) -> Shadow? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let x = Int(pad + side / 2)
        let coverBottom = Int(pad + side)
        var extent = 0, minLum = 1.0, summed = 0.0
        for y in (coverBottom + 1) ..< height {
            let i = (y * width + x) * 4
            let lum = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
            if lum < 0.99 { extent = y - coverBottom }
            minLum = min(minLum, lum)
            summed += 1 - lum
        }
        return Shadow(extentPoints: extent, minLuminance: minLum, summedDarkness: summed)
    }

    @Test("the shadow cast by the base cover is the same before, mid and after a blend")
    func constantShadow() throws {
        let before = try #require(Self.measure(Self.page(blending: false, progress: 0, onBase: true)))
        let mid = try #require(Self.measure(Self.page(blending: true, progress: 0.5, onBase: true)))
        let after = try #require(Self.measure(Self.page(blending: false, progress: 1, onBase: true)))
        print("T681 on base: before \(before); mid \(mid); after \(after)")
        #expect(before.extentPoints > 10)                                 // there is a shadow to measure
        #expect(mid.extentPoints == before.extentPoints)
        #expect(after.extentPoints == before.extentPoints)
        #expect(abs(mid.summedDarkness - before.summedDarkness) < before.summedDarkness * 0.01)
        #expect(abs(after.summedDarkness - before.summedDarkness) < before.summedDarkness * 0.01)
        #expect(abs(mid.minLuminance - before.minLuminance) < 0.005)
        #expect(abs(after.minLuminance - before.minLuminance) < 0.005)
    }

    @Test("the old code's shadow on the layered cover is wider and darker mid-blend than before it")
    func layeredShadowGrows() throws {
        let before = try #require(Self.measure(Self.page(blending: false, progress: 0, onBase: false)))
        let mid = try #require(Self.measure(Self.page(blending: true, progress: 0.5, onBase: false)))
        print("T681 layered: before \(before); mid \(mid)")
        // Three stacked shadows: visibly wider, darker and deeper than one. This pins the defect
        // so a future `.shadow` put back on the layered view fails here.
        #expect(mid.extentPoints > before.extentPoints + 4)
        #expect(mid.minLuminance < before.minLuminance - 0.05)
        #expect(mid.summedDarkness > before.summedDarkness * 1.3)
    }
}
