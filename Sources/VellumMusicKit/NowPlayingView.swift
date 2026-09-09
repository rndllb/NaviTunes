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

/// Apple Music-style press feedback for transport buttons: the icon springs down
/// on touch and snaps back on release, with a slight dim while held. Shared by the
/// Now Playing transport row and the mini player.
/// Apple Music / Lock Screen skip-button glyph. The stock `forward.fill` is
/// replaced by two adjacent triangles; bumping `pulse` swaps both triangles'
/// identities so asymmetric transitions play the "march": the triangle on the
/// skip-direction side slides off shrinking while a fresh one grows in on the
/// opposite side, with a quick squish of the whole glyph. (There is no stock
/// symbolEffect for this — see the id-swap technique.)
private struct SkipMarchGlyph: View {
    /// `true` = next (marches trailing-ward), `false` = previous (mirrored).
    let pointsForward: Bool
    let fontSize: CGFloat
    let color: Color
    /// Bump to play one march cycle.
    let pulse: Int

    @State private var flipA = false
    @State private var flipB = false
    @State private var squish: CGFloat = 1.0

    private var inEdge: Edge { pointsForward ? .leading : .trailing }
    private var outEdge: Edge { pointsForward ? .trailing : .leading }

    private var triangle: some View {
        Image(systemName: pointsForward ? "arrowtriangle.forward.fill" : "arrowtriangle.backward.fill")
            .font(.system(size: fontSize * 0.74, weight: .semibold))
            .foregroundStyle(color)
    }

    /// The triangle on the entering side *grows* in from the edge; the one on
    /// the exiting side *shrinks* off. The other two legs are plain slides.
    private func marchTransition(growsIn: Bool, shrinksOut: Bool) -> AnyTransition {
        var insertion: AnyTransition = .move(edge: inEdge)
        if growsIn {
            insertion = insertion.combined(
                with: .scale(scale: 0.0, anchor: inEdge == .leading ? .leading : .trailing)
            )
        }
        var removal: AnyTransition = .move(edge: outEdge)
        if shrinksOut {
            removal = removal.combined(
                with: .scale(scale: 0.0, anchor: outEdge == .leading ? .leading : .trailing)
            )
        }
        return .asymmetric(insertion: insertion, removal: removal).combined(with: .opacity)
    }

    var body: some View {
        // Skipping forward: the new triangle enters on the leading side.
        let leadingSideEnters = pointsForward
        HStack(spacing: -fontSize * 0.05) {
            triangle
                .id("a-\(flipA)")
                .transition(marchTransition(growsIn: leadingSideEnters, shrinksOut: !leadingSideEnters))
            triangle
                .id("b-\(flipB)")
                .transition(marchTransition(growsIn: !leadingSideEnters, shrinksOut: leadingSideEnters))
        }
        .scaleEffect(squish)
        .onChange(of: pulse) { _, _ in
            withAnimation(.bouncy(duration: 0.38)) {
                flipA.toggle()
                flipB.toggle()
            }
            withAnimation(.easeInOut(duration: 0.09)) { squish = 0.9 }
            withAnimation(.easeInOut(duration: 0.12).delay(0.09)) { squish = 1.0 }
        }
    }
}

struct TransportPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.58), value: configuration.isPressed)
    }
}

private enum NowPlayingLibraryRoute: Hashable {
    case album(AlbumSummary)
    /// Carries the tapped row's own artist id, not just the name. The row that was tapped is not
    /// always the active track — a queue row has its own artist — so the id has to travel with
    /// the route rather than be read off the player at the far end.
    case artist(ArtistNameNavigation)
    case playlist
}

/// Apple Music–style Now Playing: artwork-derived backdrop + luminance handoff (same as album detail).
struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var player: PlaybackEngine
    @Binding var isPresented: Bool
    @State private var showLyrics = false
    @State private var showQueue = false
    /// The queue's now-playing module is *always* a real first list row (so it
    /// scrolls natively with the queue and never fights the history paging gesture).
    /// During the open morph the floating ``sharedHeader`` artwork travels into the
    /// row's slot; this flag flips `true` once it lands — instantly hiding the
    /// floating copy and showing the row's own artwork at the same coordinates.
    /// Set on the open animation's completion, or earlier if the user scrolls.
    @State private var queueArtworkHandedOff = false
    /// Tap counters driving the lock-screen-style skip-button symbol bounce.
    @State private var prevTapPulse = 0
    @State private var nextTapPulse = 0
    @State private var libraryPath: [NowPlayingLibraryRoute] = []
    /// Which of the paged queue sections is currently snapped, held in its own object.
    ///
    /// It used to be `@State` here, which meant every page settle invalidated *this* view — the
    /// NavigationStack, `sharedHeader`'s GeometryReader, the backdrop and the whole bottom
    /// chrome — rather than just the scroll region that moved. Only ``QueuePagingScroll``
    /// observes this object, so a settle now re-runs that view and nothing else. Same shape as
    /// `PlaybackTimeModel`, which exists so the playhead tick does not re-render every player
    /// view; this is that pattern applied to the one place it had not been.
    ///
    /// Held with `@State` rather than `@StateObject` deliberately: `@State` on a reference type
    /// does not subscribe to `objectWillChange`, so this view keeps the object *alive* without
    /// observing it. Lifetime is therefore exactly what it was — it survives leaving and
    /// re-entering the queue pane, and survives a close/reopen, so which page you return to is
    /// unchanged. (Scoping it to the queue pane's own view would have reset it on every visit,
    /// which is the kind of pane-restoration change this pass must not make.)
    @State private var queuePageAnchor = QueuePageAnchorModel()
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

    /// Paused artwork size. Bigger → cover shrinks LESS when paused
    /// (296/315 ≈ 94% of playing size). Only affects the paused state.
    private let albumArtPausedSide: CGFloat = 296
    /// Playing — base artwork size before play-state overscale. Bigger →
    /// cover larger in BOTH states (paused scale derives from the ratio).
    private let albumArtPlayingSide: CGFloat = 315
    /// Scales past ``albumArtPlayingSide`` when playback resumes (Apple
    /// Music–style pulse). Bigger → larger playing cover AND a taller header
    /// reservation, pushing the title + chrome column down.
    private let albumArtPlayOverscale: CGFloat = 1.14

    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback

    @Environment(\.colorScheme) private var colorScheme

    private func artworkURL(for track: Track?) -> URL? {
        guard let track else { return nil }
        return app.resolvedArtworkURL(for: track)
    }

    /// Decode target for the small fixed-size rows in the queue and history lists.
    ///
    /// `AlbumArtworkView` defaults to 768px, which is the hero's size and correct for the hero.
    /// A 44pt row on a 3x screen needs 132px and a 56pt row needs 168px, so the rows were
    /// decoding and *cacheing* 16x the pixels they can display — the exact thing
    /// `Rules/swiftui-render-cost.md` tells this project not to do. 192 is not a new number:
    /// `LibrarySongsView.rowArtworkDecodePixels` already uses it for comparable rows.
    private static let rowArtworkDecodePixels: CGFloat = 192

    /// - Parameter maxDecodePixels: left at the `AlbumArtworkView` default for everything that
    ///   morphs into or out of the hero — those views get resized to full artwork dimensions
    ///   mid-transition, so a row-sized decode would be visibly soft while they travel.
    private func artworkView(
        for track: Track,
        cornerRadius: CGFloat,
        maxDecodePixels: CGFloat = 768,
    ) -> some View {
        AlbumArtworkView(
            url: artworkURL(for: track),
            meshArtworkSeed: isLiveRadio(track)
                ? RadioStationMeshArtwork.seedKey(for: track)
                : nil,
            cornerRadius: cornerRadius,
            maxDecodePixels: maxDecodePixels,
            showsSubtleBorder: false,
        )
    }

    private func isLiveRadio(_ track: Track) -> Bool {
        track.isInternetRadioStream
    }

    @ViewBuilder
    private func nowPlayingLeadingActionButton(
        track: Track,
        font: Font,
        foreground: Color,
        frame: CGFloat,
    ) -> some View {
        if isLiveRadio(track) {
            Button {
                app.toggleRadioTrackInYourStations(track)
            } label: {
                Image(
                    systemName: app.isRadioTrackInYourStations(track)
                        ? "checkmark.circle.fill" : "plus.circle"
                )
                    .font(font)
                    .foregroundStyle(foreground)
                    .frame(width: frame, height: frame)
                    .background(Circle().fill(fgCapsule))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                app.isRadioTrackInYourStations(track)
                    ? "Remove from Your Stations" : "Save to Your Stations"
            )
        } else {
            Button {
                app.toggleFavoriteTrack(id: track.id)
            } label: {
                Image(systemName: app.favoriteTrackIds.contains(track.id) ? "star.fill" : "star")
                    .font(font)
                    .foregroundStyle(foreground)
                    .frame(width: frame, height: frame)
                    .background(Circle().fill(fgCapsule))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                app.favoriteTrackIds.contains(track.id) ? "Unfavorite" : "Favorite"
            )
        }
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

    /// Apple Music paints the main player's metadata chrome (artist line,
    /// star/ellipsis, bottom icon row) red. With the color backdrop disabled
    /// the palette is neutral, so those elements map to the app accent; with
    /// a backdrop on, the artwork-derived palette keeps owning them.
    private var usesAccentChrome: Bool { !app.playerBackdropEnabled }
    private var fgAccentChrome: Color { usesAccentChrome ? MusicDesign.accent : fgPrimary }

    /// Display-normalizes multi-artist tags to Apple Music's joiner style:
    /// "A, B, & C" → "A, B & C".
    private func artistDisplay(_ raw: String) -> String {
        raw.replacingOccurrences(of: ", & ", with: " & ")
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
#if DEBUG
        // Diagnostic: how often this body is re-evaluated. A control cannot complete a tap if
        // the subtree holding it is rebuilt between touch-down and touch-up, and the device log
        // shows taps reaching SwiftUI's recogniser while buttons stay dead — so the rebuild rate
        // right after the player opens is the thing to measure.
        let _ = NowPlayingBodyCounter.shared.tick()
#endif
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
                        // Keep the morphing artwork above the queue list so it can
                        // travel over the list's first-row slot during the open
                        // morph, then hand off to the row's own artwork.
                        .zIndex(1)

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
            .task(id: nowPlayingBackdropTaskKey) {
                guard app.playerBackdropEnabled else {
                    await MainActor.run { backdropPalette = .listSurface(colorScheme: colorScheme) }
                    return
                }
                if let url = artworkURL(for: player.activeTrack) {
                    if let cached = ArtworkDynamicGradient.cachedBackdrop(for: url) {
                        backdropPalette = cached
                        return
                    }
                    let p = await ArtworkDynamicGradient.analyzeBackdrop(from: url)
                    await MainActor.run { backdropPalette = p }
                    return
                }
                if let track = player.activeTrack,
                   isLiveRadio(track),
                   let seedKey = RadioStationMeshArtwork.seedKey(for: track) {
                    let p = await ArtworkDynamicGradient.analyzeBackdrop(fromMeshSeedKey: seedKey, style: .detail)
                    await MainActor.run { backdropPalette = p }
                    return
                }
                await MainActor.run { backdropPalette = .listSurface(colorScheme: colorScheme) }
            }
        }
        .onChange(of: player.activeTrack?.id) { _, _ in
            if player.activeTrack.map(isLiveRadio) == true {
                showLyrics = false
                showQueue = false
                queueArtworkHandedOff = false
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

    private var nowPlayingBackdropTaskKey: String {
        guard let track = player.activeTrack else { return "none-\(colorScheme)" }
        if let url = artworkURL(for: track) {
            return "url-\(url.absoluteString)-\(app.playerBackdropEnabled)-\(colorScheme)"
        }
        if isLiveRadio(track), let seedKey = RadioStationMeshArtwork.seedKey(for: track) {
            return "mesh-\(seedKey)-\(app.playerBackdropEnabled)-\(colorScheme)"
        }
        return "fallback-\(colorScheme)"
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
            // SPACING NOTE — the area between artwork and bottom chrome is
            // squeezed to its minimum height, so vertical position flows
            // TOP-DOWN from the (fixed) artwork: a padding increase here moves
            // this row AND everything below it (bar, transport, volume, icons)
            // down together.
            metadataRow(track: track)
                .padding(.horizontal, 24)
                // Bigger → title/artist (and the whole chrome column below)
                // sink lower beneath the artwork.
                .padding(.top, 30)
                // Title/artist → playback bar gap. Bigger → wider gap; the
                // bar and everything under it shift down.
                .padding(.bottom, 0)

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
    /// One row of the up-next list.
    ///
    /// Exists because **`Track.id` is not a row identity**. A queue can hold the same id twice — a
    /// playlist with a repeated song, or Play Next / Add to Queue used on the track already
    /// playing — and every queue-row operation used to address rows by id. That single mistake
    /// produced all of it: `ForEach(_, id: \.id)` collapsed the copies, a tap or swipe on the
    /// second copy hit the first, and reordering trapped in
    /// `Dictionary(uniqueKeysWithValues:)` with "Fatal error: Duplicate values for key".
    ///
    /// `rowId` is the id plus which occurrence it is, so identity survives rows shifting position
    /// when something above them is removed — an absolute index would change for every row after
    /// the removal and make SwiftUI animate the wrong one out. `queueIndex` and `upNextOffset`
    /// carry the *position*, which is what the engine is told to act on.
    private struct QueueEntry: Identifiable {
        let rowId: String
        /// Absolute index into `PlaybackEngine.queue`.
        let queueIndex: Int
        /// Offset from the start of up-next — the coordinate space `moveUpNextItem` and
        /// `removeUpNextItems` both use.
        let upNextOffset: Int
        let track: Track
        var id: String { rowId }
    }

    /// Pairs each up-next track with its position and a stable per-row identity.
    private func upNextEntries() -> [QueueEntry] {
        let start = player.currentIndex + 1
        guard start < player.queue.count else { return [] }
        var occurrences: [String: Int] = [:]
        return player.queue.indices.dropFirst(start).map { index in
            let track = player.queue[index]
            let n = occurrences[track.id, default: 0]
            occurrences[track.id] = n + 1
            return QueueEntry(
                rowId: "\(track.id)#\(n)",
                queueIndex: index,
                upNextOffset: index - start,
                track: track,
            )
        }
    }

    private func queueScrollContent(track: Track) -> some View {
        let upNext = upNextEntries()
        // Don't duplicate the currently-playing track in the history list.
        // Storage is newest-first; the queue view reads oldest-at-top so the most
        // recently played track sits right above the Now Playing line.
        let queueHistory = app.recentlyPlayedTracks
            .filter { $0.id != track.id }
            .reversed()
            .map { $0 }

        return QueuePagingScroll(model: queuePageAnchor) {
            historySection(history: queueHistory)
        } nowPlaying: {
            nowPlayingPage(track: track, upNext: upNext)
        }
    }

    /// Middle page — single `List` for upcoming tracks ("Queue" + "Continue
    /// Playing"). Reorderable sections use 3-line drag handles (system-drawn
    /// via active edit mode); the bottom chrome below is untouched by the
    /// scrolling list. Compact artwork + title live in ``sharedHeader``.
    private func nowPlayingPage(track: Track, upNext: [QueueEntry]) -> some View {
        let userQueueTracks = upNext.filter { player.userQueuedTrackIds.contains($0.track.id) }
        let continuePlayingTracks = upNext.filter { !player.userQueuedTrackIds.contains($0.track.id) }
        return queueAndContinuePlayingList(
            track: track,
            userQueue: userQueueTracks,
            continuePlaying: continuePlayingTracks
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var continuePlayingSourceLabel: String? {
        if case .playlist(let p) = player.playbackSource { return p.name }
        let title = player.activeTrack?.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// Inline now-playing row — always the first row of the queue list, so it
    /// scrolls natively with the queue. Title, artist menu, star and ellipsis live
    /// here. The artwork slot is reserved (clear) and the real artwork only shows
    /// once ``queueArtworkHandedOff`` is set — until then the floating
    /// ``sharedHeader`` artwork occupies the slot mid-morph, at identical
    /// coordinates, so the swap to this row's artwork is invisible.
    private func queueNowPlayingModuleRow(track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Color.clear.frame(width: 56, height: 56)
                // Static slot: the shared header's artwork is what actually morphs through here,
                // so this copy never travels and can decode at row size.
                artworkView(
                    for: track,
                    cornerRadius: 6,
                    maxDecodePixels: Self.rowArtworkDecodePixels,
                )
                    .frame(width: 56, height: 56)
                    .shadow(
                        color: .black.opacity(backdropPalette.prefersDarkHeroChrome ? 0.22 : 0.45),
                        radius: 6,
                        y: 4,
                    )
                    .opacity(queueArtworkHandedOff ? 1 : 0)
            }

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
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var queueListClearButton: some View {
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

    /// Wraps the shuffle/repeat row into a section header so that it pins to the
    /// top of the visible list while the user scrolls upcoming tracks.
    ///
    /// Applies `.listRowInsets(EdgeInsets())` so the backdrop spans edge-to-edge
    /// — without this, the List's default row insets leave a strip of queue
    /// artwork peeking through on the leading side when the header pins.
    @ViewBuilder
    private func queueStickyHeader(
        title: String? = nil,
        subtitle: String? = nil,
        includeShuffleRepeat: Bool,
        trailing: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if includeShuffleRepeat {
                shuffleRepeatRow
            }
            if let title {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(fgPrimary)
                            .textCase(nil)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(fgSecondary)
                                .textCase(nil)
                        }
                    }
                    Spacer()
                    if let trailing {
                        trailing
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroSolidBackdropColor)
        .listRowInsets(EdgeInsets())
    }

    private var heroSolidBackdropColor: Color {
        player.activeTrack != nil
            ? backdropPalette.heroSolidBackdropColor
            : (colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : MusicDesign.background)
    }

    /// Single `List` with reorderable Queue / Continue Playing sections.
    /// The compact now-playing header lives in ``sharedHeader`` above the
    /// scroll region (same morph as lyrics). Sticky section headers carry
    /// shuffle/repeat once the user scrolls the list.
    private func queueAndContinuePlayingList(
        track: Track,
        userQueue: [QueueEntry],
        continuePlaying: [QueueEntry]
    ) -> some View {
        let hasUserQueue = !userQueue.isEmpty
        let hasContinue = !continuePlaying.isEmpty
        return List {
            Section {
                queueNowPlayingModuleRow(track: track)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            if hasUserQueue {
                Section {
                    ForEach(userQueue) { entry in
                        queueListRow(entry: entry)
                    }
                    .onMove { source, destination in
                        moveWithinSection(entries: userQueue, source: source, destination: destination)
                    }
                } header: {
                    queueStickyHeader(
                        title: "Queue",
                        includeShuffleRepeat: true,
                        trailing: AnyView(queueListClearButton)
                    )
                }
            }

            if hasContinue {
                Section {
                    ForEach(continuePlaying) { entry in
                        queueListRow(entry: entry)
                    }
                    .onMove { source, destination in
                        moveWithinSection(entries: continuePlaying, source: source, destination: destination)
                    }
                } header: {
                    queueStickyHeader(
                        title: "Continue Playing",
                        subtitle: continuePlayingSourceLabel.map { "From \($0)" },
                        includeShuffleRepeat: !hasUserQueue
                    )
                }
            }

            if !hasUserQueue && !hasContinue {
                Section {
                    Text("Nothing up next")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(fgMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    queueStickyHeader(includeShuffleRepeat: true)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // If the user scrolls before the open morph finishes, hand the artwork off
        // immediately so the row's own artwork is there as it scrolls (no empty
        // slot, no late fade). This is a passive *observer* — unlike a gesture it
        // doesn't compete with the list scroll or the history paging swipe.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
            if offset > 0.5 && !queueArtworkHandedOff { queueArtworkHandedOff = true }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        .tint(fgPrimary)
        .background {
            NowPlayingQueueListTableChrome(
                reorderTint: UIColor(fgPrimary.opacity(0.35)),
                scrollIndicatorStyle: queueScrollIndicatorStyle,
            )
        }
        #endif
    }

    private func queueListRow(entry: QueueEntry) -> some View {
        let t = entry.track
        // Jump to THIS row, not to the first track that happens to share its id. The old
        // `firstIndex(where: { $0.id == t.id })` sent every copy of a repeated song to the topmost
        // one, so tapping the second copy played the first.
        return Button {
            player.jumpToQueueItem(at: entry.queueIndex)
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
                // By position: removes this one row. Passing the bare id removed every copy —
                // including the one playing, which then tore down the player and started a
                // different song because the cursor could no longer find itself.
                player.removeUpNextItems(at: IndexSet(integer: entry.upNextOffset))
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu { queueSongMenuContent(track: t) }
    }

    /// Translates an `onMove` IndexSet+destination from a section's local coordinates into
    /// the full `Up Next` index space, then forwards to `PlaybackEngine.moveUpNextItem`.
    ///
    /// Each entry already knows its own `upNextOffset`, so this is a direct lookup. It used to
    /// build `Dictionary(uniqueKeysWithValues:)` keyed on `Track.id` to recover those offsets,
    /// which has a documented precondition of unique keys — so with the same song twice in up-next
    /// it trapped with "Fatal error: Duplicate values for key" and hard-crashed the app. Note it
    /// fired on the **drop**, not during the drag: the user released the row and the app died. Any
    /// row could trigger it, not only a duplicated one, because the dictionary was built over the
    /// whole of up-next.
    private func moveWithinSection(entries: [QueueEntry], source: IndexSet, destination: Int) {
        guard !entries.isEmpty else { return }
        let mappedSource = IndexSet(source.compactMap { entries.indices.contains($0) ? entries[$0].upNextOffset : nil })
        guard !mappedSource.isEmpty else { return }
        let mappedDestination: Int = {
            if destination < entries.count { return entries[destination].upNextOffset }
            // Append at end of section: just past the section's last row, in up-next coords.
            if let last = entries.last { return last.upNextOffset + 1 }
            return 0
        }()
        player.moveUpNextItem(from: mappedSource, to: mappedDestination)
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
                            .contextMenu { queueSongMenuContent(track: t) }
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
        let libraryAlbum = app.catalogAlbum(id: track.albumId)
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
                        heroBackdropPalette: backdropPalette,
                        accentOverride: usesAccentChrome ? MusicDesign.accent : nil,
                        sourcePlaylist: sourcePlaylistForActiveTrack(track),
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
                            dismissAndNavigate(to: .artist(ArtistNameNavigation(id: track.artist, serverArtistId: track.artistId)))
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
        let liveRadio = isLiveRadio(track)
        return VStack(spacing: 0) {
            // SPACING NOTE — positions flow top-down from the playback bar
            // (see metadataRow). The column can run past the screen's bottom
            // edge; the volume row's top padding below is the counterweight
            // that pulls the volume bar + icons back up.
            progressBlock(track: track, isEnabled: !liveRadio)
                // Bigger → bar + timers pull in narrower from both edges.
                .padding(.horizontal, 22)
                .padding(.top, 8)
                // Playback bar → transport gap. Bigger → play/skip/replay
                // buttons (and volume + icons) drop lower.
                .padding(.bottom, 34)

            transportRow(for: track)
                .padding(.horizontal, 20)
                .padding(.top, 15)
                // Bigger → volume bar + icons drop lower (transport stays).
                .padding(.bottom, 28)

            NowPlayingVolumeRow(backdropPalette: backdropPalette)
                // Counterweight: bigger → volume bar + icons drop lower.
                // SHRINK this by the amount you add to a gap above when the
                // bottom block should hold its place — otherwise it slides
                // toward (or past) the screen edge.
                .padding(.top, 30)

            nowPlayingBottomChrome(track: track)
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
                nowPlayingLeadingActionButton(
                    track: track,
                    font: .body.weight(.semibold),
                    foreground: fgPrimary,
                    frame: 30,
                )

                Menu {
                    nowPlayingTrackMenuContent(track: track)
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

    /// Artist row in the compact shared header — uses the same tappable
    /// ``ArtistNowPlayingMenuButton`` (Go to Artist / Album / Playlist) as
    /// the standard-mode metadata row, so the menu is available in lyrics
    /// and queue modes too. Falls back to plain text when the artist field
    /// is empty (button has nothing to anchor).
    @ViewBuilder
    private func compactArtistMenu(track: Track) -> some View {
        if isLiveRadio(track) {
            Text("Live stream")
                .font(.subheadline)
                .foregroundStyle(fgSecondaryStrong)
                .lineLimit(1)
        } else {
        let artistKey = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryAlbum = app.catalogAlbum(id: track.albumId)
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
                heroBackdropPalette: backdropPalette,
                accentOverride: usesAccentChrome ? MusicDesign.accent : nil,
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
                    dismissAndNavigate(to: .artist(ArtistNameNavigation(id: track.artist, serverArtistId: track.artistId)))
                },
                onGoToPlaylist: {
                    dismissAndNavigate(to: .playlist)
                },
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    /// Star + ellipsis action buttons shown trailing the inline title/artist
    /// in the compact (lyrics / queue) shared header — restores the action
    /// affordances that lived in the old per-mode headers before the artwork
    /// was hoisted.
    @ViewBuilder
    private func compactHeaderActionButtons(track: Track) -> some View {
        let liveRadio = isLiveRadio(track)
        HStack(spacing: 10) {
            nowPlayingLeadingActionButton(
                track: track,
                font: .body.weight(.semibold),
                foreground: fgPrimary,
                frame: 30,
            )

            Menu {
                nowPlayingTrackMenuContent(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(liveRadio ? fgMuted : fgPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(fgCapsule))
            }
            .disabled(liveRadio)
        }
    }

    /// Standard song overflow menu used by the ellipsis button on the Now Playing
    /// header (regardless of mode — main player, lyrics, queue). Matches the
    /// shape used by library / album / browse song rows so the affordances are
    /// consistent app-wide; only the actions that don't make sense for the
    /// currently-playing track (Play, Play Next) are omitted.
    @ViewBuilder
    private func nowPlayingTrackMenuContent(track: Track) -> some View {
        let isInLibrary = app.isSongInLibrary(track.id)
        let isOfflineCached = app.offline.downloadedTrackIds.contains(track.id)
        let isFavorite = app.favoriteTrackIds.contains(track.id)
        let albumForNav: AlbumSummary? = app.catalogAlbum(id: track.albumId)
            ?? catalogAlbumFallback(from: track)

        ControlGroup {
            if !isInLibrary {
                Button {
                    Task { await app.addSongToLibrary(track) }
                } label: {
                    Label("Add to Library", systemImage: "plus")
                }
            } else if !isOfflineCached {
                Button {
                    Task {
                        guard let lib = app.activeLibrary else { return }
                        try? await downloadNowPlayingTrack(track, lib: lib)
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }
            }
            Button {
                app.toggleFavoriteTrack(id: track.id)
            } label: {
                Label(
                    isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: isFavorite ? "star.fill" : "star"
                )
            }
            ShareLink(item: "\(track.title) — \(track.artist)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .tint(Color.primary)

        Section {
            Button {
                app.presentAddToPlaylist(tracks: [track])
            } label: {
                Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
            }
            if let album = albumForNav {
                Button {
                    app.scrobbleService.excludeAlbum(album)
                    app.showTransientToast("Excluded from listening history")
                } label: {
                    Label("Exclude from Listening History", systemImage: "eye.slash")
                }
            }
        }
        .tint(Color.primary)

        if let album = albumForNav {
            Section {
                Button {
                    dismissAndNavigate(to: .album(album))
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            .tint(Color.primary)
        }

        Section {
            Button {
                Task { await app.playMoreLikeThis(track: track) }
            } label: {
                Label("Play more like this", systemImage: "sparkles")
            }
            Button {
                Task { await app.queueMoreLikeThis(track: track) }
            } label: {
                Label("Add similar to queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button {
                Task { await app.playArtistMix(for: track) }
            } label: {
                Label("Play artist mix", systemImage: "shuffle")
            }
        }
        .tint(Color.primary)

        NavidromeShareMenuSection(
            itemId: track.id,
            description: "\(track.title) — \(track.artist)"
        )

        if isOfflineCached {
            Section {
                Button {
                    try? app.offline.remove(trackId: track.id)
                } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                }
            }
            .tint(Color.primary)
        }

        if isInLibrary {
            Section {
                Button(role: .destructive) {
                    app.requestRemoveSongFromLibrary(track)
                } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
            }
            .menuSectionDestructiveTint()
        }
    }

    private func downloadNowPlayingTrack(_ track: Track, lib: MusicLibraryProviding) async throws {
        app.enqueueOfflineTrack(track)
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
        // Queue reserves zero header height — its now-playing module is always the
        // first row of the list below. The header here only hosts the artwork while
        // it morphs into that row's slot (at the same coordinates), then hides.
        let inQueue = showQueue
        let bigSize = albumArtPlayingSide
        let smallSize: CGFloat = 56
        let artworkSize: CGFloat = compact ? smallSize : bigSize
        let cornerRadius: CGFloat = compact ? 6 : 12
        let playPulseScale: CGFloat = {
            if compact { return 1 }
            return app.player.isPlaying ? albumArtPlayOverscale : (albumArtPausedSide / bigSize)
        }()
        // Bigger → cover sits lower on the screen (and the title + chrome
        // column below it shifts down too, via containerHeight). Standard mode
        // carries the lowered Apple-Music position; compact (lyrics/queue)
        // keeps the original 14 so the small artwork sits where those layouts
        // expect — the morph animates the y difference.
        let topPad: CGFloat = compact ? 14 : 32
        // Reserved space UNDER the cover: bigger → title + all chrome below
        // sink lower while the cover stays put. To move ONLY the cover,
        // change topPad and bottomPad in opposite directions by the same
        // amount (their sum sets where everything below starts).
        let bottomPad: CGFloat = compact ? 12 : 14
        let standardOverscaleHeight = bigSize * albumArtPlayOverscale
        let containerHeight: CGFloat = {
            if !compact { return standardOverscaleHeight + topPad + bottomPad }
            // Lyrics reserves the full compact header; queue collapses to zero so
            // the list — carrying its own now-playing first row — rises to the top.
            return inQueue ? 0 : (smallSize + topPad + bottomPad)
        }()

        return GeometryReader { geo in
            let centerX = geo.size.width / 2
            let leadingX = 20 + smallSize / 2
            let xCenter = compact ? leadingX : centerX
            let yCenter = topPad + artworkSize / 2

            ZStack(alignment: .topLeading) {
                // Play-pulse scale lives in a separate wrapper so its
                // .animation(value: isPlaying) context only sees the scale,
                // not the morph's frame/position/shadow changes.
                artworkView(for: track, cornerRadius: cornerRadius)
                    .frame(width: artworkSize, height: artworkSize)
                    // Destination rect for the mini-player cover zoom. The shared header is the
                    // one artwork that is on screen when the player opens and closes.
                    .coverZoomHeroAnchor(id: NowPlayingCoverZoom.id, cornerRadius: cornerRadius)
                    // Hidden while the transition carries a copy of this cover, so only one is
                    // ever on screen. Observes a single small object — not the player's state.
                    .nowPlayingHeroFlightHiding()
                    .modifier(PlayPulseScale(scale: playPulseScale, isPlaying: app.player.isPlaying))
                    .shadow(
                        color: .black.opacity(backdropPalette.prefersDarkHeroChrome ? 0.22 : 0.45),
                        radius: compact ? 6 : 20,
                        y: compact ? 4 : 12,
                    )
                    .position(x: xCenter, y: yCenter)
                    // Hidden the instant the morph lands and the in-list row's own
                    // artwork takes over (same coordinates). Instant, no crossfade.
                    .opacity(inQueue && queueArtworkHandedOff ? 0 : 1)

                if compact && !inQueue {
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
            if compact && !inQueue {
                Rectangle().fill(fgDivider).frame(height: 0.5)
            }
        }
        // Explicit binding so every property the morph touches — frame,
        // position, corner radius, shadow, container height — animates on
        // exactly the same spring as the toggle's withAnimation context.
        .animation(.spring(duration: 0.46, bounce: 0.16), value: compact)
    }

    private func metadataRow(track: Track) -> some View {
        let liveRadio = isLiveRadio(track)
        let artistKey = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryAlbum = app.catalogAlbum(id: track.albumId)
        let albumSubtitle: String = {
            let t = track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            if let title = libraryAlbum?.title, !title.isEmpty { return title }
            return "Unknown Album"
        }()
        // .center keeps the star/ellipsis buttons vertically spanning the
        // title AND artist rows (Apple Music) instead of hugging the title.
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2)
                    .foregroundStyle(fgPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if isLiveRadio(track) {
                    Text("Live stream")
                        .font(.title3)
                        .foregroundStyle(fgSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                } else if artistKey.isEmpty {
                    Text(artistDisplay(track.artist))
                        .font(.title3)
                        .foregroundStyle(usesAccentChrome ? MusicDesign.accent : fgSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                } else {
                    ArtistNowPlayingMenuButton(
                        artist: artistDisplay(track.artist),
                        albumSubtitle: albumSubtitle,
                        libraryAlbum: libraryAlbum,
                        heroBackdropPalette: backdropPalette,
                        accentOverride: usesAccentChrome ? MusicDesign.accent : nil,
                        sourcePlaylist: sourcePlaylistForActiveTrack(track),
                        goToAlbumDisabled: libraryAlbum == nil && catalogAlbumFallback(from: track) == nil,
                        onGoToAlbum: {
                            if let album = libraryAlbum {
                                dismissAndNavigate(to: .album(album))
                            } else if let album = catalogAlbumFallback(from: track) {
                                dismissAndNavigate(to: .album(album))
                            }
                        },
                        onGoToArtist: {
                            dismissAndNavigate(to: .artist(ArtistNameNavigation(id: track.artist, serverArtistId: track.artistId)))
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
                nowPlayingLeadingActionButton(
                    track: track,
                    font: .title3.weight(.semibold),
                    foreground: fgAccentChrome,
                    frame: 34,
                )

                Menu {
                    nowPlayingTrackMenuContent(track: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(liveRadio ? fgMuted : fgAccentChrome)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(fgCapsule))
                }
                .disabled(liveRadio)
            }
        }
    }

    /// When the playing track's album isn't in the user's library (so ``libraryAlbum``
    /// is nil), synthesize an ``AlbumSummary`` from track metadata so "Go to Album"
    /// can still navigate — `dismissAndNavigate` will set `librarySource: false` on it.
    /// Long-press menu for the queue and history rows — the shared
    /// ``StandardSongMenuContent``, so a song offers the same actions here as it does in
    /// search, the artist page, or a playlist. (The player's own header ellipsis keeps its
    /// now-playing variant: Play Next / Add to Queue make no sense for the track that is
    /// already playing.)
    @ViewBuilder
    private func queueSongMenuContent(track: Track) -> some View {
        let album = app.catalogAlbum(id: track.albumId) ?? catalogAlbumFallback(from: track)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        StandardSongMenuContent(
            track: track,
            onPlayNext: {
                Task { @MainActor in
                    try? await player.playTracksNext(library: app.activeLibrary, tracks: [track])
                }
            },
            onAddToQueue: {
                Task { @MainActor in
                    guard let lib = app.activeLibrary else { return }
                    try? await player.addToQueue(library: lib, track: track, sourcePlaylistId: nil)
                }
            },
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
            onGoToAlbum: album.map { album in { dismissAndNavigate(to: .album(album)) } },
            onGoToArtist: ArtistNavigation.isTappable(artist)
                ? { dismissAndNavigate(to: .artist(ArtistNameNavigation(id: track.artist, serverArtistId: track.artistId))) }
                : nil,
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { app.requestRemoveSongFromLibrary(track) }
                : nil,
            onDeleteFromLibrary: app.canDeleteFromLibrary
                ? { app.beginLibraryTrackDeletion(track) }
                : nil
        )
    }

    private func catalogAlbumFallback(from track: Track) -> AlbumSummary? {
        guard !track.albumId.isEmpty else { return nil }
        let title = track.albumTitle.isEmpty ? "Unknown Album" : track.albumTitle
        let art = app.resolvedArtworkURL(for: track)
        return AlbumSummary(
            id: track.albumId,
            title: title,
            artist: track.artist,
            artworkURL: art
        )
    }

    /// Closes the player from inside the player.
    ///
    /// The binding is only half of it. `NowPlayingCoverPresenter` acts on the binding from
    /// `updateUIViewController`, which needs the *shell* to re-render — and the shell is
    /// completely covered while the player is up, so SwiftUI stops updating it. Device log:
    /// "Go to Playlist" wrote the binding at t=462.13 and the presenter's next `NP-SYNC` did
    /// not arrive for 1.3s, when the user gave up and swiped the player down by hand; the deep
    /// link had been sitting queued behind a player that never left. Write the binding so
    /// SwiftUI's state stays truthful, then tell UIKit directly.
    private func closeCover() {
        isPresented = false
        NowPlayingCoverState.shared.requestDismiss?()
    }

    private func dismissAndNavigate(to route: NowPlayingLibraryRoute) {
        let activeTrackId = player.activeTrack?.id
#if DEBUG
        DebugUIRemote.log("NP-NAV enter route=\(route) isPresented=\(isPresented)")
#endif

        // Special case: behind the player the user is already on this destination on the current
        // tab — dismiss the overlay and let the underlying view scroll + highlight.
        switch route {
        case .album(let album) where app.currentlyVisibleAlbumId == album.id:
            if let activeTrackId {
                app.pendingAlbumScroll = PendingAlbumScroll(albumId: album.id, trackId: activeTrackId)
            }
            closeCover()
            return
        case .playlist:
            if let track = player.activeTrack,
               let p = sourcePlaylistForActiveTrack(track),
               app.currentlyVisiblePlaylistId == p.id {
                app.pendingPlaylistScroll = PendingPlaylistScroll(playlistId: p.id, trackId: track.id)
                closeCover()
                return
            }
        default:
            break
        }

        // Normal case: strictly sequential — player closes, wait, destination overlay slides in.
        let nav: NowPlayingDeepLink?
        switch route {
        case .album(let album):
            let useLibrarySource = activeTrackId.map { app.isSongInLibrary($0) } ?? true
            nav = .album(album, scrollToTrackId: activeTrackId, librarySource: useLibrarySource)
        case .artist(let artistNav):
            nav = .artist(artistNav)
        case .playlist:
            if let track = player.activeTrack,
               let p = sourcePlaylistForActiveTrack(track) {
                let playlist = playlistForNavigation(id: p.id) ?? p
                nav = .playlist(playlist, scrollToTrackId: activeTrackId)
            } else {
                nav = nil
            }
        }

        let targetTab = app.selectedTab
        closeCover()
        guard let nav else { return }
        if case .playlist(let playlist, _) = nav {
            // Warm the rows cache concurrently with the dismiss animation. Never
            // serialize the push behind the network — if the fetch hasn't landed
            // by presentation time, the detail view shows its own loading state
            // and shares this in-flight request via fetchPlaylistRows dedup.
            Task { @MainActor in
                await app.prefetchPlaylistRows(playlistId: playlist.id)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
#if DEBUG
            DebugUIRemote.log("NP-NAV deepLink set tab=\(targetTab)")
#endif
            app.deepLinkTab = targetTab
            app.presentedDeepLink = nav
        }
    }


    private func playlistForNavigation(id: String) -> PlaylistSummary? {
        if let playlist = app.libraryPlaylist(id: id) {
            return playlist
        }
        if case .playlist(let playlist) = player.playbackSource, playlist.id == id {
            return playlist
        }
        return nil
    }

    private func sourcePlaylistForActiveTrack(_ track: Track) -> PlaylistSummary? {
        app.sourcePlaylistForNowPlaying(activeTrack: track, playbackSource: player.playbackSource)
    }

    private func progressBlock(track: Track, isEnabled: Bool = true) -> some View {
        ScrubberBlock(track: track, player: player, time: player.time, backdropPalette: backdropPalette, isEnabled: isEnabled)
    }

    /// Transport SF Symbols (contrast follows Light / Dark Now Playing chrome).
    private func transportRow(for track: Track) -> some View {
        let liveRadio = isLiveRadio(track)
        let showSkipIntervals = player.showSkipIntervalButtons
        return HStack {
            Spacer(minLength: 0)
            HStack(spacing: showSkipIntervals ? 16 : 30) {
                if showSkipIntervals {
                    transportButton(
                        systemName: "gobackward.\(Int(app.skipBackwardInterval.rawValue))",
                        fontSize: 22,
                        frameWidth: 44,
                        isEnabled: !liveRadio,
                    ) {
                        player.skipBackward()
                    }
                }

                transportButton(
                    systemName: "backward.fill",
                    fontSize: 27,
                    frameWidth: 56,
                    isEnabled: !liveRadio,
                    bouncePulse: prevTapPulse,
                    bouncesBackward: true,
                ) {
                    prevTapPulse += 1
                    player.skipPrevious()
                }

                if player.isBuffering {
                    // Audio isn't progressing — show the buffering spinner instead
                    // of a pause glyph that implies sound is playing. Still tappable
                    // so the user can cancel the pending play.
                    Button {
                        player.togglePlayPause()
                    } label: {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(fgPrimary)
                            .frame(width: 64, height: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportPressButtonStyle())
                } else {
                    transportButton(
                        systemName: player.isPlaying ? "pause.fill" : "play.fill",
                        fontSize: 37,
                        frameWidth: 64,
                        isEnabled: true,
                        symbolReplace: true,
                    ) {
                        player.togglePlayPause()
                    }
                }

                transportButton(
                    systemName: "forward.fill",
                    fontSize: 27,
                    frameWidth: 56,
                    isEnabled: !liveRadio,
                    bouncePulse: nextTapPulse,
                ) {
                    nextTapPulse += 1
                    player.skipNext()
                }

                if showSkipIntervals {
                    transportButton(
                        systemName: "goforward.\(Int(app.skipForwardInterval.rawValue))",
                        fontSize: 22,
                        frameWidth: 44,
                        isEnabled: !liveRadio,
                    ) {
                        player.skipForward()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        systemName: String,
        fontSize: CGFloat,
        frameWidth: CGFloat,
        frameHeight: CGFloat = 56,
        isEnabled: Bool,
        symbolReplace: Bool = false,
        bouncePulse: Int? = nil,
        bouncesBackward: Bool = false,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Group {
                if let bouncePulse {
                    // Skip buttons render the two-triangle "march" glyph so the
                    // tap can play the Lock Screen skip animation (one triangle
                    // slides off in the skip direction while a new one grows in
                    // on the other side). Not achievable as a symbolEffect.
                    SkipMarchGlyph(
                        pointsForward: !bouncesBackward,
                        fontSize: fontSize,
                        color: isEnabled ? fgPrimary : fgMuted,
                        pulse: bouncePulse,
                    )
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(isEnabled ? fgPrimary : fgMuted)
                        // Smoothly morph play.fill ↔ pause.fill instead of hard-swapping.
                        .contentTransition(symbolReplace ? .symbolEffect(.replace) : .identity)
                        .animation(symbolReplace ? .smooth(duration: 0.22) : nil, value: systemName)
                }
            }
            .frame(width: frameWidth, height: frameHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportPressButtonStyle())
        .disabled(!isEnabled)
    }

    private var shuffleRepeatRow: some View {
        let liveRadio = player.activeTrack.map(isLiveRadio) == true
        return HStack(spacing: 10) {
            queueModeToggle(
                systemName: "shuffle",
                isActive: player.isQueueOutOfNaturalOrder,
                isEnabled: !liveRadio,
                action: { player.toggleShuffle() },
            )
            queueModeToggle(
                systemName: player.repeatMode == .one ? "repeat.1" : "repeat",
                isActive: player.repeatMode != .off,
                isEnabled: !liveRadio,
                action: { player.cycleRepeat() },
            )
            queueModeToggle(
                label: PlaybackRateOption.nearest(to: player.playbackRate).title,
                isActive: abs(player.playbackRate - 1.0) > 0.01,
                isEnabled: !liveRadio,
                action: {
                    player.cyclePlaybackRate()
                    app.showTransientToast(PlaybackRateOption.nearest(to: player.playbackRate).title)
                },
            )
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.2), value: player.shuffleMode)
        .animation(.easeInOut(duration: 0.2), value: player.repeatMode)
        .animation(.easeInOut(duration: 0.2), value: player.playbackRate)
    }

    private func queueModeToggle(
        systemName: String? = nil,
        label: String? = nil,
        isActive: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
    ) -> some View {
        let chrome = queueModeToggleChrome(isActive: isEnabled && isActive)
        return Button(action: action) {
            Group {
                if let label {
                    Text(label)
                        .font(.system(size: 14, weight: isActive && isEnabled ? .bold : .semibold))
                        .monospacedDigit()
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: isActive && isEnabled ? .bold : .semibold))
                }
            }
            .foregroundStyle(isEnabled ? chrome.foreground : fgMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Capsule(style: .continuous).fill(isEnabled ? chrome.background : fgCapsule.opacity(0.65)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isActive && isEnabled ? .isSelected : [])
        .accessibilityLabel(label.map { "Playback speed, \($0)" } ?? systemName ?? "Mode")
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

    private func nowPlayingBottomChrome(track: Track) -> some View {
        let liveRadio = isLiveRadio(track)
        // Spacing measured off Apple Music's plain player: outer icons sit at
        // ~0.23 of the screen width (c2c ≈ 109pt on a 402pt screen).
        return HStack(spacing: player.showSleepTimerButton ? 48 : 64) {
            bottomChromeIconButton(
                showLyrics ? "quote.bubble.fill" : "quote.bubble",
                isActive: showLyrics,
                isEnabled: !liveRadio,
                iconFont: .system(size: 20, weight: .semibold),
            ) {
                queueArtworkHandedOff = false
                withAnimation(.spring(duration: 0.46, bounce: 0.16)) {
                    showLyrics.toggle()
                    if showLyrics { showQueue = false }
                }
            }
            if player.showSleepTimerButton {
                if player.sleepTimerEndDate != nil {
                    bottomChromeIconButton(
                        "moon.fill",
                        isActive: true,
                        iconFont: .system(size: 20, weight: .semibold),
                    ) {
                        player.cancelSleepTimer()
                        app.showTransientToast("Sleep timer canceled")
                    }
                } else {
                    Menu {
                        sleepTimerOverflowMenuContent
                    } label: {
                        bottomChromeIconLabel(
                            "moon",
                            isActive: false,
                            iconFont: .system(size: 20, weight: .semibold),
                        )
                    }
                    .menuOrder(.fixed)
                }
            }
            #if os(iOS)
            AirPlayRoutePickerView(tint: fgAccentChrome, activeTint: fgAccentChrome)
                .frame(width: 46, height: 46)
            #endif
            bottomChromeIconButton(
                "list.bullet",
                isActive: showQueue,
                isEnabled: !liveRadio,
                iconFont: .system(size: 20, weight: .semibold),
            ) {
                if showQueue {
                    // Closing: hide the row's artwork so the floating header artwork
                    // takes the slot back and morphs to big.
                    queueArtworkHandedOff = false
                    withAnimation(.spring(duration: 0.46, bounce: 0.16)) {
                        showQueue = false
                    }
                } else {
                    queueArtworkHandedOff = false
                    withAnimation(.spring(duration: 0.46, bounce: 0.16)) {
                        showQueue = true
                        showLyrics = false
                    } completion: {
                        // Morph landed: hand off to the row's own artwork (instant).
                        if showQueue { queueArtworkHandedOff = true }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Native overflow menu for sleep timer durations — same `Menu` / `Section`
    /// shape as the Now Playing track ellipsis and chart row overflow panels.
    @ViewBuilder
    private var sleepTimerOverflowMenuContent: some View {
        Section {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    startSleepTimer(minutes: minutes)
                } label: {
                    Label("\(minutes) minutes", systemImage: "moon.zzz")
                }
            }
        }
        .tint(Color.primary)
    }

    private func startSleepTimer(minutes: Int) {
        player.startSleepTimer(minutes: minutes)
        app.showTransientToast("Sleep timer · \(minutes) min")
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
        isEnabled: Bool = true,
        iconFont: Font = .title2,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            bottomChromeIconLabel(
                systemName,
                isActive: isActive && isEnabled,
                isEnabled: isEnabled,
                iconFont: iconFont,
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func bottomChromeIconLabel(
        _ systemName: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        iconFont: Font = .title2,
    ) -> some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(fgBottomGlow)
                    .frame(width: 40, height: 40)
            }
            Image(systemName: systemName)
                .font(iconFont)
                .foregroundStyle(isEnabled ? fgAccentChrome : fgMuted)
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }

    private func queueRow(track: Track) -> some View {
        HStack(spacing: 12) {
            artworkView(
                for: track,
                cornerRadius: 4,
                maxDecodePixels: Self.rowArtworkDecodePixels,
            )
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
    /// Per-tick clock — the engine itself no longer publishes time updates, so
    /// the scrubber subscribes to the dedicated time model for live progress.
    @ObservedObject var time: PlaybackTimeModel
    let backdropPalette: ArtworkDynamicGradient.BackdropPalette
    var isEnabled: Bool = true

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    private var timeLabelColor: Color {
        isEnabled ? backdropPalette.nowPlayingTimeLabel : backdropPalette.nowPlayingTimeLabel.opacity(0.38)
    }

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
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                NowPlayingMatchedTrackBar(
                    fraction: CGFloat(displayFraction),
                    enlarged: isScrubbing,
                    backdropPalette: backdropPalette,
                    isEnabled: isEnabled,
                )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEnabled else { return }
                                if !isScrubbing { isScrubbing = true }
                                scrubFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                guard isEnabled else { return }
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
            .allowsHitTesting(isEnabled)
            // A diagonal seek must stay a seek. Without this the window-level dismiss pan sees
            // a downward-ish drag outside any scroll view and starts closing the player.
            .nowPlayingDismissExclusionZone()

            HStack {
                Text(formatTime(displayTime))
                Spacer()
                Text("−" + formatTime(max(0, effectiveDuration - displayTime)))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(timeLabelColor)
            .monospacedDigit()
            .animation(nil, value: displayTime)
            // Delivered-format badge, centered between the time labels the way
            // Apple Music centers "Dolby Atmos" / "Lossless" under the scrubber.
            .overlay {
                if let format = player.nowPlayingFormatLabel {
                    Text(format)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(timeLabelColor)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
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
    var isEnabled: Bool = true

    var body: some View {
        let barHeight = enlarged ? NowPlayingScrubberMetrics.slotHeight : NowPlayingScrubberMetrics.barHeight
        let clamped = min(max(fraction, 0), 1)
        let dimFill = backdropPalette.nowPlayingScrubberTrackFill
        let progressFill = backdropPalette.nowPlayingScrubberProgressFill
        let strokeColor = backdropPalette.nowPlayingScrubberStroke
        let barOpacity = isEnabled ? 1.0 : 0.38
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
            .opacity(barOpacity)
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
        // Identities of the cells the reorder walk last ran over. `contentOffset` fires on every
        // display-link tick while the queue scrolls or pages, and the walk below is a
        // `String(describing:)` over every subview of every visible cell — so the tint was being
        // re-derived at 120Hz to reapply a colour that had not changed, which is the cost that
        // showed up as stutter on a long queue. The tint only ever needs reapplying when the set
        // of visible cells changes, and comparing identities catches every case that matters:
        // a cell scrolling in, one scrolling out, and a recycled cell arriving with a reorder
        // control that has not been tinted yet.
        private var lastStyledCells: [ObjectIdentifier] = []

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
            // The tint itself may have changed here, so the cached cell set cannot stand in for
            // "already the right colour".
            lastStyledCells = []
            styleReorderControls(in: table)
        }

        private func styleReorderControls(in table: UITableView) {
            let cells = table.visibleCells
            let identities = cells.map(ObjectIdentifier.init)
            guard identities != lastStyledCells else { return }
            lastStyledCells = identities
            for cell in cells {
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
            // Same reason as ``ScrubberBlock``: a diagonal volume drag must not become a dismiss.
            .nowPlayingDismissExclusionZone()

            Image(systemName: "speaker.wave.3.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(backdropPalette.nowPlayingVolumeGlyph)
                .frame(width: 20, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .onAppear {
            // The `setActive(true)` that used to sit here is gone: it was a third synchronous
            // `mediaserverd` round trip on every player open, on top of the two the engine
            // already did, and it was unconditional — unlike the lyrics and queue panes, this
            // block is not behind a mode flag, so it ran whether or not anyone touched the
            // volume bar. `PlaybackEngine.reconcilePlaybackSessionAfterUIMilestone()` activates
            // the session on the same open, so there was nothing left for this one to do.
            //
            // The volume read stays. `HiddenSystemVolumeBridge` does KVO `outputVolume` and
            // would catch any *change*, but the player's hosting controller is reused rather
            // than rebuilt, so this `@State` survives between opens — and seeding it here is
            // what guarantees the slider is in the right place the moment the player appears
            // rather than a frame later. It is a property read, not a session round trip.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Index into `displayItems` of the currently active row. Mirrored as
    /// `@State` (vs. computed) so SwiftUI consistently re-renders styling and
    /// fires `.onChange(of: activeIndex)` for scroll. Driven by two sources:
    /// the coarse `player.$currentTime` publisher (re-sync/correction) and
    /// `runLineFlipScheduler()` (frame-accurate flips on line boundaries).
    @State private var activeIndex: Int = 0

    /// Wall-clock anchor for the extrapolated playhead. The engine's periodic
    /// observer only ticks every ~0.35 s — visibly late for beat-accurate line
    /// flips and far too coarse for a smooth silence-dot fill. Each tick
    /// re-anchors; between ticks `estimatedTime(at:)` projects forward at the
    /// current playback rate.
    @State private var clockAnchor = PlaybackClockAnchor(time: 0, date: .distantPast)

    /// `lines` interleaved with silence markers for instrumental gaps.
    /// Recomputed only when the underlying `lines` change.
    @State private var displayItems: [LyricRenderItem] = []

    /// True while the user is browsing the lyrics by hand. Auto-scroll is
    /// suspended and the distance blur is lifted so every line is readable
    /// (Apple Music behaviour); ~3 s after the finger lifts we spring back to
    /// the active line.
    @State private var isUserBrowsing = false
    @State private var browseGeneration = 0
    @State private var scrollPhaseIsSettled = true

    /// True when the source has no per-line timestamps (every `start` is 0).
    /// Jellyfin returns plain-text lyrics this way; render the lines but skip
    /// sync, silence dots, and tap-to-seek so the view doesn't pin the
    /// highlight to a bogus row.
    private var isUnsynced: Bool {
        !lines.lyricsAppearSynced
    }

    /// Threshold (seconds) for inserting a silence marker between two lines.
    /// Apple Music shows dots for instrumental gaps roughly this long.
    private static let silenceThreshold: TimeInterval = 5
    /// Heuristic for how long a typical lyric line is sung; we only count gap
    /// time *after* this offset as silence, so a normal vocal pause doesn't
    /// sprout dots.
    private static let typicalLineDuration: TimeInterval = 3

    /// One size for every synced line — emphasis comes from opacity, blur and
    /// a leading-anchored scale pop, never from font jumps (font changes
    /// re-wrap the text and make the whole column jitter on each flip).
    private static let syncedLineFont = Font.system(size: 28, weight: .bold)

    /// Signature Apple-Music-style motion for line flips + auto-scroll.
    private var focusSpring: Animation { .spring(response: 0.55, dampingFraction: 0.85) }

    private struct PlaybackClockAnchor: Equatable {
        var time: TimeInterval
        var date: Date
    }

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

    private var scrollAnchor: UnitPoint { UnitPoint(x: 0.5, y: 0.35) }

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
            reanchorClock()
            syncActiveIndex(to: estimatedNow(), animated: false)
        }
        .onChange(of: lines.map(\.id)) { _, _ in
            displayItems = Self.buildDisplayItems(from: lines)
            reanchorClock()
            syncActiveIndex(to: estimatedNow(), animated: false)
        }
        .onReceive(player.time.$currentTime) { _ in
            // `currentTime` is UI-throttled; use it only as a publisher tick
            // and sample the fresher `livePlaybackTime` for sync accuracy.
            reanchorClock()
            syncActiveIndex(to: estimatedNow())
        }
        .onChange(of: player.isPlaying) { _, _ in
            reanchorClock()
            syncActiveIndex(to: estimatedNow())
        }
        .task(id: lineFlipSchedulerKey) {
            await runLineFlipScheduler()
        }
    }

    // MARK: Extrapolated playback clock

    private func reanchorClock() {
        clockAnchor = PlaybackClockAnchor(time: player.livePlaybackTime, date: Date())
    }

    /// Playhead projected forward from the last observer tick at the current
    /// rate. Capped so a stalled observer (e.g. route change hiccup) can't
    /// run the estimate away from reality.
    private func estimatedTime(at date: Date) -> TimeInterval {
        guard player.isPlaying else { return clockAnchor.time }
        let elapsed = date.timeIntervalSince(clockAnchor.date)
        guard elapsed > 0 else { return clockAnchor.time }
        return clockAnchor.time + min(elapsed, 3.0) * Double(player.playbackRate)
    }

    private func estimatedNow() -> TimeInterval {
        estimatedTime(at: Date())
    }

    // MARK: Frame-accurate line flips

    /// Restart key: any re-anchor (observer tick, seek, play/pause) or item
    /// rebuild cancels the in-flight sleep and reschedules from fresh state.
    private var lineFlipSchedulerKey: String {
        "\(clockAnchor.date.timeIntervalSinceReferenceDate)-\(player.isPlaying)-\(displayItems.count)-\(isUnsynced)"
    }

    /// Sleeps until the next row boundary and flips `activeIndex` exactly on
    /// it, instead of waiting out the coarse observer tick. The publisher
    /// tick that follows re-anchors and restarts this task, correcting any
    /// extrapolation drift.
    private func runLineFlipScheduler() async {
        guard !isUnsynced, player.isPlaying, !displayItems.isEmpty else { return }
        while !Task.isCancelled {
            let now = estimatedNow()
            guard let next = displayItems.first(where: { $0.start > now + 0.08 })?.start else { return }
            let delay = next - now
            try? await Task.sleep(for: .seconds(max(delay, 0.05)))
            if Task.isCancelled { return }
            syncActiveIndex(to: estimatedNow())
        }
    }

    private func syncActiveIndex(to time: TimeInterval, animated: Bool = true) {
        guard !isUnsynced else {
            if activeIndex != 0 { activeIndex = 0 }
            return
        }
        let newIndex = Self.computeActiveIndex(at: time, in: displayItems)
        guard newIndex != activeIndex else { return }
        if animated && !reduceMotion {
            withAnimation(focusSpring) { activeIndex = newIndex }
        } else {
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
                // Lazy, because this was an eager `VStack`: every line of the song was
                // instantiated regardless of the viewport, and each line carries its own
                // `.blur()` — one offscreen Gaussian pass per line, for the whole song. That
                // cost is paid again whenever the player is snapshotted or rebuilt with the
                // lyrics pane open. `.id()` and the `scrollTo` calls below are unchanged, which
                // is what keeps the focus scrolling working.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        renderItemView(item, index: index)
                            .id(item.id)
                            .padding(.bottom, spacingAfterItem(at: index))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 120)
            }
            .onScrollPhaseChange { _, newPhase in
                handleScrollPhaseChange(newPhase)
            }
            .onAppear {
                scrollToActiveItem(proxy: proxy, animated: false)
            }
            .onChange(of: activeIndex) { _, _ in
                guard !isUnsynced, !isUserBrowsing else { return }
                scrollToActiveItem(proxy: proxy, animated: true)
            }
            .onChange(of: displayItems.map(\.id)) { _, _ in
                scrollToActiveItem(proxy: proxy, animated: false)
            }
            .onChange(of: isUserBrowsing) { _, browsing in
                guard !browsing else { return }
                scrollToActiveItem(proxy: proxy, animated: true)
            }
            .task(id: browseGeneration) {
                // Resume countdown: only once the finger is up and the scroll
                // has settled. Any new touch bumps the generation and cancels.
                guard isUserBrowsing, scrollPhaseIsSettled else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    isUserBrowsing = false
                } else {
                    withAnimation(focusSpring) { isUserBrowsing = false }
                }
            }
        }
    }

    private func handleScrollPhaseChange(_ phase: ScrollPhase) {
        guard !isUnsynced else { return }
        switch phase {
        case .tracking, .interacting, .decelerating:
            scrollPhaseIsSettled = false
            if !isUserBrowsing {
                if reduceMotion {
                    isUserBrowsing = true
                } else {
                    withAnimation(focusSpring) { isUserBrowsing = true }
                }
            }
            browseGeneration += 1
        case .idle:
            scrollPhaseIsSettled = true
            if isUserBrowsing { browseGeneration += 1 }
        default:
            break
        }
    }

    private func scrollToActiveItem(proxy: ScrollViewProxy, animated: Bool) {
        guard displayItems.indices.contains(activeIndex) else { return }
        let id = displayItems[activeIndex].id
        if animated && !reduceMotion {
            withAnimation(focusSpring) {
                proxy.scrollTo(id, anchor: scrollAnchor)
            }
        } else {
            proxy.scrollTo(id, anchor: scrollAnchor)
        }
    }

    private func seekToLine(_ line: LyricLine, index: Int) {
        player.seek(toSeconds: line.start)
        // Snap the local clock immediately — waiting for the next publisher
        // tick would leave the highlight on the old line for up to ~0.35 s.
        clockAnchor = PlaybackClockAnchor(time: line.start, date: Date())
        if reduceMotion {
            isUserBrowsing = false
            activeIndex = index
        } else {
            withAnimation(focusSpring) {
                isUserBrowsing = false
                activeIndex = index
            }
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
        let isActive = distance == 0

        Text(line.text)
            .font(isUnsynced ? .title2.weight(.bold) : Self.syncedLineFont)
            .foregroundStyle(isUnsynced ? primaryColor : primaryColor.opacity(opacity(for: distance)))
            .blur(radius: (isUnsynced || isUserBrowsing) ? 0 : blur(for: distance))
            .scaleEffect(
                (isUnsynced || reduceMotion) ? 1 : (isActive ? 1.0 : 0.92),
                anchor: .leading,
            )
            .opacity(isUnsynced ? 0.92 : 1)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isUnsynced else { return }
                seekToLine(line, index: index)
            }
    }

    @ViewBuilder
    private func silenceMarkerView(start: TimeInterval, end: TimeInterval, index: Int) -> some View {
        // Apple Music only materialises the gap dots while the gap is live —
        // inactive gaps contribute nothing to the scroll. The row itself stays
        // in the ForEach (stable ids for scroll targeting); its content
        // springs in and out.
        let isActive = !isUnsynced && index == activeIndex

        Group {
            if isActive {
                SilenceBreathingDots(
                    start: start,
                    end: end,
                    color: primaryColor,
                    isPlaying: player.isPlaying,
                    reduceMotion: reduceMotion,
                    timeProvider: { estimatedTime(at: $0) },
                )
                .transition(
                    .opacity.combined(with: .scale(scale: 0.4, anchor: .leading))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isActive else { return }
            player.seek(toSeconds: start)
            clockAnchor = PlaybackClockAnchor(time: start, date: Date())
        }
    }

    private func spacingAfterItem(at index: Int) -> CGFloat {
        guard !isUnsynced else { return 14 }
        // Collapsed (inactive) silence rows must not leave a phantom gap.
        if case .silence = displayItems[index], index != activeIndex { return 0 }
        return index == activeIndex ? 30 : 22
    }

    private func opacity(for distance: Int) -> Double {
        if isUserBrowsing { return distance == 0 ? 1 : 0.72 }
        switch distance {
        case ..<0: return 0.3
        case 0: return 1
        case 1: return 0.58
        case 2: return 0.44
        case 3: return 0.34
        default: return 0.26
        }
    }

    private func blur(for distance: Int) -> CGFloat {
        guard distance != 0 else { return 0 }
        return min(CGFloat(abs(distance)) * 0.9, 4.5)
    }
}

/// Apple-Music-style instrumental-gap dots: three dots that fill smoothly
/// left-to-right as the gap elapses, breathe gently while waiting, then swell
/// and fade out just before the next line lands. Runs on a `TimelineView`
/// animation schedule (paused when playback is paused) so the fill is
/// per-frame smooth instead of stepping on the coarse observer tick.
/// Which paged queue section is currently snapped.
enum QueueScrollAnchor: Hashable {
    case historyTop, nowPlayingHeader
}

/// The queue pager's snap position, isolated from ``NowPlayingView``'s `objectWillChange`.
///
/// See the comment on `NowPlayingView.queuePageAnchor` for why this is its own object.
@MainActor
final class QueuePageAnchorModel: ObservableObject {
    @Published var anchor: QueueScrollAnchor? = .nowPlayingHeader
    /// Last anchor that fired a haptic. Deliberately **not** `@Published`: it is bookkeeping for
    /// the impact below, and publishing it would cause a second render for no visible reason.
    var lastHapticAnchor: QueueScrollAnchor? = .nowPlayingHeader
}

/// The two-page vertical pager inside the queue (History above, Now Playing + Up Next below).
///
/// Exists so that a page settle invalidates this view instead of the whole ~2,800-line player
/// body. The pages themselves are passed in as builders, so their content is still assembled by
/// `NowPlayingView` — this owns only the scroll container and the snap position.
private struct QueuePagingScroll<History: View, NowPlaying: View>: View {
    @ObservedObject var model: QueuePageAnchorModel
    @ViewBuilder var history: () -> History
    @ViewBuilder var nowPlaying: () -> NowPlaying

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                history()
                    .containerRelativeFrame(.vertical)
                    .id(QueueScrollAnchor.historyTop)
                nowPlaying()
                    .containerRelativeFrame(.vertical)
                    .id(QueueScrollAnchor.nowPlayingHeader)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $model.anchor)
        .onChange(of: model.anchor) { _, new in
            guard let new, new != model.lastHapticAnchor else { return }
            model.lastHapticAnchor = new
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
        }
    }
}

private struct SilenceBreathingDots: View {
    let start: TimeInterval
    let end: TimeInterval
    let color: Color
    let isPlaying: Bool
    let reduceMotion: Bool
    let timeProvider: (Date) -> TimeInterval

    /// Final swell-and-vanish window before the next line takes over.
    private var handoffLead: TimeInterval {
        min(1.0, max(0.35, (end - start) * 0.12))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let t = timeProvider(context.date)
            let fillEnd = end - handoffLead
            let fillProgress = fillEnd > start
                ? min(max((t - start) / (fillEnd - start), 0), 1)
                : 1.0
            let exitProgress = min(max((t - fillEnd) / handoffLead, 0), 1)
            let breathePhase = reduceMotion
                ? 0.0
                : max(0, t - start).truncatingRemainder(dividingBy: 2.4) / 2.4 * 2 * .pi

            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { i in
                    let dotFill = min(max(fillProgress * 3 - Double(i), 0), 1)
                    Circle()
                        .fill(color)
                        .frame(width: 11, height: 11)
                        .opacity((0.25 + 0.75 * dotFill) * (1 - exitProgress))
                        .scaleEffect(dotScale(dot: i, dotFill: dotFill, breathePhase: breathePhase))
                }
            }
            .scaleEffect(groupScale(exit: exitProgress), anchor: .leading)
        }
        .frame(height: 22, alignment: .leading)
    }

    private func dotScale(dot i: Int, dotFill: Double, breathePhase: Double) -> CGFloat {
        guard !reduceMotion else { return 1 }
        // Gentle out-of-phase breathing plus a slight grow as each dot fills.
        let breathe = 0.05 * sin(breathePhase + Double(i) * 0.9)
        return CGFloat(1 + breathe + 0.12 * dotFill)
    }

    private func groupScale(exit: Double) -> CGFloat {
        guard exit > 0, !reduceMotion else { return 1 }
        // Swell slightly, then shrink away as the next line takes over.
        if exit < 0.4 { return 1 + 0.18 * CGFloat(exit / 0.4) }
        return 1.18 - 0.5 * CGFloat((exit - 0.4) / 0.6)
    }
}
