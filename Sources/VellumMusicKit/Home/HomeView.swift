import SwiftUI

/// Apple Music–style **Home** tab: personalized sections pulled from the user's library.
/// Every section is a single horizontal-scroll shelf — matches Apple Music's home layout.
/// One circular tile in the Home → "New Artists Added" shelf. Synthesized
/// in-memory from ``AppModel/recentlyAddedAlbums`` so there's no extra fetch.
private struct HomeArtistTile: Identifiable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
}

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showFloatingHeader = true
    @State private var navigationPath = NavigationPath()
    /// Shelf covers push through `navigationDestination(item:)` rather than a destination-closure
    /// `NavigationLink`.
    ///
    /// Not a style preference — it is what makes the cover-zoom transition possible here at all.
    /// Measured on device: a `NavigationLink { destination } label:` inside these horizontal
    /// shelves pushes with **`animated: false`** (`COVERZOOM willShow animated=false … depth=2
    /// coordinator=false`), and UIKit never asks any delegate for an animator on a non-animated
    /// push — so the custom animator was never even offered, on every Home cover, while Library
    /// and the New tab reported `animated=true` on the identical code. The New tab already used
    /// this button + `navigationDestination(item:)` shape and animates correctly; Home now
    /// matches it.
    @State private var navigateAlbum: AlbumSummary?
    @State private var navigatePlaylist: PlaylistSummary?
    @State private var navigateMix: HomeMix?
    @State private var navigateArtistName: String?

    private let inset: CGFloat = MusicDesign.newTabHorizontalInset

    private var topPicksAlbums: [AlbumSummary] {
        app.homeTopPickAlbums
    }

    private var newReleasesAlbums: [AlbumSummary] {
        app.homeNewReleaseAlbums
    }

    /// Unique artists from server recently-added albums the user has **not** added to their library.
    private var newlyAddedArtists: [HomeArtistTile] {
        var seen = Set<String>()
        var out: [HomeArtistTile] = []
        for album in app.recentlyAddedAlbums {
            guard app.isEligibleForHomeTopPick(album) else { continue }
            let normalized = LibraryTrackMatcher.normalize(album.artist)
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            out.append(HomeArtistTile(
                id: "\(normalized)",
                name: album.artist,
                artworkURL: album.artworkURL
            ))
            if out.count >= 12 { break }
        }
        return out
    }

    private var madeForYouPlaylists: [PlaylistSummary] {
        Array(app.libraryPlaylists.prefix(12))
    }

    /// Home discovery shelves are still resolving — show skeleton rows instead of empty space.
    private var homeDiscoveryPending: Bool {
        app.homeRefreshInFlight
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if let err = app.libraryAlbumsLoadError, app.libraryAlbums.isEmpty {
                        ContentUnavailableView(
                            "Couldn't load library",
                            systemImage: "exclamationmark.triangle",
                            description: Text(err)
                        )
                        .padding(.top, 40)
                    } else {
                        if topPicksAlbums.isEmpty, homeDiscoveryPending {
                            MusicHorizontalShelfSkeleton(
                                title: "Top Picks for You",
                                style: .topPickHero,
                                count: 4,
                                horizontalInset: inset,
                            )
                        } else if !topPicksAlbums.isEmpty {
                            heroShelf(
                                title: "Top Picks for You",
                                albums: topPicksAlbums
                            )
                        }

                        newArtistsSection

                        if !app.homeRecentlyPlayed.isEmpty {
                            recentlyPlayedShelf(
                                title: "Recently Played",
                                items: app.homeRecentlyPlayed
                            )
                        }

                        if !app.homeMixes.isEmpty {
                            madeForYouShelf(title: "Made for You", mixes: app.homeMixes)
                        }

                        if !madeForYouPlaylists.isEmpty {
                            playlistShelf(
                                title: "Your Playlists",
                                playlists: madeForYouPlaylists
                            )
                        }

                        if app.homeGenreShelves.isEmpty, homeDiscoveryPending {
                            MusicHorizontalShelfSkeleton(
                                title: "Browse by Genre",
                                style: .album,
                                count: 5,
                                horizontalInset: inset,
                            )
                        } else {
                            ForEach(app.homeGenreShelves, id: \.genre) { shelf in
                                self.shelf(title: shelf.genre, albums: shelf.albums)
                            }
                        }

                        if newReleasesAlbums.isEmpty, homeDiscoveryPending {
                            MusicHorizontalShelfSkeleton(
                                title: "New Releases for You",
                                style: .album,
                                count: 5,
                                horizontalInset: inset,
                            )
                        } else if !newReleasesAlbums.isEmpty {
                            shelf(
                                title: "New Releases for You",
                                albums: newReleasesAlbums
                            )
                        }

                        if app.homeRecentlyPlayed.isEmpty,
                           app.homeGenreShelves.isEmpty,
                           topPicksAlbums.isEmpty,
                           !app.libraryAlbums.isEmpty {
                            shelf(
                                title: "Your Library",
                                albums: Array(app.libraryAlbums.prefix(20))
                            )
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: MusicTabFloatingHeaderScrollModifier.defaultSlack,
                showFloatingHeader: $showFloatingHeader
            ))
            .musicTabFloatingHeaderInset(isVisible: showFloatingHeader) {
                MusicTabTitleHeaderBar(title: "Home") {
                    MusicToolbarSettingsAvatarLink(diameter: 45)
                }
            }
            .background(MusicDesign.background)
            .musicNewTabNavigationChrome()
            .musicNewTabRootHidesNavigationBar()
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .task {
                await app.refreshHome()
            }
            .onChange(of: app.isSignedIn) { _, signed in
                guard signed else { return }
                Task { await app.refreshHome() }
            }
            .refreshable {
                await app.refreshLibraryAlbums()
                await app.refreshHome(forceDiscoveryReshuffle: true)
            }
            .navigationDestination(item: $navigateAlbum) { album in
                ServerPlaylistDetailView(album: album)
            }
            .navigationDestination(item: $navigatePlaylist) { playlist in
                ServerPlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(item: $navigateMix) { mix in
                ServerPlaylistDetailView(homeMixId: mix.id)
            }
            .navigationDestination(item: $navigateArtistName) { name in
                ArtistPageView(input: .named(name))
            }
            .deepLinkPush(tab: .home, path: $navigationPath)
        }
        .coverZoomContext()
        .tint(MusicDesign.accent)
    }

    /// ``newlyAddedArtists`` walks the recently-added albums and tests each for library
    /// eligibility, so it is resolved once per pass rather than in both branch conditions.
    @ViewBuilder
    private var newArtistsSection: some View {
        let artists = newlyAddedArtists
        if artists.isEmpty {
            if homeDiscoveryPending {
                MusicHorizontalShelfSkeleton(
                    title: "New Artists Added",
                    style: .artistCircle,
                    count: 6,
                    horizontalInset: inset,
                )
            }
        } else {
            newArtistsShelf(title: "New Artists Added", artists: artists)
        }
    }

    // MARK: - Section builders

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .foregroundStyle(.primary)
            .padding(.horizontal, inset)
    }

    /// Top of home — larger banner-style album cards matching Apple Music's "Top Picks for You" hero row.
    private func heroShelf(title: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(albums) { album in
                        Button {
                            navigateAlbum = album
                        } label: {
                            heroCard(album: album)
                                // The cover inside is square-cornered; the card's clip supplies
                                // the visible rounding, so the origin rect takes that radius.
                                .coverZoomSource(id: album.id, style: .custom, cellCornerRadius: MusicDesign.homeTopPickCardCorner)
                        }
                        .buttonStyle(.plain)
                        .libraryAlbumContextMenu(album)
                    }
                }
                .padding(.horizontal, inset)
            }
            .frame(height: MusicDesign.homeTopPickCardHeight)
        }
    }

    private func shelf(title: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        Button {
                            navigateAlbum = album
                        } label: {
                            shelfCard(album: album)
                                .coverZoomSource(id: album.id, style: .custom)
                        }
                        .buttonStyle(.plain)
                        .libraryAlbumContextMenu(album)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    /// Mixed-content shelf (albums + playlists) used by Recently Played, where each tile reflects
    /// whatever surface the user actually started playback from.
    private func recentlyPlayedShelf(title: String, items: [RecentPlayedItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        switch item {
                        case .album(let album):
                            Button {
                                navigateAlbum = album
                            } label: {
                                shelfCard(album: album)
                                    .coverZoomSource(id: album.id, style: .custom)
                            }
                            .buttonStyle(.plain)
                            .libraryAlbumContextMenu(album)
                        case .playlist(let playlist):
                            Button {
                                navigatePlaylist = playlist
                            } label: {
                                playlistShelfCard(playlist: playlist)
                                    .coverZoomSource(id: playlist.id, style: .custom)
                            }
                            .buttonStyle(.plain)
                            .libraryPlaylistContextMenu(playlist)
                        }
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    private func newArtistsShelf(title: String, artists: [HomeArtistTile]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(artists) { artist in
                        Button {
                            navigateArtistName = artist.name
                        } label: {
                            newArtistCircleTile(artist: artist)
                                .coverZoomSource(
                                    id: ArtistPageInput.coverZoomPageId(forName: artist.name),
                                    style: .custom,
                                    // The tile's rounding is a `clipShape(Circle())` outside the
                                    // artwork, so the origin rect has to be told it is round.
                                    cellCornerRadius: MusicDesign.artistCircleTileSize / 2,
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    private func newArtistCircleTile(artist: HomeArtistTile) -> some View {
        VStack(spacing: 8) {
            AlbumArtworkView(
                url: artist.artworkURL,
                cornerRadius: MusicDesign.artistCircleTileSize / 2,
                maxDecodePixels: MusicDesign.artistCircleArtworkDecodePixels
            )
                .frame(width: MusicDesign.artistCircleTileSize, height: MusicDesign.artistCircleTileSize)
                .clipShape(Circle())
            Text(artist.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(
                    minWidth: MusicDesign.artistCircleTileLabelWidth,
                    idealWidth: MusicDesign.artistCircleTileLabelWidth,
                    maxWidth: MusicDesign.artistCircleTileLabelWidth,
                    minHeight: 30,
                    alignment: .top
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func playlistShelf(title: String, playlists: [PlaylistSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists) { playlist in
                        Button {
                            navigatePlaylist = playlist
                        } label: {
                            playlistShelfCard(playlist: playlist)
                                .coverZoomSource(id: playlist.id, style: .custom)
                        }
                        .buttonStyle(.plain)
                        .libraryPlaylistContextMenu(playlist)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    private func madeForYouShelf(title: String, mixes: [HomeMix]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(mixes) { mix in
                        // Tap opens the mix like any playlist; Play / Shuffle live on the
                        // long-press menu — the same one Library's mix rows use.
                        Button {
                            navigateMix = mix
                        } label: {
                            mixShelfCard(mix: mix)
                                .coverZoomSource(id: mix.libraryPlaylistId, style: .custom)
                        }
                        .buttonStyle(.plain)
                        .homeMixOrPlaylistContextMenu(mix.asPlaylistSummary(), app: app)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    // MARK: - Cells

    private func heroCard(album: AlbumSummary) -> some View {
        HomeTopPickCard(album: album)
            .equatable()
    }

    private func shelfCard(album: AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(
                url: album.artworkURL,
                cornerRadius: MusicDesign.heroCorner,
                maxDecodePixels: MusicDesign.shelfArtworkDecodePixels
            )
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            shelfLabelBlock(title: album.title, subtitle: album.artist, width: MusicDesign.shelfCardWidth)
        }
    }

    private func playlistShelfCard(playlist: PlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(
                url: playlist.artworkURL,
                cornerRadius: MusicDesign.heroCorner,
                maxDecodePixels: MusicDesign.shelfArtworkDecodePixels
            )
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            shelfLabelBlock(
                title: playlist.name,
                subtitle: playlist.songCount.map { $0 == 1 ? "1 song" : "\($0) songs" } ?? "Playlist",
                width: MusicDesign.shelfCardWidth
            )
        }
    }

    private func mixShelfCard(mix: HomeMix) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MixCollageArtworkView(
                urls: mix.artworkURLs,
                fallbackSeed: "homeMix:\(mix.id)",
                cornerRadius: MusicDesign.heroCorner
            )
            .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            shelfLabelBlock(title: mix.title, subtitle: mix.subtitle, width: MusicDesign.shelfCardWidth)
        }
    }

    /// Tight title + subtitle pair used by every shelf card.
    /// directly adjacent (spacing 2), and the **combined** block reserves the
    /// 2-line title + 1-line subtitle height. When the title only takes 1 line
    /// (short album/playlist names), the leftover space falls below the
    /// subtitle — not between title and subtitle — so the cards stay aligned
    /// across the row without an awkward gap inside the label.
    private func shelfLabelBlock(title: String, subtitle: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
        }
        .frame(
            minWidth: width, idealWidth: width, maxWidth: width,
            minHeight: Self.shelfLabelBlockMinHeight, alignment: .topLeading
        )
    }

    /// Reserved height for the combined `(title, subtitle)` block: two title
    /// lines + spacing + one subtitle line. Keeps shelf rows aligned regardless
    /// of how long the individual album/playlist names are.
    private static let shelfLabelBlockMinHeight: CGFloat = 56
}

// MARK: - Top Picks editorial card

/// Apple Music–style Home shelf card: sharp cover on top, vertically stretched color bleed below, metadata at the bottom.
private struct HomeTopPickCard: View, Equatable {
    let album: AlbumSummary

    static func == (lhs: HomeTopPickCard, rhs: HomeTopPickCard) -> Bool {
        lhs.album == rhs.album
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var palette: ArtworkDynamicGradient.BackdropPalette

    init(album: AlbumSummary) {
        self.album = album
        _palette = State(initialValue: ArtworkDynamicGradient.seededBackdrop(for: album.artworkURL))
    }

    private var cardWidth: CGFloat { MusicDesign.homeTopPickCardWidth }
    private var cardHeight: CGFloat { MusicDesign.homeTopPickCardHeight }
    private var cardCorner: CGFloat { MusicDesign.homeTopPickCardCorner }
    private var artworkSize: CGFloat { MusicDesign.homeTopPickArtworkSize }
    private var bleedBandHeight: CGFloat { MusicDesign.homeTopPickBleedBandHeight }
    private var seamOverlap: CGFloat { MusicDesign.homeTopPickBleedSeamOverlap }
    private var bleedRenderHeight: CGFloat { bleedBandHeight + seamOverlap }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBleedBand
                .offset(y: artworkSize - seamOverlap)

            coverArtWithSeamFade

            VStack(spacing: 0) {
                Color.clear
                    .frame(width: cardWidth, height: artworkSize)
                bleedMetadataRegion
                    .frame(width: cardWidth, height: bleedBandHeight)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
        .overlay {
            MusicDesign.artworkSubtleBorderOverlay(
                cornerRadius: cardCorner,
                colorScheme: colorScheme,
            )
        }
        // The `.onAppear` prefetch that used to sit here is gone. It fired at the same moment as
        // the `.task` below, and on a cold cache both missed and both ran the whole path —
        // and `ArtworkURLCache.data(for:)` has no in-flight de-duplication, so one image cost
        // two network requests, two decodes and two pixel analyses. The `.task` already reads
        // the cache first, so it covers the warm case the prefetch was meant to win.
        .task(id: album.artworkURL?.absoluteString ?? album.id) {
            if let cached = ArtworkDynamicGradient.cachedBackdrop(for: album.artworkURL) {
                palette = cached
                return
            }
            palette = await ArtworkDynamicGradient.analyzeBackdrop(from: album.artworkURL)
        }
    }

    private var coverArtWithSeamFade: some View {
        AlbumArtworkView(
            url: album.artworkURL,
            cornerRadius: 0,
            maxDecodePixels: MusicDesign.homeTopPickArtworkDecodePixels,
            showsSubtleBorder: false
        )
            .frame(width: artworkSize, height: artworkSize)
            .mask {
                VStack(spacing: 0) {
                    Rectangle().fill(.white)
                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .top,
                        endPoint: .bottom,
                    )
                    .frame(height: MusicDesign.homeTopPickArtSeamFadeHeight)
                }
            }
    }

    private var bleedMetadataRegion: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            metadataBlock
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var artworkBleedBand: some View {
        ZStack(alignment: .top) {
            HomeTopPickArtworkBleed(
                url: album.artworkURL,
                width: cardWidth,
                height: bleedRenderHeight,
                fallbackColor: palette.heroSolidBackdropColor,
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.2), location: 0.78),
                    .init(color: .black.opacity(0.46), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
        }
        .frame(width: cardWidth, height: bleedRenderHeight)
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Addition")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .padding(.bottom, 2)
            Text(album.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(album.artist)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .padding(.top, 1)
        }
    }
}
