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
    @State private var downtifyDownloadingIds: Set<String> = []
    @State private var downtifyDownloadFraction: [String: Double] = [:]
    @State private var downtifyToast: String?
    /// Shows the custom **New** + profile row; driven by vertical scroll offset via ``onScrollGeometryChange``.
    @State private var newTabShowFloatingHeader = true

    /// Hide the floating **New** / profile row after this much vertical scroll past the initial resting offset.
    private let newTabFloatingHeaderCollapseSlack: CGFloat = 72

    private var hasNewTabTracks: Bool {
        !app.newTabTopTracks.isEmpty || !app.newTabTopAlbums.isEmpty
    }

    private var hasRecentReleases: Bool {
        !app.newTabRecentReleases.isEmpty
    }

    private var hasAnyNewTabContent: Bool {
        hasNewTabTracks || hasRecentReleases
    }

    private var browseHeroEyebrow: String {
        "New Releases"
    }

    private var browseHeroBadge: String {
        switch app.newTabBrowseBackend {
        case .musicBrainz: return "Recent on MusicBrainz"
        case .none: return "Discover"
        }
    }

    private var trendingSectionTitle: String {
        "New Albums"
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
        .overlay(alignment: .bottom) {
            if let downtifyToast {
                Text(downtifyToast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(MusicDesign.chromeCapsuleFill))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: downtifyToast)
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
                if !app.newTabTopTracks.isEmpty {
                    heroCarousel(Array(app.newTabTopTracks.prefix(6)))
                    gap
                }

                if !app.newTabTopTracks.isEmpty {
                    sectionHeader(trendingSectionTitle)
                    trendingSongsCarousel(Array(app.newTabTopTracks.prefix(10)))
                    gap
                }

                if hasRecentReleases {
                    sectionHeader("Recent Releases")
                    albumShelf(Array(app.newTabRecentReleases.prefix(12)))
                    gap
                }

                if !app.newTabTopAlbums.isEmpty {
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

    private func newTabHeroCarouselStackHeight(containerWidth: CGFloat) -> CGFloat {
        let inset = MusicDesign.newTabHorizontalInset
        let peek = MusicDesign.newTabHeroPeek
        let spacing: CGFloat = 12
        let cardWidth = max(260, containerWidth - inset - peek - spacing)
        let imageHeight = cardWidth * MusicDesign.newTabHeroImageHeightFactor
        let textBlock: CGFloat = 78
        return textBlock + 12 + imageHeight
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
            let spacing: CGFloat = 12
            let cardWidth = max(260, geo.size.width - inset - peek - spacing)
            let imageHeight = cardWidth * MusicDesign.newTabHeroImageHeightFactor
            let stackHeight = newTabHeroCarouselStackHeight(containerWidth: geo.size.width)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(items) { track in
                        heroCarouselPage(track: track, cardWidth: cardWidth, imageHeight: imageHeight)
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

    private func heroCarouselPage(track: ChartTrack, cardWidth: CGFloat, imageHeight: CGFloat) -> some View {
        let lib = resolvedLibraryTrack(for: track)
        return VStack(alignment: .leading, spacing: 10) {
            Text(browseHeroEyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .textCase(.uppercase)
                .tracking(0.6)

            Text(track.name)
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(track.artistName)
                .font(.title3)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)

            Group {
                if let lib {
                    Button {
                        navigateLibraryTrack = lib
                    } label: {
                        heroCarouselArtworkCard(track: track, imageHeight: imageHeight, showOverflow: false, badgeText: browseHeroBadge)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        BrowseAlbumDetailView(source: .chartBrowse(
                            artistName: track.artistName,
                            title: track.name,
                            imageURL: track.imageURL,
                            kind: track.browseKind
                        ))
                    } label: {
                        heroCarouselArtworkCard(track: track, imageHeight: imageHeight, showOverflow: true, badgeText: browseHeroBadge)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: cardWidth, height: imageHeight)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private func heroCarouselArtworkCard(track: ChartTrack, imageHeight: CGFloat, showOverflow: Bool, badgeText: String) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                RemoteArtworkScaledFill(url: track.imageURL, maxPixelSize: 900) {
                    MusicDesign.tertiarySurfaceFill
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.22), .black.opacity(0.62)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(badgeText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 1)
                    .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: MusicDesign.newTabHeroCardCorner, style: .continuous))

            if showOverflow {
                newTabChartOverflowEllipsis(track: track)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Trending Songs (horizontal pages, 4 rows each)

    /// Row height: artwork 56 + vertical padding 20.
    private var trendingSongCarouselHeight: CGFloat {
        let rowHeight = CGFloat(56 + 20)
        let dividerAllowance: CGFloat = 3
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
                            leading: MusicDesign.newTabHorizontalInset + 4 + 56 + 14,
                            trailing: MusicDesign.newTabHorizontalInset,
                        )
                    )
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Native ``Menu`` (UIKit `UIMenu`) for chart ⋯ — same pattern as Downtify rows in ``DiscoverySearchView``.
    @ViewBuilder
    private func newTabChartOverflowEllipsis(track: ChartTrack) -> some View {
        let song = DowntifySong(chartTrack: track)
        let resolvedTrack = resolvedLibraryTrack(for: track)
        if downtifyDownloadingIds.contains(song.songId) {
            VStack(alignment: .trailing, spacing: 3) {
                if let fr = downtifyDownloadFraction[song.songId] {
                    ProgressView(value: min(1, fr))
                        .tint(MusicDesign.accent)
                        .frame(width: 52)
                    Text("\(Int((min(1, fr) * 100).rounded()))%")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(MusicDesign.secondaryLabel)
                } else {
                    ProgressView()
                        .tint(MusicDesign.accent)
                }
            }
            .frame(width: 54, alignment: .trailing)
        } else {
            NewTabChartOverflowPanel(
                track: track,
                onAdd: {
                    Task { await requestDowntifyDownload(for: song) }
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
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        BrowseAlbumDetailView(source: .chartBrowse(
                            artistName: track.artistName,
                            title: track.name,
                            imageURL: track.imageURL,
                            kind: track.browseKind
                        ))
                    } label: {
                        trendingSongRowMainContent(track: track)
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
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func trendingSongRowMainContent(track: ChartTrack) -> some View {
        HStack(spacing: 14) {
            AlbumArtworkView(url: track.imageURL, cornerRadius: 8)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
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

    private func requestDowntifyDownload(for song: DowntifySong) async {
        guard !downtifyDownloadingIds.contains(song.songId) else { return }
        guard !LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) else {
            flashDowntifyToast("Already in your library")
            return
        }
        downtifyDownloadingIds.insert(song.songId)
        downtifyDownloadFraction[song.songId] = 0
        defer {
            downtifyDownloadingIds.remove(song.songId)
            downtifyDownloadFraction.removeValue(forKey: song.songId)
        }
        let artistLine = song.artists.joined(separator: ", ")
        do {
            let name = try await DowntifyClient.download(artist: artistLine, title: song.name) { p in
                Task { @MainActor in
                    downtifyDownloadFraction[song.songId] = p
                }
            }
            flashDowntifyToast("Downloading \"\(name)\"")
        } catch {
            flashDowntifyToast(error.localizedDescription)
        }
    }

    private func flashDowntifyToast(_ msg: String) {
        downtifyToast = msg
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            downtifyToast = nil
        }
    }

    // MARK: - Album Shelves

    private func albumShelf(_ items: [ChartAlbum]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(items) { album in
                    Group {
                        if let lib = matchedLibraryAlbum(for: album) {
                            Button {
                                navigateLibraryAlbum = lib
                            } label: {
                                albumCard(url: album.imageURL, title: album.name, subtitle: album.artistName)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                BrowseAlbumDetailView(source: .chartBrowse(
                                    artistName: album.artistName,
                                    title: album.name,
                                    imageURL: album.imageURL,
                                    kind: "Album"
                                ))
                            } label: {
                                albumCard(url: album.imageURL, title: album.name, subtitle: album.artistName)
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

    private func albumCard(url: URL?, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: url, cornerRadius: MusicDesign.albumCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
        }
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
