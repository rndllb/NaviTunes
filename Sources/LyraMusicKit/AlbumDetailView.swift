import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Apple Music–style **library** album page: server track list only (no MusicBrainz catalog merge).
/// For chart/discovery releases with optional MB tracklist + Downtify, use ``BrowseAlbumDetailView``.
struct AlbumDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    let album: AlbumSummary
    /// When set (e.g. deep-linked from Downtify), scrolls the tracklist to this item after load.
    var scrollToTrackId: String? = nil
    /// `true` when the user navigated here from a library surface (Library tab, library
    /// playlist, etc.). Enables the Apple-Music behavior of filtering the tracklist to
    /// only the songs the user has added, with a "Show Complete Album" toggle. Outside
    /// the library (Home, search, discovery) the tracklist always shows the full album.
    var librarySource: Bool = false

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var isDownloadingAll = false
    @State private var toast: String?
    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback
    @State private var didScrollToFocusTrack = false
    /// When the album is in the user's Lyra library, the tracklist defaults to the
    /// subset they actually added; flipping this exposes the full album so they can
    /// add the rest (matches Apple Music behavior).
    @State private var showCompleteAlbum: Bool = false

    private var heroArtSide: CGFloat {
        let w: CGFloat = {
#if os(iOS)
            UIScreen.main.bounds.width
#else
            800
#endif
        }()
        return min(max(w - 52, 260), 320)
    }

    private var metadataDetailLine: String {
        AlbumHeroMetadataLine.compose(album: album, tracks: orderedTracks)
    }

    private var totalDurationSeconds: TimeInterval {
        tracks.reduce(0) { $0 + max($1.duration, 0) }
    }

    /// All album tracks in playback order, ignoring library membership. Drives playback
    /// actions (Play / Shuffle / Download All) so those always operate on the full album.
    private var allOrderedTracks: [Track] {
        tracks.sorted { lhs, rhs in
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            return lhs.indexNumber < rhs.indexNumber
        }
    }

    /// `true` when the album is in the user's library and the user hasn't flipped the
    /// "Show Complete Album" toggle. While true, the tracklist filters to just the
    /// songs the user has actually added to their library. Only effective when the
    /// view was reached from a library entry point — outside library (Home, browse,
    /// search) we always show the full album.
    private var isFilteredToLibraryTracks: Bool {
        librarySource
            && app.isAlbumInLibrary(album.id)
            && !showCompleteAlbum
            && libraryTracksInAlbum.count < allOrderedTracks.count
    }

    private var libraryTracksInAlbum: [Track] {
        allOrderedTracks.filter { app.isSongInLibrary($0.id) }
    }

    /// Visible tracklist for the UI. Filters when the album is in library and the user
    /// hasn't asked to see the complete album.
    private var orderedTracks: [Track] {
        guard isFilteredToLibraryTracks else { return allOrderedTracks }
        let filtered = libraryTracksInAlbum
        // Defensive: if the filter would zero the list (shouldn't happen because
        // isFilteredToLibraryTracks requires > 0), fall through to showing everything.
        return filtered.isEmpty ? allOrderedTracks : filtered
    }

    /// Toolbar ⋯ leading control — cache all tracks for offline (same as hero download-all).
    private var albumTracksAllSavedOffline: Bool {
        !orderedTracks.isEmpty && orderedTracks.allSatisfy { app.offline.downloadedTrackIds.contains($0.id) }
    }

    private var albumOfflineLeadingAction: (() -> Void)? {
        guard app.isSignedIn, !orderedTracks.isEmpty, app.activeLibrary != nil else { return nil }
        return {
            Task { await downloadAllTracks() }
        }
    }

    private var displayArtworkURL: URL? {
        app.resolvedArtworkURL(for: album)
    }

    var body: some View {
        ZStack(alignment: .top) {
            AlbumHeroBackdropView(artworkURL: displayArtworkURL, palette: backdropPalette)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        heroBlock
                        AppleMusicAlbumTrackDivider(palette: backdropPalette)
                            .padding(.top, 22)

                        tracklistBlock
                        footerBlock
                    }
                    .padding(.bottom, 36)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: tracks.map(\.id)) { _, _ in
                    scrollToFocusedTrackIfNeeded(proxy: proxy)
                }
            }
        }
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .musicHeroAlbumNavigationChrome(palette: backdropPalette)
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                if let url = displayArtworkURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(backdropPalette.heroChromePrimary)
                    }
                }
                AlbumToolbarOverflowMenu(
                    shareItem: "\(album.title) — \(album.artist)",
                    playlistTracks: orderedTracks,
                    onLeading: albumOfflineLeadingAction,
                    leadingDisabled: albumTracksAllSavedOffline,
                    leadingTitle: "Offline (download for offline use)",
                    leadingSystemImage: "arrow.down.circle",
                    ellipsisTint: backdropPalette.heroChromePrimary
                )
            }
        }
        .task { await load() }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await load() }
        }
        .task(id: displayArtworkURL?.absoluteString ?? "") {
            let p = await ArtworkDynamicGradient.analyzeBackdrop(from: displayArtworkURL)
            await MainActor.run { backdropPalette = p }
        }
        .overlay {
            if isLoading, tracks.isEmpty {
                ProgressView()
                    .tint(MusicDesign.accent)
                    .scaleEffect(1.1)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(MusicDesign.chromeCapsuleFill)
                    )
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private var heroBlock: some View {
        VStack(spacing: 18) {
            AlbumArtworkView(url: displayArtworkURL, cornerRadius: 14)
                .frame(width: heroArtSide, height: heroArtSide)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 8) {
                Text(album.title)
                    .font(.system(size: 26, weight: .bold, design: .default))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Text(album.artist)
                    .font(.title3.weight(.regular))
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                if !metadataDetailLine.isEmpty {
                    Text(metadataDetailLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(backdropPalette.heroChromeTertiary)
                        .multilineTextAlignment(.center)
                }
            }

            actionButtonTriplet
                .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    private var actionIconColor: Color { backdropPalette.heroGlassIcon }
    private var actionCircleFill: Color { backdropPalette.heroGlassCircleFill }

    /// Right-hand action in the hero triplet. Switches between "Add to Library" (album not
    /// in user's library) and "Download All" (album in library, fetch remaining tracks to
    /// device). When everything is already cached or no tracks loaded, the button is
    /// disabled but stays in the same slot so layout doesn't shift.
    @ViewBuilder
    private var albumPrimaryActionButton: some View {
        let inLibrary = app.isAlbumInLibrary(album.id)
        let allDownloaded = albumTracksAllSavedOffline
        let isDisabled = tracks.isEmpty || isDownloadingAll || (inLibrary && allDownloaded)
        Button {
            if inLibrary {
                Task { await downloadAllTracks() }
            } else {
                Task { await app.addAlbumToLibrary(album, tracks: tracks) }
            }
        } label: {
            Group {
                if isDownloadingAll {
                    ProgressView()
                        .tint(actionIconColor)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: inLibrary ? "arrow.down" : "plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                            isDisabled ? actionIconColor.opacity(0.35) : actionIconColor,
                        )
                }
            }
            .frame(width: 54, height: 54)
            .background(
                Circle().fill(
                    isDisabled
                        ? backdropPalette.heroGlassCircleFillDisabled
                        : backdropPalette.heroGlassCircleFill,
                ),
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(inLibrary ? "Download album" : "Add to library")
    }

    private var actionButtonTriplet: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button {
                    Task { await playShuffled() }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(actionIconColor)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(actionCircleFill))
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)

                Button {
                    Task { await play(startingAt: orderedTracks.first) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(backdropPalette.heroPlayCapsuleForeground)
                        .padding(.vertical, 14)
                        .frame(width: MusicDesign.albumHeroPrimaryCapsuleWidth)
                        .background(Capsule().fill(backdropPalette.heroPlayCapsuleBackground))
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)

                albumPrimaryActionButton
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    private var tracklistBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = orderedTracks
            if rows.isEmpty {
                if !isLoading {
                    Text("No tracks returned for this album.")
                        .font(.subheadline)
                        .foregroundStyle(backdropPalette.heroChromeSecondary.opacity(0.9))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 20)
                }
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, track in
                    VStack(spacing: 0) {
                        AppleMusicAlbumTrackRow(
                            index: index + 1,
                            title: track.title,
                            subtitle: track.artist == album.artist || track.artist.isEmpty ? nil : track.artist,
                            isFavorite: app.favoriteTrackIds.contains(track.id),
                            offlineDownload: offline.activeDownloads[track.id],
                            isOfflineCached: app.offline.downloadedTrackIds.contains(track.id),
                            isInLibrary: app.isSongInLibrary(track.id),
                            onCancelOfflineDownload: {
                                app.offline.cancelDownload(trackId: track.id)
                            },
                            onTapStartOfflineDownload: {
                                Task {
                                    guard let lib = app.activeLibrary else { return }
                                    try? await cache(track: track, lib: lib)
                                }
                            },
                            onTapAddToLibrary: {
                                Task { await app.addSongToLibrary(track) }
                            },
                            backdropPalette: backdropPalette,
                            onRowTap: {
                                Task { await play(startingAt: track) }
                            },
                            menuContent: { libraryTrackOverflowMenu(track: track) }
                        )
                        .id(track.id)
                        if index < rows.count - 1 {
                            AppleMusicAlbumTrackDivider(palette: backdropPalette)
                        }
                    }
                }
                showCompleteAlbumToggle
            }
        }
        .padding(.top, 6)
    }

    /// Tracklist footer toggle — only present when the album is in the user's library
    /// and some of its tracks are not, AND the view is being shown from a library
    /// entry point. Flipping it reveals the rest of the album so the user can add
    /// more songs without leaving the page.
    @ViewBuilder
    private var showCompleteAlbumToggle: some View {
        let inLibrary = app.isAlbumInLibrary(album.id)
        let hasHiddenTracks = libraryTracksInAlbum.count < allOrderedTracks.count
        if librarySource, inLibrary, hasHiddenTracks {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showCompleteAlbum.toggle()
                    }
                } label: {
                    Text(showCompleteAlbum ? "Show Library Only" : "Show Complete Album")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(backdropPalette.heroChromePrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(backdropPalette.heroGlassCircleFill),
                        )
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .padding(.horizontal, 22)
        }
    }

    @ViewBuilder
    private func libraryTrackOverflowMenu(track: Track) -> some View {
        ControlGroup {
            if !app.isSongInLibrary(track.id) {
                // Per the Apple-Music model: adding a single song adds just that track
                // and registers its album in library (so the album appears in Library →
                // Albums with the song visible inside).
                Button {
                    Task { await app.addSongToLibrary(track) }
                } label: {
                    Label("Add to Library", systemImage: "plus")
                }
            } else if app.offline.downloadedTrackIds.contains(track.id) {
                Button {
                    try? app.offline.remove(trackId: track.id)
                } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                }
            } else {
                Button {
                    if let lib = app.activeLibrary {
                        Task { try? await cache(track: track, lib: lib) }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }
            }
            Button {
                app.toggleFavoriteTrack(id: track.id)
            } label: {
                Label(
                    app.favoriteTrackIds.contains(track.id) ? "Unfavorite" : "Favorite",
                    systemImage: app.favoriteTrackIds.contains(track.id) ? "star.fill" : "star"
                )
            }
            ShareLink(item: "\(track.title) — \(track.artist)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .tint(Color.primary)

        Section {
            Button {} label: { Label("Pin Song", systemImage: "pin") }
            Button {
                app.presentAddToPlaylist(tracks: [track])
            } label: {
                Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
            }
        }
        .tint(Color.primary)

        Section {
            Button {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playNext(library: lib, track: track)
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {} label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        }
        .tint(Color.primary)

        Section {
            Button {} label: { Label("View Credits", systemImage: "info.circle") }
        }
        .tint(Color.primary)

        Section {
            Button {} label: { Label("Suggest Less", systemImage: "hand.thumbsdown") }
        }
        .tint(Color.primary)

        Section {
            if app.isSongInLibrary(track.id) {
                // User-level: drops the song from the magic playlist tracks but leaves
                // the album entry in `comment.albums` intact (album stays in library,
                // just with one fewer track).
                Button(role: .destructive) {
                    Task { await app.removeSongFromLibrary(track) }
                } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
            }
            // Admin-only: removes the audio file from the server entirely.
            if app.canDeleteFromLibrary {
                Button(role: .destructive) {
                    app.beginLibraryTrackDeletion(track)
                } label: {
                    Label("Delete File from Server", systemImage: "xmark.bin")
                }
            }
        }
    }

    private var footerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let line = album.releaseFooterDisplayString {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
            }

            if !tracks.isEmpty {
                Text(footerDurationSummary)
                    .font(.subheadline)
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 22)
    }

    private var footerDurationSummary: String {
        let n = tracks.count
        let totalMin = max(1, Int(ceil(totalDurationSeconds / 60.0)))
        if n == 0 { return "No songs" }
        if n == 1 { return "1 song, \(totalMin) minutes" }
        return "\(n) songs, \(totalMin) minutes"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let offlineTracks = app.offline.cachedTracks(forAlbumId: album.id)
        if let lib = app.activeLibrary {
            do {
                let remote = try await lib.tracks(forAlbumId: album.id)
                tracks = remote.isEmpty ? offlineTracks : remote
                if tracks.isEmpty {
                    flashToast("No songs found for this album.")
                }
                return
            } catch {
                tracks = offlineTracks
                if tracks.isEmpty {
                    flashToast(error.musicPlaybackToastMessage)
                }
                return
            }
        }
        tracks = offlineTracks
        if tracks.isEmpty {
            flashToast("Sign in or download this album for offline playback.")
        }
    }

    private func play(startingAt track: Track?) async {
        let playback = orderedTracks
        guard !playback.isEmpty else {
            flashToast("No tracks loaded yet.")
            return
        }
        let idx: Int
        if let track, let i = playback.firstIndex(where: { $0.id == track.id }) {
            idx = i
        } else {
            idx = 0
        }
        do {
            try await app.player.playAlbum(library: app.activeLibrary, tracks: playback, startIndex: idx)
        } catch {
            flashToast(error.musicPlaybackToastMessage)
        }
    }

    private func playShuffled() async {
        guard !tracks.isEmpty else { return }
        let shuffled = orderedTracks.shuffled()
        do {
            try await app.player.playAlbum(library: app.activeLibrary, tracks: shuffled, startIndex: 0)
        } catch {
            flashToast(error.musicPlaybackToastMessage)
        }
    }

    private func cache(track: Track, lib: MusicLibraryProviding) async throws {
        let url = try lib.offlineDownloadURL(for: track)
        try await app.offline.cache(track: track, remote: url, headers: lib.httpHeadersForMediaRequests())
    }

    private func downloadAllTracks() async {
        guard let lib = app.activeLibrary, !tracks.isEmpty else { return }
        isDownloadingAll = true
        defer { isDownloadingAll = false }
        var succeeded = 0
        for track in orderedTracks {
            try? await cache(track: track, lib: lib)
            succeeded += 1
        }
        flashToast("\(succeeded) track\(succeeded == 1 ? "" : "s") downloaded")
    }

    private func flashToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            toast = nil
        }
    }

    private func scrollToFocusedTrackIfNeeded(proxy: ScrollViewProxy) {
        guard !didScrollToFocusTrack else { return }
        guard let id = scrollToTrackId else { return }
        guard tracks.contains(where: { $0.id == id }) else { return }
        didScrollToFocusTrack = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3))
            }
        }
    }
}
