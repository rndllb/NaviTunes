import SwiftUI

struct MyListeningView: View {
    @EnvironmentObject private var app: AppModel

    // Row metrics. The charts are the point of this screen, so they get a tall editorial row
    // rather than the default list density: a heavy rank numeral, a cover the height of the
    // row, then the name. Covers sit close enough to read as one vertical strip without
    // abandoning the app's rounded-cover language for square edges.
    private static let artworkSize: CGFloat = 64
    private static let artworkDecodePixels: CGFloat = 192
    private static let rowSpacing: CGFloat = 12
    private static let rowVerticalPadding: CGFloat = 5
    private static let rankFontSize: CGFloat = 30

    /// Width of the rank column, **measured** from the widest label a top-10 chart can show.
    ///
    /// A hardcoded 38pt was too narrow for "10", so the last row of every chart — and every
    /// chart has a tenth row — broke the numeral across two lines. The width now comes from
    /// laying out the widest string in the same font the row renders it with, so it cannot be
    /// wrong for the content it has to hold. `.monospacedDigit()` on the label means every
    /// digit has the same advance, so "10" is the widest two-digit case and measuring it
    /// covers 11 through 99 as well.
    private static let rankColumnWidth: CGFloat = {
        let widest = "10" as NSString
        #if canImport(UIKit)
        let base = UIFont.monospacedDigitSystemFont(ofSize: rankFontSize, weight: .heavy)
        let font: UIFont
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: rounded, size: rankFontSize)
        } else {
            font = base
        }
        return ceil(widest.size(withAttributes: [.font: font]).width)
        #else
        return ceil(rankFontSize * 1.3)
        #endif
    }()

    /// Resolved covers, keyed by track id and by artist name.
    ///
    /// Held in `@State` and filled from a `.task` rather than resolved in `body`: finding an
    /// artist's cover means scanning the album catalog, and every view here observes the whole
    /// of `AppModel`, so doing that per row per publish is exactly the body cost the project
    /// rules forbid.
    @State private var trackArtwork: [String: URL] = [:]
    @State private var artistArtwork: [String: URL] = [:]

    private var summary: ListeningAnalyticsSummary {
        ListeningAnalytics.summarize(
            completed: app.scrobbleService.store.completed,
            lifetimePlays: app.scrobbleService.store.lifetimeCompletedCount,
        )
    }

    var body: some View {
        List {
            if summary.totalPlays == 0 {
                ContentUnavailableView(
                    "No listening data yet",
                    systemImage: "chart.bar",
                    description: Text("Completed scrobbles power this screen. Play some music and scrobble a few tracks first.")
                )
            } else {
                overviewSection
                if !summary.dailyHeatmap.isEmpty {
                    heatmapSection
                }
                if !summary.topArtists.isEmpty {
                    topArtistsSection
                }
                if !summary.topTracks.isEmpty {
                    topTracksSection
                }
            }
        }
        .navigationTitle("My Listening")
        .navigationBarTitleDisplayMode(.inline)
        .task { resolveArtwork() }
    }

    /// Fills the two artwork maps once per appearance.
    ///
    /// Tracks resolve through the same cache the rest of the app uses. Artists have no artwork
    /// of their own on this path, so the first catalog album credited to them supplies the
    /// cover — which is what the artist circles elsewhere fall back to as well. The catalog is
    /// walked exactly once here rather than once per row.
    private func resolveArtwork() {
        let s = summary

        var tracks: [String: URL] = [:]
        for row in s.topTracks {
            // Preferred: the cached `Track`, which knows its album's own cover id.
            if let track = app.cachedLibraryTrack(id: row.trackId),
               let url = app.resolvedArtworkURL(for: track) {
                tracks[row.trackId] = url
                continue
            }
            // Fallback: ask the server for art by song id. A scrobble outlives the caches —
            // `cachedLibraryTrack` only sees the personal-library index, recently played, and
            // albums whose track lists happen to be cached — so a track played twice months ago
            // and never added resolved to nothing and rendered the placeholder.
            if let url = app.artworkURLForTrackId(row.trackId) {
                tracks[row.trackId] = url
            }
        }

        let wanted = Set(s.topArtists.map { $0.name.lowercased() })
        var artists: [String: URL] = [:]
        if !wanted.isEmpty {
            for album in app.libraryAlbums {
                let key = album.artist.lowercased()
                guard wanted.contains(key), artists[album.artist] == nil else { continue }
                if let url = app.resolvedArtworkURL(for: album) { artists[album.artist] = url }
            }
        }
        // Key on the exact spelling the rows use, not the lowercased match key.
        var byDisplayName: [String: URL] = [:]
        for row in s.topArtists {
            if let exact = artists[row.name] {
                byDisplayName[row.name] = exact
            } else if let loose = artists.first(where: { $0.key.lowercased() == row.name.lowercased() })?.value {
                byDisplayName[row.name] = loose
            } else if let fallback = tracks.first(where: { id, _ in
                s.topTracks.first { $0.trackId == id }?.artist.lowercased() == row.name.lowercased()
            })?.value {
                // An artist with no album row in the catalog still has their tracks' covers.
                byDisplayName[row.name] = fallback
            }
        }

        trackArtwork = tracks
        artistArtwork = byDisplayName
    }

    private var overviewSection: some View {
        Section {
            statRow("Total plays", value: "\(summary.totalPlays)")
            statRow("Unique tracks", value: "\(summary.uniqueTracks)")
        } header: {
            Text("Overview")
        } footer: {
            // Say which numbers are lifetime and which are windowed, rather than letting one
            // doubtful figure cast doubt over the whole screen.
            if summary.totalPlays > summary.analyzedPlays {
                Text("Total plays counts every scrobble. Unique tracks and the sections below are "
                     + "computed over your most recent \(summary.analyzedPlays) plays.")
            } else {
                Text("Counted from completed scrobbles.")
            }
        }
    }

    private var heatmapSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(summary.dailyHeatmap.reversed()) { day in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(barColor(for: day.playCount))
                                .frame(width: 10, height: barHeight(for: day.playCount))
                            Text(shortDayLabel(day.date))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Recent activity")
        }
    }

    /// Each entry is its **own** `Section`, so it renders as its own inset card rather than as
    /// one row of a shared grouped list. Only the first carries the header, which keeps a single
    /// "Top artists" title above the run of cards instead of repeating it ten times.
    @ViewBuilder
    private var topArtistsSection: some View {
        ForEach(Array(summary.topArtists.enumerated()), id: \.offset) { index, row in
            Section {
                chartRow(
                    rank: index + 1,
                    artworkURL: artistArtwork[row.name],
                    title: row.name,
                    subtitle: nil,
                    count: row.count,
                )
            } header: {
                if index == 0 { Text("Top artists") } else { EmptyView() }
            }
        }
    }

    /// One ranked row: numeral, cover, name, play count.
    ///
    /// Shared by both charts so they cannot drift apart again — the previous versions were
    /// written separately and disagreed about where the text column started.
    private func chartRow(
        rank: Int,
        artworkURL: URL?,
        title: String,
        subtitle: String?,
        count: Int,
    ) -> some View {
        HStack(spacing: Self.rowSpacing) {
            Text("\(rank)")
                .font(.system(size: Self.rankFontSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                // Belt and braces alongside the measured width: even if the measurement and the
                // rendered font ever disagreed, the numeral must not wrap.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.rankColumnWidth, alignment: .leading)
            AlbumArtworkView(
                url: artworkURL,
                cornerRadius: MusicDesign.albumCorner,
                maxDecodePixels: Self.artworkDecodePixels,
            )
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Self.rowVerticalPadding)
        .listRowSeparator(.hidden)
    }

    /// Own-section-per-entry, matching ``topArtistsSection``.
    @ViewBuilder
    private var topTracksSection: some View {
        ForEach(Array(summary.topTracks.enumerated()), id: \.offset) { index, row in
            Section {
                chartRow(
                    rank: index + 1,
                    artworkURL: trackArtwork[row.trackId],
                    title: row.title,
                    subtitle: row.artist,
                    count: row.count,
                )
            } header: {
                if index == 0 { Text("Top tracks") } else { EmptyView() }
            }
        }
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func barHeight(for count: Int) -> CGFloat {
        let maxCount = max(summary.dailyHeatmap.map(\.playCount).max() ?? 1, 1)
        let normalized = CGFloat(count) / CGFloat(maxCount)
        return max(8, normalized * 56)
    }

    private func barColor(for count: Int) -> Color {
        if count >= 20 { return MusicDesign.accent }
        if count >= 10 { return MusicDesign.accent.opacity(0.75) }
        if count >= 5 { return MusicDesign.accent.opacity(0.5) }
        return MusicDesign.accent.opacity(0.28)
    }

    private func shortDayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}
