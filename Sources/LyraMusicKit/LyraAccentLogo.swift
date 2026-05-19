import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Bundled accent-colored Lyra logos (from Icon Composer `AppIcons/*.icon` → `Resources/AccentLogos/`).
enum LyraAccentLogo {
    /// Resource base name (matches ``AppAccentPreset/id``).
    static func resourceName(forAccentPresetId id: String) -> String {
        id
    }

    static func resourceURL(forAccentPresetId id: String) -> URL? {
        let name = resourceName(forAccentPresetId: id)
        let bundle = Bundle.module
        if let url = bundle.url(forResource: name, withExtension: "png") {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "AccentLogos") {
            return url
        }
        return nil
    }

    static func hasImage(forAccentPresetId id: String) -> Bool {
        resourceURL(forAccentPresetId: id) != nil
    }

    static func cgImage(forAccentPresetId id: String, maxPixelSize: CGFloat = 512) -> CGImage? {
        guard let url = resourceURL(forAccentPresetId: id),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return ArtworkImageDecoder.cgImage(from: data, maxPixelSize: maxPixelSize)
    }
}

/// Displays Icon Composer artwork for the selected accent (black-bg PNGs sit on a subtle plate so they read on dark UI).
struct LyraAccentLogoView: View {
    var accentPresetId: String
    var size: CGFloat = 80
    var cornerRadius: CGFloat?
    /// When true, draws a light plate behind the artwork (needed on black login chrome).
    var showsIconPlate: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.22
    }

    private var plateFill: Color {
        if !showsIconPlate { return .clear }
        return colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(white: 0.94)
    }

    var body: some View {
        ZStack {
            if showsIconPlate {
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .fill(plateFill)
            }
            if let cg = LyraAccentLogo.cgImage(forAccentPresetId: accentPresetId, maxPixelSize: size * 3) {
                ArtworkPlatformImage.swiftUIImage(cgImage: cg)
                    .resizable()
                    .scaledToFit()
                    .padding(size * (showsIconPlate ? 0.06 : 0))
            } else {
                LyraBrandMarkFallback(size: size * 0.88)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
        }
        .shadow(color: AppAccentPreset.preset(id: accentPresetId).color.opacity(0.28), radius: size > 48 ? 10 : 4, y: size > 48 ? 5 : 2)
        .accessibilityLabel("Lyra \(AppAccentPreset.preset(id: accentPresetId).name)")
    }
}

/// Fallback when bundle images are missing.
private struct LyraBrandMarkFallback: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MusicDesign.accent, MusicDesign.accent.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
