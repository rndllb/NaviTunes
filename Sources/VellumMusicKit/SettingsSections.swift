import SwiftUI

// MARK: - Shared formatting

enum SettingsFormatting {
    static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func decimalString(_ n: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
}

extension View {
    func settingsSubpageChrome() -> some View {
        musicNavigationBarTitleDisplayMode(.inline)
            .musicNavigationBarVisibleWhenPushed()
            .scrollContentBackground(.hidden)
            .background(MusicDesign.settingsBackground)
            .musicNavigationChrome()
    }
}

// MARK: - Library

struct SettingsLibrarySectionView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isRefreshingServerStats = false

    var body: some View {
        Form {
            Section {
                statRow(title: "Songs", value: app.librarySongIds.count)
                statRow(title: "Albums", value: app.libraryAlbumEntries.count)
                statRow(title: "Playlists", value: app.libraryPlaylistEntries.count)
            } header: {
                Text("Your Library")
            } footer: {
                Text("Music you've added in Vellum — synced via your personal library playlist.")
            }

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
        .navigationTitle("Library")
        .settingsSubpageChrome()
        .task { await reloadServerStatistics() }
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
}

// MARK: - Sync

struct SettingsSyncSectionView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Last synced") {
                    if let d = app.lastLibrarySyncAt {
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await app.syncLibraryNow() }
                } label: {
                    HStack {
                        if app.isLibrarySyncing {
                            ProgressView()
                                .tint(MusicDesign.accent)
                                .scaleEffect(0.85)
                        }
                        Text("Sync now")
                    }
                }
                .disabled(!app.isSignedIn || app.isLibrarySyncing)
                .tint(MusicDesign.accent)
            } footer: {
                Text("Refreshes albums, playlists, home shelves, and the discovery track index.")
            }
        }
        .navigationTitle("Sync")
        .settingsSubpageChrome()
    }
}

// MARK: - Offline

struct SettingsOfflineSectionView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Offline mode", isOn: $app.offlineMode)
                    .tint(MusicDesign.accent)
                Toggle("Auto offline", isOn: $app.autoOfflineEnabled)
                    .tint(MusicDesign.accent)
                if app.autoOfflineEnabled {
                    Picker("Auto offline when", selection: $app.autoOfflineMode) {
                        ForEach(AutoOfflineMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .tint(MusicDesign.accent)
                    if app.autoOfflineMode == .homeWifi {
                        if app.homeWifiSSIDs.isEmpty {
                            Text("Add your home Wi‑Fi network name (SSID) below. Location permission may be required on device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(app.homeWifiSSIDs, id: \.self) { ssid in
                            HStack {
                                Text(ssid)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    app.removeHomeWifiSSID(ssid)
                                }
                                .font(.caption)
                            }
                        }
                        HomeWifiSSIDField(onAdd: { app.addHomeWifiSSID($0) })
                    }
                }
                if app.effectiveOfflineMode {
                    Label("Browsing downloaded content only", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Offline mode limits Discovery search and server catalog browsing to downloaded content.")
            }
        }
        .navigationTitle("Offline")
        .settingsSubpageChrome()
    }
}

// MARK: - Downloads

struct SettingsDownloadsSectionView: View {
    @EnvironmentObject private var app: AppModel
    @State private var imageCacheCount: Int?
    @State private var metadataCacheCount: Int?

    var body: some View {
        Form {
            Section {
                LabeledContent("Downloaded files") {
                    Text(SettingsFormatting.formatBytes(app.offline.totalCacheBytes))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Tracks on disk") {
                    Text("\(app.offline.downloadedTrackIds.count)")
                        .foregroundStyle(.secondary)
                }
                Picker("Storage limit", selection: $app.offlineStorageLimitMode) {
                    ForEach(OfflineStorageLimitMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .tint(MusicDesign.accent)
                if app.offlineStorageLimitMode == .fixed {
                    Stepper(value: $app.maxCacheSizeGB, in: 1...512, step: 1) {
                        Text("Cap: \(Int(app.maxCacheSizeGB)) GB")
                    }
                }
                Picker("Concurrent downloads", selection: $app.maxConcurrentDownloads) {
                    ForEach(OfflineMaxConcurrentDownloads.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .tint(MusicDesign.accent)
                Toggle("Wi‑Fi only downloads", isOn: $app.wifiOnlyDownloads)
                    .tint(MusicDesign.accent)
                Toggle("Auto-download favorites", isOn: $app.favoritesAutoDownload)
                    .tint(MusicDesign.accent)
                NavigationLink {
                    DownloadQueueView()
                        .environmentObject(app)
                        .environmentObject(app.offline)
                } label: {
                    HStack {
                        Text("Download queue")
                        Spacer()
                        if activeDownloadCount > 0 {
                            Text("\(activeDownloadCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    DownloadedTracksBrowserView()
                        .environmentObject(app.offline)
                } label: {
                    Text("Browse downloaded music")
                }
                NavigationLink {
                    ImageCacheBrowserView()
                        .environmentObject(app.offline)
                } label: {
                    HStack {
                        Text("Browse image cache")
                        Spacer()
                        Text(cacheCountLabel(imageCacheCount))
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    MetadataCacheBrowserView()
                } label: {
                    HStack {
                        Text("Browse metadata cache")
                        Spacer()
                        Text(cacheCountLabel(metadataCacheCount))
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    OfflineCacheBrowserView()
                        .environmentObject(app.offline)
                } label: {
                    Text("Manage downloaded groups")
                }
                DangerousStorageActionsSection()
                    .environmentObject(app)
            } footer: {
                if app.offline.isStorageFull {
                    Text("Storage limit reached — free space or raise the cap to resume downloads.")
                } else if let budget = app.offline.availableBudgetBytes() {
                    Text("\(SettingsFormatting.formatBytes(budget)) remaining under your cap.")
                }
            }
        }
        .navigationTitle("Downloads")
        .settingsSubpageChrome()
        .onAppear {
            app.offline.recalculateCacheBytes()
            Task {
                let summary = await app.localCacheUsageSummaryAsync()
                imageCacheCount = summary.imageCacheCount
                metadataCacheCount = summary.metadataEntryCount
            }
        }
    }

    private var activeDownloadCount: Int {
        app.offline.downloadQueue.reduce(0) { count, item in
            count + (item.isTerminal ? 0 : 1)
        }
    }

    private func cacheCountLabel(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }
}

// MARK: - Appearance

struct SettingsAppearanceView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $app.themePreference) {
                    ForEach(AppThemePreference.allCases) { pref in
                        Text(pref.title).tag(pref)
                    }
                }
                .tint(MusicDesign.accent)

                Picker("Song list items", selection: $app.songListItemSize) {
                    ForEach(SongListItemSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .tint(MusicDesign.accent)

                Toggle("Album color backdrop", isOn: $app.albumBackdropEnabled)
                    .tint(MusicDesign.accent)
                Toggle("Playlist color backdrop", isOn: $app.playlistBackdropEnabled)
                    .tint(MusicDesign.accent)
                Toggle("Player color backdrop", isOn: $app.playerBackdropEnabled)
                    .tint(MusicDesign.accent)
            }

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Accent Color")
                        .font(.subheadline.weight(.medium))
                    AccentColorPickerGrid(
                        accentPresetId: $app.accentPresetId,
                        customAccentHex: $app.customAccentHex,
                    )
                    .padding(.vertical, 4)

                    if app.accentPresetId == AppAccentPreset.customId {
                        CustomAccentColorControls(
                            accentPresetId: $app.accentPresetId,
                            customAccentHex: $app.customAccentHex,
                        )
                    }
                }
                .padding(.vertical, 8)
            } footer: {
                Text("Accent color tints buttons, highlights, and chrome throughout the app.")
            }

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("App Icon")
                        .font(.subheadline.weight(.medium))
                    AppIconPickerGrid(appIconPresetId: $app.appIconPresetId)
                        .padding(.vertical, 4)
                }
                .padding(.vertical, 8)
            } footer: {
                Text("Chooses the Vellum home screen icon. Independent from accent color — custom accents do not include matching icon artwork.")
            }
        }
        .navigationTitle("Appearance")
        .settingsSubpageChrome()
    }
}

// MARK: - Plugins

struct SettingsPluginsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AcquisitionPluginSettingsView()
                        .environmentObject(app)
                } label: {
                    SettingsPluginRow(
                        icon: app.acquisitionCapabilities.iconName,
                        title: "Music Requests",
                        subtitle: app.acquisitionConfigured
                            ? app.acquisitionCapabilities.displayName
                            : "Set up \(app.acquisitionCapabilities.displayName)",
                    )
                }

                NavigationLink {
                    SubscriptionsView()
                        .environmentObject(app)
                } label: {
                    SettingsPluginRow(
                        icon: "bell",
                        title: "Following",
                        subtitle: app.subscriptions.followed.isEmpty
                            ? "Auto-complete followed artists' discographies"
                            : "\(app.subscriptions.followed.count) artist\(app.subscriptions.followed.count == 1 ? "" : "s")",
                    )
                }
            }
        }
        .navigationTitle("Plugins")
        .settingsSubpageChrome()
    }
}

struct SettingsPluginRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MusicDesign.accent.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MusicDesign.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - About

struct SettingsAboutView: View {
    var body: some View {
        Form {
            Section {
                Text("Vellum Music streams from your Jellyfin or Navidrome server. Offline cache stores encrypted-at-rest copies in Application Support.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .settingsSubpageChrome()
    }
}
