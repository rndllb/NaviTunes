import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isCheckingConnection = false
    @State private var connectionSuccess = false

    var body: some View {
        Form {
            librarySection
            syncSection
            mediaQualitySection
            appearanceSection
            pluginsSection
            accountSection
            aboutSection
        }
        .navigationTitle("Settings")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .onAppear {
            Task { await app.refreshServerConnectionHealth() }
        }
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

            VStack(alignment: .leading, spacing: 16) {
                Text("Accent Color")
                    .font(.subheadline.weight(.medium))

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                    spacing: 14
                ) {
                    ForEach(AppAccentPreset.presets) { preset in
                        Button {
                            app.accentPresetId = preset.id
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 44, height: 44)
                                    if app.accentPresetId == preset.id {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 2.5)
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(preset.name)
                                    .font(.caption2)
                                    .foregroundStyle(app.accentPresetId == preset.id ? .white : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                    iconColor: Color(red: 186/255, green: 90/255, blue: 0/255),
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

    // MARK: - Account (server)

    private var accountSection: some View {
        Section {
            Picker("Server type", selection: $app.backendKind) {
                Text("Jellyfin").tag(BackendKind.jellyfin)
                Text("Navidrome").tag(BackendKind.navidrome)
            }
            .tint(MusicDesign.accent)

            TextField(
                app.backendKind == .jellyfin ? "http://192.168.1.x:8096" : "http://192.168.1.x:4533",
                text: $app.baseURLString
            )
            .textContentType(.URL)
            .musicTextInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField("Username", text: $app.username)
                .textContentType(.username)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Password", text: $app.password)
                .textContentType(.password)

            Button {
                Task { await checkConnection() }
            } label: {
                HStack {
                    if isCheckingConnection {
                        ProgressView()
                            .tint(MusicDesign.accent)
                            .scaleEffect(0.8)
                    } else if connectionSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected")
                    } else {
                        Text("Check Connection")
                    }
                }
            }
            .disabled(isCheckingConnection || app.baseURLString.isEmpty || app.username.isEmpty)
            .tint(MusicDesign.accent)

            if app.isSignedIn {
                serverConnectionRow

                LabeledContent("Signed in as") {
                    Text(app.activeLibrary?.displayName ?? app.username)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Sign out", role: .destructive) {
                app.signOut()
            }
        } header: {
            Text("Account")
        } footer: {
            Text(accountSectionFooter)
                .foregroundStyle(accountFooterIsError ? .red : .secondary)
        }
    }

    private var serverKindName: String {
        app.backendKind == .jellyfin ? "Jellyfin" : "Navidrome"
    }

    private var serverConnectionRow: some View {
        LabeledContent("Server") {
            HStack(spacing: 8) {
                if app.serverConnectionHealth == .checking {
                    ProgressView()
                        .tint(MusicDesign.accent)
                        .scaleEffect(0.75)
                } else {
                    Circle()
                        .fill(serverHealthColor)
                        .frame(width: 8, height: 8)
                }
                Text(app.serverConnectionHealth.statusTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverHealthColor: Color {
        switch app.serverConnectionHealth {
        case .connected: return .green
        case .checking, .unknown: return .secondary
        case .noNetwork, .unreachable: return .orange
        }
    }

    private var accountSectionFooter: String {
        if app.isSignedIn {
            return app.serverConnectionHealth.detailText(serverName: serverKindName)
        }
        if let err = app.errorMessage, !err.isEmpty {
            return err
        }
        return app.backendKind == .jellyfin
            ? "Jellyfin is a free, open-source media server. Point Lyra at your server's base URL to stream your music library."
            : "Navidrome is an open-source Subsonic-compatible music server. Enter the base URL where your Navidrome instance is running."
    }

    private var accountFooterIsError: Bool {
        !app.isSignedIn && app.errorMessage != nil
    }

    private func checkConnection() async {
        isCheckingConnection = true
        connectionSuccess = false
        defer { isCheckingConnection = false }
        await app.signIn()
        await app.refreshServerConnectionHealth()
        connectionSuccess = app.serverConnectionHealth.isHealthy
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
                TextField("http://192.168.1.x:8582", text: $app.downtifyBaseURLString)
                    .textContentType(.URL)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save") {
                    app.saveDowntifyURL()
                }
                .tint(MusicDesign.accent)

                if app.downtifyConfigured {
                    Button("Disconnect", role: .destructive) {
                        app.disconnectDowntify()
                    }
                }
            }

            Section {
                Text("Requests open a search sheet at \(app.downtifyBaseURLString.isEmpty ? "<base URL>" : app.downtifyBaseURLString)/search/<query>.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Downtify")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
    }
}
