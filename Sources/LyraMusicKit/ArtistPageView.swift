import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Apple Music–style artist page. Stretchy banner hero with transparent nav bar
/// (banner extends through the safe area and stretches with overscroll), Top
/// Songs as a paged horizontal carousel of 4-row columns, classified discography
/// with size hierarchy (Albums prominent, Singles/EPs/Live/Compilations smaller),
/// MusicBrainz "Other Releases" the user's server doesn't have, About with inline
/// MORE expansion, and Similar Artists.
///
/// Driven by ``ArtistViewModel`` which loads server catalog + Last.fm + TheAudioDB
/// + MusicBrainz in parallel and publishes each slice independently so sections
/// render as their data resolves. Empty slices hide entirely.
struct ArtistPageView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: ArtistViewModel
    /// Local push target for "Go to Album" menu actions fired from rows inside this
    /// artist page. Using `@State` here (not `app.presentedDeepLink`) keeps the push
    /// on **this** page's NavigationStack, so Back returns to this artist instead of
    /// the tab root.
    @State private var navigateAlbum: AlbumSummary?

    init(input: ArtistPageInput) {
        _model = StateObject(wrappedValue: ArtistViewModel(input: input))
    }

    private static let scrollCoordinateSpace = "ArtistPageView.scroll"

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ArtistHeroSection(model: model, scrollSpace: Self.scrollCoordinateSpace)

                ArtistTopSongsSection(model: model, onGoToAlbum: { navigateAlbum = $0 })
                ArtistDiscographyCarousel(model: model, bucket: .albums, title: "Albums", layout: .prominent)
                ArtistDiscographyCarousel(model: model, bucket: .singlesAndEPs, title: "Singles & EPs", layout: .compact)
                ArtistDiscographyCarousel(model: model, bucket: .live, title: "Live Albums", layout: .compact)
                ArtistDiscographyCarousel(model: model, bucket: .compilations, title: "Compilations", layout: .compact)
                ArtistAboutSection(model: model)
                ArtistSimilarSection(model: model)

                Spacer(minLength: 32)
            }
        }
        .coordinateSpace(name: Self.scrollCoordinateSpace)
        .scrollIndicators(.hidden)
        .background(MusicDesign.background)
        .ignoresSafeArea(edges: .top)
        .navigationTitle(model.displayName)
        .musicNavigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ArtistFollowButton(name: model.displayName)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ArtistFavoriteStarButton(name: model.displayName)
            }
        }
        .task(id: artistTaskKey) {
            await model.load(using: app)
        }
        .refreshable {
            await model.load(using: app)
        }
        .overlay(alignment: .center) {
            if !model.hasAnyContent, !model.isLoadingServerCatalog, !model.isLoadingEnrichment {
                ContentUnavailableView(
                    "No info for this artist",
                    systemImage: "mic",
                    description: Text("We couldn't find any songs, releases, or biography for \(model.displayName).")
                )
                .padding(.horizontal, 24)
            } else if !model.hasAnyContent, model.isLoadingServerCatalog || model.isLoadingEnrichment {
                ProgressView()
                    .tint(MusicDesign.accent)
            }
        }
        .navigationDestination(item: $navigateAlbum) { album in
            ServerPlaylistDetailView(album: album, librarySource: app.isAlbumInLibrary(album.id))
        }
    }

    private var artistTaskKey: String {
        switch model.input {
        case .libraryArtist(let a): return "lib:\(a.id)"
        case .named(let n): return "name:\(n)"
        }
    }
}

// MARK: - Hero (stretchy banner that extends behind the nav bar and grows on overscroll)

private struct ArtistHeroSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel
    let scrollSpace: String

    private var bannerURL: URL? {
        model.details?.wideArtworkURL
            ?? model.details?.thumbArtworkURL
            ?? model.input.serverArtworkURL
    }

    private var baseHeight: CGFloat {
        #if os(iOS)
        return min(max(UIScreen.main.bounds.width * 0.95, 320), 460)
        #else
        return 380
        #endif
    }

    var body: some View {
        StretchyHeaderContainer(scrollSpace: scrollSpace, baseHeight: baseHeight) {
            ArtistBannerImage(url: bannerURL, seed: model.displayName)
        } overlay: { _ in
            ArtistHeroOverlay(model: model)
        }
    }
}

private struct ArtistHeroOverlay: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ArtistViewModel

    var body: some View {
        ZStack {
            // Dark scrim at the bottom so the artist name + buttons stay readable
            // regardless of how light the banner is.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Title + play row pinned to the bottom.
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.leading)
                        if let line = metadataLine {
                            Text(line)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 20)

                    Spacer(minLength: 12)

                    ArtistHeroPlayButton(model: model)
                        .padding(.trailing, 20)
                }
                .padding(.bottom, 22)
            }
        }
    }

    private var metadataLine: String? {
        guard let d = model.details else { return nil }
        var parts: [String] = []
        if let g = d.genre { parts.append(g) }
        if let y = d.formedYear { parts.append("Formed \(y)") }
        if let c = d.country { parts.append(c) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Top-right toolbar action — just the star glyph. The toolbar already wraps
/// items in its own chrome on iOS 26 (Liquid Glass), so we deliberately don't
/// add a background or border here — doing so produces a visible double-layer.
private struct ArtistFavoriteStarButton: View {
    @EnvironmentObject private var app: AppModel
    let name: String

    private var isFavorited: Bool {
        app.isArtistFavorited(name: name)
    }

    var body: some View {
        Button {
            let wasFavorited = isFavorited
            app.toggleFavoriteArtist(name: name)
            app.showTransientToast(wasFavorited ? "Removed from Favorites" : "Added to Favorites")
        } label: {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .font(.body.weight(.semibold))
                .foregroundStyle(isFavorited ? MusicDesign.accent : .white)
        }
        .accessibilityLabel(isFavorited ? "Remove from favorites" : "Add to favorites")
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
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Circle().fill(MusicDesign.accent))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!model.hasPlayableTracks)
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
    @ViewBuilder var banner: () -> Banner
    @ViewBuilder var overlay: (CGFloat) -> Overlay

    var body: some View {
        GeometryReader { proxy in
            let yOffset = proxy.frame(in: .named(scrollSpace)).minY
            let extra = max(yOffset, 0)
            let safeAreaTop = proxy.safeAreaInsets.top

            ZStack(alignment: .bottom) {
                banner()
                    .frame(width: proxy.size.width, height: baseHeight + extra + safeAreaTop)
                    .clipped()

                overlay(baseHeight + extra)
                    .frame(width: proxy.size.width, height: baseHeight + extra)
            }
            .frame(width: proxy.size.width, height: baseHeight + extra + safeAreaTop)
            .offset(y: -extra - safeAreaTop)
        }
        .frame(height: baseHeight)
    }
}

/// Banner image: AsyncImage when a remote URL exists, otherwise a deterministic
/// gradient seeded by the artist name (Apple Music–style premium fallback).
private struct ArtistBannerImage: View {
    let url: URL?
    let seed: String

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty, .failure:
                        ArtistGradientFallback(seed: seed)
                    @unknown default:
                        ArtistGradientFallback(seed: seed)
                    }
                }
            } else {
                ArtistGradientFallback(seed: seed)
            }
        }
    }
}

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
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)
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
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                            ArtistTopSongsPage(rows: page,
                                               onRequest: { requestSheetFor = $0 },
                                               onGoToAlbum: onGoToAlbum)
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
                        kind: "Single"
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
                ArtistTopSongRowView(row: row, onRequest: onRequest, onGoToAlbum: onGoToAlbum)
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
    let row: ArtistTopSongRow
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
                        .foregroundStyle(row.libraryTrack == nil ? MusicDesign.secondaryLabel : Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        if let album = row.albumTitle {
                            Text(album)
                                .lineLimit(1)
                        }
                        if let year = row.releaseYear, year > 1900 {
                            if row.albumTitle != nil {
                                Text("·").foregroundStyle(MusicDesign.secondaryLabel.opacity(0.6))
                            }
                            Text(String(year))
                                .foregroundStyle(MusicDesign.secondaryLabel.opacity(0.85))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    // Pull the subtitle baseline up so it sits tight under the
                    // title's descender (Apple Music's compact row rhythm). The
                    // default `Text` line-box leaves ~3pt of slack between
                    // semibold subheadline and caption, which reads as a gap.
                    .padding(.top, -2)
                }

                Spacer(minLength: 6)

                ArtistTopSongOverflowMenu(row: row, onRequest: onRequest, onGoToAlbum: onGoToAlbum)
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
        } else {
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
    let row: ArtistTopSongRow
    let onRequest: (ArtistTopSongRow) -> Void
    let onGoToAlbum: (AlbumSummary) -> Void

    var body: some View {
        Menu {
            if let track = row.libraryTrack {
                StandardSongMenuContent(
                    track: track,
                    onPlayNext: {
                        Task { @MainActor in
                            try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [track])
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
                        ? { Task { await app.removeSongFromLibrary(track) } }
                        : nil,
                    onDeleteFromLibrary: app.canDeleteFromLibrary
                        ? { app.beginLibraryTrackDeletion(track) }
                        : nil
                )
            } else {
                ChartStyleSongOverflowMenuContent(
                    shareItem: "\(row.title) — \(row.artist)",
                    onAdd: { onRequest(row) },
                    addDisabled: !app.acquisitionConfigured
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.secondaryLabel.opacity(0.65))
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
    case prominent  // Albums — large cards
    case compact    // Singles & EPs / Live / Compilations / Other Releases

    var cardSide: CGFloat {
        switch self {
        case .prominent: return 172
        case .compact: return 116
        }
    }

    var titleFont: Font {
        switch self {
        case .prominent: return .subheadline.weight(.semibold)
        case .compact: return .caption.weight(.semibold)
        }
    }

    var subtitleFont: Font {
        switch self {
        case .prominent: return .caption
        case .compact: return .caption2
        }
    }

    /// Reserved height for the combined `(title, subtitle)` block — two title
    /// lines + spacing + one subtitle line. Keeps cards in a row aligned while
    /// keeping the title and subtitle visually tight (any leftover space falls
    /// below the subtitle, not between title and subtitle).
    var labelBlockMinHeight: CGFloat {
        switch self {
        case .prominent: return 52
        case .compact: return 42
        }
    }
}

private struct ArtistDiscographyCarousel: View {
    @ObservedObject var model: ArtistViewModel
    let bucket: ArtistDiscographyBucket
    let title: String
    let layout: DiscographyLayout

    private var items: [ArtistDiscographyItem] {
        model.discography[bucket] ?? []
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ArtistSectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            ArtistDiscographyCard(item: item, layout: layout)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

private struct ArtistDiscographyCard: View {
    let item: ArtistDiscographyItem
    let layout: DiscographyLayout

    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ArtistAlbumCardArtwork(url: item.artworkURL, seed: item.title)
                        .frame(width: layout.cardSide, height: layout.cardSide)
                        .clipShape(RoundedRectangle(cornerRadius: MusicDesign.albumCorner, style: .continuous))
                    if item.needsRequest {
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
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.needsRequest {
                            Image(systemName: "arrow.down.circle")
                                .font(layout.subtitleFont)
                                .foregroundStyle(MusicDesign.accent)
                        }
                    }
                    Text(subtitle)
                        .font(layout.subtitleFont)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .lineLimit(1)
                }
                .frame(
                    minWidth: layout.cardSide, idealWidth: layout.cardSide, maxWidth: layout.cardSide,
                    minHeight: layout.labelBlockMinHeight, alignment: .topLeading
                )
            }
            .frame(width: layout.cardSide, alignment: .leading)
            .coverZoomSource(id: coverZoomId)
        }
        .buttonStyle(.plain)
        .libraryAlbumContextMenu(libraryAlbumForContextMenu)
    }

    private var browseSource: BrowseAlbumDetailSource? {
        guard case .musicBrainz(let release) = item.source else { return nil }
        return .chartBrowse(
            artistName: release.artistCredit.isEmpty ? item.artist : release.artistCredit,
            title: release.title,
            imageURL: release.coverArtURL,
            kind: bucketLabel
        )
    }

    private var coverZoomId: String {
        switch item.source {
        case .libraryAlbum(let album): return album.id
        case .musicBrainz: return browseSource?.coverZoomId ?? item.id
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch item.source {
        case .libraryAlbum(let album):
            ServerPlaylistDetailView(album: album, librarySource: true)
        case .musicBrainz:
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

    private var bucketLabel: String {
        switch item.bucket {
        case .albums: return "Album"
        case .singlesAndEPs: return "Single"
        case .live: return "Live"
        case .compilations: return "Compilation"
        }
    }

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
/// MusicBrainz release-group, the gradient stays visible (the default
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

private struct ArtistAboutSection: View {
    @ObservedObject var model: ArtistViewModel
    @State private var expanded = false

    private var bio: String? {
        if let b = model.details?.biography, !b.isEmpty { return b }
        if let o = model.jellyfinOverview, !o.isEmpty { return o }
        return nil
    }

    var body: some View {
        if bio != nil || hasMetadataRows {
            VStack(alignment: .leading, spacing: 14) {
                ArtistSectionHeader(title: "About \(model.displayName)")

                if let bio {
                    ArtistInlineMoreText(text: bio, expanded: $expanded)
                        .padding(.horizontal, 20)
                }

                if hasMetadataRows, let details = model.details {
                    metadataStack(details)
                        .padding(.horizontal, 20)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private var hasMetadataRows: Bool {
        guard let d = model.details else { return false }
        return d.country != nil || d.formedYear != nil || d.genre != nil
    }

    @ViewBuilder
    private func metadataStack(_ details: TheAudioDBClient.ArtistDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let country = details.country {
                ArtistMetadataRow(key: "Origin", value: country)
            }
            if let year = details.formedYear {
                ArtistMetadataRow(key: "Formed", value: String(year))
            }
            if let genre = details.genre {
                ArtistMetadataRow(key: "Genre", value: genre)
            }
        }
    }
}

/// Bold value · muted key on the same line — Apple Music's About-section pattern.
private struct ArtistMetadataRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(key)
                .font(.caption.weight(.medium))
                .foregroundStyle(MusicDesign.secondaryLabel)
                .textCase(.uppercase)
                .tracking(0.4)
        }
    }
}

/// Truncated bio with an inline "MORE" expansion trigger anchored to the end of
/// the visible copy (not a separate button on a new line). When expanded, swaps
/// in the full text with an inline "Less" trigger at the very end.
private struct ArtistInlineMoreText: View {
    let text: String
    @Binding var expanded: Bool

    private let truncationLength = 220

    var body: some View {
        if expanded || text.count <= truncationLength {
            (Text(text) + actionText(label: text.count > truncationLength ? " Less" : ""))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .onTapGesture {
                    guard text.count > truncationLength else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
                }
        } else {
            let truncated = String(text.prefix(truncationLength).trimmingCharacters(in: .whitespacesAndNewlines)) + "…"
            (Text(truncated) + actionText(label: "  MORE"))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                }
        }
    }

    private func actionText(label: String) -> Text {
        Text(label)
            .font(.caption.weight(.heavy))
            .foregroundColor(MusicDesign.accent)
    }
}

// MARK: - Similar Artists

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
    let similar: LastFmSimilarArtist
    private let side: CGFloat = 88

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let url = similar.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ArtistGradientFallback(seed: similar.name)
                        }
                    }
                } else {
                    ArtistGradientFallback(seed: similar.name)
                }
            }
            .frame(width: side, height: side)
            .clipShape(Circle())

            Text(similar.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
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
