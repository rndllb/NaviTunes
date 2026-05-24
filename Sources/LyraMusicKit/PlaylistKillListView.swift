import SwiftUI

/// Reviewer screen for tracks Kill Mode has queued for removal from a single playlist.
///
/// Receives the parent playlist's current `rows` snapshot and filters down to the rows
/// whose track id appears in `AppModel.killModePendingRemovals[playlistId]`. Both the
/// pending set and the displayed rows are observed via `@EnvironmentObject app`, so a
/// successful commit naturally shrinks the list; when it goes empty the view dismisses
/// itself back to the playlist detail.
///
/// Two delete paths, both confirmation-gated:
/// - Per-row swipe → alert → `commitKillModeRemovals` for that one row.
/// - Top-right "Remove All" → confirmation dialog → commit every currently visible row.
struct PlaylistKillListView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let playlistId: String
    let rows: [PlaylistRowItem]

    @State private var pendingRowDelete: PlaylistRowItem?
    @State private var showRemoveAllConfirm = false

    private var visibleRows: [PlaylistRowItem] {
        let order = app.killModePendingOrderedTrackIds(playlistId: playlistId)
        guard !order.isEmpty else { return [] }
        // Preserve duplicates: a track id may map to multiple rows when a playlist contains
        // the same track twice. Stale ids (no matching row) are silently dropped.
        let rowsByTrackId = Dictionary(grouping: rows, by: { $0.track.id })
        return order.flatMap { rowsByTrackId[$0] ?? [] }
    }

    var body: some View {
        List {
            ForEach(visibleRows) { row in
                rowView(row)
                    .listRowBackground(MusicDesign.background)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            app.restoreFromKillList(playlistId: playlistId, trackId: row.track.id)
                            app.showTransientToast("Kept in Playlist")
                        } label: {
                            Label("Keep", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingRowDelete = row
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .navigationTitle("Songs to Remove")
        .musicNavigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: MusicToolbar.trailingItemPlacement) {
                Button(role: .destructive) {
                    showRemoveAllConfirm = true
                } label: {
                    Text("Remove All")
                }
                .disabled(visibleRows.isEmpty)
            }
        }
        .musicNavigationChrome()
        .alert(
            "Remove from Playlist?",
            isPresented: Binding(
                get: { pendingRowDelete != nil },
                set: { if !$0 { pendingRowDelete = nil } }
            ),
            presenting: pendingRowDelete
        ) { row in
            Button("Cancel", role: .cancel) { pendingRowDelete = nil }
            Button("Remove", role: .destructive) {
                let target = row
                pendingRowDelete = nil
                Task { await commit(rows: [target]) }
            }
        } message: { row in
            Text("Remove \u{201C}\(row.track.title)\u{201D} from this playlist?")
        }
        .confirmationDialog(
            "Remove \(visibleRows.count) song\(visibleRows.count == 1 ? "" : "s") from this playlist?",
            isPresented: $showRemoveAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                let targets = visibleRows
                Task { await commit(rows: targets) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: visibleRows.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    private func rowView(_ row: PlaylistRowItem) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: row.track.artworkURL, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.track.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(row.track.artist)
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func commit(rows: [PlaylistRowItem]) async {
        guard !rows.isEmpty else { return }
        let count = rows.count
        do {
            try await app.commitKillModeRemovals(playlistId: playlistId, rows: rows)
            app.showTransientToast("Removed \(count) song\(count == 1 ? "" : "s")")
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}
