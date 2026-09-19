import SwiftUI

struct MyListeningView: View {
    @EnvironmentObject private var app: AppModel

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

    private var topArtistsSection: some View {
        Section {
            ForEach(Array(summary.topArtists.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                    Text(row.name)
                    Spacer()
                    Text("\(row.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Top artists")
        }
    }

    private var topTracksSection: some View {
        Section {
            ForEach(Array(summary.topTracks.enumerated()), id: \.offset) { index, row in
                // Title and artist share one leading edge because they share one column.
                // They used to be siblings in a VStack with the artist nudged across by a
                // hand-written `.padding(.leading, 24)` that matched the index frame but not
                // the HStack's own spacing, so the artist sat ~8pt left of the title it
                // belonged to — and out of line with the Top artists rows above.
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.body.weight(.medium))
                        Text(row.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(row.count)")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Top tracks")
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
