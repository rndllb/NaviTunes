import SwiftUI

enum MiniPlayerLayout {
    /// Own glass capsule (settings / standalone use).
    case standalone
    /// Full controls in `tabViewBottomAccessory` — system applies liquid glass.
    case tabViewAccessoryExpanded
    /// Collapsed into the tab bar while scrolling — art, title, artist, play/pause (no skip).
    case tabViewAccessoryInline
    /// Regular-width iPad: transport controls, the track, and lyrics / queue shortcuts across one
    /// wide capsule, as in Apple Music.
    case tabViewAccessoryPad
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
                case .tabViewAccessoryPad:
                    padBody(track: track, artURL: artURL)
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
                        let dx = value.translation.width
                        let dy = value.translation.height
                        let predictedDx = value.predictedEndTranslation.width
                        let isHorizontalSwipe = (abs(dx) > 45 && abs(dx) > abs(dy))
                            || (abs(predictedDx) > 120
                                && abs(predictedDx) > abs(value.predictedEndTranslation.height))
                        let isUpwardSwipe = dy < -40
                            && abs(dy) > abs(dx)

                        if isHorizontalSwipe {
                            if dx < 0 || predictedDx < -120 {
                                player.skipNext()
                            } else {
                                player.skipPrevious()
                            }
                        }

                        if isUpwardSwipe {
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

    // MARK: - iPad

    @ViewBuilder
    private func padBody(track: Track, artURL: URL?) -> some View {
        let liveRadio = track.isInternetRadioStream

        HStack(spacing: 0) {
            HStack(spacing: 4) {
                padTransportButton(
                    "shuffle",
                    isToggle: true,
                    isActive: player.isQueueOutOfNaturalOrder,
                    isDisabled: liveRadio,
                    label: "Shuffle"
                ) { player.toggleShuffle() }
                padTransportButton("backward.fill", size: 20, isDisabled: liveRadio, label: "Previous") {
                    player.skipPrevious()
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Group {
                        if player.isBuffering {
                            ProgressView().controlSize(.regular).tint(.primary)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.primary)
                                .contentTransition(.symbolEffect(.replace))
                                .animation(.smooth(duration: 0.22), value: player.isPlaying)
                        }
                    }
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportPressButtonStyle())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                padTransportButton("forward.fill", size: 20, isDisabled: liveRadio, label: "Next") {
                    player.skipNext()
                }
                padTransportButton(
                    player.repeatMode == .one ? "repeat.1" : "repeat",
                    isToggle: true,
                    isActive: player.repeatMode != .off,
                    isDisabled: liveRadio,
                    label: "Repeat"
                ) { player.cycleRepeat() }
            }

            Spacer().frame(width: 6)

            Button {
                expandNowPlaying()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    AlbumArtworkView(
                        url: artURL,
                        meshArtworkSeed: RadioStationMeshArtwork.seedKey(for: track),
                        cornerRadius: 6,
                    )
                    .frame(width: 44, height: 44)
                    .coverZoomCellAnchor(id: NowPlayingCoverZoom.id, cornerRadius: 6)
                    .id("mini-art-\(track.id)-\(artURL?.absoluteString ?? "")")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.callout)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                // The ⋯ itself is drawn by ``MiniPlayerMoreMenu``, a sibling of the capsule (see
                // ``MainShellView/padMiniPlayerOverlay``): a system menu opened from inside the glass capsule
                // took the capsule as its source and hid it while open. This keeps its place in the row.
                Color.clear
                    .frame(width: 40, height: 40)
                    .allowsHitTesting(false)

                // Each opens the full player on its own pane.
                padTransportButton("quote.bubble", size: 20, isDisabled: liveRadio, label: "Lyrics") {
                    app.pendingNowPlayingPane = .lyrics
                    expandNowPlaying()
                }
                padTransportButton("list.bullet", size: 20, label: "Queue") {
                    app.pendingNowPlayingPane = .queue
                    expandNowPlaying()
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func padTransportButton(
        _ systemImage: String,
        size: CGFloat = 18,
        isToggle: Bool = false,
        isActive: Bool = false,
        isDisabled: Bool = false,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(
                    isActive ? MusicDesign.accent
                        : (isDisabled ? MusicDesign.secondaryLabel.opacity(0.45)
                            // Shuffle and repeat rest in a soft grey and take the accent when on.
                            : (isToggle ? MusicDesign.secondaryLabel.opacity(0.6) : Color.primary))
                )
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportPressButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel(label)
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


/// The ⋯ on the iPad mini player: the system `Menu`, with the same items a song row's ⋯ offers.
///
/// Drawn by the shell as a sibling of the glass capsule, over the spot the capsule leaves empty. Inside the
/// capsule the system took the whole capsule as the menu's source and hid it while the menu was open.
struct MiniPlayerMoreMenu: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var player: PlaybackEngine

    /// How far above the ⋯ the menu opens. The menu is placed off the top of its label, so empty,
    /// untappable space is added above the glyph; the shell shifts the whole view down by half of it to
    /// keep the glyph where it was.
    static let menuLift: CGFloat = 24

    var body: some View {
        if let track = player.activeTrack {
            Menu {
                trackMenu(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .padding(.top, Self.menuLift)
            }
            .buttonStyle(.plain)
            .disabled(track.isInternetRadioStream)
            .accessibilityLabel("More")
        }
    }

    /// The same menu a song row's ⋯ opens: ``StandardSongMenuContent``, so the mini player offers the
    /// actions a track does everywhere else. Going to an album or artist has no player to close first,
    /// so it sets the deep link directly.
    @ViewBuilder
    fileprivate func trackMenu(track: Track) -> some View {
        let album = app.catalogAlbum(id: track.albumId) ?? miniAlbumFallback(from: track)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        StandardSongMenuContent(
            track: track,
            onPlayNext: nil,
            onAddToQueue: nil,
            onFavorite: { app.toggleFavoriteTrack(id: track.id) },
            onAddToPlaylist: { app.presentAddToPlaylist(tracks: [track]) },
            onAddToLibrary: app.isSongInLibrary(track.id)
                ? nil
                : { Task { await app.addSongToLibrary(track) } },
            onDownload: app.isSongInLibrary(track.id) && !app.offline.downloadedTrackIds.contains(track.id)
                ? { app.enqueueOfflineTrack(track) }
                : nil,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                ? { try? app.offline.remove(trackId: track.id) }
                : nil,
            onGoToAlbum: album.map { album in
                {
                    app.deepLinkTab = app.selectedTab
                    app.presentedDeepLink = .album(
                        album,
                        scrollToTrackId: track.id,
                        librarySource: app.isSongInLibrary(track.id),
                    )
                }
            },
            onGoToArtist: ArtistNavigation.isTappable(artist)
                ? {
                    app.deepLinkTab = app.selectedTab
                    app.presentedDeepLink = .artist(ArtistNameNavigation(id: track.artist, serverArtistId: track.artistId))
                }
                : nil,
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { app.requestRemoveSongFromLibrary(track) }
                : nil,
            onDeleteFromLibrary: app.canDeleteFromLibrary
                ? { app.beginLibraryTrackDeletion(track) }
                : nil
        )
    }

    private func miniAlbumFallback(from track: Track) -> AlbumSummary? {
        guard !track.albumId.isEmpty else { return nil }
        return AlbumSummary(
            id: track.albumId,
            title: track.albumTitle.isEmpty ? "Unknown Album" : track.albumTitle,
            artist: track.artist,
            artworkURL: app.resolvedArtworkURL(for: track)
        )
    }
}
