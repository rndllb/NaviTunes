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
            } else if isLoadingShelves {
                // ONLY while genuinely loading. `isLoadingShelves` is true from the moment the
                // shelf task starts until `refreshShelvesFromServer` has returned, so once the
                // answer is known and it is "nothing similar", this disappears and the section
                // renders nothing — a legitimately empty shelf never shows a permanent shimmer.
                // Reuses the app's own skeleton, the same one the artist page uses for its shelves.
                MusicHorizontalShelfSkeleton(
                    title: "You Might Also Like",
                    style: .album,
                    count: 4,
                    horizontalInset: inset,
                )
                .padding(.top, 28)
                .padding(.bottom, 8)
            }
        }
        // No `.onAppear(perform: applyMemoryShelves)` here on purpose. `reloadToken` already
        // carries `libraryCatalogEpoch`, so `.task(id:)` re-runs whenever the answer could have
        // changed — and it runs `applyMemoryShelves` itself. The extra `onAppear` only added a
        // second full derivation on every scroll-into-view.
        .task(id: reloadToken) {
            isLoadingShelves = true
            applyMemoryShelves()
            await refreshShelvesFromServer()
            isLoadingShelves = false
        }
    }

    /// True from the moment the shelf work starts until the server refresh has returned. It is the
    /// only thing that separates "still loading" from "there is genuinely nothing similar" — before
    /// this, both rendered nothing at all and the user could not tell them apart.
    @State private var isLoadingShelves = false

    private func applyMemoryShelves() {
#if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
#endif
        let shelves = app.albumDetailShelvesFromMemory(
            artist: artist,
            title: title,
            excludingAlbumId: excludingAlbumId,
        )
        otherVersions = shelves.otherVersions
        moreByArtist = shelves.moreByArtist
        youMightAlsoLike = shelves.youMightAlsoLike
#if DEBUG
        // Deliberately unthresholded. The acceptance test is that this drops to ~0 ms on every
        // appearance after the first, and a threshold would hide exactly the readings that prove
        // it — a span that stops logging is indistinguishable from one that stopped running.
        DebugUIRemote.log(String(
            format: "SHELF applyMemoryShelves=%.1fms artist=%@",
            (CFAbsoluteTimeGetCurrent() - start) * 1000, artist))
#endif
    }

    @MainActor
    private func refreshShelvesFromServer() async {
#if DEBUG
        // `defer` so the span still records when the early `Task.isCancelled` return fires —
        // a scroll-away mid-fetch is a normal outcome and its cost still counts.
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            DebugUIRemote.log(String(
                format: "SHELF refreshShelvesFromServer=%.1fms artist=%@",
                (CFAbsoluteTimeGetCurrent() - start) * 1000, artist))
        }
#endif
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

        let refreshed = app.albumDetailYouMightAlsoLike(
            artist: artist,
            excludingAlbumId: excludingAlbumId,
            excludingVersionIDs: versionIDs,
        )
        // Same guard the two shelves above already have: never replace a shelf that is on screen
        // with an empty one. This assignment being unguarded is why the shelf could appear and then
        // disappear seconds later without the user doing anything.
        if !refreshed.isEmpty { youMightAlsoLike = refreshed }
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
                maxDecodePixels: MusicDesign.shelfArtworkDecodePixels,
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
