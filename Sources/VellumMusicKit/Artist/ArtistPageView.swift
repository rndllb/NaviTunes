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
    @State private var showArtistIdentityInfo = false
    /// Gate on "Request Missing": the count is shown and has to be accepted before a single
    /// request is placed. See ``requestDiscographyConfirmationMessage``.
    @State private var showRequestDiscographyConfirmation = false

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
                            // Sits above the shelves so a partial or fallback load is read
                            // before the releases it qualifies, rather than discovered after
                            // scrolling to an unexplained short list.
                            if model.showsDiscographyLoadNotice {
                                ArtistDiscographyLoadNotice(model: model) {
                                    Task { await model.refresh(using: app) }
                                }
                            }
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
                    // Both labels are kept short enough to stay on one line at the longest real
                    // count. Three digits is real — Nana Mouskouri is 314 release groups — and a
                    // menu row that hyphenates across two lines reads as broken next to Share and
                    // Info. Measured against "Remove from Favorites" (173.8pt at the 17pt body
                    // font), the longest item here that is known to fit:
                    //   "Request Discography (314)"   207.3pt  wraps  (what this used to say)
                    //   "Request Missing (314)"       169.7pt  fits
                    //   "Stop Requesting (196 of 314)" 222.6pt wraps
                    //   "Stop (196 of 314)"           132.5pt  fits
                    //
                    // "Missing" rather than "Discography" is also the accurate word: the action
                    // requests what the server does not have, and the number in brackets is that
                    // missing count — never the size of the discography.
                    if let progress = app.bulkAcquisitionProgress {
                        Divider()
                        Button(role: .destructive) {
                            app.cancelBulkAcquisition()
                        } label: {
                            Label(
                                "Stop (\(progress.placed) of \(progress.total))",
                                systemImage: "stop.circle"
                            )
                        }
                    } else if showsRequestDiscography {
                        Divider()
                        Button {
                            showRequestDiscographyConfirmation = true
                        } label: {
                            Label(
                                "Request Missing (\(model.discographyRequestPlan.count))",
                                systemImage: "arrow.down.circle"
                            )
                        }
                    }
                    Divider()
                    Button {
                        showArtistIdentityInfo = true
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(backdropPalette.heroChromePrimary)
            }
        }
        // The count is the point of this dialog: a one-tap action that silently places 300
        // requests is not an action anybody asked for. Stock `confirmationDialog`, so Cancel is
        // where the reader already expects it.
        .confirmationDialog(
            "Request \(model.discographyRequestPlan.count) \(model.discographyRequestPlan.count == 1 ? "release" : "releases")?",
            isPresented: $showRequestDiscographyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Request \(model.discographyRequestPlan.count)") {
                app.startBulkAcquisition(model.discographyRequestPlan.releases.map(\.acquisitionRequest))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(requestDiscographyConfirmationMessage)
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
            // The only place in the app that forces a refresh. Re-entering the page does not:
            // `.task` above runs the ordinary cache check, which refetches only when the entry
            // is missing, incomplete, or past its week. Adding an on-appear refetch here would
            // mean a MusicBrainz round-trip every time an artist is opened.
            await model.refresh(using: app)
        }
        .overlay(alignment: .center) {
            switch model.contentState {
            case .loading, .content:
                // Nothing to say. The skeleton above covers the loading case; saying "not found"
                // while a fetch is still running tells the reader the opposite of the truth.
                EmptyView()
            case .empty:
                ContentUnavailableView(
                    "No info for this artist",
                    systemImage: "mic",
                    description: Text("We couldn't find any songs, releases, or biography for \(model.displayName).")
                )
                .padding(.horizontal, 24)
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't load this artist", systemImage: "arrow.clockwise")
                } description: {
                    Text("Something went wrong fetching \(model.displayName)'s releases. This isn't an empty artist — the request didn't get through.")
                } actions: {
                    Button("Try Again") {
                        Task { await model.refresh(using: app) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)
            }
        }
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: app.isAlbumInLibrary(album.id))
        }
        .navigationDestination(isPresented: $navigateAbout) {
            ArtistAboutPageView(model: model, palette: backdropPalette)
        }
        // Diagnostic rather than decorative: the id alone does not say whether this page is
        // showing the artist you meant, but the id plus how it was chosen does.
        .alert("Artist Info", isPresented: $showArtistIdentityInfo) {
            if let mbid = model.musicBrainzIdentity {
                Button("Copy MusicBrainz ID") {
                    #if os(iOS)
                    UIPasteboard.general.string = mbid
                    #endif
                    app.showTransientToast("MusicBrainz ID copied")
                }
            }
            Button("Done", role: .cancel) {}
        } message: {
            Text(model.identityReport)
        }
    }

    private var artistTaskKey: String {
        switch model.input {
        case .libraryArtist(let a): return "lib:\(a.id)"
        case .named(let n): return "name:\(n)"
        case .musicBrainzArtist(let a): return "mbid:\(a.id)"
        case .musicBrainzArtistId(let id, _): return "mbid:\(id)"
        }
    }

    private var artistPageShowsSkeleton: Bool {
        !model.hasRenderableBodyContent
            && (model.isLoadingServerCatalog
                || model.isLoadingEnrichment
                || model.isLoadingTopSongs
                || model.isLoadingDiscography
                // Keep the placeholders up while later discography pages are still arriving,
                // for the same reason `contentState` treats paging as loading: an empty first
                // page is not an empty artist.
                || model.isPagingDiscography)
    }

    /// Shareable link for the artist — an Apple Music search URL that opens to this artist.
    private var artistShareURL: URL? {
        let q = model.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty else { return nil }
        return URL(string: "https://music.apple.com/search?term=\(q)")
    }

    /// Whether the overflow menu offers "Request Missing".
    ///
    /// The same three conditions the shelves' per-row request badge answers to — a configured
    /// plugin, an artist that plugin will accept, and at least one release the page is showing
    /// as missing — so the menu appears exactly when tapping request on a row would have worked.
    private var showsRequestDiscography: Bool {
        app.acquisitionConfigured
            && model.canRequestViaAcquisition
            && !model.discographyRequestPlan.isEmpty
    }

    /// Who the page thinks this artist is, as the confirmation's first line.
    ///
    /// A count with no name attached is the most dangerous shape this dialog could take. Eighteen
    /// MusicBrainz artists are named exactly "Rocket", and a page that resolved the wrong one
    /// still shows a confident, correct-looking number — 29 releases, all of them the Russian
    /// rapper's. The disambiguation is what makes that visible in the half-second before tapping,
    /// so it is not decoration: "Rocket (Russian rapper)" and "Rocket (indie rock band from Los
    /// Angeles)" are the difference between catching the mismatch and firing 29 requests at it.
    ///
    /// Uses ``MusicBrainzArtist/searchRowDescriptor`` — the same line Discover search rows use to
    /// tell same-named artists apart — rather than a second formatting of the same fields.
    private var requestDiscographyArtistLine: String {
        guard let artist = model.musicBrainzArtist else { return model.displayName }
        guard let descriptor = artist.searchRowDescriptor else { return artist.name }
        return "\(artist.name) (\(descriptor))"
    }

    /// The sentence under the confirmation's "Request N releases?" title.
    ///
    /// Leads with who the releases belong to, then says what the number is made of and what each
    /// request costs the server, and — when the discography is still paging — says plainly that
    /// the number is not the whole catalogue yet, rather than letting a partial count read as a
    /// complete one.
    private var requestDiscographyConfirmationMessage: String {
        let plan = model.discographyRequestPlan
        var lines: [String] = [requestDiscographyArtistLine]
        let breakdown = plan.breakdown.map(\.label).formatted(.list(type: .and))
        lines.append(
            "\(breakdown) on this page aren’t on your server. "
            + "Each one is added to \(app.acquisitionCapabilities.displayName) and searched for."
        )
        if plan.pending > 0 {
            lines.append("\(plan.pending) more releases are still loading and aren’t included.")
        }
        return lines.joined(separator: "\n\n")
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
                kind: ArtistReleaseKind.from(
                    albumType: release.albumType,
                    secondaryTypes: release.secondaryTypes,
                    trackCount: release.trackCount,
                ).label,
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
                            try? await app.player.playNext(library: app.activeLibrary, track: track)
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
                        ? { app.requestRemoveSongFromLibrary(track) }
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

    /// Placeholder cards for release groups MusicBrainz has counted but not yet delivered.
    ///
    /// This is the second of the page's two loading states. A discography arrives 100 rows at a
    /// time, and the server's `release-group-count` is known from the first page — so the shelf
    /// can show exactly how much more is coming instead of looking finished and then jumping.
    /// Capped so a 300-release artist does not render 200 shimmer cards nobody scrolls to.
    private var placeholderCount: Int {
        guard model.isPagingDiscography, !items.isEmpty else { return 0 }
        return min(model.discographyPendingCount, 4)
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ArtistSectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy: a discography can be 100+ releases per bucket, and each card
                    // carries artwork plus a context menu.
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            ArtistDiscographyCard(
                                item: item,
                                layout: layout,
                                canRequest: model.canRequestViaAcquisition
                            )
                        }
                        ForEach(0 ..< placeholderCount, id: \.self) { _ in
                            ArtistDiscographyCardSkeleton(layout: layout)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 4)
            // Start the leading covers as soon as the shelf's URLs are known, rather than
            // waiting for each cell to be built by the lazy stack. Bounded per shelf — see
            // ``ArtworkPrefetcher`` for why the unbounded version would be a different bug.
            .task(id: prefetchToken) {
                let urls = items.prefix(ArtworkPrefetcher.defaultLeadingCount).compactMap(\.artworkURL)
                await ArtworkPrefetcher.shared.prefetch(
                    owner: prefetchOwner,
                    urls: urls,
                    maxPixelSize: MusicDesign.shelfCardWidth * 3
                )
            }
            .onDisappear {
                Task { await ArtworkPrefetcher.shared.cancel(owner: prefetchOwner) }
            }
        }
    }

    private var prefetchOwner: String { "artist-shelf:\(title)" }

    /// O(1) "the shelf's contents changed" token — deliberately not a map over every row, which
    /// would run on each body evaluation of a shelf that can hold hundreds of cards.
    private var prefetchToken: String {
        "\(items.count)|\(items.first?.id ?? "")|\(items.last?.id ?? "")"
    }
}

/// What the page says out loud when a discography load did not fully succeed.
///
/// The flag existing on the model is not the fix — the point is that a failure reaches the
/// screen in words instead of the shelf quietly ending early. Two distinct things get said,
/// because they are two different situations for the reader:
///
/// - **A pass that ran out of retries partway.** What already loaded is real and current; some
///   of it is simply missing. The count is named so it is clear how much.
/// - **A saved copy standing in.** The refresh failed outright and what is on screen is an
///   older copy. It is labelled as such — showing out-of-date data without saying so is the
///   thing this is here to prevent.
private struct ArtistDiscographyLoadNotice: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel
    @Environment(\.artistPageBackdropPalette) private var backdropPalette
    let onRetry: () -> Void

    private static let savedCopyFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var title: String {
        model.discographyIsSavedCopy
            ? "Showing a saved copy"
            : "Couldn't load everything"
    }

    private var detail: String {
        if model.discographyIsSavedCopy {
            guard let fetchedAt = model.discographyFetchedAt else {
                return "This artist's releases couldn't be refreshed, so an earlier copy is shown."
            }
            let when = Self.savedCopyFormatter.localizedString(for: fetchedAt, relativeTo: Date())
            return "Couldn't refresh this artist's releases, so this is the copy saved \(when)."
        }
        if model.discographyTotal > 0, model.discographyLoadedCount < model.discographyTotal {
            return "Showing \(model.discographyLoadedCount) of \(model.discographyTotal) releases. The rest didn't load."
        }
        return "Some of this artist's releases didn't load."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.discographyIsSavedCopy ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(ArtistPageChrome.secondary(app: app, palette: backdropPalette))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ArtistPageChrome.primary(app: app, palette: backdropPalette))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(ArtistPageChrome.secondary(app: app, palette: backdropPalette))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(MusicDesign.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

/// A discography card that has not arrived yet. Matches ``ArtistDiscographyCard``'s artwork
/// size and label block so the shelf does not reflow when the real row replaces it.
private struct ArtistDiscographyCardSkeleton: View {
    let layout: DiscographyLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicSquareArtworkSkeleton(size: layout.cardSide, cornerRadius: MusicDesign.albumCorner)
            VStack(alignment: .leading, spacing: 4) {
                MusicTextLineSkeleton(width: layout.cardSide * 0.8, height: 12)
                MusicTextLineSkeleton(width: layout.cardSide * 0.5, height: 10)
            }
            .frame(minHeight: layout.labelBlockMinHeight, alignment: .top)
        }
        .frame(width: layout.cardSide, alignment: .leading)
        .accessibilityLabel("Loading more releases")
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

    /// The release's own kind, not its shelf. The `singlesAndEPs` shelf holds both, so reading
    /// the caption off the bucket labelled every EP "Single".
    private var bucketLabel: String { item.releaseKind.label }

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
        // Genre falls back to the plugin's tags only when MusicBrainz has none, so the two
        // sources never disagree on screen.
        let mb = model.musicBrainzArtist
        let genre = mb?.primaryGenre ?? model.pluginProfile?.genres.first
        let origin = mb?.originLine
        let formed = mb?.lifeSpanBeginDisplay

        VStack(alignment: .leading, spacing: 20) {
            if model.isLoadingArtistHeader && mb == nil {
                artistFactsShimmer
            } else {
                if let origin {
                    factRow(label: "From", value: origin)
                }
                if let formed {
                    factRow(label: mb?.lifeSpanBeginLabel ?? "Formed", value: formed)
                }
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

    private func factRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(secondaryColor)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(primaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The first of the page's two loading states. Only ever visible on a cold open — a page
    /// reached from a search hit already has these facts and never shimmers here.
    private var artistFactsShimmer: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([CGFloat(150), CGFloat(110)], id: \.self) { width in
                VStack(alignment: .leading, spacing: 8) {
                    MusicTextLineSkeleton(width: 48, height: 9, cornerRadius: 3)
                    MusicTextLineSkeleton(width: width, height: 14)
                }
            }
        }
        .accessibilityLabel("Loading artist details")
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
