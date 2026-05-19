import SwiftUI

// MARK: - Luminance handoff → semantic chrome (step 3)

extension ArtworkDynamicGradient.BackdropPalette {
    /// Primary hero headline / toolbar glyphs — **luminance handoff**: white on dark backdrops, black when ``prefersDarkHeroChrome``.
    var heroChromePrimary: Color { prefersDarkHeroChrome ? .black : .white }

    /// Secondary hero line (artist).
    var heroChromeSecondary: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.58) : Color.white.opacity(0.82)
    }

    /// Tertiary metadata (year, lossless row).
    var heroChromeTertiary: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.48) : Color.white.opacity(0.55)
    }

    /// Circular glass buttons (shuffle, download, …).
    var heroGlassCircleFill: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.11) : Color.white.opacity(0.14)
    }

    var heroGlassCircleFillDisabled: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.06) : Color.white.opacity(0.08)
    }

    /// Icons sitting on glass circles.
    var heroGlassIcon: Color { prefersDarkHeroChrome ? .black : .white }

    /// Primary **Play** / **Request** capsule (high contrast vs hero wash).
    var heroPlayCapsuleBackground: Color { prefersDarkHeroChrome ? Color.black : Color.white }

    var heroPlayCapsuleForeground: Color { prefersDarkHeroChrome ? Color.white : Color.black }

    /// Optional accent on hero (e.g. shuffle) — stays Apple Music red but dims on light chrome.
    var heroAccent: Color {
        prefersDarkHeroChrome ? MusicDesign.accent.opacity(0.92) : MusicDesign.accent
    }

    /// Hairline under the hero and between track rows — matches luminance handoff (dark line on light heroes, light line on dark).
    var heroTracklistSeparator: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.14) : Color.white.opacity(0.12)
    }

    // MARK: - Now Playing (same luminance handoff as album hero)

    /// Shuffle / repeat capsule when the mode is **on** (stronger than ``heroGlassCircleFill``).
    var nowPlayingToggleCapsuleActive: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.22) : Color.white.opacity(0.22)
    }

    /// Sheet drag indicator.
    var nowPlayingDragHandle: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.28) : Color.white.opacity(0.28)
    }

    /// High-emphasis dismiss chevron.
    var nowPlayingDismissGlyph: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.9) : Color.white.opacity(0.9)
    }

    /// Time labels under the scrubber (tertiary chrome).
    var nowPlayingTimeLabel: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.48) : Color.white.opacity(0.5)
    }

    /// Scrubber track well (subtle vs ``heroChromePrimary`` progress).
    var nowPlayingScrubberTrackFill: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.18) : Color.white.opacity(MusicDesign.nowPlayingSliderDimOpacity)
    }

    var nowPlayingScrubberProgressFill: Color {
        heroChromePrimary
    }

    var nowPlayingScrubberStroke: Color {
        prefersDarkHeroChrome ? Color.black.opacity(MusicDesign.nowPlayingSliderStrokeOpacity) : Color.white.opacity(MusicDesign.nowPlayingSliderStrokeOpacity)
    }

    /// Bottom tab row: inactive label (AirPlay, etc.).
    var nowPlayingBottomChromeMuted: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.48) : Color.white.opacity(0.5)
    }

    /// Queue empty-state secondary line.
    var nowPlayingQueueHint: Color {
        prefersDarkHeroChrome ? Color.black.opacity(0.35) : Color.white.opacity(0.3)
    }

    /// Volume row speaker glyphs (matches ``nowPlayingTimeLabel`` rhythm).
    var nowPlayingVolumeGlyph: Color { nowPlayingTimeLabel }
}

// MARK: - Album backdrop (step 2): full-screen flat artwork tint (no gradients)

/// Full-screen **solid** color from artwork analysis — no banding, no gradients. Chrome follows ``BackdropPalette``.
struct AlbumHeroBackdropView: View {
    let artworkURL: URL?
    let palette: ArtworkDynamicGradient.BackdropPalette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Rectangle()
                .fill(palette.heroSolidBackdropColor)
                .frame(width: w, height: h)
                .id(artworkURL?.absoluteString ?? "")
        }
        .ignoresSafeArea()
    }
}
