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
            listeningHistorySection
            LibraryScanControlsView()
            backupSection
            navidromeSharesSection
        }
        .navigationTitle("Library")
        .settingsSubpageChrome()
        .task { await reloadServerStatistics() }
    }

    private var yourLibraryStatsSection: some View {
        Section {
            statRow(title: "Songs", value: app.librarySongIds.count)
            statRow(title: "Albums", value: app.libraryAlbumEntries.count)
            statRow(title: "Playlists", value: app.libraryPlaylistEntries.count)
        } header: {
            Text("Your Library")
        } footer: {
            Text("Music you've added in Vellum — synced via your personal library playlist.")
        }
    }

    private var serverCatalogStatsSection: some View {
        Section {
            if isRefreshingServerStats {
                HStack {
                    Text("Loading server totals…")
                    Spacer()
                    ProgressView()
                        .tint(MusicDesign.accent)
                }
            }
            statRow(title: "Artists", value: app.libraryStatistics.artistCount)
            statRow(title: "Albums", value: app.libraryStatistics.albumCount)
            statRow(title: "Songs", value: app.libraryStatistics.songCount)
            statRow(title: "Playlists", value: app.libraryStatistics.playlistCount)
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

    private var listeningHistorySection: some View {
        Section {
            HStack {
                Text("Pending scrobbles")
                Spacer()
                Text("\(app.scrobbleService.store.pending.count)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Completed scrobbles")
                Spacer()
                Text("\(app.scrobbleService.store.completed.count)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Exclusions")
                Spacer()
                Text("\(app.scrobbleService.store.exclusions.count)")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                MyListeningView()
            } label: {
                Label("My Listening", systemImage: "chart.bar.fill")
            }
            NavigationLink {
                ScrobbleBrowserView()
            } label: {
                Label("Browse scrobbles", systemImage: "list.bullet")
            }
            NavigationLink {
                ScrobbleExclusionBrowserView()
            } label: {
                Label("Manage exclusions", systemImage: "eye.slash")
            }
        } header: {
            Text("Listening History")
        } footer: {
            Text("Scrobbles are submitted to your server when a track passes the playback threshold (~50% or 30 seconds).")
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

struct ScrobbleExclusionBrowserView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List {
            if app.scrobbleService.store.exclusions.isEmpty {
                ContentUnavailableView(
                    "No exclusions",
                    systemImage: "eye.slash",
                    description: Text("Exclude albums, artists, or playlists from listening history via their context menus.")
                )
            } else {
                ForEach(app.scrobbleService.store.exclusions) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.body.weight(.medium))
                            Text(item.kind.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            app.scrobbleService.store.removeExclusion(id: item.id, kind: item.kind)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Exclusions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
