import WidgetKit
import SwiftUI
import LyraMusicKit

// MARK: - Recently Played Widget

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    let items: [WidgetDataStore.MusicItem]
    let nowPlayingId: String?
    let isPlaying: Bool
    let accentColor: Color
}

struct RecentlyPlayedProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(date: Date(), items: widgetPlaceholderItems, nowPlayingId: nil, isPlaying: false, accentColor: widgetDefaultAccent)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        let payload = WidgetDataStore.read()
        completion(RecentlyPlayedEntry(
            date: Date(),
            items: payload?.recentlyPlayed ?? widgetPlaceholderItems,
            nowPlayingId: payload?.nowPlaying?.id,
            isPlaying: payload?.isPlaying ?? false,
            accentColor: widgetAccentColor(from: payload?.accentHex)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        let payload = WidgetDataStore.read()
        let entry = RecentlyPlayedEntry(
            date: Date(),
            items: payload?.recentlyPlayed ?? widgetPlaceholderItems,
            nowPlayingId: payload?.nowPlaying?.id,
            isPlaying: payload?.isPlaying ?? false,
            accentColor: widgetAccentColor(from: payload?.accentHex)
        )
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Shared widget helpers

let widgetDefaultAccent = Color(red: 250/255, green: 45/255, blue: 72/255)

func widgetAccentColor(from hex: String?) -> Color {
    guard let hex else { return widgetDefaultAccent }
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let val = UInt64(s, radix: 16) else { return widgetDefaultAccent }
    return Color(
        red:   Double((val >> 16) & 0xFF) / 255,
        green: Double((val >>  8) & 0xFF) / 255,
        blue:  Double( val        & 0xFF) / 255
    )
}

let widgetPlaceholderItems: [WidgetDataStore.MusicItem] = [
    .init(id: "1", title: "Album Title",   artist: "Artist Name", artworkURLString: nil, kind: .album),
    .init(id: "2", title: "Another Album", artist: "Artist Name", artworkURLString: nil, kind: .album),
    .init(id: "3", title: "Third Album",   artist: "Artist Name", artworkURLString: nil, kind: .album),
    .init(id: "4", title: "Fourth Album",  artist: "Artist Name", artworkURLString: nil, kind: .album),
    .init(id: "5", title: "Fifth Album",   artist: "Artist Name", artworkURLString: nil, kind: .album),
    .init(id: "6", title: "Sixth Album",   artist: "Artist Name", artworkURLString: nil, kind: .album),
]

// MARK: - Widget

struct LyraRecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.randll.lyra.recentlyplayed",
            provider: RecentlyPlayedProvider()
        ) { entry in
            RecentlyPlayedWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recently Played")
        .description("Your recently played albums from Lyra Music.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct RecentlyPlayedWidgetView: View {
    let entry: RecentlyPlayedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  smallView
        case .systemMedium: mediumView
        default:            largeView
        }
    }

    // MARK: Small — Apple Music-style layout
    private var smallView: some View {
        let item = entry.items.first
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                artworkImage(for: item)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                Image(systemName: "music.note")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(entry.accentColor)
            }
            .padding(.bottom, 10)

            Text("RECENTLY PLAYED")
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.4)
                .foregroundStyle(entry.accentColor)
                .lineLimit(1)
                .padding(.bottom, 2)

            Text(item?.title ?? "Lyra Music")
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.bottom, 1)

            Text(item?.artist ?? "Open to listen")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            let isThisPlaying = entry.isPlaying && item?.id == entry.nowPlayingId
            if isThisPlaying {
                Button(intent: TogglePlaybackIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill").font(.system(size: 9))
                        Text("Pause").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(intent: PlayWidgetItemIntent(itemId: item?.id ?? "", itemKind: item?.kind.rawValue ?? "album")) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Play").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .widgetURL(item?.deepLinkURL ?? URL(string: "lyra://home")!)
    }

    // MARK: Medium — header + 3 rows
    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            widgetHeader
            ForEach(entry.items.prefix(3)) { item in
                itemRow(item, artSize: 40, titleFont: .subheadline.weight(.semibold), subtitleFont: .caption)
                    .padding(.vertical, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: Large — header + 6 rows
    private var largeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            widgetHeader.padding(.bottom, 4)
            ForEach(entry.items.prefix(6)) { item in
                itemRow(item, artSize: 46, titleFont: .body.weight(.semibold), subtitleFont: .subheadline)
                    .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill").font(.caption2).foregroundStyle(entry.accentColor)
            Text("Recently Played").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "music.note").font(.caption2).foregroundStyle(entry.accentColor)
        }
        .padding(.bottom, 6)
    }

    private func itemRow(_ item: WidgetDataStore.MusicItem, artSize: CGFloat, titleFont: Font, subtitleFont: Font) -> some View {
        HStack(spacing: 10) {
            artworkImage(for: item)
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: artSize * 0.15, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(titleFont).foregroundStyle(.primary).lineLimit(1)
                Text(item.artist).font(subtitleFont).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            let isThisItemPlaying = entry.isPlaying && item.id == entry.nowPlayingId
            if isThisItemPlaying {
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: "pause.fill").font(.caption2).foregroundStyle(entry.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Button(intent: PlayWidgetItemIntent(itemId: item.id, itemKind: item.kind.rawValue)) {
                    Image(systemName: "play.fill").font(.caption2).foregroundStyle(entry.accentColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func artworkImage(for item: WidgetDataStore.MusicItem?) -> some View {
        if let item, let data = WidgetDataStore.cachedArtworkData(for: item.id),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage).resizable().scaledToFill()
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            Image(systemName: "music.note").foregroundStyle(entry.accentColor.opacity(0.5))
        }
    }
}
