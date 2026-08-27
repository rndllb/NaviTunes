import SwiftUI
#if os(iOS)
import UIKit
#endif


/// Apple Music-style album page for New tab rows (library match → Play; otherwise Request via the active acquisition plugin).
struct BrowseAlbumDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager
    @EnvironmentObject private var acquisition: AcquisitionManager
    @Environment(\.colorScheme) private var colorScheme
    let source: BrowseAlbumDetailSource

    @State private var libraryTracks: [Track] = []
    @State private var previewTracks: [BrowseAlbumPreviewTrack] = []
    @State private var browseQueuedRows: [BrowseQueuedRow] = []
    @State private var missingFromBrowseCatalogCount = 0
    @State private var isLoadingTracks = false
    @State private var isLoadingPreviewTracks = false
    /// Debounced gate for the "couldn't load a track list" note. Off-server tracklists
    /// arrive from the acquisition plugin / library and can land a beat after the first
    /// load pass finishes empty, so the note is only shown once the empty state has held
    /// for a short grace window — otherwise it flashes false info for tracks that do load.
    @State private var emptyNoteVisible = false
    @State private var emptyNoteDebounceTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback
    @State private var isDownloading = false
    @State private var navigateLibraryAlbum: AlbumSummary?
    @State private var navigateArtist: ArtistNameNavigation?
    @State private var trackPendingDownloadedDelete: Track?
    @State private var dismissalPhase: CoverZoomTransitionPhase = .idle
    @State private var isBeingDismissed = false
    @State private var artistRequestBlocked = false

    private var acquisitionRequestsEnabled: Bool {
        app.acquisitionConfigured && !artistRequestBlocked
    }

    /// True only once both track sources have finished loading and returned nothing.
    /// Drives the debounced empty-state note (see ``emptyNoteVisible``).
    private var tracksSettledEmpty: Bool {
        !isLoadingTracks && !isLoadingPreviewTracks
            && libraryTracks.isEmpty && previewTracks.isEmpty
    }

    /// Shows the empty-state note only after the empty result has held for a grace window.
    /// A plugin/library re-fetch that lands late clears `settled` and cancels the pending
    /// note, so tracks that do arrive never flash a "couldn't load" message.
    private func scheduleEmptyNoteDebounce(settled: Bool) {
        emptyNoteDebounceTask?.cancel()
        guard settled else {
            emptyNoteVisible = false
            return
        }
        emptyNoteDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, tracksSettledEmpty else { return }
            emptyNoteVisible = true
        }
    }

    init(source: BrowseAlbumDetailSource) {
        self.source = source
        let seedURL: URL? = {
            if case .chartBrowse(_, _, let imageURL, _, _) = source { return imageURL }
            return nil
        }()
        _backdropPalette = State(initialValue: ArtworkDynamicGradient.seededBackdrop(for: seedURL))
    }

    private var matchedLibraryAlbum: AlbumSummary? {
        app.libraryAlbumMatchingBrowseRelease(artist: matchArtist, albumTitle: matchAlbumTitle)
    }

    private var isLibraryPlayback: Bool {
        matchedLibraryAlbum != nil || !libraryTracks.isEmpty || browseHasResolvedServerTracks
    }

    private var browseHasResolvedServerTracks: Bool {
        browseQueuedRows.contains {
            if case .library = $0.kind { return true }
            return false
        }
    }

    private var matchArtist: String {
        if case .chartBrowse(let a, _, _, _, _) = source { return a }
        return ""
    }

    private var matchAlbumTitle: String {
        if case .chartBrowse(_, let t, _, _, _) = source { return t }
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
        if case .chartBrowse(_, _, let url, _, _) = source { return url }
        return nil
    }

    private var albumKindLabel: String {
        if case .chartBrowse(_, _, _, let kind, _) = source { return kind }
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

    /// Rebuilds track rows once when inputs change — avoids scanning ``discoveryLibraryTracks`` on every body pass (back-navigation freeze on large libraries).
    private func recomputeBrowseQueuedRows() {
        guard !previewTracks.isEmpty else {
            browseQueuedRows = libraryTracks.enumerated().map {
                BrowseQueuedRow(kind: .library($0.element), displayIndex: $0.offset + 1)
            }
            missingFromBrowseCatalogCount = 0
            return
        }
        var usedLibraryIds = Set<String>()
        var rows: [BrowseQueuedRow] = []
        var missingCount = 0
        for (loopIdx, preview) in previewTracks.enumerated() {
            let displayIdx = preview.position > 0 ? preview.position : loopIdx + 1
            if let matched = libraryTrackMatchingPreview(preview),
               !usedLibraryIds.contains(matched.id)
            {
                rows.append(BrowseQueuedRow(kind: .library(matched), displayIndex: displayIdx))
                usedLibraryIds.insert(matched.id)
            } else {
                rows.append(BrowseQueuedRow(kind: .missing(preview), displayIndex: displayIdx))
                missingCount += 1
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
        browseQueuedRows = rows
        missingFromBrowseCatalogCount = missingCount
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
        return false
    }

    private var browseLeadingMenuTitle: String {
        isLibraryPlayback ? "Offline (download for offline use)" : "Request"
    }

    private var browseLeadingMenuIcon: String {
        isLibraryPlayback ? "arrow.down.circle" : "arrow.down.circle.fill"
    }

    /// Leading ⋯ control: offline cache when this release is in your library; acquisition **Request** otherwise.
    private var browseLeadingMenuAction: (() -> Void)? {
        if isLibraryPlayback {
            guard app.isSignedIn, !browseToolbarPlaylistTracks.isEmpty, app.activeLibrary != nil else { return nil }
            return {
                Task { await browseDownloadLibraryTracksForOffline() }
            }
        }
        guard app.acquisitionConfigured, !isDownloading else { return nil }
        return {
            Task { await primaryBrowseRequestAction() }
        }
    }

    // Split from `body` so the List content and the long modifier chain type-check as two
    // separate expressions (the combined one exceeds the Swift type-checker's time budget).
    private var detailContent: some View {
        ZStack(alignment: .top) {
            AlbumHeroBackdropView(artworkURL: displayArtworkURL, palette: backdropPalette)

            List {
                Section {
                    heroBlock
                    AppleMusicAlbumTrackDivider(palette: backdropPalette)
                        .padding(.top, 22)
                }
                // The transition gate is scoped to the hero alone. Wrapping the whole
                // screen (as it used to) made scrolling and every track row dead for
                // ~0.6s after each open; all it needs to stop is a finger still down from
                // the list tap releasing onto Play / Request / +.
                .coverZoomDetailHitTesting(phase: $dismissalPhase, isBeingDismissed: $isBeingDismissed)
                .albumTrackListRowStyle()

                tracklistSection

                Section {
                    footerBlock
                }
                .albumTrackListRowStyle()

                Section {
                    AlbumDetailRelatedSectionsView(
                        artist: displayArtist,
                        title: displayTitle,
                        excludingAlbumId: matchedLibraryAlbum?.id,
                        backdropPalette: backdropPalette,
                        onSelectAlbum: { album in
                            if navigateLibraryAlbum?.id == album.id {
                                navigateLibraryAlbum = nil
                                DispatchQueue.main.async { navigateLibraryAlbum = album }
                            } else {
                                navigateLibraryAlbum = album
                            }
                        },
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .listRowSpacing(5)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .padding(.bottom, 36)
        }
    }

    var body: some View {
        detailContent
        .coverZoomDestination(id: source.coverZoomId, dismissalPhase: $dismissalPhase)
        .detailDismissTracker(isBeingDismissed: $isBeingDismissed)
        .onAppear {
            isBeingDismissed = false
            if dismissalPhase == .gone { dismissalPhase = .idle }
        }
        .navigationTitle("")
        // Bar stays untitled (the hero carries the name); this names the screen only in the
        // back button's long-press history menu.
        .musicBackHistoryTitle(displayTitle)
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .musicHeroAlbumNavigationChrome(palette: backdropPalette)
        .toolbar {
            ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                toolbarButtons
                    .coverZoomDetailHitTesting(phase: $dismissalPhase, isBeingDismissed: $isBeingDismissed)
            }
        }
        .navigationDestination(item: $navigateLibraryAlbum) { album in
            ServerPlaylistDetailView(album: album)
                .onDisappear { navigateLibraryAlbum = nil }
        }
        .navigationDestination(item: $navigateArtist) { item in
            ArtistPageView(input: .named(item.id))
        }
        .task(id: matchArtist) {
            guard app.acquisitionConfigured, app.acquisitionCapabilities.granularity == .album else {
                artistRequestBlocked = false
                return
            }
            let canRequest = await acquisition.canRequestArtist(named: matchArtist)
            artistRequestBlocked = !canRequest
        }
        .task(id: "\(matchArtist)-\(matchAlbumTitle)-\(albumKindLabel)") {
            await app.reconcileBrowseChartRelease(
                artist: matchArtist,
                albumTitle: matchAlbumTitle,
                kind: albumKindLabel
            )
            await loadPreviewTracksIfNeeded()
            await loadLibraryTracks()
        }
        .onChange(of: app.libraryCatalogEpoch) { _, _ in
            Task { await loadLibraryTracks() }
            recomputeBrowseQueuedRows()
        }
        .onChange(of: app.discoveryLibraryTracks.count) { _, _ in
            recomputeBrowseQueuedRows()
        }
        .onChange(of: tracksSettledEmpty) { _, settled in
            scheduleEmptyNoteDebounce(settled: settled)
        }
        .onAppear(perform: seedCachedBrowseBackdropIfNeeded)
        .task(id: "\(displayArtworkURL?.absoluteString ?? "")-\(app.albumBackdropEnabled)-\(colorScheme)") {
            guard app.albumBackdropEnabled else {
                backdropPalette = .listSurface(colorScheme: colorScheme)
                return
            }
            if let cached = ArtworkDynamicGradient.cachedBackdrop(for: displayArtworkURL) {
                backdropPalette = cached
                return
            }
            let p = await ArtworkDynamicGradient.analyzeBackdrop(from: displayArtworkURL)
            guard !Task.isCancelled, dismissalPhase != .gone else { return }
            backdropPalette = p
        }
        .overlay {
            // Keep the spinner up through the empty-state grace window (note not yet shown)
            // so the tracklist reads as "still resolving" rather than blank or a false error.
            if libraryTracks.isEmpty, previewTracks.isEmpty,
               isLoadingTracks || isLoadingPreviewTracks || !emptyNoteVisible {
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
                        Task { await requestAlbum() }
                    } label: {
                        HStack(spacing: MusicDesign.requestActionLabelSpacing) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Request \(app.acquisitionCapabilities.displayName)")
                        }
                    }
                    .disabled(!acquisitionRequestsEnabled)
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
                // Destination rect for the custom cover-zoom animator (see ServerPlaylistViews).
                .coverZoomHeroAnchor(id: source.coverZoomId, cornerRadius: 14)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            VStack(spacing: 8) {
                Text(displayTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(backdropPalette.heroChromePrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                ArtistNameButton(
                    name: displayArtist,
                    font: .title3.weight(.regular),
                    foreground: backdropPalette.heroChromeSecondary,
                    lineLimit: nil,
                    multilineTextAlignment: .center,
                ) {
                    navigateArtist = ArtistNameNavigation(id: displayArtist)
                }
                .padding(.horizontal, 20)

                if !metadataDetailLine.isEmpty {
                    Text(metadataDetailLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(backdropPalette.heroChromeTertiary)
                        .multilineTextAlignment(.center)
                }

                if artistRequestBlocked {
                    Text("This artist isn’t in \(app.acquisitionCapabilities.displayName) and can’t be requested.")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
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
                                RequestActionLabel(font: .headline.weight(.bold))
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
                    .disabled(!acquisitionRequestsEnabled || isDownloading)
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
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(backdropPalette.heroChromeTertiary.opacity(0.45))
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(backdropPalette.heroGlassCircleFillDisabled))
                        .accessibilityLabel("Add to library unavailable until requested")
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
            if emptyNoteVisible {
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
        TrackDownloadProgressReader(progress: offline.progressModel, trackId: track.id) { downloadState in
            browseLibraryTrackRowContent(track: track, downloadState: downloadState, displayIndex: displayIndex, showsBottomDivider: showsBottomDivider)
        }
    }

    private func browseLibraryTrackRowContent(track: Track, downloadState: OfflineDownloadUIState?, displayIndex: Int, showsBottomDivider: Bool) -> some View {
        AppleMusicAlbumTrackRow(
            index: displayIndex,
            title: track.title,
            subtitle: nil,
            isFavorite: app.favoriteTrackIds.contains(track.id),
            offlineDownload: downloadState,
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
            Text("Loading full track list…")
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
        let previewJob = acquisitionJob(forPreview: preview)
        let isRequestingPreview = previewJob.map { !$0.status.isTerminal } ?? false
        let acquireOfflineState: OfflineDownloadUIState? = {
            guard let previewJob, !previewJob.status.isTerminal else { return nil }
            return .progress(min(1, max(0, previewJob.progress)))
        }()

        return AppleMusicAlbumTrackRow(
            index: displayIndex,
            title: preview.title,
            subtitle: subtitle,
            offlineDownload: acquireOfflineState,
            isOfflineCached: false,
            isInLibrary: false,
            isInServerCatalog: false,
            greysTitle: true,
            showsOfflineIndicator: isRequestingPreview,
            backdropPalette: backdropPalette,
            showsBottomDivider: showsBottomDivider,
            onRowTap: {
                Task { await requestPreviewTrack(preview) }
            },
            menuContent: {
                ChartStyleSongOverflowMenuContent(
                    shareItem: "\(preview.title) — \(matchArtist)",
                    onAdd: {
                        Task { await requestPreviewTrack(preview) }
                    },
                    addDisabled: !acquisitionRequestsEnabled || isRequestingPreview
                )
            }
        )
        .id("browse-missing-\(preview.id)")
    }

    /// Same native ``Menu`` / ``ControlGroup`` shape as ``NewTabChartOverflowPanel`` / the request backend search.
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

        NavidromeShareMenuSection(
            itemId: track.id,
            description: "\(track.title) — \(track.artist)"
        )

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
        if app.acquisitionConfigured {
            return "Couldn’t load a track list for this release. You can still use Request above, or try again later."
        }
        return "Set up a download plugin in Settings to request downloads."
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
                Text("Track list from Apple Music where available \u{00B7} \(app.acquisitionCapabilities.displayName) for downloads.")
                    .font(.caption)
                    .foregroundStyle(backdropPalette.heroChromeTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 22)
    }

    // MARK: - Actions

    private func seedCachedBrowseBackdropIfNeeded() {
        guard app.albumBackdropEnabled else { return }
        if let cached = ArtworkDynamicGradient.cachedBackdrop(for: displayArtworkURL) {
            backdropPalette = cached
            return
        }
        ArtworkDynamicGradient.prefetchBackdrop(for: displayArtworkURL)
    }

    @MainActor
    private func waitForSafeBrowseMutation() async -> Bool {
        while dismissalPhase == .appearing || dismissalPhase == .dismissing {
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return false
            }
        }
        return dismissalPhase != .gone && !Task.isCancelled
    }

    private func loadLibraryTracks() async {
        guard let lib = app.activeLibrary else {
            libraryTracks = []
            recomputeBrowseQueuedRows()
            return
        }
        isLoadingTracks = true
        defer { isLoadingTracks = false }

        if let album = matchedLibraryAlbum {
            let tracks = (try? await lib.tracks(forAlbumId: album.id)) ?? []
            guard await waitForSafeBrowseMutation() else { return }
            libraryTracks = tracks
            recomputeBrowseQueuedRows()
            return
        }

        if let preview = previewTracks.first,
           let track = libraryTrackMatchingPreview(preview) {
            let tracks = (try? await lib.tracks(forAlbumId: track.albumId)) ?? [track]
            guard await waitForSafeBrowseMutation() else { return }
            libraryTracks = tracks
            recomputeBrowseQueuedRows()
            return
        }

        guard await waitForSafeBrowseMutation() else { return }
        libraryTracks = []
        recomputeBrowseQueuedRows()
    }

    private func loadPreviewTracksIfNeeded() async {
        isLoadingPreviewTracks = true
        defer { isLoadingPreviewTracks = false }
        let previews = await app.resolveBrowseAlbumPreviewTracks(source: source)
        guard await waitForSafeBrowseMutation() else { return }
        previewTracks = previews
        recomputeBrowseQueuedRows()
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

    private func matchableSong(forPreview preview: BrowseAlbumPreviewTrack) -> MatchableSong {
        MatchableSong(
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
        let song = matchableSong(forPreview: preview)
        if let matched = LibraryTrackMatcher.firstLibraryTrack(matching: song, in: libraryTracks) {
            return matched
        }
        if let matched = app.libraryChartTrackIndex.firstMatch(song: song) {
            return matched
        }
        let chart = ChartTrack(
            id: preview.id,
            name: matchAlbumTitle,
            artistName: matchArtist,
            imageURL: displayArtworkURL,
            playcount: 0,
            browseKind: albumKindLabel
        )
        return app.libraryChartTrackIndex.firstMatch(chart: chart)
    }

    private func primaryBrowseRequestAction() async {
        if previewTracks.isEmpty {
            await requestAlbum()
        } else {
            await requestAllPreviewTracksSequentially()
        }
    }

    /// Request for a missing preview row. Album-granularity plugins request the whole
    /// album; track-granularity plugins request just this track.
    private func acquisitionRequest(forPreview preview: BrowseAlbumPreviewTrack) -> AcquisitionRequest {
        if app.acquisitionCapabilities.granularity == .album {
            return AcquisitionRequest(artist: matchArtist, albumTitle: matchAlbumTitle, coverURL: displayArtworkURL)
        }
        return AcquisitionRequest(artist: matchArtist, trackTitle: preview.title, albumTitle: matchAlbumTitle, coverURL: displayArtworkURL)
    }

    /// The manager job for a preview row, matched by normalized title (previews have no URL).
    private func acquisitionJob(forPreview preview: BrowseAlbumPreviewTrack) -> AcquisitionJob? {
        app.acquisition.job(matchingTitle: preview.title)
    }

    private func requestPreviewTrack(_ preview: BrowseAlbumPreviewTrack) async {
        guard acquisitionRequestsEnabled else {
            flashToast(artistRequestBlocked
                ? "This artist can't be requested via \(app.acquisitionCapabilities.displayName)."
                : "Set up a download plugin in Settings first.")
            return
        }
        if libraryTrackMatchingPreview(preview) != nil {
            flashToast("Already on your server")
            return
        }
        let song = matchableSong(forPreview: preview)
        if LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) {
            flashToast("Already in your library")
            return
        }
        await app.requestAcquisition(acquisitionRequest(forPreview: preview))
    }

    private func requestAllPreviewTracksSequentially() async {
        guard acquisitionRequestsEnabled else {
            flashToast(artistRequestBlocked
                ? "This artist can't be requested via \(app.acquisitionCapabilities.displayName)."
                : "Set up a download plugin in Settings first.")
            return
        }
        if previewTracks.isEmpty {
            await requestAlbum()
            return
        }
        // Album-granularity plugins request the whole release once.
        if app.acquisitionCapabilities.granularity == .album {
            await requestAlbum()
            return
        }
        var requested = 0
        var skipped = 0
        for preview in previewTracks {
            if libraryTrackMatchingPreview(preview) != nil {
                skipped += 1
                continue
            }
            let song = matchableSong(forPreview: preview)
            if LibraryTrackMatcher.matchesLibrary(song, titleIndex: app.libraryTrackTitleIndex) {
                skipped += 1
                continue
            }
            await app.requestAcquisition(acquisitionRequest(forPreview: preview))
            requested += 1
        }
        if requested > 0 {
            flashToast(skipped > 0 ? "Requested \(requested) tracks (\(skipped) already in library)." : "Requested \(requested) tracks.")
        } else if skipped > 0 {
            flashToast("Every track is already in your library.")
        } else {
            flashToast("Couldn’t start downloads.")
        }
    }

    private func play(startingAt track: Track?) async {
        guard let track else { return }
        if !libraryTracks.isEmpty {
            let idx = libraryTracks.firstIndex(where: { $0.id == track.id }) ?? 0
            await app.playAlbumOrToast(tracks: libraryTracks, startIndex: idx)
        } else {
            await app.playAlbumOrToast(tracks: [track], startIndex: 0)
        }
    }

    private func playShuffled() async {
        guard let lib = app.activeLibrary, !libraryTracks.isEmpty else { return }
        try? await app.player.playAlbumShuffled(library: lib, tracks: libraryTracks)
    }

    private func browseDownloadLibraryTracksForOffline() async {
        guard app.activeLibrary != nil, !browseToolbarPlaylistTracks.isEmpty else { return }
        if let album = matchedLibraryAlbum {
            app.enqueueOfflineAlbum(album, tracks: browseToolbarPlaylistTracks)
        } else {
            app.offline.enqueueTracks(browseToolbarPlaylistTracks)
        }
        flashToast("Added to download queue")
    }

    private func cache(track: Track, lib: MusicLibraryProviding) async throws {
        app.enqueueOfflineTrack(track)
    }

    private func requestAlbum() async {
        guard acquisitionRequestsEnabled else {
            flashToast(artistRequestBlocked
                ? "This artist can't be requested via \(app.acquisitionCapabilities.displayName)."
                : "Set up a download plugin in Settings first.")
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        let request = AcquisitionRequest(artist: matchArtist, albumTitle: matchAlbumTitle, coverURL: displayArtworkURL)
        await app.requestAcquisition(request)
    }

    private func flashToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            toast = nil
        }
    }
}
