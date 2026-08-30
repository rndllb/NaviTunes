import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Apple Music–style artist page. Stretchy banner hero with transparent nav bar
/// (banner extends through the safe area and stretches with overscroll), Top
/// Songs as a paged horizontal carousel of 4-row columns, classified discography
/// with size hierarchy (primary discography shelves share one card size; Live/Compilations
/// use the same grid as Albums and Singles & EPs),
/// iTunes releases the user's server doesn't have, About with inline MORE expansion,
/// and Similar Artists.
///
/// Driven by ``ArtistViewModel`` which loads the server catalog plus the active
/// acquisition plugin's discography (Lidarr / DroppedNeedle) when configured.
struct ArtistPageView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: ArtistViewModel
    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette
    /// Local push target for "Go to Album" menu actions fired from rows inside this
    /// artist page. Using `@State` here (not `app.presentedDeepLink`) keeps the push
    /// on **this** page's NavigationStack, so Back returns to this artist instead of
    /// the tab root.
    @State private var navigateAlbum: AlbumSummary?
    @State private var navigateAbout = false

    /// This page's cover-zoom key. Held rather than derived from `model` so it is stable from
    /// `init` — the animator asks for geometry before the body has run.
    private let coverZoomPageId: String

    init(input: ArtistPageInput) {
        _model = StateObject(wrappedValue: ArtistViewModel(input: input))
        _backdropPalette = State(initialValue: ArtworkDynamicGradient.seededBackdrop(for: input.serverArtworkURL, style: .artistPage))
        coverZoomPageId = input.coverZoomPageId
    }

    private static let scrollCoordinateSpace = "ArtistPageView.scroll"

    var body: some View {
        ZStack(alignment: .top) {
            AlbumHeroBackdropView(
                artworkURL: model.bannerArtworkURL,
                palette: backdropPalette,
            )

            ScrollView {
                LazyVStack(spacing: 0) {
                    ArtistHeroSection(
                        model: model,
                        scrollSpace: Self.scrollCoordinateSpace,
                        backdropPalette: backdropPalette,
                        showsInfoButton: model.hasAboutSection,
                        onInfo: { navigateAbout = true },
                        coverZoomId: coverZoomPageId,
                    )
                    ArtistLatestReleaseCard(model: model, onGoToAlbum: { navigateAlbum = $0 })
                    ArtistAcquisitionBanner(model: model)

                    if artistPageShowsSkeleton {
                        ArtistPageLoadingSkeletonSections()
                            .transition(.opacity)
                    } else {
                        Group {
                            ArtistTopSongsSection(model: model, onGoToAlbum: { navigateAlbum = $0 })
                            ArtistDiscographyCarousel(model: model, bucket: .albums, title: "Albums", layout: .prominent)
                            ArtistDiscographyCarousel(model: model, bucket: .singlesAndEPs, title: "Singles & EPs", layout: .prominent)
                            ArtistDiscographyCarousel(model: model, bucket: .live, title: "Live Albums", layout: .prominent)
                            ArtistDiscographyCarousel(model: model, bucket: .compilations, title: "Compilations", layout: .prominent)
                            ArtistSimilarSection(model: model)
                        }
                        .transition(.opacity)
                    }

                    Spacer(minLength: 32)
                }
                .animation(.easeInOut(duration: 0.18), value: artistPageShowsSkeleton)
            }
            .modifier(ArtistPageScrollChromeModifier(
                scrollSpace: Self.scrollCoordinateSpace,
                backdropPalette: backdropPalette,
            ))
        }
        .ignoresSafeArea(edges: .top)
        // The *animation* is a no-op unless the tile or row that opened this page marked itself
        // `.custom` — the dozen programmatic pushes of this view (Now Playing, "Go to Artist",
        // deep links, Following) keep the ordinary slide.
        //
        // **The installer is not a no-op**, and the old wording here claiming otherwise is what
        // made an earlier attempt at the swipe bug look correct on paper. It installs the
        // navigation-delegate proxy and the shared edge pan on the navigation controller
        // regardless of how this page was pushed, so a page reached by a button is still subject
        // to whatever gesture arbitration that proxy answers. That is precisely how a
        // button-pushed artist page ended up unable to swipe: not because anything here ran
        // differently, but because a *global* `shouldBeRequiredToFailBy` answer applied to it
        // while the per-screen permission behind it did not. See
        // `CoverZoomNavigationDelegate.gestureRecognizer(_:shouldBeRequiredToFailBy:)`.
        .coverZoomCustomTransition(id: coverZoomPageId)
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .musicHeroAlbumNavigationChrome(palette: backdropPalette)
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                ArtistFollowButton(
                    name: model.displayName,
                    mbid: model.pluginProfile?.mbid,
                    coverURL: model.bannerArtworkURL
                )
                    .tint(backdropPalette.heroChromePrimary)

                Menu {
                    Button(action: toggleFavoriteArtist) {
                        let favorited = app.isArtistFavorited(name: model.displayName)
                        Label(
                            favorited ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: favorited ? "star.fill" : "star",
                        )
                    }
                    if let url = artistShareURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(backdropPalette.heroChromePrimary)
            }
        }
        .onAppear(perform: seedCachedArtistBackdropIfNeeded)
        .task(id: artistBackdropTaskKey) {
            guard app.albumBackdropEnabled else {
                backdropPalette = .listSurface(colorScheme: colorScheme)
                return
            }
            if let url = model.bannerArtworkURL {
                if let cached = ArtworkDynamicGradient.cachedBackdrop(for: url, style: .artistPage) {
                    backdropPalette = cached
                    return
                }
                backdropPalette = await ArtworkDynamicGradient.analyzeBackdrop(from: url, style: .artistPage)
            } else {
                // No photo yet: stay on the neutral surface instead of generating a random
                // colored mesh gradient that flashes before the real artwork loads.
                backdropPalette = .listSurface(colorScheme: colorScheme)
            }
        }
        .task(id: artistTaskKey) {
            await model.load(using: app)
        }
        .refreshable {
            await model.load(using: app)
        }
        .overlay(alignment: .center) {
            if !model.hasAnyContent, !artistPageShowsSkeleton,
               !model.isLoadingServerCatalog, !model.isLoadingEnrichment {
                ContentUnavailableView(
                    "No info for this artist",
                    systemImage: "mic",
                    description: Text("We couldn't find any songs, releases, or biography for \(model.displayName).")
                )
                .padding(.horizontal, 24)
            }
        }
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: app.isAlbumInLibrary(album.id))
        }
        .navigationDestination(isPresented: $navigateAbout) {
            ArtistAboutPageView(model: model, palette: backdropPalette)
        }
    }

    private var artistTaskKey: String {
        switch model.input {
        case .libraryArtist(let a): return "lib:\(a.id)"
        case .named(let n): return "name:\(n)"
        }
    }

    private var artistPageShowsSkeleton: Bool {
        !model.hasRenderableBodyContent
            && (model.isLoadingServerCatalog
                || model.isLoadingEnrichment
                || model.isLoadingTopSongs
                || model.isLoadingDiscography)
    }

    /// Shareable link for the artist — an Apple Music search URL that opens to this artist.
    private var artistShareURL: URL? {
        let q = model.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty else { return nil }
        return URL(string: "https://music.apple.com/search?term=\(q)")
    }

    private func toggleFavoriteArtist() {
        let wasFavorited = app.isArtistFavorited(name: model.displayName)
        app.toggleFavoriteArtist(name: model.displayName)
        app.showTransientToast(wasFavorited ? "Removed from Favorites" : "Added to Favorites")
    }

    private var artistBackdropTaskKey: String {
        let url = model.bannerArtworkURL?.absoluteString ?? ""
        return "\(url)-\(app.albumBackdropEnabled)-\(colorScheme)"
    }

    private func seedCachedArtistBackdropIfNeeded() {
        guard app.albumBackdropEnabled,
              let url = model.bannerArtworkURL,
              let cached = ArtworkDynamicGradient.cachedBackdrop(for: url, style: .artistPage)
        else { return }
        backdropPalette = cached
    }
}

// MARK: - Artist page backdrop palette (section chrome)

private struct ArtistPageBackdropPaletteKey: EnvironmentKey {
    static let defaultValue: ArtworkDynamicGradient.BackdropPalette? = nil
}

extension EnvironmentValues {
    fileprivate var artistPageBackdropPalette: ArtworkDynamicGradient.BackdropPalette? {
        get { self[ArtistPageBackdropPaletteKey.self] }
        set { self[ArtistPageBackdropPaletteKey.self] = newValue }
    }
}

/// Adaptive label colors for artist-page content on the artwork backdrop.
@MainActor
private enum ArtistPageChrome {
    static func primary(app: AppModel, palette: ArtworkDynamicGradient.BackdropPalette?) -> Color {
        guard app.albumBackdropEnabled, let palette else { return .primary }
        return palette.heroChromePrimary
    }

    static func secondary(app: AppModel, palette: ArtworkDynamicGradient.BackdropPalette?) -> Color {
        guard app.albumBackdropEnabled, let palette else { return MusicDesign.secondaryLabel }
        return palette.heroChromeSecondary
    }

    static func tertiary(app: AppModel, palette: ArtworkDynamicGradient.BackdropPalette?) -> Color {
        guard app.albumBackdropEnabled, let palette else { return MusicDesign.secondaryLabel.opacity(0.85) }
        return palette.heroChromeTertiary
    }
}

// MARK: - Hero (stretchy banner that extends behind the nav bar and grows on overscroll)

private struct ArtistHeroSection: View {
    @ObservedObject var model: ArtistViewModel
    let scrollSpace: String
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette
    var showsInfoButton: Bool = false
    var onInfo: () -> Void = {}
    /// Cover-zoom key for the page. The banner is this destination's hero rect.
    var coverZoomId: String = ""

    private var bannerURL: URL? { model.bannerArtworkURL }

    private var baseHeight: CGFloat {
        #if os(iOS)
        let screenH = UIScreen.main.bounds.height
        return min(
            max(screenH * MusicDesign.artistHeroHeightScreenFactor, MusicDesign.artistHeroMinHeight),
            screenH * MusicDesign.artistHeroMaxHeightScreenFactor
        )
        #else
        return 440
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            StretchyHeaderContainer(
                scrollSpace: scrollSpace,
                baseHeight: baseHeight,
                clipBanner: false,
            ) {
                ArtistHeroBannerStack(
                    url: bannerURL,
                    seed: model.displayName,
                    backdropColor: backdropPalette.heroSolidBackdropColor,
                )
            } overlay: { _ in
                ArtistHeroOverlay(
                    model: model,
                    showsInfoButton: showsInfoButton,
                    onInfo: onInfo,
                )
            }
            // Square corners: the banner is full-bleed, so the card's radius should reach zero
            // as it arrives rather than keeping the tile's rounding.
            .coverZoomHeroAnchor(id: coverZoomId, cornerRadius: 0)
        }
        .padding(.bottom, -MusicDesign.artistHeroBottomSeamOverlap)
    }
}

/// Apple Music–style hero: sharp portrait on top, feathered blur melt into the page tint at the play row.
private struct ArtistHeroBannerStack: View {
    let url: URL?
    let seed: String
    let backdropColor: Color

    @State private var cgImage: CGImage?
    @State private var blurredImage: CGImage?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = geo.size.width

            ZStack(alignment: .top) {
                // Solid page tint under the photo so the bottom edge melts cleanly.
                backdropColor

                if let cgImage {
                    let image = ArtworkPlatformImage.swiftUIImage(cgImage: cgImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()

                    // Sharp portrait.
                    image

                    // Soft-focus melt — pre-blurred bitmap (same mask as before). Live
                    // SwiftUI `.blur(radius: 30)` on this full-bleed hero re-ran whenever
                    // the mini player opened/closed and AppModel republished.
                    meltLayer(width: width, height: height)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.54),
                                    .init(color: .white.opacity(0.5), location: 0.70),
                                    .init(color: .white, location: 0.84),
                                    .init(color: .white, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom,
                            )
                        )
                        .allowsHitTesting(false)

                    // Colour melt into the page background behind the title + play controls.
                    LinearGradient(
                        stops: [
                            .init(color: backdropColor.opacity(0), location: 0),
                            .init(color: backdropColor.opacity(0), location: 0.58),
                            .init(color: backdropColor.opacity(0.35), location: 0.78),
                            .init(color: backdropColor.opacity(0.74), location: 0.92),
                            .init(color: backdropColor, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom,
                    )
                    .allowsHitTesting(false)
                } else if url != nil {
                    MusicShimmerSurface(cornerRadius: 0)
                        .frame(width: width, height: height)
                } else {
                    backdropColor
                        .frame(width: width, height: height)
                        .overlay {
                            Image(systemName: "music.mic")
                                .font(.system(size: 52, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.10))
                        }
                }
            }
            .frame(width: width, height: height)
        }
        .task(id: url?.absoluteString ?? "gradient-\(seed)") {
            await loadImage()
        }
    }

    @ViewBuilder
    private func meltLayer(width: CGFloat, height: CGFloat) -> some View {
        if let blurredImage {
            ArtworkPlatformImage.swiftUIImage(cgImage: blurredImage)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
        }
    }

    private func loadImage() async {
        guard let url else {
            await MainActor.run {
                cgImage = nil
                blurredImage = nil
            }
            return
        }
        let loaded = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: 960)
        #if os(iOS)
        let displayedWidth = UIScreen.main.bounds.width
        #else
        let displayedWidth: CGFloat = 390
        #endif
        let blurred: CGImage?
        if let loaded {
            let radius = ArtworkGaussianBlur.matchingSwiftUIRadius(
                MusicDesign.artistHeroImageBlurRadius,
                sourceWidth: loaded.width,
                displayedWidth: displayedWidth
            )
            blurred = await Task.detached(priority: .utility) {
                ArtworkGaussianBlur.cgImage(from: loaded, radius: radius)
            }.value
        } else {
            blurred = nil
        }
        await MainActor.run {
            cgImage = loaded
            blurredImage = blurred
        }
    }
}

private struct ArtistHeroOverlay: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel
    var showsInfoButton: Bool
    var onInfo: () -> Void

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text(model.displayName)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    ZStack {
                        ArtistHeroPlayButton(model: model)
                        if showsInfoButton {
                            ArtistHeroSideIconButton(
                                systemImage: "info",
                                foreground: .white,
                                accessibilityLabel: "About \(model.displayName)",
                                action: onInfo,
                            )
                            .offset(x: -ArtistHeroControlButton.sideOffsetFromPlayCenter)
                        }
                        ArtistHeroFavoriteButton(name: model.displayName)
                            .offset(x: ArtistHeroControlButton.sideOffsetFromPlayCenter)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, MusicDesign.artistHeroControlsBottomInset)
            }
        }
    }
}

/// Apple Music–style dark circular side control (info / favorite).
private struct ArtistHeroSideIconButton: View {
    let systemImage: String
    let foreground: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: ArtistHeroControlButton.sideDiameter, height: ArtistHeroControlButton.sideDiameter)
                .background(Circle().fill(.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Shared hero control sizing (play + side glass buttons).
private enum ArtistHeroControlButton {
    static let playDiameter: CGFloat = 68
    static let sideDiameter: CGFloat = 46
    static let sideSpacing: CGFloat = 16

    /// Horizontal offset for info / favorite so play stays at the true screen center.
    static var sideOffsetFromPlayCenter: CGFloat {
        playDiameter / 2 + sideSpacing + sideDiameter / 2
    }
}

private struct ArtistHeroFavoriteButton: View {
    @EnvironmentObject private var app: AppModel
    let name: String

    private var isFavorited: Bool {
        app.isArtistFavorited(name: name)
    }

    var body: some View {
        ArtistHeroSideIconButton(
            systemImage: isFavorited ? "star.fill" : "star",
            foreground: isFavorited ? MusicDesign.accent : .white,
            accessibilityLabel: isFavorited ? "Remove from favorites" : "Add to favorites",
        ) {
            let wasFavorited = isFavorited
            app.toggleFavoriteArtist(name: name)
            app.showTransientToast(wasFavorited ? "Removed from Favorites" : "Added to Favorites")
        }
    }
}

private struct ArtistHeroPlayButton: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel

    var body: some View {
        Button {
            Task { await playAll(mode: app.artistPlayMode) }
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.88))
                .offset(x: 2.5)
                .frame(width: ArtistHeroControlButton.playDiameter, height: ArtistHeroControlButton.playDiameter)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!model.hasPlayableTracks)
        .opacity(model.hasPlayableTracks ? 1 : 0.45)
        .contextMenu {
            ForEach(ArtistPlayMode.allCases) { mode in
                Button {
                    Task { await playAll(mode: mode) }
                } label: {
                    Label(mode.playMenuTitle, systemImage: "play.fill")
                }
                .disabled(model.playbackTracks(for: mode).isEmpty)
            }
        }
    }

    private func playAll(mode: ArtistPlayMode) async {
        let tracks = model.playbackTracks(for: mode)
        guard let lib = app.activeLibrary, !tracks.isEmpty else { return }
        try? await app.player.playAlbum(library: lib, tracks: tracks, startIndex: 0)
    }
}

/// Generic stretchy-header container. Renders the banner edge-to-edge, extends
/// it through the top safe area, and grows the banner height by any positive
/// scroll offset (pull-down overscroll) so the image appears to extend infinitely
/// upward — matching Apple Music's artist page.
private struct StretchyHeaderContainer<Banner: View, Overlay: View>: View {
    let scrollSpace: String
    let baseHeight: CGFloat
    var clipBanner: Bool = true
    @ViewBuilder var banner: () -> Banner
    @ViewBuilder var overlay: (CGFloat) -> Overlay

    var body: some View {
        GeometryReader { proxy in
            let yOffset = proxy.frame(in: .named(scrollSpace)).minY
            let extra = max(yOffset, 0)
            let safeAreaTop = proxy.safeAreaInsets.top
            let bannerHeight = baseHeight + extra + safeAreaTop

            ZStack(alignment: .bottom) {
                Group {
                    if clipBanner {
                        banner()
                            .frame(width: proxy.size.width, height: bannerHeight)
                            .clipped()
                    } else {
                        banner()
                            .frame(width: proxy.size.width, height: bannerHeight)
                    }
                }

                overlay(baseHeight + extra)
                    .frame(width: proxy.size.width, height: baseHeight + extra)
            }
            .frame(width: proxy.size.width, height: bannerHeight)
            .offset(y: -extra - safeAreaTop)
        }
        .frame(height: baseHeight)
    }
}

/// Banner image: AsyncImage when a remote URL exists, otherwise a deterministic
/// gradient seeded by the artist name (Apple Music–style premium fallback).

/// Smart fallback for missing artwork: deterministic 2-stop gradient seeded by
/// the artist name. Replaces the flat gray placeholder that breaks the premium
/// feel when an image is missing.
private struct ArtistGradientFallback: View {
    let seed: String

    var body: some View {
        let palette = Self.palette(for: seed)
        LinearGradient(
            colors: palette,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.mic")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.18))
        }
    }

    /// Deterministic palette from a stable hash of the seed string so the same
    /// artist always gets the same colors across sessions.
    static func palette(for seed: String) -> [Color] {
        let hash = seed.unicodeScalars.reduce(into: 0) { acc, scalar in
            acc = ((acc << 5) &+ acc) &+ Int(scalar.value)
        }
        let pairs: [(Color, Color)] = [
            (.purple.opacity(0.85), .indigo.opacity(0.55)),
            (.blue.opacity(0.85), .teal.opacity(0.55)),
            (.pink.opacity(0.85), .orange.opacity(0.55)),
            (.red.opacity(0.85), .pink.opacity(0.55)),
            (.green.opacity(0.85), .teal.opacity(0.55)),
            (.orange.opacity(0.85), .yellow.opacity(0.55)),
            (.cyan.opacity(0.85), .blue.opacity(0.55)),
            (.purple.opacity(0.85), .pink.opacity(0.55)),
        ]
        let idx = abs(hash) % pairs.count
        let pair = pairs[idx]
        return [pair.0, pair.1, .black.opacity(0.4)]
    }
}

// MARK: - Section header

private struct ArtistSectionHeader: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette

    let title: String

    private var titleColor: Color {
        ArtistPageChrome.primary(app: app, palette: backdropPalette)
    }

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(titleColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)
    }
}

// MARK: - Latest release (featured card under the hero)

private struct ArtistLatestReleaseCard: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette
    @Environment(\.colorScheme) private var colorScheme
    let onGoToAlbum: (AlbumSummary) -> Void

    private let cornerRadius: CGFloat = 20

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private var titleColor: Color { ArtistPageChrome.primary(app: app, palette: backdropPalette) }
    private var subtitleColor: Color { ArtistPageChrome.secondary(app: app, palette: backdropPalette) }

    var body: some View {
        if let release = model.latestRelease {
            let serverAlbum = model.serverAlbum(matching: release)
            HStack(spacing: 12) {
                NavigationLink {
                    destination(release: release, serverAlbum: serverAlbum)
                } label: {
                    rowContent(release: release)
                }
                .buttonStyle(.plain)

                addButton(release: release, serverAlbum: serverAlbum)
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.08)),
            )
            .overlay(MusicDesign.artworkSubtleBorderOverlay(cornerRadius: cornerRadius, colorScheme: colorScheme))
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private func rowContent(release: AcquisitionRelease) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: release.artworkURL, cornerRadius: MusicDesign.albumCorner)
                .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 2) {
                if let date = release.releaseDate {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                }
                Text(release.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                if let count = release.trackCount {
                    Text(count == 1 ? "1 song" : "\(count) songs")
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func destination(release: AcquisitionRelease, serverAlbum: AlbumSummary?) -> some View {
        if let serverAlbum {
            ServerPlaylistDetailView(album: serverAlbum, librarySource: app.isAlbumInLibrary(serverAlbum.id))
        } else {
            BrowseAlbumDetailView(source: .chartBrowse(
                artistName: release.artist,
                title: release.title,
                imageURL: release.artworkURL,
                kind: release.bucket == .singlesAndEPs ? "EP" : "Album",
                albumId: release.trackLookupId,
            ))
        }
    }

    @ViewBuilder
    private func addButton(release: AcquisitionRelease, serverAlbum: AlbumSummary?) -> some View {
        let inLibrary = serverAlbum.map { app.isAlbumInLibrary($0.id) } ?? false
        Button {
            Task { await addOrRequest(release: release, serverAlbum: serverAlbum) }
        } label: {
            Image(systemName: inLibrary ? "checkmark" : "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(inLibrary ? subtitleColor : titleColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inLibrary ? "In library" : (serverAlbum == nil ? "Request album" : "Add to library"))
    }

    private func addOrRequest(release: AcquisitionRelease, serverAlbum: AlbumSummary?) async {
        if let serverAlbum {
            guard !app.isAlbumInLibrary(serverAlbum.id) else { return }
            await app.addAlbumToLibrary(serverAlbum)
        } else {
            _ = await app.requestAcquisition(release.acquisitionRequest)
        }
    }
}

// MARK: - Acquisition availability

private struct ArtistAcquisitionBanner: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel

    var body: some View {
        if model.showsCannotRequestBanner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("This artist isn’t in \(app.acquisitionCapabilities.displayName), so albums here can’t be requested.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MusicDesign.tertiarySurfaceFill)
        }
    }
}

// MARK: - Top Songs (paginated horizontal carousel: each page is 4 rows tall)

private struct ArtistTopSongsSection: View {
    @ObservedObject var model: ArtistViewModel
    let onGoToAlbum: (AlbumSummary) -> Void
    @State private var requestSheetFor: ArtistTopSongRow?

    private static let rowsPerPage = 4

    private var pages: [[ArtistTopSongRow]] {
        guard !model.topSongs.isEmpty else { return [] }
        return stride(from: 0, to: model.topSongs.count, by: Self.rowsPerPage).map {
            Array(model.topSongs[$0..<min($0 + Self.rowsPerPage, model.topSongs.count)])
        }
    }

    var body: some View {
        if !pages.isEmpty {
            VStack(spacing: 0) {
                ArtistSectionHeader(title: "Top Songs")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                            ArtistTopSongsPage(
                                rows: page,
                                canRequest: model.canRequestViaAcquisition,
                                onRequest: { requestSheetFor = $0 },
                                onGoToAlbum: onGoToAlbum
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .padding(.bottom, 4)
            .sheet(item: $requestSheetFor) { row in
                NavigationStack {
                    BrowseAlbumDetailView(source: .chartBrowse(
                        artistName: row.artist,
                        title: row.albumTitle ?? row.title,
                        imageURL: row.artworkURL,
                        kind: "Single",
                        albumId: nil
                    ))
                }
            }
        }
    }
}

/// One page of Top Songs (4 rows). Sized to ~92% of viewport so the next page
/// peeks in at the trailing edge — Apple Music's paging affordance.
private struct ArtistTopSongsPage: View {
    let rows: [ArtistTopSongRow]
    let canRequest: Bool
    let onRequest: (ArtistTopSongRow) -> Void
    let onGoToAlbum: (AlbumSummary) -> Void

    private var pageWidth: CGFloat {
        #if os(iOS)
        return UIScreen.main.bounds.width - 56
        #else
        return 380
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ArtistTopSongRowView(
                    row: row,
                    canRequest: canRequest,
                    onRequest: onRequest,
                    onGoToAlbum: onGoToAlbum
                )
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(MusicDesign.secondaryLabel.opacity(0.18))
                        .frame(height: 0.5)
                        .padding(.leading, 60)
                }
            }
        }
        .frame(width: pageWidth)
    }
}

private struct ArtistTopSongRowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette
    let row: ArtistTopSongRow
    let canRequest: Bool
    let onRequest: (ArtistTopSongRow) -> Void
    let onGoToAlbum: (AlbumSummary) -> Void

    private let artSide: CGFloat = 44

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                AlbumArtworkView(url: row.artworkURL, cornerRadius: 4)
                    .frame(width: artSide, height: artSide)

                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            row.libraryTrack == nil
                                ? ArtistPageChrome.secondary(app: app, palette: backdropPalette)
                                : ArtistPageChrome.primary(app: app, palette: backdropPalette)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        if let album = row.albumTitle {
                            Text(album)
                                .lineLimit(1)
                        }
                        if let year = row.releaseYear, year > 1900 {
                            if row.albumTitle != nil {
                                Text("·").foregroundStyle(ArtistPageChrome.tertiary(app: app, palette: backdropPalette).opacity(0.6))
                            }
                            Text(String(year))
                                .foregroundStyle(ArtistPageChrome.tertiary(app: app, palette: backdropPalette))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(ArtistPageChrome.secondary(app: app, palette: backdropPalette))
                    // Pull the subtitle baseline up so it sits tight under the
                    // title's descender (Apple Music's compact row rhythm). The
                    // default `Text` line-box leaves ~3pt of slack between
                    // semibold subheadline and caption, which reads as a gap.
                    .padding(.top, -2)
                }

                Spacer(minLength: 6)

                ArtistTopSongOverflowMenu(
                    row: row,
                    canRequest: canRequest,
                    onRequest: onRequest,
                    onGoToAlbum: onGoToAlbum
                )
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleTap() {
        if let track = row.libraryTrack {
            Task {
                guard let lib = app.activeLibrary else { return }
                try? await app.player.playAlbum(library: lib, tracks: [track], startIndex: 0)
            }
        } else if canRequest {
            onRequest(row)
        }
    }
}

/// Top Songs row ⋯ menu. Library tracks render the shared `StandardSongMenuContent`
/// so the option set matches every other song-row ⋯ in the app. Preview-only tracks
/// (the artist's catalog lookup found no matching server track) fall back to the
/// chart-style menu whose primary action is Request via the request backend.
private struct ArtistTopSongOverflowMenu: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette
    let row: ArtistTopSongRow
    let canRequest: Bool
    let onRequest: (ArtistTopSongRow) -> Void
    let onGoToAlbum: (AlbumSummary) -> Void

    var body: some View {
        Menu {
            if let track = row.libraryTrack {
                StandardSongMenuContent(
                    track: track,
                    onPlayNext: {
                        Task { @MainActor in
                            try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [track])
                        }
                    },
                    onAddToQueue: {
                        Task { @MainActor in
                            guard let lib = app.activeLibrary else { return }
                            try? await app.player.addToQueue(library: lib, track: track, sourcePlaylistId: nil)
                        }
                    },
                    onFavorite: { app.toggleFavoriteTrack(id: track.id) },
                    onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
                    onAddToLibrary: app.isSongInLibrary(track.id)
                        ? nil
                        : { Task { await app.addSongToLibrary(track) } },
                    onDownload: app.isSongInLibrary(track.id) && !app.offline.downloadedTrackIds.contains(track.id)
                        ? { cacheOffline(track: track) }
                        : nil,
                    onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                        ? { try? app.offline.remove(trackId: track.id) }
                        : nil,
                    onGoToAlbum: { onGoToAlbum(app.albumSummary(for: track)) },
                    onRemoveFromLibrary: app.isSongInLibrary(track.id)
                        ? { Task { await app.removeSongFromLibrary(track) } }
                        : nil,
                    onDeleteFromLibrary: app.canDeleteFromLibrary
                        ? { app.beginLibraryTrackDeletion(track) }
                        : nil
                )
            } else {
                ChartStyleSongOverflowMenuContent(
                    shareItem: "\(row.title) — \(row.artist)",
                    onAdd: { onRequest(row) },
                    addDisabled: !app.acquisitionConfigured || !canRequest
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(ArtistPageChrome.secondary(app: app, palette: backdropPalette).opacity(0.65))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
    }

    private func cacheOffline(track: Track) {
        app.enqueueOfflineTrack(track)
    }
}

// MARK: - Discography carousels (variable card size)

private enum DiscographyLayout {
    case prominent  // Albums, Singles & EPs, Live, Compilations

    var cardSide: CGFloat {
        MusicDesign.shelfCardWidth
    }

    var titleFont: Font {
        .subheadline.weight(.semibold)
    }

    var subtitleFont: Font {
        .caption
    }

    /// Reserved height for the combined `(title, subtitle)` block — two title
    /// lines + spacing + one subtitle line. Keeps cards in a row aligned while
    /// keeping the title and subtitle visually tight (any leftover space falls
    /// below the subtitle, not between title and subtitle).
    var labelBlockMinHeight: CGFloat { 52 }
}

private struct ArtistDiscographyCarousel: View {
    @ObservedObject var model: ArtistViewModel
    let bucket: ArtistDiscographyBucket
    let title: String
    let layout: DiscographyLayout

    private var items: [ArtistDiscographyItem] {
        model.discography[bucket] ?? []
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ArtistSectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy: a plugin discography can be 100+ releases per bucket, and each
                    // card carries artwork plus a context menu.
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            ArtistDiscographyCard(
                                item: item,
                                layout: layout,
                                canRequest: model.canRequestViaAcquisition
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

private struct ArtistDiscographyCard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette
    let item: ArtistDiscographyItem
    let layout: DiscographyLayout
    let canRequest: Bool

    private var showsRequestBadge: Bool {
        item.needsRequest && canRequest
    }
    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ArtistAlbumCardArtwork(url: item.artworkURL, seed: item.title)
                        .frame(width: layout.cardSide, height: layout.cardSide)
                        .clipShape(RoundedRectangle(cornerRadius: MusicDesign.albumCorner, style: .continuous))
                        // Not an `AlbumArtworkView`, so the origin rect is marked by hand.
                        .coverZoomCellAnchor(id: coverZoomId, cornerRadius: MusicDesign.albumCorner)
                    if showsRequestBadge {
                        // Compact glyph in the top-right corner of the cover signals
                        // "not on your server — tap to request via the request backend".
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(item.title)
                            .font(layout.titleFont)
                            .foregroundStyle(ArtistPageChrome.primary(app: app, palette: backdropPalette))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if showsRequestBadge {
                            Image(systemName: "arrow.down.circle")
                                .font(layout.subtitleFont)
                                .foregroundStyle(MusicDesign.accent)
                        }
                    }
                    Text(subtitle)
                        .font(layout.subtitleFont)
                        .foregroundStyle(ArtistPageChrome.secondary(app: app, palette: backdropPalette))
                        .lineLimit(1)
                }
                .frame(
                    minWidth: layout.cardSide, idealWidth: layout.cardSide, maxWidth: layout.cardSide,
                    minHeight: layout.labelBlockMinHeight, alignment: .topLeading
                )
            }
            .frame(width: layout.cardSide, alignment: .leading)
            .coverZoomSource(id: coverZoomId, style: .custom)
        }
        .buttonStyle(.plain)
        .libraryAlbumContextMenu(libraryAlbumForContextMenu)
    }

    private var browseSource: BrowseAlbumDetailSource? {
        guard case .remote(let album) = item.source else { return nil }
        return .chartBrowse(
            artistName: album.artist.isEmpty ? item.artist : album.artist,
            title: album.title,
            imageURL: album.artworkURL,
            kind: bucketLabel,
            albumId: album.trackLookupId
        )
    }

    private var coverZoomId: String {
        switch item.source {
        case .libraryAlbum(let album): return album.id
        case .remote: return browseSource?.coverZoomId ?? item.id
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch item.source {
        case .libraryAlbum(let album):
            ServerPlaylistDetailView(album: album, librarySource: true)
        case .remote:
            if let browseSource {
                BrowseAlbumDetailView(source: browseSource)
            }
        }
    }

    private var libraryAlbumForContextMenu: AlbumSummary {
        if let a = item.libraryAlbum { return a }
        return AlbumSummary(
            id: item.id,
            title: item.title,
            artist: item.artist,
            artworkURL: item.artworkURL,
            releaseYear: item.releaseYear
        )
    }

    private var bucketLabel: String {
        switch item.bucket {
        case .albums: return "Album"
        case .singlesAndEPs: return "Single"
        case .live: return "Live"
        case .compilations: return "Compilation"
        }
    }

    /// Caption shown directly under the album title. Apple Music style:
    /// - year alone for albums when the year is known
    /// - `year · kind` for non-album buckets so the user can tell singles/EPs/live apart
    /// - kind alone when no year is present (`Album` is omitted as redundant)
    private var subtitle: String {
        let yearStr: String? = {
            if let y = item.releaseYear, y > 1900 { return String(y) }
            return nil
        }()
        switch item.bucket {
        case .albums:
            return yearStr ?? ""
        case .singlesAndEPs, .live, .compilations:
            switch (yearStr, bucketLabel) {
            case (let y?, let kind): return "\(y) · \(kind)"
            case (nil, let kind): return kind
            }
        }
    }
}

/// Album-card artwork that always falls back to a seeded gradient (matching the
/// artist banner) instead of a flat gray rectangle. Uses
/// ``RemoteArtworkScaledFill`` so when Cover Art Archive returns 404 for a
/// iTunes album artwork, the gradient stays visible (the default
/// ``AlbumArtworkView`` would show its own music.note placeholder, which the
/// design brief explicitly calls out as breaking the premium feel).
private struct ArtistAlbumCardArtwork: View {
    let url: URL?
    let seed: String

    var body: some View {
        RemoteArtworkScaledFill(url: url, maxPixelSize: 480) {
            ArtistGradientFallback(seed: seed)
        }
    }
}

// MARK: - About (inline MORE expansion + tight key-value rows)

/// Dedicated full-screen "About" page (Apple Music style): hero photo melting into the page,
/// the artist name, a From / Born / Genre block, and the complete biography.
private struct ArtistAboutPageView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel
    let palette: ArtworkDynamicGradient.BackdropPalette

    private var bio: String? {
        if let b = model.pluginProfile?.overview, !b.isEmpty { return b }
        if let o = model.jellyfinOverview, !o.isEmpty { return o }
        return nil
    }

    private var primaryColor: Color { palette.heroChromePrimary }
    private var secondaryColor: Color { palette.heroChromeSecondary }

    private var heroHeight: CGFloat {
        #if os(iOS)
        UIScreen.main.bounds.height * 0.5
        #else
        420
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ArtistHeroBannerStack(
                    url: model.bannerArtworkURL,
                    seed: model.displayName,
                    backdropColor: palette.heroSolidBackdropColor,
                )
                .frame(height: heroHeight)

                VStack(alignment: .leading, spacing: 24) {
                    Text(model.displayName)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(primaryColor)
                        .fixedSize(horizontal: false, vertical: true)

                    metadataBlock

                    if let bio {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("About")
                                .font(.title2.bold())
                                .foregroundStyle(primaryColor)
                            Text(bio)
                                .font(.callout)
                                .foregroundStyle(primaryColor)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 48)
            }
        }
        .background(palette.heroSolidBackdropColor.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .scrollIndicators(.hidden)
        .navigationTitle(model.displayName)
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicHeroAlbumNavigationChrome(palette: palette)
    }

    @ViewBuilder
    private var metadataBlock: some View {
        let genre = model.pluginProfile?.genres.first

        VStack(alignment: .leading, spacing: 20) {
            if let genre {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Genre")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(secondaryColor)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(genre)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(primaryColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
                }
            }
        }
    }

}

// MARK: - Similar Artists

private struct ArtistPageLoadingSkeletonSections: View {
    var body: some View {
        VStack(spacing: 0) {
            MusicHorizontalShelfSkeleton(
                title: "Top Songs",
                style: .album,
                count: 3,
                horizontalInset: 20,
            )
            .padding(.bottom, 24)
            MusicHorizontalShelfSkeleton(
                title: "Albums",
                style: .album,
                count: 4,
                horizontalInset: 20,
            )
            .padding(.bottom, 24)
            MusicHorizontalShelfSkeleton(
                title: "Similar Artists",
                style: .artistCircle,
                count: 4,
                horizontalInset: 20,
            )
            .padding(.bottom, 24)
        }
    }
}

private struct ArtistSimilarSection: View {
    @ObservedObject var model: ArtistViewModel

    var body: some View {
        if !model.similarArtists.isEmpty {
            VStack(spacing: 0) {
                ArtistSectionHeader(title: "Similar Artists")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(model.similarArtists) { similar in
                            NavigationLink {
                                ArtistPageView(input: .named(similar.name))
                            } label: {
                                SimilarArtistCard(similar: similar)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 24)
        }
    }
}

private struct SimilarArtistCard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette

    let similar: LastFmSimilarArtist
    private let side: CGFloat = 112

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let url = similar.imageURL {
                    AlbumArtworkView(url: url, cornerRadius: side / 2)
                } else {
                    ArtistGradientFallback(seed: similar.name)
                }
            }
            .frame(width: side, height: side)
            .clipShape(Circle())

            Text(similar.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ArtistPageChrome.primary(app: app, palette: backdropPalette))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(
                    minWidth: side + 8, idealWidth: side + 8, maxWidth: side + 8,
                    minHeight: 26, alignment: .top
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ArtistPageScrollChromeModifier: ViewModifier {
    let scrollSpace: String
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: scrollSpace)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .environment(\.artistPageBackdropPalette, backdropPalette)
    }
}
