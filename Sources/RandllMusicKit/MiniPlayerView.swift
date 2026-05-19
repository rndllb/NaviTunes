import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var player: PlaybackEngine
    @Binding private var showNowPlaying: Bool
    @GestureState private var isDragging = false

    init(showNowPlaying: Binding<Bool>, player: PlaybackEngine) {
        _showNowPlaying = showNowPlaying
        _player = ObservedObject(wrappedValue: player)
    }

    var body: some View {
        if let track = player.activeTrack {
            let artSize = MusicDesign.miniPlayerArtwork
            let artURL = app.resolvedArtworkURL(for: track)

            HStack(alignment: .center, spacing: 12) {
                Button {
                    player.reconcilePlaybackSessionAfterUIMilestone()
                    showNowPlaying = true
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        AlbumArtworkView(url: artURL, cornerRadius: 6)
                            .frame(width: artSize, height: artSize)
                            .id("mini-art-\(track.id)-\(artURL?.absoluteString ?? "")")

                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.skipNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .modifier(MiniPlayerChromeModifier())
            .scaleEffect(isDragging ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isDragging)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onEnded { value in
                        let isUpwardSwipe = value.translation.height < -40
                            && abs(value.translation.height) > abs(value.translation.width)
                        if isUpwardSwipe {
                            player.reconcilePlaybackSessionAfterUIMilestone()
                            showNowPlaying = true
                        }
                    }
            )
        }
    }
}

private struct MiniPlayerChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .musicGlassCapsuleInteractiveChrome()
    }
}
