import SwiftUI

/// Apple Music–style **Home** tab: personalized sections pulled from the user's library.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(MiniPlayerCollapseState.self) private var collapseState

    @State private var showFloatingHeader = true

    private let inset: CGFloat = MusicDesign.newTabHorizontalInset
    private let twoCol = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

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
                        if !app.homeRecentlyPlayed.isEmpty {
                            shelf(
                                title: "Recently Played",
                                systemImage: "clock.arrow.circlepath",
                                albums: app.homeRecentlyPlayed
                            )
                        }

                        if !app.recentlyAddedAlbums.isEmpty {
                            twoColumnSection(
                                title: "Top Picks for You",
                                systemImage: "sparkles",
                                albums: Array(app.recentlyAddedAlbums.prefix(6))
                            )
                        }

                        ForEach(app.homeGenreShelves, id: \.genre) { shelf in
                            self.shelf(
                                title: shelf.genre,
                                systemImage: "music.note",
                                albums: shelf.albums
                            )
                        }

                        if app.homeRecentlyPlayed.isEmpty,
                           app.homeGenreShelves.isEmpty,
                           !app.libraryAlbums.isEmpty {
                            twoColumnSection(
                                title: "Your Library",
                                systemImage: "music.note.list",
                                albums: Array(app.libraryAlbums.prefix(10))
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
            .collapsesMiniPlayerOnScroll(collapseState)
            .safeAreaInset(edge: .top, spacing: 0) {
                if showFloatingHeader {
                    MusicTabTitleHeaderBar(title: "Home") {
                        MusicToolbarSettingsAvatarLink(diameter: 45)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showFloatingHeader)
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

    private func twoColumnSection(title: String, systemImage: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: title)

            LazyVGrid(columns: twoCol, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        gridCell(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, inset)
        }
    }

    private func shelf(title: String, systemImage: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            shelfCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    // MARK: - Cells

    private func gridCell(album: AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: MusicDesign.gridAlbumCorner)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .lineLimit(1)
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
}
