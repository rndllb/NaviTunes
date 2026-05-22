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

    // MARK: - Track row trailing actions (＋, download, progress ring)

    /// Primary affordance on the row backdrop (plus, download arrow, cached disk glyph).
    var trackOfflineActionPrimary: Color { heroGlassIcon }

    /// Secondary affordances (request cloud, muted missing).
    var trackOfflineActionSecondary: Color { heroChromeSecondary }

    /// Active download ring stroke.
    var trackOfflineProgressStroke: Color { heroChromePrimary }

    /// Idle download ring track.
    var trackOfflineRingTrack: Color { heroTracklistSeparator }

    /// Filled disk behind the cached arrow.
    var trackOfflineCachedDiskFill: Color { heroGlassCircleFill }

    /// ``FavoritePlaylistView`` — static white wash + dark hero chrome.
    static let favoriteSongsHero: Self = {
        let backdrop = Color.white
        return ArtworkDynamicGradient.BackdropPalette(
            gradientStops: [
                Gradient.Stop(color: backdrop, location: 0),
                Gradient.Stop(color: backdrop, location: 1),
            ],
            heroSolidBackdropColor: backdrop,
            backdropRelativeLuminance: 0.98,
            prefersDarkHeroChrome: true,
        )
    }()

    /// Standard library / playlist lists (no artwork backdrop) — handoff from system color scheme.
    static func listSurface(colorScheme: ColorScheme) -> Self {
        let prefersDarkChrome = colorScheme == .light
        return ArtworkDynamicGradient.BackdropPalette(
            gradientStops: ArtworkDynamicGradient.fallbackStops,
            heroSolidBackdropColor: MusicDesign.background,
            backdropRelativeLuminance: prefersDarkChrome ? 0.85 : 0.15,
            prefersDarkHeroChrome: prefersDarkChrome,
        )
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
