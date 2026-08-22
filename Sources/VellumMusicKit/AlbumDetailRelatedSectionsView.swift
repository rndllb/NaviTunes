import SwiftUI

/// Footer carousels below album metadata: alternate editions, more from the artist, taste picks.
struct AlbumDetailRelatedSectionsView: View {
    @EnvironmentObject private var app: AppModel

    let artist: String
    let title: String
    let excludingAlbumId: String?
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette
    let onSelectAlbum: (AlbumSummary) -> Void

    @State private var otherVersions: [AlbumSummary] = []
    @State private var moreByArtist: [AlbumSummary] = []
    @State private var youMightAlsoLike: [AlbumSummary] = []

    private let inset: CGFloat = 22

    private var displayArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var reloadToken: String {
        "\(artist)|\(title)|\(excludingAlbumId ?? "")|\(app.libraryCatalogEpoch)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !otherVersions.isEmpty {
                carouselShelf(title: "Other Versions", albums: otherVersions)
            }
            if !moreByArtist.isEmpty {
                carouselShelf(title: "More By \(displayArtist)", albums: moreByArtist)
            }
            if !youMightAlsoLike.isEmpty {
                carouselShelf(title: "You Might Also Like", albums: youMightAlsoLike)
            }
        }
        .onAppear(perform: applyMemoryShelves)
        .task(id: reloadToken) {
            applyMemoryShelves()
            await refreshShelvesFromServer()
        }
    }

    private func applyMemoryShelves() {
        let shelves = app.albumDetailShelvesFromMemory(
            artist: artist,
            title: title,
            excludingAlbumId: excludingAlbumId,
        )
        otherVersions = shelves.otherVersions
        moreByArtist = shelves.moreByArtist
        youMightAlsoLike = shelves.youMightAlsoLike
    }

    @MainActor
    private func refreshShelvesFromServer() async {
        let catalog = await app.fetchAlbumDetailArtistCatalog(artist: artist)
        guard !Task.isCancelled else { return }

        let versions = app.albumDetailOtherVersions(
            in: catalog,
            artist: artist,
            title: title,
            excludingAlbumId: excludingAlbumId,
        )
        let versionIDs = Set(versions.map(\.id))
        let more = app.albumDetailMoreByArtist(
            in: catalog,
            artist: artist,
            excludingAlbumId: excludingAlbumId,
            excludingVersionIDs: versionIDs,
        )

        if !versions.isEmpty || !more.isEmpty {
            otherVersions = versions
            moreByArtist = more
        }

        youMightAlsoLike = app.albumDetailYouMightAlsoLike(
            artist: artist,
            excludingAlbumId: excludingAlbumId,
            excludingVersionIDs: versionIDs,
        )
    }

    @ViewBuilder
    private func carouselShelf(title: String, albums: [AlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(backdropPalette.heroChromePrimary)
                .padding(.horizontal, inset)
                .padding(.top, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        Button {
                            onSelectAlbum(album)
                        } label: {
                            AlbumDetailRelatedShelfCard(
                                album: album,
                                backdropPalette: backdropPalette,
                            )
                                .coverZoomSource(id: album.id, style: .custom)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, inset)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct AlbumDetailRelatedShelfCard: View {
    @EnvironmentObject private var app: AppModel
    let album: AlbumSummary
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette

    private static let labelBlockMinHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(
                url: app.resolvedArtworkURL(for: album),
                cornerRadius: MusicDesign.heroCorner,
            )
            .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
                    .lineLimit(1)
            }
            .frame(
                minWidth: MusicDesign.shelfCardWidth,
                idealWidth: MusicDesign.shelfCardWidth,
                maxWidth: MusicDesign.shelfCardWidth,
                minHeight: Self.labelBlockMinHeight,
                alignment: .topLeading,
            )
        }
    }
}
