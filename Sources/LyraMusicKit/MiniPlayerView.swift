import SwiftUI

enum MiniPlayerLayout {
    /// Own glass capsule (settings / standalone use).
    case standalone
    /// Full controls in `tabViewBottomAccessory` — system applies liquid glass.
    case tabViewAccessoryExpanded
    /// Collapsed into the tab bar while scrolling — art, title, artist, play/pause (no skip).
    case tabViewAccessoryInline
}

struct MiniPlayerView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var player: PlaybackEngine
    @Binding private var showNowPlaying: Bool
    @GestureState private var isDragging = false
    var layout: MiniPlayerLayout = .standalone

    init(showNowPlaying: Binding<Bool>, player: PlaybackEngine, layout: MiniPlayerLayout = .standalone) {
        _showNowPlaying = showNowPlaying
        _player = ObservedObject(wrappedValue: player)
        self.layout = layout
    }

    var body: some View {
        if let track = player.activeTrack {
            let artURL = app.resolvedArtworkURL(for: track)

            Group {
                switch layout {
                case .tabViewAccessoryInline:
                    inlineAccessoryBody(track: track, artURL: artURL)
                case .standalone, .tabViewAccessoryExpanded:
                    expandedBody(track: track, artURL: artURL)
                }
            }
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

    @ViewBuilder
    private func inlineAccessoryBody(track: Track, artURL: URL?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                player.reconcilePlaybackSessionAfterUIMilestone()
                showNowPlaying = true
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    AlbumArtworkView(url: artURL, cornerRadius: 6)
                        .frame(width: MusicDesign.miniPlayerArtwork, height: MusicDesign.miniPlayerArtwork)
                        .id("mini-art-\(track.id)-\(artURL?.absoluteString ?? "")")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 10))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func expandedBody(track: Track, artURL: URL?) -> some View {
        let isTabAccessory = layout == .tabViewAccessoryExpanded
        let artSize = MusicDesign.miniPlayerArtwork
        let spacing: CGFloat = isTabAccessory ? 8 : 12
        let showsSkip = layout == .standalone || layout == .tabViewAccessoryExpanded

        HStack(alignment: .center, spacing: spacing) {
            Button {
                player.reconcilePlaybackSessionAfterUIMilestone()
                showNowPlaying = true
            } label: {
                HStack(alignment: .center, spacing: spacing) {
                    AlbumArtworkView(url: artURL, cornerRadius: isTabAccessory ? 6 : 6)
                        .frame(width: artSize, height: artSize)
                        .id("mini-art-\(track.id)-\(artURL?.absoluteString ?? "")")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(isTabAccessory ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(isTabAccessory ? .system(size: 10) : .caption)
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
                    .font(.system(size: isTabAccessory ? 14 : 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isTabAccessory ? 28 : 32, height: isTabAccessory ? 28 : 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsSkip {
                Button {
                    player.skipNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: isTabAccessory ? 14 : 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: isTabAccessory ? 28 : 32, height: isTabAccessory ? 28 : 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, isTabAccessory ? 10 : 12)
        .padding(.trailing, isTabAccessory ? 6 : 12)
        .padding(.vertical, isTabAccessory ? 2 : 5)
        .modifier(MiniPlayerChromeModifier(applyCapsule: layout == .standalone))
    }
}

private struct MiniPlayerChromeModifier: ViewModifier {
    var applyCapsule: Bool = true

    func body(content: Content) -> some View {
        if applyCapsule {
            content.musicGlassCapsuleInteractiveChrome()
        } else {
            content
        }
    }
}
