import SwiftUI

/// The Kill List header's numbers. Only marks that match one of the playlist's own rows count —
/// the same intersection the playlist toolbar badge uses — so ids removed elsewhere or stranded by
/// a rescan cannot inflate the percentages. Both bar segments are clamped so together they never
/// exceed the total, even when `songCount` lags the rows.
struct KillListProgress: Equatable {
    let total: Int
    let kept: Int
    let removed: Int
    let listened: Int
    let percentListened: Int
    let percentRemoved: Int
    let keptFraction: Double
    let removedFraction: Double

    init(rowTrackIds: Set<String>, pending: Set<String>, passed: Set<String>, totalSongCount: Int) {
        let total = max(totalSongCount, 1)
        let removed = min(pending.intersection(rowTrackIds).count, total)
        // A song is red or green, never both; red wins, as in marking.
        let kept = min(passed.intersection(rowTrackIds).subtracting(pending).count, total - removed)
        let listened = kept + removed
        self.total = total
        self.kept = kept
        self.removed = removed
        self.listened = listened
        percentListened = Int((Double(listened) / Double(total) * 100).rounded())
        percentRemoved = Int((Double(removed) / Double(total) * 100).rounded())
        keptFraction = Double(kept) / Double(total)
        removedFraction = Double(removed) / Double(total)
    }
}

/// Reviewer screen for tracks Kill Mode has queued for removal from a single playlist.
///
/// Receives the parent playlist's current `rows` snapshot and filters down to the rows
/// whose track id appears in `AppModel.killModePendingRemovals[playlistId]`. Both the
/// pending set and the displayed rows are observed via `@EnvironmentObject app`, so a
/// successful commit naturally shrinks the list; when it goes empty the view dismisses
/// itself back to the playlist detail.
///
/// Two delete paths, both confirmation-gated, and both routed through
/// `AppModel.runKillModeRemoval` so progress, partial-commit persistence and the completion
/// summary behave identically whether one song goes or a hundred and fifty:
/// - Per-row swipe → alert → run for that one row.
/// - Top-right "Remove All" → confirmation dialog → run over every currently visible row.
///
/// The screen deliberately does NOT dismiss itself when the removal list empties — it also
/// owns "Clear Listen History", which is the only control that resets the listened set.
struct PlaylistKillListView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let playlistId: String
    let rows: [PlaylistRowItem]

    @State private var pendingRowDelete: PlaylistRowItem?
    @State private var showRemoveAllConfirm = false
    /// Copied out of `AppModel` when a run finishes so the alert keeps its content while it
    /// animates away — same pattern as `pendingRowDelete`.
    @State private var finishedSummary: AppModel.KillModeRemovalSummary?

    private var visibleRows: [PlaylistRowItem] {
        let order = app.killModePendingOrderedTrackIds(playlistId: playlistId)
        guard !order.isEmpty else { return [] }
        // Preserve duplicates: a track id may map to multiple rows when a playlist contains
        // the same track twice. Stale ids (no matching row) are silently dropped.
        let rowsByTrackId = Dictionary(grouping: rows, by: { $0.track.id })
        return order.flatMap { rowsByTrackId[$0] ?? [] }
    }

    /// Authoritative playlist song total for the summary percentages — the playlist's
    /// own `songCount` when known, else the snapshot row count.
    private var totalSongCount: Int {
        app.libraryPlaylists.first(where: { $0.id == playlistId })?.songCount ?? rows.count
    }

    /// The live run, but only if it belongs to this playlist.
    private var activeProgress: AppModel.KillModeRemovalProgress? {
        guard let progress = app.killModeRemovalProgress, progress.playlistId == playlistId else { return nil }
        return progress
    }

    private var isRemoving: Bool { activeProgress != nil }

    var body: some View {
        List {
            summaryHeader
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)
            if visibleRows.isEmpty {
                emptyRemovalState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(visibleRows) { row in
                rowView(row)
                    .listRowBackground(MusicDesign.background)
                    .disabled(isRemoving)
                    // Both actions live on the trailing edge on purpose. A leading
                    // `swipeActions` row eats the leading-edge pan, which is the same
                    // gesture as the interactive back-swipe — so dragging right from a row
                    // ran "Keep" instead of popping Kill Mode, and a drag begun at the very
                    // edge fell through to the playlist underneath. Back-swipe is a
                    // system-wide expectation and its absence reads as a bug, so the leading
                    // edge is left to navigation. "Remove" stays declared first, which keeps
                    // it the full-swipe action exactly as before.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingRowDelete = row
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        Button {
                            app.restoreFromKillList(playlistId: playlistId, trackId: row.track.id)
                            app.showTransientToast("Kept in Playlist")
                        } label: {
                            Label("Keep", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .navigationTitle("Kill Mode")
        .musicNavigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: MusicToolbar.trailingItemPlacement) {
                Button(role: .destructive) {
                    showRemoveAllConfirm = true
                } label: {
                    Text("Remove All")
                }
                .disabled(visibleRows.isEmpty || isRemoving)
            }
        }
        .musicNavigationChrome()
        .overlay { removalProgressOverlay }
        .animation(.easeInOut(duration: 0.2), value: isRemoving)
        .onChange(of: app.killModeRemovalSummary) { _, summary in
            guard let summary, summary.playlistId == playlistId else { return }
            app.killModeRemovalSummary = nil
            // A single clean removal is self-evident — a toast is enough. Anything bigger,
            // or anything that did not fully succeed, gets the counts spelled out.
            if summary.isComplete, summary.removed <= 1, summary.alreadyGone == 0 {
                app.showTransientToast(summary.removed == 1 ? "Removed 1 song" : "Nothing to remove")
            } else {
                finishedSummary = summary
            }
        }
        // This view already carries the row-delete `.alert` and the Remove All
        // `.confirmationDialog`. Stacking a third presentation modifier on the SAME view is
        // unreliable in SwiftUI — they compete and one silently never presents — so the
        // completion summary hangs off its own empty background view, which keeps the three
        // independent without changing what the user sees.
        .background {
            Color.clear
                .alert(
                    finishedSummary?.isComplete == false ? "Removal Incomplete" : "Removal Finished",
                    isPresented: Binding(
                        get: { finishedSummary != nil },
                        set: { if !$0 { finishedSummary = nil } }
                    ),
                    presenting: finishedSummary
                ) { summary in
                    if summary.failed > 0 {
                        // Failed songs kept their pending marks, so they are still listed —
                        // continuing re-walks only those, never what already succeeded.
                        Button("Continue") {
                            let targets = visibleRows
                            finishedSummary = nil
                            Task { await commit(rows: targets) }
                        }
                    }
                    Button("Done", role: .cancel) { finishedSummary = nil }
                } message: { summary in
                    Text(summaryMessage(summary))
                }
        }
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
    }

    /// Progress summary: % of the playlist listened (kept + removed) and % marked for
    /// removal, with a two-segment bar (green = kept, red = to-remove) and the
    /// "Clear listen history" reset.
    private var summaryHeader: some View {
        let passedIds = app.killModePassedTrackIds(playlistId: playlistId)
        let progress = KillListProgress(
            rowTrackIds: Set(rows.map(\.track.id)),
            pending: app.killModePendingTrackIds(playlistId: playlistId),
            passed: passedIds,
            totalSongCount: totalSongCount
        )
        // Clearing works on the stored set, so it stays available while any green mark exists —
        // including ones that no longer match a row and so no longer count above.
        let hasListenHistory = !passedIds.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(progress.percentListened)% listened")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(progress.listened) of \(progress.total) · \(progress.removed) to remove")
                        .font(.caption)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                Spacer(minLength: 8)
                Text("\(progress.percentRemoved)% removed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.green)
                            .frame(width: w * progress.keptFraction)
                        Rectangle().fill(Color.red)
                            .frame(width: w * progress.removedFraction)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 6)
            Button {
                app.clearKillModeListenHistory(playlistId: playlistId)
                app.showTransientToast("Listen history cleared")
            } label: {
                Label("Clear Listen History", systemImage: "arrow.counterclockwise")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MusicDesign.accent)
            .disabled(!hasListenHistory)
            .opacity(hasListenHistory ? 1 : 0.4)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    /// Shown when nothing is queued for removal. This screen is still worth reaching in
    /// that state — it owns "Clear Listen History" — so it must read as "you are done here",
    /// not as a broken or empty screen.
    private var emptyRemovalState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MusicDesign.secondaryLabel)
            Text("Nothing queued for removal")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Skip a song while this playlist is playing to queue it here.")
                .font(.footnote)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
    }

    /// Determinate, never a bare spinner: the whole point is being able to tell working
    /// from stalled from done. Skipped for a single-song swipe, where it would just flash.
    @ViewBuilder
    private var removalProgressOverlay: some View {
        if let progress = activeProgress, progress.total > 1 {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(progressTitle(progress))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(.red)
                    Text(progressDetail(progress))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                .padding(20)
                .frame(maxWidth: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .transition(.opacity)
        }
    }

    private func progressTitle(_ progress: AppModel.KillModeRemovalProgress) -> String {
        switch progress.phase {
        case .preparing: return "Checking playlist\u{2026}"
        case .removing: return "Removing songs"
        case .refreshing: return "Finishing up\u{2026}"
        }
    }

    private func progressDetail(_ progress: AppModel.KillModeRemovalProgress) -> String {
        switch progress.phase {
        case .preparing:
            return "Preparing \(progress.total) song\(progress.total == 1 ? "" : "s")"
        case .removing:
            return "Removing \(min(progress.completed + 1, progress.total)) of \(progress.total)"
        case .refreshing:
            return "Removed \(progress.completed) of \(progress.total)"
        }
    }

    private func summaryMessage(_ summary: AppModel.KillModeRemovalSummary) -> String {
        var parts: [String] = ["Removed \(summary.removed) song\(summary.removed == 1 ? "" : "s")."]
        if summary.alreadyGone > 0 {
            parts.append("\(summary.alreadyGone) \(summary.alreadyGone == 1 ? "was" : "were") already gone from this playlist.")
        }
        if summary.failed > 0 {
            parts.append("\(summary.failed) could not be removed and \(summary.failed == 1 ? "is" : "are") still listed.")
        }
        if let message = summary.errorMessage, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " ")
    }

    private func rowView(_ row: PlaylistRowItem) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(url: app.resolvedArtworkURL(for: row.track), cornerRadius: 6)
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

    /// Every delete path goes through the same orchestrated run — see `runKillModeRemoval`
    /// for the progress / background-assertion / resume behaviour. Reporting is handled by
    /// the `killModeRemovalSummary` observer above, not here.
    private func commit(rows: [PlaylistRowItem]) async {
        guard !rows.isEmpty else { return }
        await app.runKillModeRemoval(playlistId: playlistId, rows: rows)
    }
}
