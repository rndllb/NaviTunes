import SwiftUI
import AVFoundation
import MediaPlayer
#if os(iOS)
import AVKit
import UIKit
#endif

private enum NowPlayingScrubberMetrics {
    static let slotHeight: CGFloat = 22
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
    @ObservedObject var player: PlaybackEngine
    @Binding var isPresented: Bool
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var libraryPath: [NowPlayingLibraryRoute] = []
    @State private var selectedPlaylist: PlaylistSummary?
    /// Which of the three paged queue sections is currently snapped. Drives the
    /// inter-section haptic so each swipe-and-snap fires its own impact, and
    /// reaching the boundary the user is swiping toward requires a second swipe.
    @State private var queueScrollAnchor: QueueScrollAnchor? = .nowPlayingHeader
    @State private var lastQueueHapticAnchor: QueueScrollAnchor? = .nowPlayingHeader
    @Namespace private var artworkNamespace

    init(
        player playbackEngine: PlaybackEngine,
        isPresented: Binding<Bool>,
        onLibraryNavigationDepthChanged: @escaping (Int) -> Void = { _ in }
    ) {
        self._player = ObservedObject(wrappedValue: playbackEngine)
        self._isPresented = isPresented
        self.onLibraryNavigationDepthChanged = onLibraryNavigationDepthChanged
    }

    var onLibraryNavigationDepthChanged: ((Int) -> Void)

    private enum QueueScrollAnchor: Hashable {
        case historyTop, nowPlayingHeader
    }

    /// Paused — baseline artwork size. Tuned so paused is visibly smaller than
    /// playing (~80%) without the dramatic shrink the older 256pt value caused.
    private let albumArtPausedSide: CGFloat = 280
    /// Playing — base artwork size before play-state overscale.
    private let albumArtPlayingSide: CGFloat = 315
    /// Scales past ``albumArtPlayingSide`` when playback resumes (Apple Music–style pulse).
    private let albumArtPlayOverscale: CGFloat = 1.14

    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback

    @Environment(\.colorScheme) private var colorScheme

    private func artworkURL(for track: Track?) -> URL? {
        guard let track else { return nil }
        return app.resolvedArtworkURL(for: track)
    }

    private func artworkView(for track: Track, cornerRadius: CGFloat) -> some View {
        AlbumArtworkView(
            url: artworkURL(for: track),
            meshArtworkSeed: RadioStationMeshArtwork.seedKey(for: track),
            cornerRadius: cornerRadius,
            showsSubtleBorder: false,
        )
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
        player.activeTrack != nil ? backdropPalette.heroChromePrimary : npPrimarySystem
    }

    private var fgSecondary: Color {
        player.activeTrack != nil ? backdropPalette.heroChromeSecondary : npSecondarySystem
    }

    private var fgSecondaryStrong: Color {
        player.activeTrack != nil ? backdropPalette.heroChromeSecondary : npSecondaryStrongSystem
    }

    private var fgMuted: Color {
        player.activeTrack != nil ? backdropPalette.nowPlayingBottomChromeMuted : npMutedSystem
    }

    private var fgSubtle: Color {
        player.activeTrack != nil ? backdropPalette.nowPlayingQueueHint : npSubtleSystem
    }

    private var fgCapsule: Color {
        player.activeTrack != nil ? backdropPalette.heroGlassCircleFill : npCapsuleSystem
    }

    private var fgCapsuleStrong: Color {
        player.activeTrack != nil ? backdropPalette.nowPlayingToggleCapsuleActive : npCapsuleStrongSystem
    }

    private var fgDivider: Color {
        player.activeTrack != nil ? backdropPalette.heroTracklistSeparator : npDividerSystem
    }

    private var fgDragHandle: Color {
        player.activeTrack != nil ? backdropPalette.nowPlayingDragHandle : npDragHandleSystem
    }

    private var fgBottomGlow: Color {
        player.activeTrack != nil ? backdropPalette.heroGlassCircleFill : npBottomGlowSystem
    }

    #if os(iOS)
    /// Scroll bar on the queue list — white on dark Now Playing chrome, black on light hero backdrops.
    private var queueScrollIndicatorStyle: UIScrollView.IndicatorStyle {
        guard player.activeTrack != nil else {
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
                    // Shared artwork (+ inline title/artist in compact mode) lives
                    // here so it's a sibling of the conditional body region —
                    // matched-geometry bridges between two parallel branches at
                    // the same depth, not between branches buried inside per-mode
                    // subtrees.
                    sharedHeader(track: track)

                    // Each mode lives inside a `Group` that's permanently in the
                    // ZStack — only the inner conditional changes. That keeps
                    // `.allowsHitTesting(...)` on a non-transitioning view, so
                    // its argument is re-evaluated against the current state
                    // even while the inner content is animating out. Without
                    // this wrapper, the hit-test modifier sits inside the
                    // disappearing subtree and SwiftUI uses its last-captured
                    // value (the now-stale `true`) during the exit transition,
                    // letting queue rows accept taps on the way down.
                    ZStack {
                        Group {
                            if !showLyrics && !showQueue {
                                standardPlayerContent(track: track)
                                    .transition(
                                        AnyTransition.move(edge: .top)
                                            .combined(with: .opacity)
                                            .animation(.spring(response: 0.25, dampingFraction: 0.9))
                                    )
                            }
                        }
                        .allowsHitTesting(!showLyrics && !showQueue)

                        Group {
                            if showLyrics {
                                lyricsScrollContent(track: track)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .allowsHitTesting(showLyrics)

                        Group {
                            if showQueue {
                                queueScrollContent(track: track)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .allowsHitTesting(showQueue)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    pinnedBottomChrome(track: track)
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
                    ServerPlaylistDetailView(album: album)
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
            .task(id: artworkURL(for: player.activeTrack)?.absoluteString ?? "") {
                guard let url = artworkURL(for: player.activeTrack) else {
                    await MainActor.run { backdropPalette = .fallback }
                    return
                }
                let p = await ArtworkDynamicGradient.analyzeBackdrop(from: url, style: .nowPlaying)
                await MainActor.run { backdropPalette = p }
            }
        }
        .onAppear {
            player.reconcilePlaybackSessionAfterUIMilestone()
            onLibraryNavigationDepthChanged(libraryPath.count)
        }
        .onChange(of: libraryPath.count) { _, count in
            onLibraryNavigationDepthChanged(count)
        }
    }

    private var chromeBackground: some View {
        Group {
            if player.activeTrack != nil {
                AlbumHeroBackdropView(
                    artworkURL: artworkURL(for: player.activeTrack),
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

    // MARK: - Standard player content (default mode)

    /// Default mode — metadata + spacer below the shared artwork header. The
    /// artwork itself is rendered by ``sharedHeader``; this subtree's exit
    /// transition slides the metadata up and fades it out without disturbing
    /// the artwork's matched-geometry move.
    private func standardPlayerContent(track: Track) -> some View {
        VStack(spacing: 0) {
            metadataRow(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Lyrics scroll area only — artwork + compact title/artist live in
    /// ``sharedHeader`` above the conditional body region.
    private func lyricsScrollContent(track: Track) -> some View {
        LyricsFocusScrollView(
            lines: app.player.lyrics,
            player: app.player,
            primaryColor: fgPrimary,
            secondaryColor: fgSecondary,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Queue scroll content (triggered by the queue button)

    /// Paged scroll with three full-height sections: History (above), Now Playing
    /// (initial center page), Up Next (below). `.scrollTargetBehavior(.paging)`
    /// enforces one snap per gesture, so swiping past the now-playing boundary
    /// requires a second deliberate swipe to reach history / up-next — and a
    /// medium haptic fires at each snap.
    ///
    /// History here = `app.recentlyPlayedTracks`, the *persistent* track-level history
    /// fed by the scrobble hook (~50% of the song crossed). That means skipping past
    /// songs without listening doesn't pollute the list, and the history survives
    /// queue resets — switching from an album to a single keeps the prior history.
    private func queueScrollContent(track: Track) -> some View {
        let upNext = Array(player.queue.dropFirst(player.currentIndex + 1))
        // Don't duplicate the currently-playing track in the history list.
        // Storage is newest-first; the queue view reads oldest-at-top so the most
        // recently played track sits right above the Now Playing line.
        let queueHistory = app.recentlyPlayedTracks
            .filter { $0.id != track.id }
            .reversed()
            .map { $0 }

        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                historySection(history: queueHistory)
                    .containerRelativeFrame(.vertical)
                    .id(QueueScrollAnchor.historyTop)
                nowPlayingPage(track: track, upNext: upNext)
                    .containerRelativeFrame(.vertical)
                    .id(QueueScrollAnchor.nowPlayingHeader)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $queueScrollAnchor)
        .onChange(of: queueScrollAnchor) { _, new in
            guard let new, new != lastQueueHapticAnchor else { return }
            lastQueueHapticAnchor = new
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }
    }

    /// Middle page — Now Playing header (the divider) at top, then shuffle/repeat,
    /// then a `List` split into two sections: "Queue" (user-queued tracks, with a
    /// Clear button) and "Continue Playing — From [source]" (the rest of the source).
    /// Both sections have 3-line drag handles (system-drawn via active edit mode).
    private func nowPlayingPage(track: Track, upNext: [Track]) -> some View {
        let userQueueTracks = upNext.filter { player.userQueuedTrackIds.contains($0.id) }
        let continuePlayingTracks = upNext.filter { !player.userQueuedTrackIds.contains($0.id) }

        return VStack(spacing: 0) {
            shuffleRepeatRow
                .padding(.top, 10)
                .padding(.bottom, 6)

            Rectangle()
                .fill(fgDivider)
                .frame(height: 0.5)
                .padding(.top, 6)

            if userQueueTracks.isEmpty && continuePlayingTracks.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing up next")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(fgMuted)
                    .padding(.vertical, 24)
                Spacer(minLength: 0)
            } else {
                queueAndContinuePlayingList(
                    userQueue: userQueueTracks,
                    continuePlaying: continuePlayingTracks
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var continuePlayingSourceLabel: String? {
        if case .playlist(let p) = player.playbackSource { return p.name }
        let title = player.activeTrack?.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// Single `List` with two reorderable sections — Apple Music's Queue + Continue Playing layout.
    private func queueAndContinuePlayingList(userQueue: [Track], continuePlaying: [Track]) -> some View {
        List {
            if !userQueue.isEmpty {
                Section {
                    ForEach(userQueue, id: \.id) { t in
                        queueListRow(track: t)
                    }
                    .onMove { source, destination in
                        moveWithinSection(tracks: userQueue, source: source, destination: destination)
                    }
                } header: {
                    HStack {
                        Text("Queue")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(fgPrimary)
                            .textCase(nil)
                        Spacer()
                        Button {
                            player.clearUserQueue()
                        } label: {
                            Text("Clear")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(fgPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(fgCapsule))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }
            }

            if !continuePlaying.isEmpty {
                Section {
                    ForEach(continuePlaying, id: \.id) { t in
                        queueListRow(track: t)
                    }
                    .onMove { source, destination in
                        moveWithinSection(tracks: continuePlaying, source: source, destination: destination)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue Playing")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(fgPrimary)
                            .textCase(nil)
                        if let label = continuePlayingSourceLabel {
                            Text("From \(label)")
                                .font(.subheadline)
                                .foregroundStyle(fgSecondary)
                                .textCase(nil)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }
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
    }

    private func queueListRow(track t: Track) -> some View {
        Button {
            if let idx = player.queue.firstIndex(where: { $0.id == t.id }) {
                player.jumpToQueueItem(at: idx)
            }
        } label: {
            queueRow(track: t)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                player.removeTracksFromQueue(trackIds: [t.id])
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// Translates an `onMove` IndexSet+destination from a section's local coordinates into
    /// the full `Up Next` index space, then forwards to `PlaybackEngine.moveUpNextItem`.
    private func moveWithinSection(tracks: [Track], source: IndexSet, destination: Int) {
        let upNext = Array(player.queue.dropFirst(player.currentIndex + 1))
        let upNextIndexById = Dictionary(uniqueKeysWithValues: upNext.enumerated().map { ($1.id, $0) })
        let mappedSource = source.compactMap { upNextIndexById[tracks[$0].id] }
        let mappedDestination: Int = {
            if destination < tracks.count, let idx = upNextIndexById[tracks[destination].id] { return idx }
            // Append at end of section: place after the last item of the section in full Up Next coords.
            if let last = tracks.last, let lastIdx = upNextIndexById[last.id] { return lastIdx + 1 }
            return upNext.count
        }()
        player.moveUpNextItem(from: IndexSet(mappedSource), to: mappedDestination)
    }

    @ViewBuilder
    private func historySection(history: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(fgPrimary)
                Spacer()
                if !history.isEmpty {
                    Button {
                        app.clearRecentlyPlayedTracks()
                    } label: {
                        Text("Clear")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(fgPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(fgCapsule))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if history.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("No history yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(fgMuted)
                    Text("Songs you've already played in this queue collect here.")
                        .font(.caption)
                        .foregroundStyle(fgSubtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(history, id: \.id) { t in
                            Button {
                                Task { await playHistoryTrack(t) }
                            } label: {
                                queueRow(track: t)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .top) {
                    let bgColor = player.activeTrack != nil
                        ? backdropPalette.heroSolidBackdropColor
                        : (colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : MusicDesign.background)
                    LinearGradient(gradient: Gradient(stops: [
                        .init(color: bgColor, location: 0),
                        .init(color: bgColor.opacity(0), location: 1),
                    ]), startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    let bgColor = player.activeTrack != nil
                        ? backdropPalette.heroSolidBackdropColor
                        : (colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : MusicDesign.background)
                    LinearGradient(gradient: Gradient(stops: [
                        .init(color: bgColor.opacity(0), location: 0),
                        .init(color: bgColor, location: 1),
                    ]), startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func nowPlayingHeader(track: Track) -> some View {
        let artistKey = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryAlbum = app.libraryAlbums.first { $0.id == track.albumId }
        let albumSubtitle: String = {
            let t = track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            if let title = libraryAlbum?.title, !title.isEmpty { return title }
            return "Unknown Album"
        }()
        return HStack(spacing: 12) {
            artworkView(for: track, cornerRadius: 6)
                .frame(width: 56, height: 56)
                .matchedGeometryEffect(id: "nowPlayingArtwork", in: artworkNamespace)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(fgPrimary)
                    .lineLimit(1)
                if artistKey.isEmpty {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(fgSecondaryStrong)
                        .lineLimit(1)
                } else {
                    ArtistNowPlayingMenuButton(
                        artist: track.artist,
                        albumSubtitle: albumSubtitle,
                        libraryAlbum: libraryAlbum,
                        sourcePlaylist: {
                            if case .playlist(let p) = player.playbackSource { return p }
                            return nil
                        }(),
                        compact: true,
                        goToAlbumDisabled: libraryAlbum == nil && catalogAlbumFallback(from: track) == nil,
                        onGoToAlbum: {
                            if let album = libraryAlbum {
                                dismissAndNavigate(to: .album(album))
                            } else if let album = catalogAlbumFallback(from: track) {
                                dismissAndNavigate(to: .album(album))
                            }
                        },
                        onGoToArtist: {
                            dismissAndNavigate(to: .artist(track.artist))
                        },
                        onGoToPlaylist: {
                            dismissAndNavigate(to: .playlist)
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Rectangle()
                .fill(fgDivider)
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Plays a single track from the persistent history. If the track is still in the
    /// current queue we jump to it (preserving Up Next); otherwise we start a fresh
    /// queue containing just that track.
    private func playHistoryTrack(_ track: Track) async {
        if let idx = player.queue.firstIndex(where: { $0.id == track.id }) {
            player.jumpToQueueItem(at: idx)
            return
        }
        do {
            try await player.playAlbum(library: app.activeLibrary, tracks: [track], startIndex: 0)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    /// Pinned beneath the paged scroll: scrubber, transport, volume, bottom chrome.
    /// Spacings tuned to match Apple Music's Now Playing — progress bar floats
    /// well above the home indicator, transport sits with symmetric breathing
    /// room above (from progress) and below (to volume), and the bottom icon
    /// row gets a generous gap so it doesn't crowd the safe-area edge.
    private func pinnedBottomChrome(track: Track) -> some View {
        VStack(spacing: 0) {
            progressBlock(track: track)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 22)

            transportRow
                .padding(.horizontal, 20)
                .padding(.bottom, 28)

            NowPlayingVolumeRow(backdropPalette: backdropPalette)
                .padding(.top, 22)

            nowPlayingBottomChrome
        }
    }

    // MARK: - Lyrics header (Apple Music–style focus scroll)

    private func lyricsCompactHeader(track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            artworkView(for: track, cornerRadius: 6)
                .frame(width: 56, height: 56)
                .matchedGeometryEffect(id: "nowPlayingArtwork", in: artworkNamespace)

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

                if let activeTrack = player.activeTrack {
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

    /// Artist row in the compact shared header — uses the same tappable
    /// ``ArtistNowPlayingMenuButton`` (Go to Artist / Album / Playlist) as
    /// the standard-mode metadata row, so the menu is available in lyrics
    /// and queue modes too. Falls back to plain text when the artist field
    /// is empty (button has nothing to anchor).
    @ViewBuilder
    private func compactArtistMenu(track: Track) -> some View {
        let artistKey = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryAlbum = app.libraryAlbums.first { $0.id == track.albumId }
        let albumSubtitle: String = {
            let t = track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            if let title = libraryAlbum?.title, !title.isEmpty { return title }
            return "Unknown Album"
        }()
        if artistKey.isEmpty {
            Text(track.artist)
                .font(.subheadline)
                .foregroundStyle(fgSecondaryStrong)
                .lineLimit(1)
        } else {
            ArtistNowPlayingMenuButton(
                artist: track.artist,
                albumSubtitle: albumSubtitle,
                libraryAlbum: libraryAlbum,
                sourcePlaylist: {
                    if case .playlist(let p) = app.player.playbackSource { return p }
                    return nil
                }(),
                compact: true,
                goToAlbumDisabled: libraryAlbum == nil && catalogAlbumFallback(from: track) == nil,
                onGoToAlbum: {
                    if let album = libraryAlbum {
                        dismissAndNavigate(to: .album(album))
                    } else if let album = catalogAlbumFallback(from: track) {
                        dismissAndNavigate(to: .album(album))
                    }
                },
                onGoToArtist: {
                    dismissAndNavigate(to: .artist(track.artist))
                },
                onGoToPlaylist: {
                    dismissAndNavigate(to: .playlist)
                },
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Star + ellipsis action buttons shown trailing the inline title/artist
    /// in the compact (lyrics / queue) shared header — restores the action
    /// affordances that lived in the old per-mode headers before the artwork
    /// was hoisted.
    @ViewBuilder
    private func compactHeaderActionButtons(track: Track) -> some View {
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

            Menu {
                ShareLink(item: "\(track.title) — \(track.artist)")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(fgPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(fgCapsule))
            }
        }
    }

    /// Isolated scale wrapper for the play/pause pulse. Keeping the
    /// `.animation(value: isPlaying)` inside its own modifier scope means it
    /// doesn't leak into the artwork's frame/position morph when ``compact``
    /// toggles.
    private struct PlayPulseScale: ViewModifier {
        let scale: CGFloat
        let isPlaying: Bool

        func body(content: Content) -> some View {
            content
                .scaleEffect(scale, anchor: .center)
                .animation(.smooth(duration: 0.5), value: isPlaying)
        }
    }

    private func albumBlock(track: Track) -> some View {
        let base = albumArtPlayingSide
        let maxSide = base * albumArtPlayOverscale
        let pausedScale = albumArtPausedSide / base
        let playingScale = albumArtPlayOverscale

        return HStack {
            Spacer(minLength: 0)
            artworkView(for: track, cornerRadius: 12)
                .frame(width: base, height: base)
                .matchedGeometryEffect(id: "nowPlayingArtwork", in: artworkNamespace)
                .scaleEffect(player.isPlaying ? playingScale : pausedScale, anchor: .center)
                .animation(.smooth(duration: 0.5), value: player.isPlaying)
                .frame(width: maxSide, height: maxSide)
                .shadow(color: .black.opacity(backdropPalette.prefersDarkHeroChrome ? 0.22 : 0.45), radius: 20, y: 12)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    // MARK: - Shared header

    /// One artwork view that's always present, animating size + position as
    /// ``showLyrics`` / ``showQueue`` toggle. Using a single instance (not two
    /// conditional branches bridged by matchedGeometryEffect) means SwiftUI
    /// just interpolates `.frame`, `.position`, and the corner/shadow values
    /// directly — the artwork visibly shrinks and slides toward the top-left
    /// in one continuous motion. The inline title/artist appears as an overlay
    /// in compact mode with its own opacity transition.
    ///
    /// The whole header is wrapped in an explicit `.animation(value: compact)`
    /// modifier so every property the morph touches — frame, position, corner
    /// radius, shadow, container height — is bound to the same spring timeline
    /// and finishes together. The play-pulse `.scaleEffect` is hoisted onto a
    /// separate wrapper so its play/pause `.animation` context can't bleed into
    /// the compact morph and desync the artwork.
    private func sharedHeader(track: Track) -> some View {
        let compact = showLyrics || showQueue
        let bigSize = albumArtPlayingSide
        let smallSize: CGFloat = 56
        let artworkSize: CGFloat = compact ? smallSize : bigSize
        let cornerRadius: CGFloat = compact ? 6 : 12
        let playPulseScale: CGFloat = {
            if compact { return 1 }
            return app.player.isPlaying ? albumArtPlayOverscale : (albumArtPausedSide / bigSize)
        }()
        // Same vertical padding above the artwork in both modes — eliminates
        // the 1–2pt y discontinuity at toggle and keeps the morph perfectly
        // continuous.
        let topPad: CGFloat = 14
        let bottomPad: CGFloat = compact ? 12 : 24
        let standardOverscaleHeight = bigSize * albumArtPlayOverscale
        let containerHeight: CGFloat = compact
            ? (smallSize + topPad + bottomPad)
            : (standardOverscaleHeight + topPad + bottomPad)

        return GeometryReader { geo in
            let centerX = geo.size.width / 2
            let leadingX = 20 + smallSize / 2
            let xCenter = compact ? leadingX : centerX
            let yCenter = topPad + artworkSize / 2

            ZStack(alignment: .topLeading) {
                // Play-pulse scale lives in a separate wrapper so its
                // .animation(value: isPlaying) context only sees the scale,
                // not the morph's frame/position/shadow changes.
                AlbumArtworkView(url: artworkURL(for: track), cornerRadius: cornerRadius, showsSubtleBorder: false)
                    .frame(width: artworkSize, height: artworkSize)
                    .modifier(PlayPulseScale(scale: playPulseScale, isPlaying: app.player.isPlaying))
                    .shadow(
                        color: .black.opacity(backdropPalette.prefersDarkHeroChrome ? 0.22 : 0.45),
                        radius: compact ? 6 : 20,
                        y: compact ? 4 : 12,
                    )
                    .position(x: xCenter, y: yCenter)

                if compact {
                    HStack(alignment: .center, spacing: 12) {
                        Color.clear.frame(width: smallSize, height: smallSize)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(fgPrimary)
                                .lineLimit(1)
                            compactArtistMenu(track: track)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        compactHeaderActionButtons(track: track)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    // Slide up from below + fade in on the same snappy curve as
                    // the standard title's exit, so visually it reads as "the
                    // title moved up into the compact header" rather than two
                    // independent fades.
                    .transition(
                        AnyTransition.move(edge: .bottom)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.25, dampingFraction: 0.9))
                    )
                }
            }
        }
        .frame(height: containerHeight)
        .overlay(alignment: .bottom) {
            if compact {
                Rectangle().fill(fgDivider).frame(height: 0.5)
            }
        }
        // Explicit binding so every property the morph touches — frame,
        // position, corner radius, shadow, container height — animates on
        // exactly the same spring as the toggle's withAnimation context.
        .animation(.spring(duration: 0.46, bounce: 0.16), value: compact)
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
                            if case .playlist(let p) = player.playbackSource { return p }
                            return nil
                        }(),
                        goToAlbumDisabled: libraryAlbum == nil && catalogAlbumFallback(from: track) == nil,
                        onGoToAlbum: {
                            if let album = libraryAlbum {
                                dismissAndNavigate(to: .album(album))
                            } else if let album = catalogAlbumFallback(from: track) {
                                dismissAndNavigate(to: .album(album))
                            }
                        },
                        onGoToArtist: {
                            dismissAndNavigate(to: .artist(track.artist))
                        },
                        onGoToPlaylist: {
                            dismissAndNavigate(to: .playlist)
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

                if let activeTrack = player.activeTrack {
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

    /// When the playing track's album isn't in the user's library (so ``libraryAlbum``
    /// is nil), synthesize an ``AlbumSummary`` from track metadata so "Go to Album"
    /// can still navigate — `dismissAndNavigate` will set `librarySource: false` on it.
    private func catalogAlbumFallback(from track: Track) -> AlbumSummary? {
        guard !track.albumId.isEmpty else { return nil }
        let title = track.albumTitle.isEmpty ? "Unknown Album" : track.albumTitle
        return AlbumSummary(
            id: track.albumId,
            title: title,
            artist: track.artist,
            artworkURL: track.artworkURL
        )
    }

    private func dismissAndNavigate(to route: NowPlayingLibraryRoute) {
        let activeTrackId = player.activeTrack?.id
        let nav: NowPlayingDeepLink?
        switch route {
        case .album(let album):
            // Library-only filtered view is fine when the track is in the user's library;
            // otherwise the filter would hide it, so fall back to the full album view.
            let useLibrarySource = activeTrackId.map { app.isSongInLibrary($0) } ?? true
            nav = .album(album, scrollToTrackId: activeTrackId, librarySource: useLibrarySource)
            if let activeTrackId {
                app.pendingAlbumScroll = PendingAlbumScroll(albumId: album.id, trackId: activeTrackId)
            }
        case .artist(let name):
            nav = .artist(name)
        case .playlist:
            if case .playlist(let p) = player.playbackSource {
                let playlist = playlistForNavigation(id: p.id) ?? p
                nav = .playlist(playlist, scrollToTrackId: activeTrackId)
                if let activeTrackId {
                    app.pendingPlaylistScroll = PendingPlaylistScroll(playlistId: playlist.id, trackId: activeTrackId)
                }
            } else {
                nav = nil
            }
        }
        app.selectedTab = .library
        isPresented = false
        // Defer navigation until the dismiss animation has completed so the
        // LibraryView NavigationStack is stable when the push is triggered.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            app.pendingNavigation = nav
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
        if case .playlist(let playlist) = player.playbackSource, playlist.id == id {
            return playlist
        }
        return nil
    }

    private func progressBlock(track: Track) -> some View {
        ScrubberBlock(track: track, player: player, backdropPalette: backdropPalette)
    }

    /// Transport SF Symbols (contrast follows Light / Dark Now Playing chrome).
    private var transportRow: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 30) {
                Button {
                    player.skipPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 37, weight: .semibold))
                        .foregroundStyle(fgPrimary)
                        .frame(width: 64, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.skipNext()
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
                isActive: player.isQueueOutOfNaturalOrder,
                action: { player.toggleShuffle() },
            )
            queueModeToggle(
                systemName: player.repeatMode == .one ? "repeat.1" : "repeat",
                isActive: player.repeatMode != .off,
                action: { player.cycleRepeat() },
            )
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.2), value: player.shuffleMode)
        .animation(.easeInOut(duration: 0.2), value: player.repeatMode)
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
        if player.activeTrack != nil {
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
        HStack(spacing: 84) {
            bottomChromeIconButton(
                showLyrics ? "quote.bubble.fill" : "quote.bubble",
                isActive: showLyrics,
                iconFont: .system(size: 20, weight: .semibold),
            ) {
                withAnimation(.spring(duration: 0.46, bounce: 0.16)) {
                    showLyrics.toggle()
                    if showLyrics { showQueue = false }
                }
            }
            #if os(iOS)
            AirPlayRoutePickerView(tint: fgPrimary, activeTint: fgPrimary)
                .frame(width: 46, height: 46)
            #endif
            bottomChromeIconButton("list.bullet", isActive: showQueue) {
                withAnimation(.spring(duration: 0.46, bounce: 0.16)) {
                    showQueue.toggle()
                    if showQueue { showLyrics = false }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 30)
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

    private func queueRow(track: Track) -> some View {
        HStack(spacing: 12) {
            artworkView(for: track, cornerRadius: 4)
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
        // Slightly larger glyph to match adjacent bottom-chrome controls (lyrics / queue).
        picker.transform = CGAffineTransform(scaleX: 1.14, y: 1.14)
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
/// One row in the lyrics scroll — either a lyric line, or a silence marker
/// representing a long instrumental gap between two lines. The silence marker
/// renders as three dots that progressively light up as the gap elapses
/// (Apple Music–style).
private enum LyricRenderItem: Identifiable, Hashable {
    case lyric(LyricLine)
    case silence(start: TimeInterval, end: TimeInterval)

    var id: String {
        switch self {
        case .lyric(let l): return "lyric-\(l.id)"
        case .silence(let s, let e): return "silence-\(s)-\(e)"
        }
    }

    var start: TimeInterval {
        switch self {
        case .lyric(let l): return l.start
        case .silence(let s, _): return s
        }
    }
}

private struct LyricsFocusScrollView: View {
    let lines: [LyricLine]
    @ObservedObject var player: PlaybackEngine
    let primaryColor: Color
    let secondaryColor: Color

    /// Index into `displayItems` of the currently active row. Mirrored as
    /// `@State` (vs. computed) so SwiftUI consistently re-renders styling and
    /// fires `.onChange(of: activeIndex)` for scroll, driven by an `onReceive`
    /// subscription on `player.$currentTime` — more reliable than relying on a
    /// computed property buried inside a `ScrollViewReader` body.
    @State private var activeIndex: Int = 0

    /// Mirrored playback time so the active silence's dot progress redraws
    /// smoothly between `activeIndex` transitions.
    @State private var displayTime: TimeInterval = 0

    /// `lines` interleaved with silence markers for instrumental gaps.
    /// Recomputed only when the underlying `lines` change.
    @State private var displayItems: [LyricRenderItem] = []

    /// True when the source has no per-line timestamps (every `start` is 0).
    /// Jellyfin returns plain-text lyrics this way; render the lines but skip
    /// sync, silence dots, and tap-to-seek so the view doesn't pin the
    /// highlight to a bogus row.
    private var isUnsynced: Bool {
        guard let last = lines.last else { return true }
        return last.start == 0
    }

    /// Threshold (seconds) for inserting a silence marker between two lines.
    /// Apple Music shows dots for instrumental gaps roughly this long.
    private static let silenceThreshold: TimeInterval = 5
    /// Heuristic for how long a typical lyric line is sung; we only count gap
    /// time *after* this offset as silence, so a normal vocal pause doesn't
    /// sprout dots.
    private static let typicalLineDuration: TimeInterval = 3

    private static func buildDisplayItems(from lines: [LyricLine]) -> [LyricRenderItem] {
        guard !lines.isEmpty else { return [] }
        var items: [LyricRenderItem] = []

        // Intro silence: only when the first lyric is well past t=0 (don't
        // dot-spam the first second of every track).
        if let first = lines.first, first.start >= silenceThreshold {
            items.append(.silence(start: 0, end: first.start))
        }

        for i in 0..<lines.count {
            items.append(.lyric(lines[i]))
            guard i + 1 < lines.count else { continue }
            let silenceStart = lines[i].start + typicalLineDuration
            let silenceEnd = lines[i + 1].start
            if silenceEnd - silenceStart >= silenceThreshold {
                items.append(.silence(start: silenceStart, end: silenceEnd))
            }
        }
        return items
    }

    private static func computeActiveIndex(at time: TimeInterval, in items: [LyricRenderItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        let t = time + 0.08
        var lo = 0, hi = items.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if items[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        return items[lo].start <= t ? lo : 0
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
        .onAppear {
            displayItems = Self.buildDisplayItems(from: lines)
            syncActiveIndex(to: player.livePlaybackTime)
            displayTime = player.livePlaybackTime
        }
        .onChange(of: lines.map(\.id)) { _, _ in
            displayItems = Self.buildDisplayItems(from: lines)
            syncActiveIndex(to: player.livePlaybackTime)
        }
        .onReceive(player.$currentTime) { _ in
            // `currentTime` is UI-throttled; use it only as a publisher tick
            // and sample the fresher `livePlaybackTime` for sync accuracy.
            let t = player.livePlaybackTime
            displayTime = t
            syncActiveIndex(to: t)
        }
    }

    private func syncActiveIndex(to time: TimeInterval) {
        guard !isUnsynced else {
            if activeIndex != 0 { activeIndex = 0 }
            return
        }
        let newIndex = Self.computeActiveIndex(at: time, in: displayItems)
        if newIndex != activeIndex {
            activeIndex = newIndex
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
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        renderItemView(item, index: index)
                            .id(item.id)
                            .padding(.bottom, spacingAfterItem(at: index))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 48)
            }
            .onAppear {
                scrollToActiveItem(proxy: proxy, animated: false)
            }
            .onChange(of: activeIndex) { _, _ in
                guard !isUnsynced else { return }
                scrollToActiveItem(proxy: proxy, animated: true)
            }
            .onChange(of: displayItems.map(\.id)) { _, _ in
                scrollToActiveItem(proxy: proxy, animated: false)
            }
        }
    }

    private func scrollToActiveItem(proxy: ScrollViewProxy, animated: Bool) {
        guard displayItems.indices.contains(activeIndex) else { return }
        let id = displayItems[activeIndex].id
        if animated {
            withAnimation(.easeInOut(duration: 0.38)) {
                proxy.scrollTo(id, anchor: scrollAnchor)
            }
        } else {
            proxy.scrollTo(id, anchor: scrollAnchor)
        }
    }

    @ViewBuilder
    private func renderItemView(_ item: LyricRenderItem, index: Int) -> some View {
        switch item {
        case .lyric(let line):
            lyricLineView(line, index: index)
        case .silence(let start, let end):
            silenceMarkerView(start: start, end: end, index: index)
        }
    }

    @ViewBuilder
    private func lyricLineView(_ line: LyricLine, index: Int) -> some View {
        let distance = isUnsynced ? Int.max : index - activeIndex

        Text(line.text)
            .font(isUnsynced ? .title3.weight(.semibold) : font(for: distance))
            .foregroundStyle(isUnsynced ? primaryColor : (distance == 0 ? primaryColor : secondaryColor))
            .opacity(isUnsynced ? 0.85 : opacity(for: distance))
            .blur(radius: isUnsynced ? 0 : blur(for: distance))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isUnsynced else { return }
                player.seek(toSeconds: line.start)
            }
            .animation(.easeInOut(duration: 0.28), value: activeIndex)
    }

    @ViewBuilder
    private func silenceMarkerView(start: TimeInterval, end: TimeInterval, index: Int) -> some View {
        let distance = index - activeIndex
        let isActive = distance == 0
        // Progress 0…1 through this silence gap. Only meaningful while active;
        // for past/future silence rows we just render three uniform dim dots.
        let progress: Double = {
            guard isActive, end > start else { return 0 }
            return min(max((displayTime - start) / (end - start), 0), 1)
        }()

        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(primaryColor)
                    .frame(width: 12, height: 12)
                    .opacity(dotOpacity(forDot: i, progress: progress, isActive: isActive, distance: distance))
                    .scaleEffect(dotScale(forDot: i, progress: progress, isActive: isActive))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .blur(radius: isActive ? 0 : silenceBlur(for: distance))
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(toSeconds: start)
        }
        .animation(.easeInOut(duration: 0.28), value: activeIndex)
        .animation(.easeInOut(duration: 0.45), value: progress)
    }

    /// Light each dot up in sequence (≈⅓, ⅔, 1.0 of the silence elapsed).
    /// Inactive silences keep all three dots at a faint, uniform opacity.
    private func dotOpacity(forDot i: Int, progress: Double, isActive: Bool, distance: Int) -> Double {
        guard isActive else {
            switch distance {
            case ..<0: return 0.18
            case 1: return 0.6
            case 2: return 0.4
            case 3: return 0.28
            default: return 0.18
            }
        }
        let threshold = Double(i + 1) / 3.0
        return progress >= threshold ? 1.0 : 0.3
    }

    private func dotScale(forDot i: Int, progress: Double, isActive: Bool) -> CGFloat {
        guard isActive else { return 1 }
        let threshold = Double(i + 1) / 3.0
        return progress >= threshold ? 1.15 : 1.0
    }

    private func silenceBlur(for distance: Int) -> CGFloat {
        switch distance {
        case ..<0: return 1.5
        case 1: return 0.4
        case 2: return 1.4
        case 3: return 2.4
        default: return 3.4
        }
    }

    private func spacingAfterItem(at index: Int) -> CGFloat {
        guard !isUnsynced else { return 14 }
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
