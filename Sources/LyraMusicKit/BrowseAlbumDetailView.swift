import SwiftUI
#if os(iOS)
import UIKit
#endif


/// Apple Music-style album page for New tab rows (library match → Play; otherwise Request via Downtify).
struct BrowseAlbumDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    let source: BrowseAlbumDetailSource

    @State private var libraryTracks: [Track] = []
    @State private var previewTracks: [BrowseAlbumPreviewTrack] = []
    @State private var isLoadingTracks = false
    @State private var isLoadingPreviewTracks = false
    @State private var toast: String?
    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback
    @State private var isDownloading = false
    @State private var downloadingPreviewTrackIds: Set<String> = []
    @State private var previewDowntifyFraction: [String: Double] = [:]
    @State private var navigateLibraryAlbum: AlbumSummary?
    @State private var trackPendingDownloadedDelete: Track?

    private var matchedLibraryAlbum: AlbumSummary? {
        app.libraryAlbums.firstMatchingNewTabRelease(artist: matchArtist, albumTitle: matchAlbumTitle)
    }

    private var matchArtist: String {
        if case .chartBrowse(let a, _, _, _) = source { return a }
        return ""
    }

    private var matchAlbumTitle: String {
        if case .chartBrowse(_, let t, _, _) = source { return t }
        return ""
    }

    private var displayTitle: String { matchedLibraryAlbum?.title ?? matchAlbumTitle }
    private var displayArtist: String {
        if let a = matchedLibraryAlbum { return a.artist }
        let n = matchArtist
        return n.isEmpty ? "Unknown Artist" : n
    }

    private var displayArtworkURL: URL? {
        if let a = matchedLibraryAlbum { return a.artworkURL }
        if case .chartBrowse(_, _, let url, _) = source { return url }
        return nil
    }

    private var albumKindLabel: String {
        if case .chartBrowse(_, _, _, let kind) = source { return kind }
        return "Album"
    }

    private var metadataDetailLine: String {
        if let libAlbum = matchedLibraryAlbum {
            return AlbumHeroMetadataLine.compose(album: libAlbum, tracks: libraryTracks)
        }
        return albumKindLabel
    }

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

    private var isLibraryPlayback: Bool { matchedLibraryAlbum != nil }

    private struct BrowseQueuedRow: Identifiable {
        enum Kind {
            case library(Track)
            case missing(BrowseAlbumPreviewTrack)
        }

        let kind: Kind
        let displayIndex: Int

        var id: String {
            switch kind {
            case .library(let t): return "lib-\(t.id)"
            case .missing(let p): return "miss-\(p.id)"
            }
        }
    }

    /// MusicBrainz order when available; matches against this album’s library tracks when the release is in your library, otherwise against the discovery index.
    private var browseQueuedRows: [BrowseQueuedRow] {
        guard !previewTracks.isEmpty else {
            return libraryTracks.enumerated().map {
                BrowseQueuedRow(kind: .library($0.element), displayIndex: $0.offset + 1)
            }
        }
        let pool = isLibraryPlayback ? libraryTracks : app.discoveryLibraryTracks
        var usedLibraryIds = Set<String>()
        var rows: [BrowseQueuedRow] = []
        for (loopIdx, preview) in previewTracks.enumerated() {
            let displayIdx = preview.position > 0 ? preview.position : loopIdx + 1
            let song = downtifySong(forPreview: preview)
            if let matched = LibraryTrackMatcher.firstLibraryTrack(matching: song, in: pool),
               !usedLibraryIds.contains(matched.id)
            {
                rows.append(BrowseQueuedRow(kind: .library(matched), displayIndex: displayIdx))
                usedLibraryIds.insert(matched.id)
            } else {
                rows.append(BrowseQueuedRow(kind: .missing(preview), displayIndex: displayIdx))
            }
        }
        if isLibraryPlayback {
            let orphans = libraryTracks.filter { !usedLibraryIds.contains($0.id) }.sorted { lhs, rhs in
                if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                return lhs.indexNumber < rhs.indexNumber
            }
            var nextIdx = (rows.map(\.displayIndex).max() ?? 0) + 1
            for t in orphans {
                rows.append(BrowseQueuedRow(kind: .library(t), displayIndex: nextIdx))
                nextIdx += 1
            }
        }
        return rows
    }

    private var missingFromBrowseCatalogCount: Int {
        guard !previewTracks.isEmpty else { return 0 }
        return previewTracks.filter { libraryTrackMatchingPreview($0) == nil }.count
    }

    /// Library tracks on this screen in MB/preview order (for ⋯ playlist + queue actions).
    private var browseToolbarPlaylistTracks: [Track] {
        browseQueuedRows.compactMap {
            if case .library(let t) = $0.kind { return t }
            return nil
        }
    }

    /// Every visible library track on this browse screen already has a file under Downloads.
    private var browseLibraryTracksAllSavedOffline: Bool {
        isLibraryPlayback
            && !browseToolbarPlaylistTracks.isEmpty
            && browseToolbarPlaylistTracks.allSatisfy { app.offline.downloadedTrackIds.contains($0.id) }
    }

    private var browseHasToolbarExtras: Bool {
        if !isLibraryPlayback, previewTracks.isEmpty { return true }
        if missingFromBrowseCatalogCount > 0 { return true }
        if !isLibraryPlayback, !previewTracks.isEmpty { return true }
        return false
    }

    private var browseLeadingMenuTitle: String {
        isLibraryPlayback ? "Offline (download for offline use)" : "Request"
    }

    private var browseLeadingMenuIcon: String {
        isLibraryPlayback ? "arrow.down.circle" : "plus"
    }

    /// Leading ⋯ control: offline cache when this release is in your library; Downtify **Request** otherwise.
    private var browseLeadingMenuAction: (() -> Void)? {
        if isLibraryPlayback {
            guard app.isSignedIn, !browseToolbarPlaylistTracks.isEmpty, app.activeLibrary != nil else { return nil }
            return {
                Task { await browseDownloadLibraryTracksForOffline() }
            }
        }
        guard app.downtifyConfigured, !isDownloading else { return nil }
        return {
            Task { await primaryBrowseRequestAction() }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AlbumHeroBackdropView(artworkURL: displayArtworkURL, palette: backdropPalette)

            List {
                Section {
                    heroBlock
                    AppleMusicAlbumTrackDivider(palette: backdropPalette)
                        .padding(.top, 22)
                }
                .albumTrackListRowStyle()

                tracklistSection

                Section {
                    footerBlock
                }
                .albumTrackListRowStyle()
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .listRowSpacing(5)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .padding(.bottom, 36)
        }
        .navigationTitle("")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .musicHeroAlbumNavigationChrome(palette: backdropPalette)
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) { toolbarButtons }
        }
        .navigationDestination(item: $navigateLibraryAlbum) { album in
            ServerPlaylistDetailView(album: album)
        }
        .task(id: matchedLibraryAlbum?.id ?? "none") { await loadLibraryTracks() }
        .task(id: "\(isLibraryPlayback)-\(matchArtist)-\(matchAlbumTitle)") { await loadPreviewTracksIfNeeded() }
        .task(id: displayArtworkURL?.absoluteString ?? "") {
            let p = await ArtworkDynamicGradient.analyzeBackdrop(from: displayArtworkURL)
            await MainActor.run { backdropPalette = p }
        }
        .overlay {
            if (isLoadingTracks || isLoadingPreviewTracks), libraryTracks.isEmpty, previewTracks.isEmpty {
                ProgressView().tint(MusicDesign.accent).scaleEffect(1.1)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .downloadedTrackDeleteSheet(
            track: $trackPendingDownloadedDelete,
            app: app,
            offline: offline
        )
    }

    @ViewBuilder
    private var toolbarButtons: some View {
        if let url = displayArtworkURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
            }
        }
        AlbumToolbarOverflowMenu(
            shareItem: "\(displayTitle) — \(displayArtist)",
            playlistTracks: browseToolbarPlaylistTracks,
            onLeading: browseLeadingMenuAction,
            leadingDisabled: browseLibraryTracksAllSavedOffline,
            leadingTitle: browseLeadingMenuTitle,
            leadingSystemImage: browseLeadingMenuIcon,
            ellipsisTint: backdropPalette.heroChromePrimary,
            extraContent: { browseToolbarMenuExtras }
        )
    }

    @ViewBuilder
    private var browseToolbarMenuExtras: some View {
        if browseHasToolbarExtras {
            Section {
                if !isLibraryPlayback, previewTracks.isEmpty {
                    Button {
                        Task { await sendToDowntify() }
                    } label: {
                        Label("Request via Downtify", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!app.downtifyConfigured)
                }
                if missingFromBrowseCatalogCount > 0 {
                    Button {
                        Task { await requestAllPreviewTracksSequentially() }
                    } label: {
                        Label(
                            "Request \(missingFromBrowseCatalogCount) missing tracks",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .disabled(!app.downtifyConfigured || isDownloading)
                } else if !isLibraryPlayback, !previewTracks.isEmpty {
                    Button {
                        Task { await requestAllPreviewTracksSequentially() }
                    } label: {
                        Label("Request all tracks", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!app.downtifyConfigured || isDownloading)
                }
            }
            .tint(Color.primary)
        }
    }
    // MARK: - Hero

    private var heroBlock: some View {
        VStack(spacing: 18) {
            AlbumArtworkView(url: displayArtworkURL, cornerRadius: 14)
                .frame(width: heroArtSide, height: heroArtSide)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 8) {
                Text(displayTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Text(displayArtist)
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

            actionRow.padding(.top, 6)
        }
        .padding(.top, 8)
    }

    /// Matches ``AlbumDetailView`` primary capsule — fixed width, not full-bleed.
    private var actionRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button {
                    if isLibraryPlayback { Task { await playShuffled() } }
                    else { flashToast("Request this first to shuffle.") }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                            isLibraryPlayback ? backdropPalette.heroAccent : backdropPalette.heroChromeTertiary
                        )
                        .frame(width: 54, height: 54)
                        .background(
                            Circle().fill(
                                isLibraryPlayback ? backdropPalette.heroGlassCircleFill : backdropPalette.heroGlassCircleFillDisabled
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isLibraryPlayback && libraryTracks.isEmpty)

                if isLibraryPlayback {
                    Button { Task { await play(startingAt: libraryTracks.first) } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(backdropPalette.heroPlayCapsuleForeground)
                        .padding(.vertical, 14)
                        .frame(width: MusicDesign.albumHeroPrimaryCapsuleWidth)
                        .background(Capsule().fill(backdropPalette.heroPlayCapsuleBackground))
                    }
                    .buttonStyle(.plain)
                    .disabled(libraryTracks.isEmpty)
                } else {
                    Button { Task { await primaryBrowseRequestAction() } } label: {
                        Group {
                            if isDownloading {
                                ProgressView().tint(backdropPalette.heroPlayCapsuleForeground)
                            } else {
                                Label("Request", systemImage: "arrow.down.circle.fill")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                        }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(backdropPalette.heroPlayCapsuleForeground)
                        .padding(.vertical, 14)
                        .frame(width: MusicDesign.albumHeroPrimaryCapsuleWidth)
                        .background(Capsule().fill(backdropPalette.heroPlayCapsuleBackground))
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.downtifyConfigured || isDownloading)
                }

                if isLibraryPlayback, let first = libraryTracks.first, let lib = app.activeLibrary {
                    let firstSavedOffline = app.offline.downloadedTrackIds.contains(first.id)
                    Menu {
                        Button("Cache first track offline") {
                            Task { try? await cache(track: first, lib: lib) }
                        }
                        .disabled(firstSavedOffline)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(
                                firstSavedOffline
                                    ? backdropPalette.heroChromeTertiary.opacity(0.45)
                                    : backdropPalette.heroGlassIcon
                            )
                            .frame(width: 54, height: 54)
                            .background(
                                Circle().fill(
                                    firstSavedOffline
                                        ? backdropPalette.heroGlassCircleFillDisabled
                                        : backdropPalette.heroGlassCircleFill
                                )
                            )
                    }
                    .disabled(firstSavedOffline)
                } else {
                    Button { Task { await primaryBrowseRequestAction() } } label: {
                        Image(systemName: isDownloading ? "arrow.down.circle" : "plus")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(
                                app.downtifyConfigured ? backdropPalette.heroGlassIcon : backdropPalette.heroChromeTertiary.opacity(0.4)
                            )
                            .frame(width: 54, height: 54)
                            .background(
                                Circle().fill(
                                    app.downtifyConfigured
                                        ? backdropPalette.heroGlassCircleFill
                                        : backdropPalette.heroGlassCircleFillDisabled
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.downtifyConfigured || isDownloading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    // MARK: - Tracklist

    @ViewBuilder
    private var tracklistSection: some View {
        let rows = browseQueuedRows
        if isLoadingPreviewTracks, previewTracks.isEmpty, !libraryTracks.isEmpty {
            browseCatalogLoadingBanner
                .albumTrackListRowStyle()
        }
        if rows.isEmpty {
            if !(isLoadingTracks || isLoadingPreviewTracks), libraryTracks.isEmpty, previewTracks.isEmpty {
                Text(emptySongNote)
                    .font(.subheadline)
                    .foregroundStyle(backdropPalette.heroChromeSecondary.opacity(0.9))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .albumTrackListRowStyle()
            }
        } else {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Group {
                        switch row.kind {
                        case .library(let track):
                            browseLibraryTrackRow(
                                track: track,
                                displayIndex: row.displayIndex,
                                showsBottomDivider: index < rows.count - 1
                            )
                            .id(track.id)
                        case .missing(let preview):
                            browseMissingCatalogTrackRow(
                                preview: preview,
                                displayIndex: row.displayIndex,
                                showsBottomDivider: index < rows.count - 1
                            )
                        }
                    }
                    .albumTrackListRowStyle()
                }
            }
        }
    }

    private func browseLibraryTrackRow(track: Track, displayIndex: Int, showsBottomDivider: Bool) -> some View {
        AppleMusicAlbumTrackRow(
            index: displayIndex,
            title: track.title,
            subtitle: nil,
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
            backdropPalette: backdropPalette,
            onPlayNext: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await app.player.playNext(library: lib, track: track)
                }
            },
            onDownload: {
                Task {
                    guard let lib = app.activeLibrary else { return }
                    try? await cache(track: track, lib: lib)
                }
            },
            onRemoveFromLibrary: app.isSongInLibrary(track.id)
                ? { Task { await app.removeSongFromLibrary(track) } }
                : nil,
            onRemoveDownload: app.offline.downloadedTrackIds.contains(track.id)
                ? { try? app.offline.remove(trackId: track.id) } : nil,
            onPresentDownloadedDeleteSheet: {
                trackPendingDownloadedDelete = track
            },
            showsBottomDivider: showsBottomDivider,
            isNowPlaying: app.player.activeTrack?.id == track.id,
            onRowTap: { Task { await play(startingAt: track) } },
            menuContent: { browseInLibraryTrackOverflowMenu(track: track) }
        )
    }

    private var browseCatalogLoadingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.85)
                .tint(MusicDesign.accent)
            Text("Checking MusicBrainz for full track list…")
                .font(.subheadline)
                .foregroundStyle(backdropPalette.heroChromeSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    private func browseMissingCatalogTrackRow(
        preview: BrowseAlbumPreviewTrack,
        displayIndex: Int,
        showsBottomDivider: Bool
    ) -> some View {
        let durationLine = formattedTrackDuration(preview.duration)
        let subtitle: String = {
            var parts = ["Not in library"]
            if let durationLine { parts.append(durationLine) }
            return parts.joined(separator: " · ")
        }()
        let downtifyOfflineState: OfflineDownloadUIState? = {
            guard downloadingPreviewTrackIds.contains(preview.id) else { return nil }
            if let fr = previewDowntifyFraction[preview.id] {
                return .progress(min(1, max(0, fr)))
            }
            return .indeterminate
        }()

        return AppleMusicAlbumTrackRow(
            index: displayIndex,
            title: preview.title,
            subtitle: subtitle,
            offlineDownload: downtifyOfflineState,
            isOfflineCached: false,
            onCancelOfflineDownload: nil,
            onTapStartOfflineDownload: app.downtifyConfigured && !downloadingPreviewTrackIds.contains(preview.id)
                ? { Task { await requestPreviewTrackViaDowntify(preview) } }
                : nil,
            showsOfflineIndicator: true,
            backdropPalette: backdropPalette,
            showsBottomDivider: showsBottomDivider,
            onRowTap: {
                Task { await requestPreviewTrackViaDowntify(preview) }
            },
            menuContent: {
                ChartStyleSongOverflowMenuContent(
                    shareItem: "\(preview.title) — \(matchArtist)",
                    onAdd: {
                        Task { await requestPreviewTrackViaDowntify(preview) }
                    },
                    addDisabled: !app.downtifyConfigured || downloadingPreviewTrackIds.contains(preview.id)
                )
            }
        )
        .id("browse-missing-\(preview.id)")
    }

    /// Same native ``Menu`` / ``ControlGroup`` shape as ``NewTabChartOverflowPanel`` / Downtify search.
    @ViewBuilder
    private func browseInLibraryTrackOverflowMenu(track: Track) -> some View {
        let isInLibrary = app.isSongInLibrary(track.id)
        let isOfflineCached = app.offline.downloadedTrackIds.contains(track.id)

        ControlGroup {
            Button {
                Task { await play(startingAt: track) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            if isInLibrary, !isOfflineCached {
                Button {
                    Task {
                        guard let lib = app.activeLibrary else { return }
                        try? await cache(track: track, lib: lib)
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            Button {
                app.toggleFavoriteTrack(id: track.id)
            } label: {
                Label("Favorite", systemImage: "star.fill")
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
                Label("Add to a Playlist", systemImage: "music.note.list")
            }
            Button {
                Task { @MainActor in
                    try? await app.player.playTracksNext(library: app.activeLibrary, tracks: [track])
                }
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        }
        .tint(Color.primary)

        Section {
            Button {} label: { Label("Suggest Less", systemImage: "hand.thumbsdown") }
        }
        .tint(Color.primary)

        if isInLibrary, isOfflineCached {
            Section {
                Button {
                    try? app.offline.remove(trackId: track.id)
                } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                }
            }
            .tint(Color.primary)
        }
    }

    private var emptySongNote: String {
        if app.downtifyConfigured {
            return "Couldn’t load a track list for this release. You can still use Request above, or try again later."
        }
        return "Add your Downtify URL in Settings to request downloads."
    }

    // MARK: - Footer

    private var footerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let album = matchedLibraryAlbum, let line = album.releaseFooterDisplayString {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
            }

            if !libraryTracks.isEmpty {
                let totalMin = max(1, Int(ceil(libraryTracks.reduce(0) { $0 + max($1.duration, 0) } / 60.0)))
                let n = libraryTracks.count
                Text(n == 1 ? "1 song, \(totalMin) minutes" : "\(n) songs, \(totalMin) minutes")
                    .font(.subheadline)
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
            } else if !previewTracks.isEmpty, let line = previewTracksFooterSummary {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
            }
            if !previewTracks.isEmpty {
                Text("Track list from MusicBrainz where available \u{00B7} Downtify for downloads.")
                    .font(.caption)
                    .foregroundStyle(backdropPalette.heroChromeTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 22)
    }

    // MARK: - Actions

    private func loadLibraryTracks() async {
        guard let album = matchedLibraryAlbum, let lib = app.activeLibrary else { return }
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        libraryTracks = (try? await lib.tracks(forAlbumId: album.id)) ?? []
    }

    private func loadPreviewTracksIfNeeded() async {
        isLoadingPreviewTracks = true
        defer { isLoadingPreviewTracks = false }
        previewTracks = await app.resolveBrowseAlbumPreviewTracks(source: source)
    }

    private var previewTracksFooterSummary: String? {
        guard !previewTracks.isEmpty else { return nil }
        let totalSec = previewTracks.compactMap(\.duration).reduce(0, +)
        let n = previewTracks.count
        if totalSec > 1 {
            let totalMin = max(1, Int(ceil(totalSec / 60.0)))
            return n == 1 ? "1 song, \(totalMin) minutes" : "\(n) songs, \(totalMin) minutes"
        }
        return n == 1 ? "1 song" : "\(n) songs"
    }

    private func formattedTrackDuration(_ seconds: TimeInterval?) -> String? {
        guard let s = seconds, s > 1 else { return nil }
        let total = Int(round(s))
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }

    private func downtifySong(forPreview preview: BrowseAlbumPreviewTrack) -> DowntifySong {
        DowntifySong(
            songId: "browse-preview:\(preview.id)",
            name: preview.title,
            artists: [matchArtist],
            albumName: matchAlbumTitle,
            url: "",
            coverURL: nil,
            year: nil,
            explicit: false
        )
    }

    private func libraryTrackMatchingPreview(_ preview: BrowseAlbumPreviewTrack) -> Track? {
        let pool = isLibraryPlayback ? libraryTracks : app.discoveryLibraryTracks
        return LibraryTrackMatcher.firstLibraryTrack(matching: downtifySong(forPreview: preview), in: pool)
    }

    private func primaryBrowseRequestAction() async {
        if previewTracks.isEmpty {
            await sendToDowntify()
        } else {
            await requestAllPreviewTracksSequentially()
        }
    }

    private func requestPreviewTrackViaDowntify(_ preview: BrowseAlbumPreviewTrack) async {
        guard app.downtifyConfigured else {
            flashToast("Add your Downtify URL in Settings first.")
            return
        }
        let song = downtifySong(forPreview: preview)
        if LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) {
            flashToast("Already in your library")
            return
        }
        downloadingPreviewTrackIds.insert(preview.id)
        previewDowntifyFraction[preview.id] = 0
        defer {
            downloadingPreviewTrackIds.remove(preview.id)
            previewDowntifyFraction.removeValue(forKey: preview.id)
        }
        do {
            let songName = try await DowntifyClient.download(artist: matchArtist, title: preview.title) { p in
                Task { @MainActor in
                    previewDowntifyFraction[preview.id] = p
                }
            }
            flashToast("Downloading \"\(songName)\"")
        } catch {
            flashToast(error.musicPlaybackToastMessage)
        }
    }

    private func requestAllPreviewTracksSequentially() async {
        guard app.downtifyConfigured else {
            flashToast("Add your Downtify URL in Settings first.")
            return
        }
        if previewTracks.isEmpty {
            await sendToDowntify()
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        var succeeded = 0
        var skipped = 0
        var failed = 0
        for preview in previewTracks {
            if libraryTrackMatchingPreview(preview) != nil {
                skipped += 1
                continue
            }
            let song = downtifySong(forPreview: preview)
            if LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) {
                skipped += 1
                continue
            }
            downloadingPreviewTrackIds.insert(preview.id)
            previewDowntifyFraction[preview.id] = 0
            do {
                _ = try await DowntifyClient.download(artist: matchArtist, title: preview.title) { p in
                    Task { @MainActor in
                        previewDowntifyFraction[preview.id] = p
                    }
                }
                succeeded += 1
            } catch {
                failed += 1
            }
            downloadingPreviewTrackIds.remove(preview.id)
            previewDowntifyFraction.removeValue(forKey: preview.id)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if succeeded > 0, failed == 0 {
            flashToast(skipped > 0 ? "Requested \(succeeded) tracks (\(skipped) already in library)." : "Requested \(succeeded) tracks.")
        } else if succeeded > 0 {
            flashToast("Requested \(succeeded) tracks; \(failed) failed\(skipped > 0 ? "; \(skipped) skipped" : "").")
        } else if failed > 0 {
            flashToast("Couldn’t start downloads.")
        } else if skipped > 0 {
            flashToast("Every track is already in your library.")
        }
    }

    private func play(startingAt track: Track?) async {
        guard let lib = app.activeLibrary, let track else { return }
        if !libraryTracks.isEmpty {
            let idx = libraryTracks.firstIndex(where: { $0.id == track.id }) ?? 0
            try? await app.player.playAlbum(library: lib, tracks: libraryTracks, startIndex: idx)
        } else {
            try? await app.player.playAlbum(library: lib, tracks: [track], startIndex: 0)
        }
    }

    private func playShuffled() async {
        guard let lib = app.activeLibrary, !libraryTracks.isEmpty else { return }
        try? await app.player.playAlbumShuffled(library: lib, tracks: libraryTracks)
    }

    private func browseDownloadLibraryTracksForOffline() async {
        guard let lib = app.activeLibrary, !browseToolbarPlaylistTracks.isEmpty else { return }
        var succeeded = 0
        for track in browseToolbarPlaylistTracks {
            try? await cache(track: track, lib: lib)
            succeeded += 1
        }
        flashToast("\(succeeded) track\(succeeded == 1 ? "" : "s") downloaded")
    }

    private func cache(track: Track, lib: MusicLibraryProviding) async throws {
        let url = try lib.offlineDownloadURL(for: track)
        try await app.offline.cache(track: track, remote: url, headers: lib.httpHeadersForMediaRequests())
    }

    private func sendToDowntify() async {
        guard app.downtifyConfigured else {
            flashToast("Add your Downtify URL in Settings first.")
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let songName = try await DowntifyClient.download(artist: matchArtist, title: matchAlbumTitle)
            flashToast("Downloading \"\(songName)\"")
        } catch {
            flashToast(error.musicPlaybackToastMessage)
        }
    }

    private func flashToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            toast = nil
        }
    }
}
