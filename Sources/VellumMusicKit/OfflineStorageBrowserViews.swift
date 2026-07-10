import SwiftUI

// MARK: - Downloaded tracks (metadata + cover art)

struct DownloadedTracksBrowserView: View {
    @EnvironmentObject private var offline: OfflineDownloadManager
    @State private var searchText = ""
    @State private var trackPendingDelete: OfflineCachedTrackEntry?
    @State private var entries: [OfflineCachedTrackEntry] = []

    private var filtered: [OfflineCachedTrackEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            "\($0.track.title) \($0.track.artist) \($0.track.albumTitle)".lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Downloaded Tracks",
                    systemImage: "music.note",
                    description: Text("Saved tracks appear here with metadata and artwork.")
                )
            } else {
                ForEach(filtered) { entry in
                    downloadedTrackRow(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                trackPendingDelete = entry
                            }
                        }
                }
            }
        }
        .musicNativeSearchable(text: $searchText, prompt: "Search downloaded tracks")
        .navigationTitle("Downloaded Music")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .onAppear(perform: reload)
        .onChange(of: offline.downloadedTrackIds) { _, _ in reload() }
        .alert("Delete downloaded track?", isPresented: Binding(
            get: { trackPendingDelete != nil },
            set: { if !$0 { trackPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let entry = trackPendingDelete {
                    try? offline.remove(trackId: entry.id)
                    reload()
                }
                trackPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { trackPendingDelete = nil }
        } message: {
            if let entry = trackPendingDelete {
                Text("Removes “\(entry.track.title)” from offline storage.")
            }
        }
    }

    @ViewBuilder
    private func downloadedTrackRow(_ entry: OfflineCachedTrackEntry) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: entry.localArtworkURL ?? entry.track.artworkURL, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.track.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(entry.track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.track.albumTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(LocalCacheByteFormatter.string(entry.fileBytes))
                    if entry.track.duration > 0 {
                        Text(formatDuration(entry.track.duration))
                    }
                    if let codec = entry.track.audioCodec, !codec.isEmpty {
                        Text(codec.uppercased())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        entries = offline.cachedTrackEntries()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Image cache

struct ImageCacheBrowserView: View {
    @EnvironmentObject private var offline: OfflineDownloadManager
    @State private var entries: [CachedImageEntry] = []
    @State private var entryPendingDelete: CachedImageEntry?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Cached Images",
                    systemImage: "photo.on.rectangle",
                    description: Text("Remote artwork and offline album art appear here.")
                )
            } else {
                ForEach(entries) { entry in
                    imageCacheRow(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                entryPendingDelete = entry
                            }
                        }
                }
            }
        }
        .navigationTitle("Image Cache")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .onAppear(perform: reload)
        .alert("Delete cached image?", isPresented: Binding(
            get: { entryPendingDelete != nil },
            set: { if !$0 { entryPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let entry = entryPendingDelete {
                    delete(entry)
                    reload()
                }
                entryPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { entryPendingDelete = nil }
        }
    }

    @ViewBuilder
    private func imageCacheRow(_ entry: CachedImageEntry) -> some View {
        HStack(spacing: 12) {
            if let preview = entry.previewURL {
                AlbumArtworkView(url: preview, cornerRadius: 8)
                    .frame(width: 50, height: 50)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MusicDesign.tertiarySurfaceFill)
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(sourceLabel(entry.source))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(LocalCacheByteFormatter.string(entry.fileBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sourceLabel(_ source: CachedImageEntry.Source) -> String {
        switch source {
        case .remoteArtwork: return "Remote artwork cache"
        case .offlineDownload: return "Offline download artwork"
        case .accountAvatar: return "Account avatar"
        }
    }

    private func delete(_ entry: CachedImageEntry) {
        switch entry.source {
        case .remoteArtwork:
            ArtworkURLCache.removeDiskEntry(key: entry.deleteToken)
        case .offlineDownload:
            offline.removeOfflineArtwork(albumId: entry.deleteToken)
        case .accountAvatar:
            break
        }
    }

    private func reload() {
        entries = ArtworkURLCache.listDiskEntries() + offline.listOfflineArtworkEntries()
        entries.sort { $0.fileBytes > $1.fileBytes }
    }
}

// MARK: - Metadata cache (library snapshot)

struct MetadataCacheBrowserView: View {
    @State private var entries: [LibraryMetadataEntry] = []
    @State private var entryPendingDelete: LibraryMetadataEntry?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Cached Metadata",
                    systemImage: "doc.text",
                    description: Text("Album and playlist details saved for offline browsing appear here.")
                )
            } else {
                if let savedAt = entries.compactMap(\.savedAt).first {
                    Section {
                        Text("Last saved \(savedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(entries) { entry in
                    metadataRow(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                entryPendingDelete = entry
                            }
                        }
                }
            }
        }
        .navigationTitle("Metadata Cache")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .onAppear(perform: reload)
        .alert("Remove cached metadata?", isPresented: Binding(
            get: { entryPendingDelete != nil },
            set: { if !$0 { entryPendingDelete = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let entry = entryPendingDelete {
                    LibrarySnapshotStore.removeMetadataEntry(id: entry.id)
                    reload()
                }
                entryPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { entryPendingDelete = nil }
        } message: {
            Text("Removes this entry from the on-device library snapshot. Your server library is unchanged.")
        }
    }

    @ViewBuilder
    private func metadataRow(_ entry: LibraryMetadataEntry) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: entry.artworkURL, cornerRadius: entry.kind == .album ? 8 : 10)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(kindLabel(entry.kind))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func kindLabel(_ kind: LibraryMetadataEntry.Kind) -> String {
        switch kind {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .track: return "Track"
        }
    }

    private func reload() {
        entries = LibrarySnapshotStore.metadataEntries()
    }
}

// MARK: - Dangerous bulk actions

struct DangerousStorageActionsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var isExpanded = false
    @State private var confirmAction: DangerousCacheAction?
    /// Precomputed off-main so the confirmation alert never decodes the library
    /// snapshot / walks disk on the main thread while building its message.
    @State private var cacheSummary: LocalCacheUsageSummary?

    private enum DangerousCacheAction: Identifiable {
        case imageCache
        case downloadedMusic
        case metadata
        case all

        var id: Self { self }
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                dangerousButton("Clear image cache", action: .imageCache)
                dangerousButton("Clear downloaded music", action: .downloadedMusic)
                dangerousButton("Clear metadata cache", action: .metadata)
                dangerousButton("Clear all data", action: .all)
            } label: {
                Label("Dangerous", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("These actions only affect data stored on this device.")
        }
        .alert(item: $confirmAction) { action in
            Alert(
                title: Text(alertTitle(action)),
                message: Text(alertMessage(action)),
                primaryButton: .destructive(Text("Clear")) {
                    perform(action)
                    Task { await refreshSummary() }
                },
                secondaryButton: .cancel()
            )
        }
        .task { await refreshSummary() }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { Task { await refreshSummary() } }
        }
    }

    private func refreshSummary() async {
        cacheSummary = await app.localCacheUsageSummaryAsync()
    }

    private func dangerousButton(_ title: String, action: DangerousCacheAction) -> some View {
        Button(role: .destructive) {
            confirmAction = action
        } label: {
            HStack {
                Image(systemName: "trash")
                Text(title)
            }
        }
    }

    private func alertTitle(_ action: DangerousCacheAction) -> String {
        switch action {
        case .imageCache: return "Clear image cache?"
        case .downloadedMusic: return "Clear downloaded music?"
        case .metadata: return "Clear metadata cache?"
        case .all: return "Clear all local cache data?"
        }
    }

    private func alertMessage(_ action: DangerousCacheAction) -> String {
        // Use the off-main precomputed summary. If it hasn't finished loading yet,
        // fall back to a message without specific counts rather than block the main thread.
        guard let summary = cacheSummary else {
            switch action {
            case .imageCache:     return "Removes all cached artwork from this device."
            case .downloadedMusic: return "Removes all downloaded tracks. Playback queue downloads are not affected."
            case .metadata:       return "Removes cached album and playlist entries from the on-device library snapshot."
            case .all:            return "Removes all downloaded music, cached images, and library metadata stored on this device."
            }
        }
        switch action {
        case .imageCache:
            return "Removes \(LocalCacheByteFormatter.string(summary.imageCacheBytes)) of cached artwork (\(summary.imageCacheCount) files)."
        case .downloadedMusic:
            return "Removes \(summary.downloadedTrackCount) downloaded tracks (\(LocalCacheByteFormatter.string(summary.downloadedMusicBytes))). Playback queue downloads are not affected."
        case .metadata:
            return "Removes \(summary.metadataEntryCount) cached album and playlist entries from the on-device library snapshot."
        case .all:
            return "Removes all downloaded music, cached images, and library metadata stored on this device."
        }
    }

    private func perform(_ action: DangerousCacheAction) {
        switch action {
        case .imageCache:
            Task { await app.clearImageCaches() }
        case .downloadedMusic:
            app.clearDownloadedMusic()
        case .metadata:
            app.clearMetadataCache()
        case .all:
            Task { await app.clearAllLocalCaches() }
        }
    }
}
