import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            accountNavigationSection
            librarySection
            syncSection
            mediaQualitySection
            appearanceSection
            pluginsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .onAppear {
            app.prefetchAccountAvatar()
            // Statistics are pulled on appear rather than during bootstrap so the
            // first-launch sync doesn't pay for counts the user can't yet see.
            Task { await app.refreshLibraryStatistics() }
        }
    }

    // MARK: - Account

    private var accountNavigationSection: some View {
        Section {
            NavigationLink {
                AccountView()
                    .environmentObject(app)
            } label: {
                HStack(spacing: 14) {
                    AccountProfileAvatarView(diameter: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountDisplayName)
                            .font(.body.weight(.semibold))
                        Text("Account info")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var accountDisplayName: String {
        if app.isSignedIn {
            let user = app.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return user.isEmpty ? "Signed in" : user
        }
        return "Guest"
    }

    // MARK: - Library

    private var librarySection: some View {
        Section {
            statRow(title: "Artists", value: app.libraryStatistics.artistCount)
            statRow(title: "Albums", value: app.libraryStatistics.albumCount)
            statRow(title: "Songs", value: app.libraryStatistics.songCount)
            statRow(title: "Playlists", value: app.libraryStatistics.playlistCount)
            if app.backendKind == .navidrome {
                Text("Navidrome totals are approximate when the library exceeds the fetch cap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Library")
        }
    }

    private func statRow(title: String, value: Int?) -> some View {
        LabeledContent(title) {
            Text(value.map { Self.decimalString($0) } ?? "—")
                .foregroundStyle(.secondary)
        }
    }

    private static func decimalString(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Sync

    private var syncSection: some View {
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
        } header: {
            Text("Sync")
        } footer: {
            Text("Refreshes albums, playlists, home shelves, and the discovery track index.")
        }
    }

    // MARK: - Media quality

    private var mediaQualitySection: some View {
        Section {
            networkQualityHint
            Picker("Wi‑Fi streaming", selection: $app.wifiStreamQuality) {
                ForEach(StreamQualityTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Cellular streaming", selection: $app.cellularStreamQuality) {
                ForEach(StreamQualityTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Downloads", selection: $app.downloadQualityTier) {
                ForEach(DownloadQualityTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Media quality")
        } footer: {
            Text("Streaming tier follows the active network (Wi‑Fi vs cellular). Downloads use the tier you pick here.")
        }
    }

    @ViewBuilder
    private var networkQualityHint: some View {
        if app.prefersCellularStreamingQuality {
            Label("Using cellular streaming tier", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Using Wi‑Fi streaming tier", systemImage: "wifi")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
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

            VStack(alignment: .leading, spacing: 16) {
                Text("Accent Color")
                    .font(.subheadline.weight(.medium))
                AccentColorPickerGrid(accentPresetId: $app.accentPresetId)
                    .padding(.vertical, 4)
            }
            .padding(.vertical, 8)
        } header: {
            Text("Appearance")
        }
    }

    // MARK: - Plugins

    private var pluginsSection: some View {
        Section {
            Toggle(isOn: $app.musicBrainzEnabled) {
                pluginRow(
                    icon: "globe",
                    iconColor: MusicDesign.accent,
                    title: "MusicBrainz",
                    subtitle: "Recent releases in New tab"
                )
            }
            .onChange(of: app.musicBrainzEnabled) { _, _ in
                Task { await app.refreshNewTabBrowse() }
            }

            NavigationLink {
                DowntifyPluginView()
                    .environmentObject(app)
            } label: {
                pluginRow(
                    icon: "arrow.down.to.line",
                    iconColor: MusicDesign.accent,
                    title: "Downtify",
                    subtitle: "One-tap download requests"
                )
            }
        } header: {
            Text("Plugins")
        }
    }

    private func pluginRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
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

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Text("Lyra Music streams from your Jellyfin or Navidrome server. Offline cache stores encrypted-at-rest copies in Application Support.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("About")
        }
    }
}

// MARK: - Downtify plugin detail

private struct DowntifyPluginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var baseURLDraft = ""

    var body: some View {
        Form {
            Section {
                Text("Downtify is a companion app that intercepts download requests from Lyra and saves audio files to your chosen destination. When configured, a download button appears on track rows that opens a search sheet in Downtify.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            Section("Server URL") {
                TextField("http://192.168.1.x:8582", text: $baseURLDraft)
                    .textContentType(.URL)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save") {
                    app.downtifyBaseURLString = baseURLDraft
                    app.saveDowntifyURL()
                }
                .tint(MusicDesign.accent)

                if app.downtifyConfigured {
                    Button("Disconnect", role: .destructive) {
                        app.disconnectDowntify()
                        baseURLDraft = ""
                    }
                }
            }

            Section {
                Text(downtifyFooterText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            baseURLDraft = app.downtifyBaseURLString
        }
        .navigationTitle("Downtify")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
    }

    private var downtifyFooterText: String {
        let base = app.downtifyBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "Requests open a search sheet at <base URL>/search/<query> after you save."
        }
        return "Requests open a search sheet at \(base)/search/<query>."
    }
}
