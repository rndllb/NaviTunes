import SwiftUI

// MARK: - Shimmer surface

/// Animated side-to-side highlight over a neutral fill — used while artwork or shelves load.
struct MusicShimmerSurface: View {
    var cornerRadius: CGFloat = MusicDesign.albumCorner
    var isCircle: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        Group {
            if isCircle {
                Circle().fill(MusicDesign.tertiarySurfaceFill)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MusicDesign.tertiarySurfaceFill)
            }
        }
        .overlay { shimmerBand.mask(shapeMask) }
        .onAppear { startAnimation() }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shapeMask: some View {
        if isCircle {
            Circle()
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        }
    }

    private var shimmerBand: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            LinearGradient(
                colors: [
                    .clear,
                    Color.primary.opacity(0.07),
                    Color.primary.opacity(0.14),
                    Color.primary.opacity(0.07),
                    .clear,
                ],
                startPoint: .leading,
                endPoint: .trailing,
            )
            .frame(width: width * 0.85)
            .offset(x: phase * width * 1.85)
        }
        .allowsHitTesting(false)
    }

    private func startAnimation() {
        guard !reduceMotion else { return }
        phase = -1
        withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

// MARK: - Skeleton primitives

struct MusicTextLineSkeleton: View {
    var width: CGFloat = 120
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    var body: some View {
        MusicShimmerSurface(cornerRadius: cornerRadius)
            .frame(width: width, height: height)
    }
}

struct MusicSquareArtworkSkeleton: View {
    var size: CGFloat
    var cornerRadius: CGFloat = MusicDesign.albumCorner
    var isCircle: Bool = false

    var body: some View {
        MusicShimmerSurface(cornerRadius: isCircle ? size / 2 : cornerRadius, isCircle: isCircle)
            .frame(width: size, height: size)
    }
}

// MARK: - Shelf skeletons

struct MusicHomeTopPickCardSkeleton: View {
    private var cardWidth: CGFloat { MusicDesign.homeTopPickCardWidth }
    private var cardHeight: CGFloat { MusicDesign.homeTopPickCardHeight }
    private var cardCorner: CGFloat { MusicDesign.homeTopPickCardCorner }

    var body: some View {
        VStack(spacing: 0) {
            MusicShimmerSurface(cornerRadius: 0)
                .frame(width: cardWidth, height: MusicDesign.homeTopPickArtworkSize)
            VStack(alignment: .leading, spacing: 8) {
                MusicTextLineSkeleton(width: cardWidth * 0.72, height: 14)
                MusicTextLineSkeleton(width: cardWidth * 0.48, height: 12)
            }
            .frame(width: cardWidth, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cardCorner, style: .continuous))
    }
}

struct MusicShelfAlbumCardSkeleton: View {
    var cardSize: CGFloat = MusicDesign.shelfCardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicSquareArtworkSkeleton(size: cardSize)
            MusicTextLineSkeleton(width: cardSize * 0.88, height: 13)
            MusicTextLineSkeleton(width: cardSize * 0.62, height: 11)
        }
        .frame(width: cardSize, alignment: .leading)
    }
}

/// 2-up Library hub grid placeholder (Recently Added / Downloaded shelves).
struct MusicLibraryHubGridSkeleton: View {
    var columns: Int = 2
    var rows: Int = 3

    private var columnsLayout: [GridItem] {
        MusicDesign.libraryHubGridColumns(count: columns)
    }

    var body: some View {
        LazyVGrid(columns: columnsLayout, spacing: 20) {
            ForEach(0 ..< (columns * rows), id: \.self) { _ in
                VStack(alignment: .leading, spacing: MusicDesign.libraryHubGridLabelSpacing) {
                    MusicShimmerSurface(cornerRadius: MusicDesign.gridAlbumCorner)
                        .aspectRatio(1, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 2) {
                        MusicTextLineSkeleton(width: 120, height: 13)
                        MusicTextLineSkeleton(width: 80, height: 11)
                    }
                    .frame(minHeight: MusicDesign.libraryHubGridLabelBlockMinHeight, alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recently Added, loading")
    }
}

struct MusicArtistCircleTileSkeleton: View {
    var size: CGFloat = MusicDesign.artistCircleTileSize

    var body: some View {
        VStack(spacing: 8) {
            MusicSquareArtworkSkeleton(size: size, isCircle: true)
            MusicTextLineSkeleton(width: size * 0.78, height: 11)
        }
        .frame(width: MusicDesign.artistCircleTileLabelWidth)
    }
}

struct MusicHorizontalShelfSkeleton: View {
    let title: String
    var style: Style = .album
    var count: Int = 5
    var horizontalInset: CGFloat = MusicDesign.newTabHorizontalInset

    enum Style {
        case topPickHero
        case album
        case artistCircle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .topPickHero ? 14 : 12) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal, horizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: style == .topPickHero ? 16 : 14) {
                    ForEach(0..<count, id: \.self) { _ in
                        switch style {
                        case .topPickHero:
                            MusicHomeTopPickCardSkeleton()
                        case .album:
                            MusicShelfAlbumCardSkeleton()
                        case .artistCircle:
                            MusicArtistCircleTileSkeleton()
                        }
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
            .scrollDisabled(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), loading")
    }
}

struct MusicNewTabHeroSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicTextLineSkeleton(width: 96, height: 14)
            MusicTextLineSkeleton(width: 220, height: 22, cornerRadius: 6)
            MusicTextLineSkeleton(width: 140, height: 14)
            MusicShimmerSurface(cornerRadius: MusicDesign.heroCorner)
                .frame(height: 280)
                .padding(.top, 4)
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .accessibilityLabel("New releases, loading")
    }
}

struct MusicArtistPageLoadingSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            MusicShimmerSurface(cornerRadius: 0)
                .frame(height: 320)

            VStack(alignment: .leading, spacing: 24) {
                MusicHorizontalShelfSkeleton(
                    title: "Top Songs",
                    style: .album,
                    count: 3,
                    horizontalInset: 20,
                )
                MusicHorizontalShelfSkeleton(
                    title: "Albums",
                    style: .album,
                    count: 4,
                    horizontalInset: 20,
                )
                MusicHorizontalShelfSkeleton(
                    title: "Similar Artists",
                    style: .artistCircle,
                    count: 4,
                    horizontalInset: 20,
                )
            }
            .padding(.top, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Artist page loading")
    }
}
