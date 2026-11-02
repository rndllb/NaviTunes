import SwiftUI

struct DownloadQueueView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: OfflineDownloadManager

    var body: some View {
        List {
            if offline.isQueuePaused, let reason = offline.queuePauseReason {
                Section {
                    Label(reason, systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if activeItems.isEmpty && completedItems.isEmpty {
                ContentUnavailableView(
                    "No Downloads Queued",
                    systemImage: "arrow.down.circle",
                    description: Text("Album and playlist downloads appear here.")
                )
            } else {
                if !activeItems.isEmpty {
                    Section("Active") {
                        ForEach(activeItems) { item in
                            queueRow(item)
                        }
                    }
                }
                if !completedItems.isEmpty {
                    Section("Completed") {
                        ForEach(completedItems) { item in
                            queueRow(item)
                        }
                        Button("Clear completed") {
                            offline.clearCompletedQueueItems()
                        }
                        .tint(MusicDesign.accent)
                    }
                }
            }
        }
        .navigationTitle("Download Queue")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .toolbar {
            if !offline.downloadQueue.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear all", role: .destructive) {
                        offline.clearQueue()
                    }
                }
            }
        }
    }

    private var activeItems: [OfflineDownloadQueueItem] {
        offline.downloadQueue.filter { !$0.isTerminal }
    }

    private var completedItems: [OfflineDownloadQueueItem] {
        offline.downloadQueue.filter(\.isTerminal)
    }

    @ViewBuilder
    private func queueRow(_ item: OfflineDownloadQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name)
                    .font(.body.weight(.semibold))
                Spacer()
                if item.status == .error {
                    Button("Retry") { offline.retryQueueItem(id: item.id) }
                        .font(.caption.weight(.semibold))
                } else if !item.isTerminal {
                    Button("Cancel", role: .destructive) { offline.cancelQueueItem(id: item.id) }
                        .font(.caption)
                }
            }
            Text(kindLabel(item.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: item.progressFraction)
            Text("\(item.completedTrackIds.count) of \(item.tracks.count) tracks")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = item.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func kindLabel(_ kind: OfflineDownloadQueueItemKind) -> String {
        switch kind {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .favorites: return "Favorites"
        case .track: return "Track"
        }
    }
}

struct OfflineCacheBrowserView: View {
    @EnvironmentObject private var offline: OfflineDownloadManager
    @State private var confirmDeleteItemId: String?

    var body: some View {
        List {
            if offline.cachedItems().isEmpty {
                ContentUnavailableView(
                    "No Grouped Downloads",
                    systemImage: "externaldrive",
                    description: Text("Download an album or playlist to manage it here.")
                )
            } else {
                ForEach(offline.cachedItems(), id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.record.name)
                            .font(.body.weight(.semibold))
                        Text("\(entry.record.trackIds.count) tracks · \(kindLabel(entry.record.kind))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Remove", role: .destructive) {
                            confirmDeleteItemId = entry.id
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloaded Items")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .alert("Remove offline copy?", isPresented: Binding(
            get: { confirmDeleteItemId != nil },
            set: { if !$0 { confirmDeleteItemId = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let id = confirmDeleteItemId {
                    try? offline.removeCachedItem(itemId: id)
                }
                confirmDeleteItemId = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteItemId = nil }
        } message: {
            Text("Tracks shared with other downloads are kept until nothing references them.")
        }
    }

    private func kindLabel(_ kind: OfflineDownloadQueueItemKind) -> String {
        switch kind {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .favorites: return "Favorites"
        case .track: return "Track"
        }
    }
}
