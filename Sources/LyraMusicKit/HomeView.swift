import SwiftUI

/// Apple Music–style **Home** tab: personalized sections pulled from the user's library.
/// Every section is a single horizontal-scroll shelf — matches Apple Music's home layout.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showFloatingHeader = true

    private let inset: CGFloat = MusicDesign.newTabHorizontalInset

    private var topPicksAlbums: [AlbumSummary] {
        Array(app.recentlyAddedAlbums.prefix(8))
    }

    private var newReleasesAlbums: [AlbumSummary] {
        Array(app.recentlyAddedAlbums.dropFirst(topPicksAlbums.count).prefix(20))
    }

    private var madeForYouPlaylists: [PlaylistSummary] {
        Array(app.libraryPlaylists.prefix(12))
    }

    var body: some View {
        NavigationStack {
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
            .deepLinkPush(tab: .home)
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
            Text(album.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            Text(album.artist)
                .font(.subheadline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }

    private func shelfCard(album: AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: MusicDesign.heroCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
        }
    }

    private func playlistShelfCard(playlist: PlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: playlist.artworkURL, cornerRadius: MusicDesign.heroCorner)
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
            Text(playlist.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
            Text(playlist.songCount.map { $0 == 1 ? "1 song" : "\($0) songs" } ?? "Playlist")
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
                .frame(width: MusicDesign.shelfCardWidth, alignment: .leading)
        }
    }
}
