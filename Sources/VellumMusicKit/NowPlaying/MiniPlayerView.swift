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
    @State private var horizontalDragOffset: CGFloat = 0
    var layout: MiniPlayerLayout = .standalone
    /// When set, opens the full player without mutating ``showNowPlaying`` from a nested
    /// button — the accessory layer calls this so the zoom source and presentation flip
    /// stay in the same view (required for ``tabViewBottomAccessory`` morphs on iOS 26).
    var onRequestExpand: (() -> Void)?

    init(
        showNowPlaying: Binding<Bool>,
        player: PlaybackEngine,
        layout: MiniPlayerLayout = .standalone,
        onRequestExpand: (() -> Void)? = nil
    ) {
        _showNowPlaying = showNowPlaying
        _player = ObservedObject(wrappedValue: player)
        self.layout = layout
        self.onRequestExpand = onRequestExpand
    }

    private func expandNowPlaying() {
        if let onRequestExpand {
            onRequestExpand()
        } else {
            showNowPlaying = true
            player.reconcilePlaybackSessionAfterUIMilestone()
        }
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
            .offset(x: horizontalDragOffset)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isDragging)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: horizontalDragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) else { return }
                        horizontalDragOffset = max(-28, min(28, dx * 0.18))
                    }
                    .onEnded { value in
                        // One gesture must produce at most one outcome, and the value that picks
                        // the axis has to be the value that picks the direction.
                        //
                        // Previously the horizontal test could be satisfied by the *predicted*
                        // translation while the upward test was satisfied by the *actual* one, so
                        // a quick diagonal skipped a track and expanded the player in the same
                        // flick. Direction was then read from `dx` even when the axis had been
                        // decided by `predictedDx`, so a short fast swipe could skip the way it
                        // was not thrown.
                        let actual = value.translation
                        let projected = value.predictedEndTranslation

                        // A deliberate drag is judged on where it ended; a flick that barely moved
                        // is judged on where it was heading. Whichever is chosen, both axes and
                        // the direction come from that same translation.
                        let isFlick = abs(actual.width) < 45 && abs(actual.height) < 40
                        let translation = isFlick ? projected : actual
                        let threshold: CGFloat = isFlick ? 120 : 45

                        if abs(translation.width) > abs(translation.height) {
                            guard abs(translation.width) > threshold else {
                                horizontalDragOffset = 0
                                return
                            }
                            if translation.width < 0 {
                                player.skipNext()
                            } else {
                                player.skipPrevious()
                            }
                        } else if translation.height < -(isFlick ? 120 : 40) {
                            expandNowPlaying()
                        }

                        horizontalDragOffset = 0
                    }
            )
        }
    }

    @ViewBuilder
    private func inlineAccessoryBody(track: Track, artURL: URL?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                expandNowPlaying()
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    AlbumArtworkView(
                        url: artURL,
                        meshArtworkSeed: RadioStationMeshArtwork.seedKey(for: track),
                        cornerRadius: 6,
                    )
                        .frame(width: MusicDesign.miniPlayerArtwork, height: MusicDesign.miniPlayerArtwork)
                        .padding(.leading, 2)
                        // Origin rect for the cover zoom into the full player, and the copy
                        // taken off screen while the card is in flight.
                        .coverZoomCellAnchor(id: NowPlayingCoverZoom.id, cornerRadius: 6)
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
                Group {
                    if player.isBuffering {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.primary)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.smooth(duration: 0.22), value: player.isPlaying)
                    }
                }
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(TransportPressButtonStyle())
            .padding(.leading, 2)

            Spacer(minLength: 6)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func expandedBody(track: Track, artURL: URL?) -> some View {
        let isTabAccessory = layout == .tabViewAccessoryExpanded
        let artSize = MusicDesign.miniPlayerArtwork
        let spacing: CGFloat = isTabAccessory ? 8 : 12
        let showsSkip = layout == .standalone || layout == .tabViewAccessoryExpanded
        let liveRadio = track.isInternetRadioStream

        HStack(alignment: .center, spacing: spacing) {
            Button {
                expandNowPlaying()
            } label: {
                HStack(alignment: .center, spacing: spacing) {
                    AlbumArtworkView(
                        url: artURL,
                        meshArtworkSeed: RadioStationMeshArtwork.seedKey(for: track),
                        cornerRadius: isTabAccessory ? 6 : 6,
                    )
                        .frame(width: artSize, height: artSize)
                        .padding(.leading, 2)
                        // Origin rect for the cover zoom into the full player, and the copy
                        // taken off screen while the card is in flight.
                        .coverZoomCellAnchor(id: NowPlayingCoverZoom.id, cornerRadius: 6)
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

            HStack(spacing: 0) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Group {
                        if player.isBuffering {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.primary)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: isTabAccessory ? 14 : 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .contentTransition(.symbolEffect(.replace))
                                .animation(.smooth(duration: 0.22), value: player.isPlaying)
                        }
                    }
                    .frame(width: isTabAccessory ? 28 : 32, height: isTabAccessory ? 28 : 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportPressButtonStyle())

                if showsSkip {
                    Button {
                        player.skipNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: isTabAccessory ? 14 : 17, weight: .semibold))
                            .foregroundStyle(liveRadio ? MusicDesign.secondaryLabel.opacity(0.45) : .primary)
                            .frame(width: isTabAccessory ? 28 : 32, height: isTabAccessory ? 28 : 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportPressButtonStyle())
                    .disabled(liveRadio)
                }
            }
            .padding(.leading, 2)

            Spacer(minLength: isTabAccessory ? 8 : 6)
        }
        .padding(.leading, isTabAccessory ? 10 : 12)
        .padding(.trailing, isTabAccessory ? 8 : 10)
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
