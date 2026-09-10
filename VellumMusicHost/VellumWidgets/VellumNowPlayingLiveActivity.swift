import ActivityKit
import SwiftUI
import VellumMusicKit
import WidgetKit

// MARK: - Live Activity (Lock Screen banner + Dynamic Island)

/// The Dynamic Island half of the "tapping it doesn't open the player" report.
///
/// This is an `ActivityConfiguration`, not a `StaticConfiguration` — a different surface with a
/// different tap path from the widgets in this bundle. `.widgetURL` on the `DynamicIsland` is
/// what makes a tap on the island (compact, minimal or expanded) open `vellum://nowplaying`
/// instead of merely foregrounding the app.
struct VellumNowPlayingLiveActivity: Widget {
    private var deepLink: URL { WidgetDataStore.MusicItem.nowPlayingDeepLinkURL }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            LiveActivityLockScreenView(state: context.state)
                .widgetURL(deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityArtwork(itemId: context.state.artworkItemId)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.title)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                LiveActivityArtwork(itemId: context.state.artworkItemId)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "music.note")
            }
            .widgetURL(deepLink)
        }
    }
}

// MARK: - Views

private struct LiveActivityLockScreenView: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            LiveActivityArtwork(itemId: state.artworkItemId)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.isPlaying ? "NOW PLAYING" : "PAUSED")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                Text(state.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

/// Reads the artwork the app already cached in the App Group for the home-screen widgets.
/// A Live Activity cannot reach the network, so a missing file falls back to a glyph rather
/// than leaving a hole.
private struct LiveActivityArtwork: View {
    let itemId: String?

    var body: some View {
        if let itemId,
           let data = WidgetDataStore.cachedArtworkData(for: itemId),
           let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.25)
                Image(systemName: "music.note").font(.caption)
            }
        }
    }
}
