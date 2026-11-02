import SwiftUI

struct SettingsLibraryDataView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isRefreshingServerStats = false

    var body: some View {
        List {
            yourLibraryStatsSection
            serverCatalogStatsSection
            mixesSection
            albumCacheSection
            LibraryScanControlsView()
            backupSection
            navidromeSharesSection
        }
        .navigationTitle("Library")
        .settingsSubpageChrome()
    }

    /// Counts of what the user has **added** in Vellum, not what exists on the server.
    ///
    /// These three read personal-library membership state, so "Playlists" is the number of
    /// server playlists explicitly added here (`addPlaylistToLibrary`, reachable only from a
    /// playlist's context menu) — **not** how many playlists exist on the server. Zero is the
    /// correct and ordinary reading for someone who has never used that menu item, however many
    /// playlists they own. That is what the old wording hid: "Music you've added in Vellum" read
    /// as a description of the section rather than as the definition of each number, so a
    /// legitimate 0 looked like a failed query. The server's own totals are the section below,
    /// which is where "how many playlists do I have" is actually answered.
    private var yourLibraryStatsSection: some View {
        Section {
            statRow(title: "Songs added", value: app.librarySongIds.count)
            statRow(title: "Albums added", value: app.libraryAlbumEntries.count)
            statRow(title: "Playlists added", value: app.libraryPlaylistEntries.count)
        } header: {
            Text("Added in Vellum")
        } footer: {
            Text("Songs, albums and playlists you've added to your library from inside Vellum, "
                 + "synced across your devices via your personal library playlist. This is not a "
                 + "count of everything on your server — see Server Catalog below for that.")
        }
    }

    /// Whether totals are already in hand — from a previous tap here, or from a "Sync now",
    /// which refreshes them as part of its work.
    private var hasServerTotals: Bool {
        let stats = app.libraryStatistics
        return stats.artistCount != nil
            || stats.albumCount != nil
            || stats.songCount != nil
            || stats.playlistCount != nil
    }

    /// Loaded on request, not on appear.
    ///
    /// Counting the server catalog is the most expensive thing on this page: on Navidrome it
    /// paginates `getAlbumList2` 500 at a time across the whole library and fetches
    /// `libraryArtists(limit: 20_000)`. It used to run from this page's `.task` *and* from the
    /// Settings hub's `onAppear`, so simply opening Settings paid for it. The numbers are
    /// informational, so they are now behind a button.
    private var serverCatalogStatsSection: some View {
        Section {
            if isRefreshingServerStats {
                HStack {
                    Text("Loading server totals…")
                    Spacer()
                    ProgressView()
                        .tint(MusicDesign.accent)
                }
            } else if hasServerTotals {
                statRow(title: "Artists", value: app.libraryStatistics.artistCount)
                statRow(title: "Albums", value: app.libraryStatistics.albumCount)
                statRow(title: "Songs", value: app.libraryStatistics.songCount)
                statRow(title: "Playlists", value: app.libraryStatistics.playlistCount)
                Button {
                    Task { await reloadServerStatistics() }
                } label: {
                    Label("Refresh totals", systemImage: "arrow.clockwise")
                }
                .tint(MusicDesign.accent)
            } else {
                Button {
                    Task { await reloadServerStatistics() }
                } label: {
                    Label("Load totals", systemImage: "number")
                }
                .tint(MusicDesign.accent)
                .disabled(!app.isSignedIn)
            }
        } header: {
            Text("Server Catalog")
        } footer: {
            serverCatalogFooter
        }
    }

    @ViewBuilder
    private var serverCatalogFooter: some View {
        if app.backendKind == .navidrome {
            if app.libraryStatistics.songsMayBeApproximate {
                Text("Navidrome song totals sum per-album track counts and may differ slightly from the true server count.")
            } else {
                Text("Everything on your connected Jellyfin or Navidrome server.")
            }
        } else {
            Text("Everything on your connected Jellyfin or Navidrome server.")
        }
    }

    private func reloadServerStatistics() async {
        isRefreshingServerStats = true
        defer { isRefreshingServerStats = false }
        await app.refreshLibraryStatistics()
    }

    private func statRow(title: String, value: Int?) -> some View {
        LabeledContent(title) {
            Text(value.map { SettingsFormatting.decimalString($0) } ?? "—")
                .foregroundStyle(.secondary)
        }
    }

    private func statRow(title: String, value: Int) -> some View {
        statRow(title: title, value: Optional(value))
    }

    private var mixesSection: some View {
        Section {
            Toggle("Show mixes in Playlists", isOn: $app.showHomeMixesInPlaylists)
                .tint(MusicDesign.accent)
        } header: {
            Text("Mixes")
        } footer: {
            Text("Adds your personalized Made for You mixes (On Repeat, Favorites Mix, and others) to Library → Playlists. They still appear on Home either way.")
        }
    }

    private var albumCacheSection: some View {
        Section {
            Picker("Refresh album metadata", selection: $app.metadataRefreshThreshold) {
                ForEach(MetadataRefreshThreshold.allCases) { threshold in
                    Text(threshold.title).tag(threshold)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Album Cache Refresh")
        } footer: {
            Text("Re-fetch album track lists before playback when the cache is older than this threshold. Helps catch server-side ID changes.")
        }
    }

    private var backupSection: some View {
        ClientBackupControlsView()
    }

    @ViewBuilder
    private var navidromeSharesSection: some View {
        if app.backendKind == .navidrome {
            Section {
                NavigationLink {
                    NavidromeSharesView()
                } label: {
                    Label("Browse share links", systemImage: "link")
                }
            } header: {
                Text("Share Links")
            } footer: {
                Text("View and manage Navidrome share URLs created from this account.")
            }
        }
    }
}

struct ScrobbleBrowserView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List {
            if app.scrobbleService.store.completed.isEmpty {
                ContentUnavailableView(
                    "No scrobbles yet",
                    systemImage: "music.note.list",
                    description: Text("Completed scrobbles appear here after successful server submission.")
                )
            } else {
                ForEach(app.scrobbleService.store.completed) { scrobble in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scrobble.title)
                            .font(.body.weight(.semibold))
                        Text(scrobble.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(scrobble.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Scrobbles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
