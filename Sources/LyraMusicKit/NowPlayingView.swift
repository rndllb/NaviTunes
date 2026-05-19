import SwiftUI
import AVFoundation
import MediaPlayer
#if os(iOS)
import AVKit
import UIKit
#endif

private enum NowPlayingScrubberMetrics {
    static let slotHeight: CGFloat = 18
    static let barHeight: CGFloat = MusicDesign.nowPlayingSliderTrackHeight
}

private enum NowPlayingLibraryRoute: Hashable {
    case album(AlbumSummary)
    case artist(String)
    case playlist
}

/// Apple Music–style Now Playing: artwork-derived backdrop + luminance handoff (same as album detail).
struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var libraryPath: [NowPlayingLibraryRoute] = []
    @State private var selectedPlaylist: PlaylistSummary?
    var onLibraryNavigationDepthChanged: ((Int) -> Void)? = nil

    /// Paused — baseline artwork size.
    private let albumArtPausedSide: CGFloat = 256
    /// Playing — base artwork size before play-state overscale.
    private let albumArtPlayingSide: CGFloat = 340
    /// Scales past ``albumArtPlayingSide`` when playback resumes (Apple Music–style pulse).
    private let albumArtPlayOverscale: CGFloat = 1.14

    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback

    @Environment(\.colorScheme) private var colorScheme

    private func artworkURL(for track: Track?) -> URL? {
        guard let track else { return nil }
        return app.resolvedArtworkURL(for: track)
    }

    // MARK: - System fallback chrome (no active track)

    private var npPrimarySystem: Color { colorScheme == .dark ? .white : .primary }
    private var npSecondarySystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.55) : MusicDesign.secondaryLabel
    }
    private var npSecondaryStrongSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.6) : MusicDesign.secondaryLabel
    }
    private var npMutedSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.5) : MusicDesign.secondaryLabel
    }
    private var npSubtleSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.3) : MusicDesign.secondaryLabel.opacity(0.65)
    }
    private var npCapsuleSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : MusicDesign.chromeCapsuleFill
    }
    private var npCapsuleStrongSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.22) : MusicDesign.tertiarySurfaceFill
    }
    private var npDividerSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : MusicDesign.separator.opacity(0.65)
    }
    private var npDragHandleSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : MusicDesign.secondaryLabel.opacity(0.42)
    }
    private var npBottomGlowSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : MusicDesign.chromeCapsuleFill
    }
    private var npDismissSystem: Color {
        colorScheme == .dark ? Color.white.opacity(0.9) : Color.primary.opacity(0.85)
    }

    // MARK: - Luminance handoff (album-detail parity) vs system appearance

    private var fgPrimary: Color {
        app.player.activeTrack != nil ? backdropPalette.heroChromePrimary : npPrimarySystem
    }

    private var fgSecondary: Color {
        app.player.activeTrack != nil ? backdropPalette.heroChromeSecondary : npSecondarySystem
    }

    private var fgSecondaryStrong: Color {
        app.player.activeTrack != nil ? backdropPalette.heroChromeSecondary : npSecondaryStrongSystem
    }

    private var fgMuted: Color {
        app.player.activeTrack != nil ? backdropPalette.nowPlayingBottomChromeMuted : npMutedSystem
    }

    private var fgSubtle: Color {
        app.player.activeTrack != nil ? backdropPalette.nowPlayingQueueHint : npSubtleSystem
    }

    private var fgCapsule: Color {
        app.player.activeTrack != nil ? backdropPalette.heroGlassCircleFill : npCapsuleSystem
    }

    private var fgCapsuleStrong: Color {
        app.player.activeTrack != nil ? backdropPalette.nowPlayingToggleCapsuleActive : npCapsuleStrongSystem
    }

    private var fgDivider: Color {
        app.player.activeTrack != nil ? backdropPalette.heroTracklistSeparator : npDividerSystem
    }

    private var fgDragHandle: Color {
        app.player.activeTrack != nil ? backdropPalette.nowPlayingDragHandle : npDragHandleSystem
    }

    private var fgBottomGlow: Color {
        app.player.activeTrack != nil ? backdropPalette.heroGlassCircleFill : npBottomGlowSystem
    }

    #if os(iOS)
    /// Scroll bar on the queue list — white on dark Now Playing chrome, black on light hero backdrops.
    private var queueScrollIndicatorStyle: UIScrollView.IndicatorStyle {
        guard app.player.activeTrack != nil else {
            return colorScheme == .dark ? .white : .black
        }
        return backdropPalette.prefersDarkHeroChrome ? .black : .white
    }
    #endif

    var body: some View {
        // Drive layout only from this column. Avoid placing `AsyncImage` / blurred artwork in a sibling
        // `ZStack` above this column — intrinsic bitmap sizes can blow up layout width.
        NavigationStack(path: $libraryPath) {
            VStack(spacing: 0) {
                dragIndicator


                if let track = app.player.activeTrack {
                    if showQueue {
                        queuePanel(track: track)
                    } else if showLyrics {
                        lyricsPanel(track: track)
                    } else {
                        standardNowPlayingPanel(track: track)
                    }
                } else {
                    VStack {
                        ContentUnavailableView("Nothing playing", systemImage: "music.note")
                            .foregroundStyle(fgPrimary)
                            .padding(.top, 80)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                chromeBackground
                    .ignoresSafeArea()
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: NowPlayingLibraryRoute.self) { route in
                switch route {
                case .album(let album):
                    AlbumDetailView(album: album)
                case .artist(let name):
                    ArtistAlbumsView(artistName: name)
                case .playlist:
                    if let playlist = selectedPlaylist {
                        ServerPlaylistDetailView(playlist: playlist)
                            .environmentObject(app.offline)
                    } else {
                        ContentUnavailableView("Playlist unavailable", systemImage: "music.note.list")
                    }
                }
            }
            .task(id: artworkURL(for: app.player.activeTrack)?.absoluteString ?? "") {
                guard let url = artworkURL(for: app.player.activeTrack) else {
                    await MainActor.run { backdropPalette = .fallback }
                    return
                }
                let p = await ArtworkDynamicGradient.analyzeBackdrop(from: url)
                await MainActor.run { backdropPalette = p }
            }
        }
        .onAppear {
            app.player.reconcilePlaybackSessionAfterUIMilestone()
            onLibraryNavigationDepthChanged?(libraryPath.count)
        }
        .onChange(of: libraryPath.count) { _, count in
            onLibraryNavigationDepthChanged?(count)
        }
    }

    private var chromeBackground: some View {
        Group {
            if app.player.activeTrack != nil {
                AlbumHeroBackdropView(
                    artworkURL: artworkURL(for: app.player.activeTrack),
                    palette: backdropPalette
                )
            } else if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.11, green: 0.11, blue: 0.12),
                        Color(red: 0.05, green: 0.05, blue: 0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottom,
                )
            } else {
                LinearGradient(
                    colors: [
                        MusicDesign.background,
                        MusicDesign.background.opacity(0.92),
                    ],
                    startPoint: .top,
                    endPoint: .bottom,
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func standardNowPlayingPanel(track: Track) -> some View {
        VStack(spacing: 0) {
            albumBlock(track: track)

            metadataRow(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)

            progressBlock(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                transportRow
                    .padding(.horizontal, 20)
                NowPlayingVolumeRow(backdropPalette: backdropPalette)
                    .padding(.top, 32)
                nowPlayingBottomChrome
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Lyrics panel (Apple Music–style focus scroll)

    private func lyricsPanel(track: Track) -> some View {
        VStack(spacing: 0) {
            lyricsCompactHeader(track: track)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 12)

            LyricsFocusScrollView(
                lines: app.player.lyrics,
                player: app.player,
                primaryColor: fgPrimary,
                secondaryColor: fgSecondary,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            progressBlock(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 4)

            transportRow
                .padding(.horizontal, 20)
                .padding(.top, 4)

            NowPlayingVolumeRow(backdropPalette: backdropPalette)
                .padding(.top, 32)

            nowPlayingBottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lyricsCompactHeader(track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AlbumArtworkView(url: artworkURL(for: track), cornerRadius: 6)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(fgPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(fgSecondaryStrong)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    app.toggleFavoriteTrack(id: track.id)
                } label: {
                    Image(systemName: app.favoriteTrackIds.contains(track.id) ? "star.fill" : "star")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(fgCapsule))
                }
                .buttonStyle(.plain)

                if let activeTrack = app.player.activeTrack {
                    Menu {
                        ShareLink(item: "\(activeTrack.title) — \(activeTrack.artist)")
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(fgPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(fgCapsule))
                    }
                }
            }
        }
    }

    private func albumBlock(track: Track) -> some View {
        let base = albumArtPlayingSide
        let maxSide = base * albumArtPlayOverscale
        let pausedScale = albumArtPausedSide / base
        let playingScale = albumArtPlayOverscale

        return HStack {
            Spacer(minLength: 0)
            AlbumArtworkView(url: artworkURL(for: track), cornerRadius: 12)
                .frame(width: base, height: base)
                .scaleEffect(app.player.isPlaying ? playingScale : pausedScale, anchor: .center)
                .animation(.smooth(duration: 0.5), value: app.player.isPlaying)
                .frame(width: maxSide, height: maxSide)
                .shadow(color: .black.opacity(backdropPalette.prefersDarkHeroChrome ? 0.22 : 0.45), radius: 20, y: 12)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 38)
    }

    private func metadataRow(track: Track) -> some View {
        let artistKey = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryAlbum = app.libraryAlbums.first { $0.id == track.albumId }
        let albumSubtitle: String = {
            let t = track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            if let title = libraryAlbum?.title, !title.isEmpty { return title }
            return "Unknown Album"
        }()
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(fgPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if artistKey.isEmpty {
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(fgSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                } else {
                    ArtistNowPlayingMenuButton(
                        artist: track.artist,
                        albumSubtitle: albumSubtitle,
                        libraryAlbum: libraryAlbum,
                        heroBackdropPalette: backdropPalette,
                        sourcePlaylist: {
                            if case .playlist(let p) = app.player.playbackSource { return p }
                            return nil
                        }(),
                        onGoToAlbum: {
                            if let album = libraryAlbum {
                                navigateToLibraryRoute(.album(album))
                            }
                        },
                        onGoToArtist: {
                            navigateToLibraryRoute(.artist(track.artist))
                        },
                        onGoToPlaylist: {
                            if case .playlist(let p) = app.player.playbackSource {
                                selectedPlaylist = playlistForNavigation(id: p.id) ?? p
                                navigateToLibraryRoute(.playlist)
                            }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    app.toggleFavoriteTrack(id: track.id)
                } label: {
                    Image(systemName: app.favoriteTrackIds.contains(track.id) ? "star.fill" : "star")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(fgCapsule))
                }
                .buttonStyle(.plain)

                if let activeTrack = app.player.activeTrack {
                    Menu {
                        ShareLink(item: "\(activeTrack.title) — \(activeTrack.artist)")
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(fgPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(fgCapsule))
                    }
                }
            }
        }
    }

    private func navigateToLibraryRoute(_ route: NowPlayingLibraryRoute) {
        guard libraryPath.last != route else { return }
        libraryPath.append(route)
    }

    private func playlistForNavigation(id: String) -> PlaylistSummary? {
        if let playlist = app.libraryPlaylists.first(where: { $0.id == id }) {
            return playlist
        }
        if case .playlist(let playlist) = app.player.playbackSource, playlist.id == id {
            return playlist
        }
        return nil
    }

    private func progressBlock(track: Track) -> some View {
        ScrubberBlock(track: track, player: app.player, backdropPalette: backdropPalette)
    }

    /// Transport SF Symbols (contrast follows Light / Dark Now Playing chrome).
    private var transportRow: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 30) {
                Button {
                    app.player.skipPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    app.player.togglePlayPause()
                } label: {
                    Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 37, weight: .semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 64, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    app.player.skipNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var shuffleRepeatRow: some View {
        HStack(spacing: 10) {
            queueModeToggle(
                systemName: "shuffle",
                isActive: app.player.shuffleMode == .on,
                action: { app.player.toggleShuffle() },
            )
            queueModeToggle(
                systemName: app.player.repeatMode == .one ? "repeat.1" : "repeat",
                isActive: app.player.repeatMode != .off,
                action: { app.player.cycleRepeat() },
            )
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.2), value: app.player.shuffleMode)
        .animation(.easeInOut(duration: 0.2), value: app.player.repeatMode)
    }

    private func queueModeToggle(
        systemName: String,
        isActive: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        let chrome = queueModeToggleChrome(isActive: isActive)
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: isActive ? .bold : .semibold))
                .foregroundStyle(chrome.foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Capsule(style: .continuous).fill(chrome.background))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// High-contrast on/off for queue shuffle & repeat (active reads clearly vs muted off state).
    private func queueModeToggleChrome(isActive: Bool) -> (foreground: Color, background: Color) {
        if app.player.activeTrack != nil {
            if backdropPalette.prefersDarkHeroChrome {
                if isActive {
                    return (Color.white, Color.black.opacity(0.88))
                }
                return (Color.black.opacity(0.42), Color.black.opacity(0.07))
            }
            if isActive {
                return (Color.white, Color.white.opacity(0.36))
            }
            return (Color.white.opacity(0.36), Color.white.opacity(0.1))
        }
        if isActive {
            if colorScheme == .dark {
                return (Color.black, Color.white)
            }
            return (Color.white, Color.primary)
        }
        return (MusicDesign.secondaryLabel, MusicDesign.chromeCapsuleFill)
    }

    private var nowPlayingBottomChrome: some View {
        HStack(spacing: 52) {
            bottomChromeIconButton(
                showLyrics ? "quote.bubble.fill" : "quote.bubble",
                isActive: showLyrics,
                iconFont: .system(size: 20, weight: .semibold),
            ) {
                withAnimation(.spring(response: 0.35)) {
                    showLyrics.toggle()
                    if showLyrics { showQueue = false }
                }
            }
            #if os(iOS)
            AirPlayRoutePickerView(tint: fgPrimary, activeTint: fgPrimary)
                .frame(width: 40, height: 40)
            #endif
            bottomChromeIconButton("list.bullet", isActive: showQueue) {
                withAnimation(.spring(response: 0.35)) {
                    showQueue.toggle()
                    if showQueue { showLyrics = false }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var dragIndicator: some View {
        Capsule()
            .fill(fgDragHandle)
            .frame(width: 50, height: 5)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
    }

    private func bottomChromeIconButton(
        _ systemName: String,
        isActive: Bool = false,
        iconFont: Font = .title2,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(fgBottomGlow)
                        .frame(width: 40, height: 40)
                }
                Image(systemName: systemName)
                    .font(iconFont)
                    .foregroundStyle(fgPrimary)
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue panel

    private func queuePanel(track: Track) -> some View {
        VStack(spacing: 0) {
            // Compact now-playing header
            HStack(spacing: 12) {
                AlbumArtworkView(url: artworkURL(for: track), cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(fgPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(fgSecondaryStrong)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    app.toggleFavoriteTrack(id: track.id)
                } label: {
                    Image(systemName: app.favoriteTrackIds.contains(track.id) ? "star.fill" : "star")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(fgCapsule))
                }
                .buttonStyle(.plain)
                if let activeTrack = app.player.activeTrack {
                    Menu {
                        ShareLink(item: "\(activeTrack.title) — \(activeTrack.artist)")
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(fgPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(fgCapsule))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)

            Rectangle()
                .fill(fgDivider)
                .frame(height: 0.5)

            shuffleRepeatRow
                .padding(.top, 12)
                .padding(.bottom, 4)

            let upNext = Array(app.player.queue.dropFirst(app.player.currentIndex + 1))

            if upNext.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("Nothing up next")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(fgMuted)
                    Text("Add songs to the queue or keep playing an album.")
                        .font(.caption)
                        .foregroundStyle(fgSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(upNext, id: \.id) { t in
                            queueRow(track: t)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        app.player.removeTracksFromQueue(trackIds: [t.id])
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        if let idx = app.player.queue.firstIndex(where: { $0.id == t.id }) {
                                            app.player.jumpToQueueItem(at: idx)
                                        }
                                    } label: {
                                        Label("Play Now", systemImage: "play.fill")
                                    }
                                    .tint(MusicDesign.accent)
                                }
                        }
                        .onMove { source, destination in
                            app.player.moveUpNextItem(from: source, to: destination)
                        }
                    } header: {
                        Text("Up Next")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(fgPrimary)
                            .textCase(nil)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                .tint(fgPrimary)
                .background {
                    NowPlayingQueueListTableChrome(
                        reorderTint: UIColor(fgPrimary),
                        scrollIndicatorStyle: queueScrollIndicatorStyle,
                    )
                }
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            progressBlock(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 4)

            transportRow
                .padding(.horizontal, 20)
                .padding(.top, 14)

            NowPlayingVolumeRow(backdropPalette: backdropPalette)
                .padding(.top, 24)
            nowPlayingBottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func queueRow(track: Track) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: artworkURL(for: track), cornerRadius: 4)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(fgPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(fgSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

}

/// Interactive progress scrubber. Drag horizontally to seek; time labels update live during scrub.
private struct ScrubberBlock: View {
    let track: Track
    @ObservedObject var player: PlaybackEngine
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    private var effectiveDuration: TimeInterval {
        let d = player.playbackDuration > 0 ? player.playbackDuration : track.duration
        return max(d, 1)
    }

    private var displayTime: TimeInterval {
        isScrubbing ? scrubFraction * effectiveDuration : player.currentTime
    }

    private var displayFraction: Double {
        isScrubbing ? scrubFraction : min(max(player.currentTime / effectiveDuration, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                NowPlayingMatchedTrackBar(
                    fraction: CGFloat(displayFraction),
                    enlarged: isScrubbing,
                    backdropPalette: backdropPalette
                )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isScrubbing { isScrubbing = true }
                                scrubFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                let f = min(max(value.location.x / geo.size.width, 0), 1)
                                scrubFraction = f
                                let targetSeconds = f * effectiveDuration
                                player.seek(toSeconds: targetSeconds) {
                                    isScrubbing = false
                                }
                            }
                    )
            }
            .frame(height: NowPlayingScrubberMetrics.slotHeight)

            HStack {
                Text(formatTime(displayTime))
                Spacer()
                Text("-" + formatTime(max(0, effectiveDuration - displayTime)))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(backdropPalette.nowPlayingTimeLabel)
            .monospacedDigit()
            .animation(nil, value: displayTime)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let s = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shared scrubber / simulator-volume pill — fills follow ``BackdropPalette`` luminance handoff.
private struct NowPlayingMatchedTrackBar: View {
    let fraction: CGFloat
    var enlarged: Bool = false
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette

    var body: some View {
        let barHeight = enlarged ? NowPlayingScrubberMetrics.slotHeight : NowPlayingScrubberMetrics.barHeight
        let clamped = min(max(fraction, 0), 1)
        let dimFill = backdropPalette.nowPlayingScrubberTrackFill
        let progressFill = backdropPalette.nowPlayingScrubberProgressFill
        let strokeColor = backdropPalette.nowPlayingScrubberStroke
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: NowPlayingScrubberMetrics.slotHeight)
            .overlay {
                GeometryReader { g in
                    let barW = g.size.width
                    let fillW = max(barW * clamped, clamped > 0.001 ? max(2.5, barHeight * 0.55) : 0)
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(dimFill)
                            .frame(width: barW, height: barHeight)
                        Capsule(style: .continuous)
                            .fill(progressFill)
                            .frame(width: min(fillW, barW), height: barHeight)
                    }
                    .frame(width: barW, height: barHeight)
                    .clipShape(Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(strokeColor, lineWidth: 0.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .animation(.spring(response: 0.2), value: enlarged)
    }
}

/// System volume row — same drag styling as the song progress scrubber.
private struct NowPlayingVolumeRow: View {
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette

    var body: some View {
        #if os(iOS)
        VolumeScrubberBlock(backdropPalette: backdropPalette)
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
// MARK: - Queue list UIKit chrome (reorder “hamburger” + scroll indicators)

/// Applies luminance-matched tint to ``UITableView`` reorder controls and vertical scroll indicators.
private struct NowPlayingQueueListTableChrome: UIViewRepresentable {
    let reorderTint: UIColor
    let scrollIndicatorStyle: UIScrollView.IndicatorStyle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.reorderTint = reorderTint
        context.coordinator.scrollIndicatorStyle = scrollIndicatorStyle
        context.coordinator.apply(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        var reorderTint: UIColor = .white
        var scrollIndicatorStyle: UIScrollView.IndicatorStyle = .white
        private weak var tableView: UITableView?
        private var scrollObservation: NSKeyValueObservation?

        func apply(from anchor: UIView) {
            if let table = tableView {
                applyAll(to: table)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = anchor.ancestorUITableView() else { return }
                self.tableView = table
                self.scrollObservation = table.observe(\.contentOffset, options: []) { [weak self] table, _ in
                    self?.styleReorderControls(in: table)
                }
                self.applyAll(to: table)
            }
        }

        func teardown() {
            scrollObservation?.invalidate()
            scrollObservation = nil
            tableView = nil
        }

        private func applyAll(to table: UITableView) {
            table.tintColor = reorderTint
            table.indicatorStyle = scrollIndicatorStyle
            styleReorderControls(in: table)
        }

        private func styleReorderControls(in table: UITableView) {
            for cell in table.visibleCells {
                for subview in cell.subviews {
                    let typeName = String(describing: type(of: subview))
                    guard typeName.contains("Reorder") else { continue }
                    subview.tintColor = reorderTint
                    for nested in subview.subviews {
                        nested.tintColor = reorderTint
                        (nested as? UIImageView)?.tintColor = reorderTint
                    }
                }
            }
        }
    }
}

private extension UIView {
    func ancestorUITableView() -> UITableView? {
        var view: UIView? = self
        while let current = view {
            if let table = current as? UITableView { return table }
            view = current.superview
        }
        return nil
    }
}

/// Native AirPlay / Bluetooth route picker (system device sheet).
private struct AirPlayRoutePickerView: UIViewRepresentable {
    var tint: Color
    var activeTint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        applyColors(to: picker)
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        applyColors(to: picker)
    }

    private func applyColors(to picker: AVRoutePickerView) {
        picker.tintColor = UIColor(tint)
        picker.activeTintColor = UIColor(activeTint)
    }
}

/// Interactive volume scrubber (matches ``ScrubberBlock`` drag + pill styling).
private struct VolumeScrubberBlock: View {
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette

    @State private var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    private var displayFraction: Double {
        isScrubbing ? scrubFraction : Double(volume)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(backdropPalette.nowPlayingVolumeGlyph)
                .frame(width: 20, alignment: .center)

            GeometryReader { geo in
                NowPlayingMatchedTrackBar(
                    fraction: CGFloat(displayFraction),
                    enlarged: isScrubbing,
                    backdropPalette: backdropPalette
                )
                .background {
                    HiddenSystemVolumeBridge(level: $volume)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing { isScrubbing = true }
                            let f = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                            scrubFraction = f
                            volume = Float(f)
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                            scrubFraction = f
                            volume = Float(f)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: NowPlayingScrubberMetrics.slotHeight)

            Image(systemName: "speaker.wave.3.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(backdropPalette.nowPlayingVolumeGlyph)
                .frame(width: 20, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .onAppear {
            try? AVAudioSession.sharedInstance().setActive(true)
            volume = AVAudioSession.sharedInstance().outputVolume
        }
    }
}

/// Hidden `MPVolumeView` host so the custom scrubber can read/write system volume.
private struct HiddenSystemVolumeBridge: UIViewRepresentable {
    @Binding var level: Float

    func makeCoordinator() -> Coordinator {
        Coordinator(level: $level)
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.isUserInteractionEnabled = false
        volumeView.alpha = 0.001
        volumeView.backgroundColor = .clear
        context.coordinator.attach(to: volumeView)
        return volumeView
    }

    func updateUIView(_ volumeView: MPVolumeView, context: Context) {
        context.coordinator.syncSystemVolume(to: level)
    }

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject {
        @Binding var level: Float
        private weak var volumeView: MPVolumeView?
        private weak var slider: UISlider?
        private var isWritingToSlider = false
        private var volumeObservation: NSKeyValueObservation?
        private var sliderResolveGeneration = 0
        private var sliderResolveAttempts = 0
        private let maxSliderResolveAttempts = 40

        init(level: Binding<Float>) {
            _level = level
        }

        func attach(to volumeView: MPVolumeView) {
            self.volumeView = volumeView
            resolveSliderIfNeeded()
            volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) {
                [weak self] session, _ in
                guard let self, !self.isWritingToSlider else { return }
                DispatchQueue.main.async {
                    self.level = session.outputVolume
                }
            }
        }

        func teardown() {
            volumeObservation?.invalidate()
            volumeObservation = nil
            slider?.removeTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
            slider = nil
        }

        func resolveSliderIfNeeded() {
            guard slider == nil, let volumeView, sliderResolveAttempts < maxSliderResolveAttempts else { return }
            sliderResolveAttempts += 1
            let generation = sliderResolveGeneration + 1
            sliderResolveGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sliderResolveGeneration == generation else { return }
                if let found = Self.findSlider(in: volumeView) {
                    self.slider = found
                    found.addTarget(self, action: #selector(self.sliderChanged(_:)), for: .valueChanged)
                    self.level = AVAudioSession.sharedInstance().outputVolume
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.resolveSliderIfNeeded()
                    }
                }
            }
        }

        @objc private func sliderChanged(_ sender: UISlider) {
            guard !isWritingToSlider else { return }
            level = sender.value
        }

        func syncSystemVolume(to value: Float) {
            if slider == nil { resolveSliderIfNeeded() }
            guard let slider else { return }
            let clamped = min(max(value, 0), 1)
            guard abs(slider.value - clamped) > 0.001 else { return }
            isWritingToSlider = true
            slider.setValue(clamped, animated: false)
            slider.sendActions(for: .valueChanged)
            isWritingToSlider = false
        }

        private static func findSlider(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            for sub in view.subviews {
                if let found = findSlider(in: sub) { return found }
            }
            return nil
        }
    }
}
#endif

/// Apple Music–style synced lyrics: large active line, dimmed/blurred upcoming lines, auto-scroll.
private struct LyricsFocusScrollView: View {
    let lines: [LyricLine]
    @ObservedObject var player: PlaybackEngine
    let primaryColor: Color
    let secondaryColor: Color

    private var currentTime: TimeInterval { player.currentTime }

    private var activeIndex: Int {
        guard !lines.isEmpty else { return 0 }
        let t = currentTime + 0.08
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        return lines[lo].start <= t ? lo : 0
    }

    private var scrollAnchor: UnitPoint { UnitPoint(x: 0.5, y: 0.38) }

    var body: some View {
        Group {
            if lines.isEmpty {
                emptyState
            } else {
                lyricsScroll
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Text("Lyrics aren't available\nfor this song.")
                .font(.title2.weight(.bold))
                .foregroundStyle(primaryColor.opacity(0.38))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        lyricLineView(line, index: index)
                            .id(line.id)
                            .padding(.bottom, spacingAfterLine(at: index))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 48)
            }
            .onAppear {
                scrollToActiveLine(proxy: proxy, animated: false)
            }
            .onChange(of: activeIndex) { _, _ in
                scrollToActiveLine(proxy: proxy, animated: true)
            }
            .onChange(of: lines.map(\.id)) { _, _ in
                scrollToActiveLine(proxy: proxy, animated: false)
            }
        }
    }

    private func scrollToActiveLine(proxy: ScrollViewProxy, animated: Bool) {
        guard lines.indices.contains(activeIndex) else { return }
        let id = lines[activeIndex].id
        if animated {
            withAnimation(.easeInOut(duration: 0.38)) {
                proxy.scrollTo(id, anchor: scrollAnchor)
            }
        } else {
            proxy.scrollTo(id, anchor: scrollAnchor)
        }
    }

    @ViewBuilder
    private func lyricLineView(_ line: LyricLine, index: Int) -> some View {
        let distance = index - activeIndex

        Text(line.text)
            .font(font(for: distance))
            .foregroundStyle(distance == 0 ? primaryColor : secondaryColor)
            .opacity(opacity(for: distance))
            .blur(radius: blur(for: distance))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                player.seek(toSeconds: line.start)
            }
            .animation(.easeInOut(duration: 0.28), value: activeIndex)
    }

    private func spacingAfterLine(at index: Int) -> CGFloat {
        let distance = index - activeIndex
        if distance == 0 { return 30 }
        if distance == 1 { return 24 }
        return 18
    }

    private func font(for distance: Int) -> Font {
        switch distance {
        case ..<0:
            return .body.weight(.medium)
        case 0:
            return .largeTitle.weight(.bold)
        case 1:
            return .title2.weight(.semibold)
        case 2:
            return .title3.weight(.medium)
        default:
            return .body
        }
    }

    private func opacity(for distance: Int) -> Double {
        switch distance {
        case ..<0: return 0.2
        case 0: return 1
        case 1: return 0.78
        case 2: return 0.52
        case 3: return 0.34
        default: return 0.2
        }
    }

    private func blur(for distance: Int) -> CGFloat {
        switch distance {
        case ..<0: return 2
        case 0: return 0
        case 1: return 0.6
        case 2: return 1.8
        case 3: return 3
        default: return min(4.5 + CGFloat(distance - 4), 7)
        }
    }
}
