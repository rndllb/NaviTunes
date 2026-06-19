import SwiftUI
#if os(iOS)
import UIKit
#endif

struct MusicNewTabView: View {
    @EnvironmentObject private var app: AppModel
    @State private var navigationPath = NavigationPath()
    @State private var navigateLibraryTrack: Track?
    @State private var navigateLibraryAlbum: AlbumSummary?
    @State private var browseChartSingle: ChartTrack?
    /// Shows the custom **New** + profile row; driven by vertical scroll offset via ``onScrollGeometryChange``.
    @State private var newTabShowFloatingHeader = true

    /// Hide the floating **New** / profile row after this much vertical scroll past the initial resting offset.
    private let newTabFloatingHeaderCollapseSlack: CGFloat = 72

    private var hasNewTabTracks: Bool {
        !app.newTabTopTracks.isEmpty
    }

    private var hasFromYourArtists: Bool {
        !app.newTabFromYourArtists.isEmpty
    }

    private var hasArtistHighlights: Bool {
        !app.newTabArtistHighlights.isEmpty
    }

    private var hasDiscoverReleases: Bool {
        !app.newTabDiscoverReleases.isEmpty
    }

    private var hasRecentReleases: Bool {
        !app.newTabRecentReleases.isEmpty
    }

    private var hasAnyNewTabContent: Bool {
        hasNewTabTracks || hasFromYourArtists || hasRecentReleases || hasDiscoverReleases
    }

    private var browseHeroEyebrow: String {
        app.newTabIsPersonalized ? "New For You" : "New Releases"
    }

    private var browseHeroBadge: String {
        if app.newTabIsPersonalized {
            return "Based on your listening"
        }
        switch app.newTabBrowseBackend {
        case .musicBrainz: return "Recent on MusicBrainz"
        case .none: return "Discover"
        }
    }

    private var trendingSectionTitle: String {
        app.newTabIsPersonalized ? "Picked For You" : "New Albums"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                newTabMainScrollColumn
            }
            .coordinateSpace(name: "newTabScroll")
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: newTabFloatingHeaderCollapseSlack,
                showFloatingHeader: $newTabShowFloatingHeader
            ))
            .musicTabFloatingHeaderInset(isVisible: newTabShowFloatingHeader) {
                MusicTabTitleHeaderBar(title: "New") {
                    MusicToolbarSettingsAvatarLink(diameter: 45)
                }
            }
            .background(MusicDesign.background)
            .musicNewTabNavigationChrome()
            .musicNewTabRootHidesNavigationBar()
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .task {
                if app.libraryAlbums.isEmpty {
                    await app.refreshLibraryAlbums()
                }
                if !hasAnyNewTabContent {
                    await app.refreshNewTabBrowse()
                }
                guard app.isSignedIn else { return }
                app.scheduleDiscoveryTrackIndexRefreshIfNeeded()
            }
            .refreshable {
                await app.refreshLibraryAlbums()
                await app.refreshNewTabBrowse()
            }
            .navigationDestination(item: $navigateLibraryTrack) { track in
                ServerPlaylistDetailView(album: app.albumSummary(for: track), scrollToTrackId: track.id)
            }
            .navigationDestination(item: $navigateLibraryAlbum) { album in
                ServerPlaylistDetailView(album: album)
            }
            .navigationDestination(item: $browseChartSingle) { tr in
                BrowseAlbumDetailView(source: .chartBrowse(
                    artistName: tr.artistName,
                    title: tr.name,
                    imageURL: tr.imageURL,
                    kind: tr.browseKind
                ))
            }
            .deepLinkPush(tab: .new, path: $navigationPath)
        }
        .coverZoomContext()
        .tint(MusicDesign.accent)
    }

    @ViewBuilder
    private var newTabMainScrollColumn: some View {
        if app.newTabBrowseLoading && !hasAnyNewTabContent {
            ProgressView()
                .tint(MusicDesign.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 72)
        } else if !hasAnyNewTabContent && !app.newTabBrowseLoading {
            if let browseErr = app.newTabBrowseError {
                ContentUnavailableView(
                    "Couldn’t load new releases",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(browseErr)
                )
                .padding(.top, 36)
            } else {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "music.note.list",
                    description: Text("Pull to refresh or check your connection.")
                )
                .padding(.top, 36)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if hasNewTabTracks {
                    heroCarousel(Array(app.newTabTopTracks.prefix(6)))
                    gap
                }

                if hasNewTabTracks {
                    sectionHeader(trendingSectionTitle)
                    trendingSongsCarousel(Array(app.newTabTopTracks.prefix(10)))
                    gap
                }

                if app.newTabIsPersonalized, hasFromYourArtists {
                    sectionHeader("From Artists You Play")
                    albumShelf(Array(app.newTabFromYourArtists.prefix(12)))
                    gap
                }

                if app.newTabIsPersonalized, hasArtistHighlights {
                    sectionHeader("Artists You're Into")
                    artistHighlightShelf(app.newTabArtistHighlights)
                    gap
                }

                if app.newTabIsPersonalized, hasDiscoverReleases {
                    sectionHeader("Discover")
                    albumShelf(app.newTabDiscoverReleases)
                    gap
                } else if !app.newTabIsPersonalized, hasRecentReleases {
                    sectionHeader("Recent Releases")
                    albumShelf(Array(app.newTabRecentReleases.prefix(12)))
                    gap
                }

                if !app.newTabIsPersonalized, !app.newTabTopAlbums.isEmpty {
                    sectionHeader("Top Albums")
                    albumShelf(app.newTabTopAlbums)
                    gap
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func resolvedLibraryTrack(for chart: ChartTrack) -> Track? {
        app.libraryChartTrackIndex.firstMatch(chart: chart)
    }

    private func matchedLibraryAlbum(for chart: ChartAlbum) -> AlbumSummary? {
        app.libraryAlbumReleaseIndex.firstMatch(artist: chart.artistName, albumTitle: chart.name)
    }

    // MARK: - Hero Carousel (Apple Music–style: labels above rounded card + horizontal peek)

    private enum NewTabHeroMetrics {
        static let interPageSpacing: CGFloat = 12
        static let eyebrowHeight: CGFloat = 16
        static let eyebrowBottomSpacing: CGFloat = 1
        static let titleArtistSpacing: CGFloat = 1
        static let textToArtworkSpacing: CGFloat = 4
        /// Max text block height for carousel layout (two title lines + artist).
        static let titleArtistBlockHeight: CGFloat = 58
    }

    private func newTabHeroTextBlockHeight() -> CGFloat {
        NewTabHeroMetrics.eyebrowHeight
            + NewTabHeroMetrics.eyebrowBottomSpacing
            + NewTabHeroMetrics.titleArtistBlockHeight
            + NewTabHeroMetrics.textToArtworkSpacing
    }

    private func newTabHeroImageHeight(forCardWidth cardWidth: CGFloat) -> CGFloat {
        cardWidth * MusicDesign.newTabHeroImageHeightFactor
    }

    private func newTabHeroCarouselStackHeight(containerWidth: CGFloat) -> CGFloat {
        let inset = MusicDesign.newTabHorizontalInset
        let peek = MusicDesign.newTabHeroPeek
        let cardWidth = max(260, containerWidth - inset - peek - NewTabHeroMetrics.interPageSpacing)
        return newTabHeroTextBlockHeight() + newTabHeroImageHeight(forCardWidth: cardWidth)
    }

    private var newTabHeroCarouselOuterHeight: CGFloat {
#if os(iOS)
        newTabHeroCarouselStackHeight(containerWidth: UIScreen.main.bounds.width)
#else
        newTabHeroCarouselStackHeight(containerWidth: 900)
#endif
    }

    private func heroCarousel(_ items: [ChartTrack]) -> some View {
        GeometryReader { geo in
            let inset = MusicDesign.newTabHorizontalInset
            let peek = MusicDesign.newTabHeroPeek
            let cardWidth = max(260, geo.size.width - inset - peek - NewTabHeroMetrics.interPageSpacing)
            let imageHeight = newTabHeroImageHeight(forCardWidth: cardWidth)
            let stackHeight = newTabHeroCarouselStackHeight(containerWidth: geo.size.width)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NewTabHeroMetrics.interPageSpacing) {
                    ForEach(items) { track in
                        heroCarouselPage(
                            track: track,
                            cardWidth: cardWidth,
                            imageHeight: imageHeight,
                            pageHeight: stackHeight,
                        )
                        .id(track.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, inset)
                .padding(.trailing, inset + peek)
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(height: stackHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: newTabHeroCarouselOuterHeight)
    }

    private func heroCarouselPage(
        track: ChartTrack,
        cardWidth: CGFloat,
        imageHeight: CGFloat,
        pageHeight: CGFloat,
    ) -> some View {
        let lib = resolvedLibraryTrack(for: track)
        return VStack(alignment: .leading, spacing: 0) {
            Text(browseHeroEyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .textCase(.uppercase)
                .tracking(0.6)
                .frame(height: NewTabHeroMetrics.eyebrowHeight, alignment: .leading)
                .padding(.bottom, NewTabHeroMetrics.eyebrowBottomSpacing)

            VStack(alignment: .leading, spacing: NewTabHeroMetrics.titleArtistSpacing) {
                Text(track.name)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .lineSpacing(-3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, NewTabHeroMetrics.textToArtworkSpacing)

            heroCarouselArtworkLink(
                track: track,
                libraryTrack: lib,
                cardWidth: cardWidth,
                imageHeight: imageHeight,
            )
        }
        .frame(width: cardWidth, height: pageHeight, alignment: .top)
    }

    @ViewBuilder
    private func heroCarouselArtworkLink(
        track: ChartTrack,
        libraryTrack: Track?,
        cardWidth: CGFloat,
        imageHeight: CGFloat,
    ) -> some View {
        if let lib = libraryTrack {
            Button {
                navigateLibraryTrack = lib
            } label: {
                heroCarouselArtworkCard(
                    track: track,
                    cardWidth: cardWidth,
                    imageHeight: imageHeight,
                    showOverflow: false,
                    badgeText: browseHeroBadge,
                )
                .coverZoomSource(id: lib.albumId)
            }
            .buttonStyle(.plain)
        } else {
            let source = BrowseAlbumDetailSource.chartBrowse(
                artistName: track.artistName,
                title: track.name,
                imageURL: track.imageURL,
                kind: track.browseKind
            )
            NavigationLink {
                BrowseAlbumDetailView(source: source)
            } label: {
                heroCarouselArtworkCard(
                    track: track,
                    cardWidth: cardWidth,
                    imageHeight: imageHeight,
                    showOverflow: true,
                    badgeText: browseHeroBadge,
                )
                .coverZoomSource(id: source.coverZoomId)
            }
            .buttonStyle(.plain)
        }
    }

    private func heroCarouselArtworkCard(
        track: ChartTrack,
        cardWidth: CGFloat,
        imageHeight: CGFloat,
        showOverflow: Bool,
        badgeText: String,
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                NewTabHeroArtwork(
                    releaseGroupId: track.id,
                    fallbackURL: track.imageURL,
                    seed: track.artistName + track.name,
                    cardWidth: cardWidth,
                    imageHeight: imageHeight,
                )

                LinearGradient(
                    colors: [.clear, .black.opacity(0.22), .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(width: cardWidth, height: imageHeight)
                .allowsHitTesting(false)

                Text(badgeText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 1)
                    .padding(14)
            }
            .frame(width: cardWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: MusicDesign.newTabHeroCardCorner, style: .continuous))

            if showOverflow {
                newTabChartOverflowEllipsis(track: track)
                    .padding(12)
            }
        }
        .frame(width: cardWidth, height: imageHeight)
    }

    // MARK: - Trending Songs (horizontal pages, 4 rows each)

    private enum NewTabPickedForYouMetrics {
        static let artworkSize: CGFloat = 48
        static let artworkToTextSpacing: CGFloat = 10
        static let titleArtistSpacing: CGFloat = 1
        static let rowVerticalPadding: CGFloat = 6
    }

    private var trendingSongCarouselHeight: CGFloat {
        let rowHeight = NewTabPickedForYouMetrics.artworkSize + (NewTabPickedForYouMetrics.rowVerticalPadding * 2)
        let dividerAllowance: CGFloat = 2
        return rowHeight * 4 + dividerAllowance
    }

    private func trendingTracksChunked(_ items: [ChartTrack]) -> [[ChartTrack]] {
        stride(from: 0, to: items.count, by: 4).map {
            Array(items[$0..<min($0 + 4, items.count)])
        }
    }

    private func trendingSongsCarousel(_ items: [ChartTrack]) -> some View {
        let chunks = trendingTracksChunked(items)
        return GeometryReader { geo in
            let leadingPad = MusicDesign.newTabHorizontalInset
            /// Visible slice of the next column (hint that you can scroll sideways).
            let nextColumnPeek = MusicDesign.newTabHeroPeek
            let interColumnSpacing = CGFloat(12)
            let columnWidth = max(280, geo.size.width - leadingPad - nextColumnPeek)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: interColumnSpacing) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        trendingSongsColumn(chunk)
                            .frame(width: columnWidth)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, leadingPad)
                .padding(.trailing, leadingPad + nextColumnPeek)
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: trendingSongCarouselHeight)
    }

    private func trendingSongsColumn(_ tracks: [ChartTrack]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                trendingSongRow(track: track)

                if idx < tracks.count - 1 {
                    MusicChevronRowDivider(
                        kind: .custom(
                            leading: MusicDesign.newTabHorizontalInset + 4
                                + NewTabPickedForYouMetrics.artworkSize
                                + NewTabPickedForYouMetrics.artworkToTextSpacing,
                            trailing: MusicDesign.newTabHorizontalInset,
                        )
                    )
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Native ``Menu`` (UIKit `UIMenu`) for chart ⋯ — same pattern as acquisition rows in ``DiscoverySearchView``.
    @ViewBuilder
    private func newTabChartOverflowEllipsis(track: ChartTrack) -> some View {
        let request = Self.acquisitionRequest(for: track)
        let resolvedTrack = resolvedLibraryTrack(for: track)
        if let job = app.acquisition.job(forKey: request.requestKey), !job.status.isTerminal {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: min(1, job.progress))
                    .tint(MusicDesign.accent)
                    .frame(width: 52)
                Text("\(Int((min(1, job.progress) * 100).rounded()))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
            .frame(width: 54, alignment: .trailing)
        } else {
            NewTabChartOverflowPanel(
                track: track,
                onAdd: {
                    Task { await requestAcquisition(for: track) }
                },
                onGoToAlbum: {
                    browseChartSingle = track
                },
                onPlayNext: resolvedTrack.map { lib in
                    {
                        Task { @MainActor in
                            try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [lib])
                        }
                    }
                },
                onToggleFavorite: resolvedTrack.map { lib in
                    { app.toggleFavoriteTrack(id: lib.id) }
                }
            )
        }
    }

    private func trendingSongRow(track: ChartTrack) -> some View {
        let lib = resolvedLibraryTrack(for: track)
        return HStack(spacing: 0) {
            Group {
                if let lib {
                    Button {
                        navigateLibraryTrack = lib
                    } label: {
                        trendingSongRowMainContent(track: track)
                            .coverZoomSource(id: lib.albumId)
                    }
                    .buttonStyle(.plain)
                } else {
                    let source = BrowseAlbumDetailSource.chartBrowse(
                        artistName: track.artistName,
                        title: track.name,
                        imageURL: track.imageURL,
                        kind: track.browseKind
                    )
                    NavigationLink {
                        BrowseAlbumDetailView(source: source)
                    } label: {
                        trendingSongRowMainContent(track: track)
                            .coverZoomSource(id: source.coverZoomId)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if lib != nil {
                MusicNavigationChevron()
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            } else {
                newTabChartOverflowEllipsis(track: track)
            }
        }
        .padding(.leading, MusicDesign.newTabHorizontalInset + 4)
        .padding(.trailing, MusicDesign.newTabHorizontalInset)
        .padding(.vertical, NewTabPickedForYouMetrics.rowVerticalPadding)
        .contentShape(Rectangle())
    }

    private func trendingSongRowMainContent(track: ChartTrack) -> some View {
        HStack(spacing: NewTabPickedForYouMetrics.artworkToTextSpacing) {
            AlbumArtworkView(url: track.imageURL, cornerRadius: 7)
                .frame(
                    width: NewTabPickedForYouMetrics.artworkSize,
                    height: NewTabPickedForYouMetrics.artworkSize,
                )
            VStack(alignment: .leading, spacing: NewTabPickedForYouMetrics.titleArtistSpacing) {
                Text(track.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }

    /// Builds the unified request for a chart row. Album rows request at album
    /// granularity; single rows request the track. Either works for any plugin.
    private static func acquisitionRequest(for track: ChartTrack) -> AcquisitionRequest {
        let isAlbum = track.browseKind.caseInsensitiveCompare("Album") == .orderedSame
        return AcquisitionRequest(
            artist: track.artistName,
            trackTitle: isAlbum ? nil : track.name,
            albumTitle: isAlbum ? track.name : nil,
            coverURL: track.imageURL
        )
    }

    private func requestAcquisition(for track: ChartTrack) async {
        let request = Self.acquisitionRequest(for: track)
        if request.trackTitle != nil,
           LibraryTrackMatcher.matchesLibrary(title: track.name, artists: [track.artistName], titleIndex: app.libraryTrackTitleIndex) {
            app.showTransientToast("Already in your library")
            return
        }
        await app.requestAcquisition(request)
    }

    // MARK: - Album Shelves

    private func artistHighlightShelf(_ items: [NewTabArtistHighlight]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(items) { highlight in
                    NavigationLink {
                        ArtistPageView(input: .named(highlight.name))
                    } label: {
                        artistHighlightCard(highlight: highlight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MusicDesign.newTabHorizontalInset)
            .padding(.bottom, 4)
        }
    }

    private func artistHighlightCard(highlight: NewTabArtistHighlight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: highlight.imageURL, cornerRadius: MusicDesign.albumCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardWidth)
                .clipShape(Circle())
            Text(highlight.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
            Text(highlight.newReleaseCount == 1 ? "1 new release" : "\(highlight.newReleaseCount) new releases")
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
        }
    }

    private func albumShelf(_ items: [ChartAlbum]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items) { album in
                    Group {
                        if let lib = matchedLibraryAlbum(for: album) {
                            Button {
                                navigateLibraryAlbum = lib
                            } label: {
                                albumCard(url: album.imageURL, title: album.name, subtitle: album.artistName)
                                    .coverZoomSource(id: lib.id)
                            }
                            .buttonStyle(.plain)
                        } else {
                            let source = BrowseAlbumDetailSource.chartBrowse(
                                artistName: album.artistName,
                                title: album.name,
                                imageURL: album.imageURL,
                                kind: "Album"
                            )
                            NavigationLink {
                                BrowseAlbumDetailView(source: source)
                            } label: {
                                albumCard(url: album.imageURL, title: album.name, subtitle: album.artistName)
                                    .coverZoomSource(id: source.coverZoomId)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, MusicDesign.newTabHorizontalInset)
            .padding(.bottom, 4)
        }
    }

    private enum NewTabAlbumShelfMetrics {
        static let titleHeight: CGFloat = 38
        static let subtitleHeight: CGFloat = 16
        static let textSpacing: CGFloat = 8
    }

    private func albumCard(url: URL?, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: NewTabAlbumShelfMetrics.textSpacing) {
            AlbumArtworkView(url: url, cornerRadius: MusicDesign.albumCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .frame(
                    width: MusicDesign.shelfCardWidth,
                    height: NewTabAlbumShelfMetrics.titleHeight,
                    alignment: .topLeading,
                )

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(
                    width: MusicDesign.shelfCardWidth,
                    height: NewTabAlbumShelfMetrics.subtitleHeight,
                    alignment: .topLeading,
                )
        }
        .frame(width: MusicDesign.shelfCardWidth, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MusicDesign.secondaryLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.bottom, 14)
    }

    private var gap: some View {
        Spacer().frame(height: 36)
    }
}

/// Hero artwork with Cover Art Archive size fallbacks and a mesh placeholder when art is missing.
private struct NewTabHeroArtwork: View {
    let releaseGroupId: String
    let fallbackURL: URL?
    let seed: String
    let cardWidth: CGFloat
    let imageHeight: CGFloat

    @State private var decoded: CGImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            if loadFailed {
                RadioStationMeshArtworkView(seedKey: seed, cornerRadius: 0)
            } else if let decoded {
                ArtworkPlatformImage.swiftUIImage(cgImage: decoded)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: imageHeight)
                    .clipped()
            } else {
                MusicDesign.tertiarySurfaceFill
            }
        }
        .frame(width: cardWidth, height: imageHeight)
        .clipped()
        .task(id: releaseGroupId) {
            await loadArtwork()
        }
    }

    private func loadArtwork() async {
        loadFailed = false
        decoded = nil

        if let cached = await CoverArtArchiveArtwork.loadReleaseGroupFront(
            releaseGroupId: releaseGroupId,
            maxPixelSize: 900,
        ) {
            decoded = cached
            return
        }

        if let fallbackURL,
           let cached = await RemoteArtworkLoad.cgImage(from: fallbackURL, maxPixelSize: 900)
        {
            decoded = cached
            return
        }

        loadFailed = true
    }
}
