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
    @State private var navigateArtist: ArtistNameNavigation?
    /// Shows the custom **New** + profile row; driven by vertical scroll offset via ``onScrollGeometryChange``.
    @State private var newTabShowFloatingHeader = true

    /// Hide the floating **New** / profile row after this much vertical scroll past the initial resting offset.
    private let newTabFloatingHeaderCollapseSlack = MusicTabFloatingHeaderScrollModifier.defaultSlack

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
        case .lidarr: return "From Lidarr"
        case .server: return "From your server"
        case .none: return "Discover"
        }
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
                // Finish (or skip) the discovery index before chart reconcile. Reconcile used to
                // pin matches one-by-one while the 50k-track index rebuilt on main and froze the tab.
                if app.libraryTrackTitleIndex.isEmpty {
                    await app.refreshLibraryTrackMatchIndex()
                }
                await app.reconcileNewTabChartServerPresence()
            }
            .refreshable {
                await app.refreshLibraryAlbums()
                await app.refreshNewTabBrowse()
                await app.reconcileNewTabChartServerPresence()
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
                    kind: tr.browseKind,
                    albumId: tr.id
                ))
            }
            .navigationDestination(item: $navigateArtist) { item in
                ArtistPageView(input: .named(item.id))
            }
            .navigationDestination(for: NewTabSectionDestination.self) { section in
                NewTabSectionDetailView(section: section)
            }
            .deepLinkPush(tab: .new, path: $navigationPath)
        }
        .coverZoomContext()
        .tint(MusicDesign.accent)
    }

    @ViewBuilder
    private var newTabMainScrollColumn: some View {
        if app.newTabBrowseLoading && !hasAnyNewTabContent {
            VStack(alignment: .leading, spacing: 32) {
                MusicNewTabHeroSkeleton()
                MusicHorizontalShelfSkeleton(
                    title: "Best New Songs",
                    style: .album,
                    count: 5,
                )
                MusicHorizontalShelfSkeleton(
                    title: "New This Week",
                    style: .album,
                    count: 5,
                )
                MusicHorizontalShelfSkeleton(
                    title: "Artists You're Into",
                    style: .artistCircle,
                    count: 5,
                )
            }
            .padding(.top, 8)
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
            // Lazy so the hero and the shelves below the fold aren't all built up front —
            // Home already does this; the New tab was eagerly composing every carousel.
            LazyVStack(alignment: .leading, spacing: 0) {
                if hasNewTabTracks {
                    heroCarousel(Array(app.newTabTopTracks.prefix(6)))
                    gap
                }

                if hasNewTabTracks {
                    sectionHeader("Best New Songs", destination: .bestNewSongs)
                    trendingSongsCarousel(Array(app.newTabTopTracks.prefix(10)))
                    gap
                }

                if hasRecentReleases {
                    sectionHeader("New This Week", destination: .newThisWeek)
                    albumShelf(Array(app.newTabRecentReleases.prefix(12)))
                    gap
                }

                if hasDiscoverReleases {
                    sectionHeader("Recent Releases", destination: .recentReleases)
                    albumShelf(Array(app.newTabDiscoverReleases.prefix(12)))
                    gap
                }

                if hasFromYourArtists {
                    sectionHeader("Trending Songs", destination: .trendingSongs)
                    albumShelf(Array(app.newTabFromYourArtists.prefix(12)))
                    gap
                }

                if hasArtistHighlights {
                    sectionHeader("Artists You're Into")
                    artistHighlightShelf(app.newTabArtistHighlights)
                    gap
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func chartRowState(for chart: ChartTrack) -> NewTabChartRowState {
        app.newTabChartRowState(for: chart)
    }

    private func chartRowOverflowMenu(for track: ChartTrack) -> some View {
        NewTabChartRowOverflowMenu(
            chart: track,
            onRequest: { Task { await requestAcquisition(for: track) } },
            onBrowseAlbum: { browseChartSingle = track },
            onGoToLibraryAlbum: { navigateLibraryAlbum = $0 }
        )
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
        /// Two `.title2` lines + artist — measured so carousel artwork aligns across pages.
        static var titleArtistBlockHeight: CGFloat {
#if os(iOS)
            let titleFont = UIFontMetrics(forTextStyle: .title2).scaledFont(
                for: .systemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize,
                    weight: .bold
                )
            )
            let artistFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: UIFont.preferredFont(forTextStyle: .subheadline)
            )
            let twoLineTitleHeight = titleFont.lineHeight * 2 - 3
            return ceil(twoLineTitleHeight + titleArtistSpacing + artistFont.lineHeight)
#else
            return 72
#endif
        }
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
        let rowState = chartRowState(for: track)
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
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ArtistNameButton(name: track.artistName, font: .subheadline) {
                    navigateArtist = ArtistNameNavigation(id: track.artistName)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: NewTabHeroMetrics.titleArtistBlockHeight, maxHeight: NewTabHeroMetrics.titleArtistBlockHeight, alignment: .topLeading)
            .padding(.bottom, NewTabHeroMetrics.textToArtworkSpacing)

            heroCarouselArtworkLink(
                track: track,
                rowState: rowState,
                cardWidth: cardWidth,
                imageHeight: imageHeight,
            )
        }
        .frame(width: cardWidth, height: pageHeight, alignment: .top)
    }

    @ViewBuilder
    private func heroCarouselArtworkLink(
        track: ChartTrack,
        rowState: NewTabChartRowState,
        cardWidth: CGFloat,
        imageHeight: CGFloat,
    ) -> some View {
        switch rowState {
        case .libraryTrack(let lib):
            Button {
                navigateLibraryTrack = lib
            } label: {
                heroCarouselArtworkCard(
                    track: track,
                    zoomId: lib.albumId,
                    cardWidth: cardWidth,
                    imageHeight: imageHeight,
                    showOverflow: true,
                    badgeText: browseHeroBadge,
                )
                .coverZoomSource(id: lib.albumId, style: .custom)
            }
            .buttonStyle(.plain)
        case .serverAlbum(let album):
            Button {
                navigateLibraryAlbum = album
            } label: {
                heroCarouselArtworkCard(
                    track: track,
                    zoomId: album.id,
                    cardWidth: cardWidth,
                    imageHeight: imageHeight,
                    showOverflow: true,
                    badgeText: browseHeroBadge,
                )
                .coverZoomSource(id: album.id, style: .custom)
            }
            .buttonStyle(.plain)
        case .missing:
            let source = BrowseAlbumDetailSource.chartBrowse(
                artistName: track.artistName,
                title: track.name,
                imageURL: track.imageURL,
                kind: track.browseKind,
                albumId: track.id
            )
            NavigationLink {
                BrowseAlbumDetailView(source: source)
            } label: {
                heroCarouselArtworkCard(
                    track: track,
                    zoomId: source.coverZoomId,
                    cardWidth: cardWidth,
                    imageHeight: imageHeight,
                    showOverflow: true,
                    badgeText: browseHeroBadge,
                )
                .coverZoomSource(id: source.coverZoomId, style: .custom)
            }
            .buttonStyle(.plain)
        }
    }

    private func heroCarouselArtworkCard(
        track: ChartTrack,
        zoomId: String,
        cardWidth: CGFloat,
        imageHeight: CGFloat,
        showOverflow: Bool,
        badgeText: String,
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                NewTabHeroArtwork(
                    imageURL: track.imageURL,
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
            // Not an `AlbumArtworkView`, so the cover-zoom origin is marked by hand.
            .coverZoomCellAnchor(id: zoomId, cornerRadius: MusicDesign.newTabHeroCardCorner)

            if showOverflow {
                chartRowOverflowMenu(for: track)
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

    private func trendingSongRow(track: ChartTrack) -> some View {
        let rowState = chartRowState(for: track)
        return HStack(spacing: 0) {
            Group {
                switch rowState {
                case .libraryTrack(let lib):
                    Button {
                        navigateLibraryTrack = lib
                    } label: {
                        trendingSongRowMainContent(track: track)
                            .coverZoomSource(id: lib.albumId, style: .custom)
                    }
                    .buttonStyle(.plain)
                case .serverAlbum(let album):
                    Button {
                        navigateLibraryAlbum = album
                    } label: {
                        trendingSongRowMainContent(track: track)
                            .coverZoomSource(id: album.id, style: .custom)
                    }
                    .buttonStyle(.plain)
                case .missing:
                    let source = BrowseAlbumDetailSource.chartBrowse(
                        artistName: track.artistName,
                        title: track.name,
                        imageURL: track.imageURL,
                        kind: track.browseKind,
                        albumId: track.id
                    )
                    NavigationLink {
                        BrowseAlbumDetailView(source: source)
                    } label: {
                        trendingSongRowMainContent(track: track)
                            .coverZoomSource(id: source.coverZoomId, style: .custom)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            chartRowOverflowMenu(for: track)
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
                ArtistNameButton(name: track.artistName) {
                    navigateArtist = ArtistNameNavigation(id: track.artistName)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private func requestAcquisition(for track: ChartTrack) async {
        if app.newTabChartRowState(for: track).isOnServer {
            app.showTransientToast("Already on your server")
            return
        }
        let request = track.acquisitionRequest
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
            AlbumArtworkView(url: highlight.imageURL, cornerRadius: MusicDesign.artistCircleTileSize / 2)
                .frame(width: MusicDesign.artistCircleTileSize, height: MusicDesign.artistCircleTileSize)
                .clipShape(Circle())
            Text(highlight.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: MusicDesign.artistCircleTileLabelWidth, alignment: .leading)
            Text(highlight.newReleaseCount == 1 ? "1 new release" : "\(highlight.newReleaseCount) new releases")
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: MusicDesign.artistCircleTileLabelWidth, alignment: .leading)
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
                                albumCard(
                                    url: album.imageURL,
                                    title: album.name,
                                    artist: album.artistName,
                                    onArtistTap: { navigateArtist = ArtistNameNavigation(id: album.artistName) },
                                )
                                    .coverZoomSource(id: lib.id, style: .custom)
                            }
                            .buttonStyle(.plain)
                        } else {
                            let source = BrowseAlbumDetailSource.chartBrowse(
                                artistName: album.artistName,
                                title: album.name,
                                imageURL: album.imageURL,
                                kind: "Album",
                                albumId: album.pluginLookupId ?? album.id
                            )
                            NavigationLink {
                                BrowseAlbumDetailView(source: source)
                            } label: {
                                albumCard(
                                    url: album.imageURL,
                                    title: album.name,
                                    artist: album.artistName,
                                    onArtistTap: { navigateArtist = ArtistNameNavigation(id: album.artistName) },
                                )
                                    .coverZoomSource(id: source.coverZoomId, style: .custom)
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

    private func albumCard(
        url: URL?,
        title: String,
        artist: String,
        onArtistTap: @escaping () -> Void,
    ) -> some View {
        let cardWidth = MusicDesign.shelfCardWidth
        return VStack(alignment: .leading, spacing: 4) {
            AlbumArtworkView(url: url, cornerRadius: MusicDesign.albumCorner)
                .frame(width: cardWidth, height: MusicDesign.shelfCardHeight)
                .padding(.bottom, 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .topLeading)

            ArtistNameButton(name: artist, font: .caption, onTap: onArtistTap)
                .frame(width: cardWidth, alignment: .topLeading)
        }
        .frame(width: cardWidth, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, destination: NewTabSectionDestination? = nil) -> some View {
        Group {
            if let destination {
                NavigationLink(value: destination) {
                    sectionHeaderLabel(title, showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                sectionHeaderLabel(title, showsChevron: false)
            }
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.bottom, 14)
    }

    private func sectionHeaderLabel(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
            Spacer(minLength: 0)
        }
    }

    private var gap: some View {
        Spacer().frame(height: 36)
    }
}

/// Hero artwork from the iTunes feed with a mesh placeholder when art is missing.
private struct NewTabHeroArtwork: View {
    let imageURL: URL?
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
        .task(id: imageURL?.absoluteString ?? seed) {
            await loadArtwork()
        }
    }

    private func loadArtwork() async {
        loadFailed = false
        decoded = nil
        guard let imageURL,
              let cached = await RemoteArtworkLoad.cgImage(from: imageURL, maxPixelSize: 900)
        else {
            loadFailed = true
            return
        }
        decoded = cached
    }
}
