import SwiftUI

/// Apple Music–style **Home** tab: personalized sections pulled from the user's library.
/// Every section is a single horizontal-scroll shelf — matches Apple Music's home layout.
/// One circular tile in the Home → "New Artists Added" shelf. Synthesized
/// in-memory from ``AppModel/recentlyAddedAlbums`` so there's no extra fetch.
private struct HomeArtistTile: Identifiable {
    let id: String
    let name: String
    let artworkURL: URL?
}

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showFloatingHeader = true
    @State private var navigationPath = NavigationPath()

    private let inset: CGFloat = MusicDesign.newTabHorizontalInset

    private var topPicksAlbums: [AlbumSummary] {
        Array(app.recentlyAddedAlbums.prefix(8))
    }

    private var newReleasesAlbums: [AlbumSummary] {
        Array(app.recentlyAddedAlbums.dropFirst(topPicksAlbums.count).prefix(20))
    }

    /// Most recently added unique artists, derived by walking ``AppModel/recentlyAddedAlbums``
    /// (already sorted newest-first) and deduping by normalized artist name. Capped at 12 so
    /// the shelf doesn't run the full library in one row.
    private var newlyAddedArtists: [HomeArtistTile] {
        var seen = Set<String>()
        var out: [HomeArtistTile] = []
        for album in app.recentlyAddedAlbums {
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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if app.libraryAlbums.isEmpty && app.libraryAlbumsLoadError == nil {
                        ProgressView()
                            .tint(MusicDesign.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if let err = app.libraryAlbumsLoadError, app.libraryAlbums.isEmpty {
                        ContentUnavailableView(
                            "Couldn't load library",
                            systemImage: "exclamationmark.triangle",
                            description: Text(err)
                        )
                        .padding(.top, 40)
                    } else {
                        if !topPicksAlbums.isEmpty {
                            heroShelf(
                                title: "Top Picks for You",
                                albums: topPicksAlbums
                            )
                        }

                        if !newlyAddedArtists.isEmpty {
                            newArtistsShelf(title: "New Artists Added", artists: newlyAddedArtists)
                        }

                        if !app.homeRecentlyPlayed.isEmpty {
                            recentlyPlayedShelf(
                                title: "Recently Played",
                                items: app.homeRecentlyPlayed
                            )
                        }

                        if !madeForYouPlaylists.isEmpty {
                            playlistShelf(
                                title: "Your Playlists",
                                playlists: madeForYouPlaylists
                            )
                        }

                        ForEach(app.homeGenreShelves, id: \.genre) { shelf in
                            self.shelf(title: shelf.genre, albums: shelf.albums)
                        }

                        if !newReleasesAlbums.isEmpty {
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
                slack: 72,
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
                await app.refreshHome()
            }
            .deepLinkPush(tab: .home, path: $navigationPath)
        }
        .tint(MusicDesign.accent)
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
                        NavigationLink {
                            ServerPlaylistDetailView(album: album)
                        } label: {
                            heroCard(album: album)
                        }
                        .buttonStyle(.plain)
                        .libraryAlbumContextMenu(album)
                    }
                }
                .padding(.horizontal, inset)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func shelf(title: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            ServerPlaylistDetailView(album: album)
                        } label: {
                            shelfCard(album: album)
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
                            NavigationLink {
                                ServerPlaylistDetailView(album: album)
                            } label: {
                                shelfCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .libraryAlbumContextMenu(album)
                        case .playlist(let playlist):
                            NavigationLink {
                                ServerPlaylistDetailView(playlist: playlist)
                            } label: {
                                playlistShelfCard(playlist: playlist)
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
                        NavigationLink {
                            ArtistPageView(input: .named(artist.name))
                        } label: {
                            newArtistCircleTile(artist: artist)
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
            AlbumArtworkView(url: artist.artworkURL, cornerRadius: 60)
                .frame(width: 110, height: 110)
                .clipShape(Circle())
            Text(artist.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minWidth: 120, idealWidth: 120, maxWidth: 120, minHeight: 30, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func playlistShelf(title: String, playlists: [PlaylistSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            ServerPlaylistDetailView(playlist: playlist)
                        } label: {
                            playlistShelfCard(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .libraryPlaylistContextMenu(playlist)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    // MARK: - Cells

    private func heroCard(album: AlbumSummary) -> some View {
        let width: CGFloat = MusicDesign.shelfCardWidth + 60
        return VStack(alignment: .leading, spacing: 10) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: MusicDesign.heroCorner)
                .frame(width: width, height: width)
            shelfLabelBlock(title: album.title, subtitle: album.artist, width: width)
        }
    }

    private func shelfCard(album: AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: MusicDesign.heroCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            shelfLabelBlock(title: album.title, subtitle: album.artist, width: MusicDesign.shelfCardWidth)
        }
    }

    private func playlistShelfCard(playlist: PlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: MusicDesign.heroCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            shelfLabelBlock(
                title: playlist.name,
                subtitle: playlist.songCount.map { $0 == 1 ? "1 song" : "\($0) songs" } ?? "Playlist",
                width: MusicDesign.shelfCardWidth
            )
        }
    }

    /// Tight title + subtitle pair used by every shelf card. The two labels sit
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
