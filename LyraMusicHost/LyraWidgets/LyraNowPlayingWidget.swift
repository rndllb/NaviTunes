import WidgetKit
import SwiftUI
import LyraMusicKit

// MARK: - Now Playing Widget

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let nowPlaying: WidgetDataStore.MusicItem?
    let isPlaying: Bool
    let recentItems: [WidgetDataStore.MusicItem]
    let accentColor: Color
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            nowPlaying: widgetPlaceholderItems.first,
            isPlaying: false,
            recentItems: Array(widgetPlaceholderItems.dropFirst()),
            accentColor: widgetDefaultAccent
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let payload = WidgetDataStore.read()
        completion(NowPlayingEntry(
            date: Date(),
            nowPlaying: payload?.nowPlaying,
            isPlaying: payload?.isPlaying ?? false,
            recentItems: payload?.recentlyPlayed ?? [],
            accentColor: widgetAccentColor(from: payload?.accentHex)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let payload = WidgetDataStore.read()
        let entry = NowPlayingEntry(
            date: Date(),
            nowPlaying: payload?.nowPlaying,
            isPlaying: payload?.isPlaying ?? false,
            recentItems: payload?.recentlyPlayed ?? [],
            accentColor: widgetAccentColor(from: payload?.accentHex)
        )
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget

struct LyraNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.randll.lyra.nowplaying",
            provider: NowPlayingProvider()
        ) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing in Lyra Music.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: smallView
        default:           mediumView
        }
    }

    // MARK: Small — Apple Music-style layout
    private var smallView: some View {
        let track = entry.nowPlaying ?? entry.recentItems.first
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                artworkView(for: track)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                Image(systemName: "music.note")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(entry.accentColor)
            }
            .padding(.bottom, 10)

            Text(entry.nowPlaying != nil ? "NOW PLAYING" : "RECENTLY PLAYED")
                .font(.system(size: 9, weight: .heavy))
                .kerning(0.4)
                .foregroundStyle(entry.accentColor)
                .lineLimit(1)
                .padding(.bottom, 2)

            Text(track?.title ?? "Nothing Playing")
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.bottom, 1)

            Text(track?.artist ?? "Open Lyra Music")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if entry.isPlaying && entry.nowPlaying != nil {
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
                Button(intent: PlayWidgetItemIntent(itemId: track?.id ?? "", itemKind: track?.kind.rawValue ?? "album")) {
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
        .widgetURL(track?.deepLinkURL ?? URL(string: "lyra://home")!)
    }

    // MARK: Medium
    private var mediumView: some View {
        Group {
            if let track = entry.nowPlaying {
                HStack(spacing: 0) {
                    artworkView(for: track)
                        .frame(width: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.trailing, 14)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Image(systemName: "music.note").font(.caption2.bold()).foregroundStyle(entry.accentColor)
                            Text("NOW PLAYING")
                                .font(.system(size: 9, weight: .heavy)).kerning(0.5)
                                .foregroundStyle(entry.accentColor)
                        }
                        .padding(.bottom, 5)

                        Text(track.title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.bottom, 10)

                        ForEach(entry.recentItems.filter { $0.id != track.id }.prefix(2)) { recent in
                            HStack(spacing: 6) {
                                artworkView(for: recent)
                                    .frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                Text(recent.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button(intent: PlayWidgetItemIntent(itemId: recent.id, itemKind: recent.kind.rawValue)) {
                                    Image(systemName: "play.fill").font(.caption2).foregroundStyle(entry.accentColor.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.bottom, 3)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .widgetURL(track.deepLinkURL)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note").font(.caption2.bold()).foregroundStyle(entry.accentColor)
                        Text("NOT PLAYING").font(.system(size: 9, weight: .heavy)).kerning(0.5).foregroundStyle(entry.accentColor)
                        Spacer()
                        Text("Tap to open Lyra").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)

                    HStack(spacing: 8) {
                        ForEach(entry.recentItems.prefix(3)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                artworkView(for: item)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(item.title).font(.caption2.bold()).foregroundStyle(.primary).lineLimit(1)
                                Text(item.artist).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Button(intent: PlayWidgetItemIntent(itemId: item.id, itemKind: item.kind.rawValue)) {
                                    Image(systemName: "play.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.white)
                                        .padding(5)
                                        .background(entry.accentColor, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .widgetURL(URL(string: "lyra://home")!)
            }
        }
    }

    @ViewBuilder
    private func artworkView(for item: WidgetDataStore.MusicItem?) -> some View {
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
            Image(systemName: "music.note").font(.title2).foregroundStyle(entry.accentColor.opacity(0.5))
        }
    }
}
