import SwiftUI

/// iOS Settings–style hub: each area opens its own detail page.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List {
            accountSection
            libraryDataSection
            connectivitySection
            playbackSection
            personalizationSection
            pluginsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.settingsBackground)
        .musicNavigationChrome()
        .onAppear {
            app.prefetchAccountAvatar()
            Task { await app.refreshLibraryStatistics() }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
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
                        Text(accountSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var libraryDataSection: some View {
        Section {
            settingsRow("Library", systemImage: "music.note.list", subtitle: librarySubtitle) {
                SettingsLibrarySectionView()
            }
            settingsRow("Sync", systemImage: "arrow.triangle.2.circlepath", subtitle: syncSubtitle) {
                SettingsSyncSectionView()
            }
            settingsRow("Library & Data", systemImage: "externaldrive") {
                SettingsLibraryDataView()
            }
        }
    }

    private var connectivitySection: some View {
        Section {
            settingsRow("Offline", systemImage: "wifi.slash", subtitle: offlineSubtitle) {
                SettingsOfflineSectionView()
            }
            settingsRow("Downloads", systemImage: "arrow.down.circle", subtitle: downloadsSubtitle) {
                SettingsDownloadsSectionView()
            }
        }
    }

    private var playbackSection: some View {
        Section {
            settingsRow("Sound & Playback", systemImage: "speaker.wave.2") {
                SettingsPlaybackView()
            }
        }
    }

    private var personalizationSection: some View {
        Section {
            settingsRow("Appearance", systemImage: "paintbrush", subtitle: appearanceSubtitle) {
                SettingsAppearanceView()
            }
        }
    }

    private var pluginsSection: some View {
        Section {
            settingsRow("Plugins", systemImage: "puzzlepiece.extension", subtitle: pluginsSubtitle) {
                SettingsPluginsView()
            }
        }
    }

    private var aboutSection: some View {
        Section {
            settingsRow("About", systemImage: "info.circle") {
                SettingsAboutView()
            }
        }
    }

    // MARK: - Row builder

    private func settingsRow<Destination: View>(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        @ViewBuilder destination: () -> Destination,
    ) -> some View {
        NavigationLink {
            destination()
                .environmentObject(app)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(MusicDesign.accent)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Subtitles

    private var accountDisplayName: String {
        if app.isSignedIn {
            let user = app.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return user.isEmpty ? "Signed in" : user
        }
        return "Guest"
    }

    private var accountSubtitle: String {
        app.isSignedIn ? "Account info" : "Sign in"
    }

    private var librarySubtitle: String? {
        if !app.librarySongIds.isEmpty {
            return "\(SettingsFormatting.decimalString(app.librarySongIds.count)) in your library"
        }
        guard let songs = app.libraryStatistics.songCount else { return nil }
        return "\(SettingsFormatting.decimalString(songs)) on server"
    }

    private var syncSubtitle: String? {
        app.lastLibrarySyncAt.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened))" }
    }

    private var offlineSubtitle: String? {
        if app.effectiveOfflineMode { return "Active" }
        if app.autoOfflineEnabled { return "Auto offline on" }
        return nil
    }

    private var downloadsSubtitle: String? {
        let count = app.offline.downloadedTrackIds.count
        guard count > 0 else { return nil }
        return "\(count) track\(count == 1 ? "" : "s") on disk"
    }

    private var appearanceSubtitle: String? {
        let accent = AppAccentPreset.preset(id: app.accentPresetId).name
        let icon = AppAccentPreset.preset(id: app.appIconPresetId).name
        if app.accentPresetId == app.appIconPresetId {
            return accent
        }
        return "\(accent) accent · \(icon) icon"
    }

    private var pluginsSubtitle: String? {
        var parts: [String] = []
        if app.acquisitionConfigured {
            parts.append(app.acquisitionCapabilities.displayName)
        }
        let followed = app.subscriptions.followed.count
        if followed > 0 {
            parts.append("\(followed) following")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Acquisition plugin settings

/// Download backend picker, server credentials, and live activity for the active plugin.
struct AcquisitionPluginSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var acquisition: AcquisitionManager
    @State private var drafts: [String: String] = [:]
    @State private var validateMessage: String?
    @State private var validateSucceeded = false
    @State private var isValidating = false

    private var activeKind: AcquisitionPluginKind { acquisition.activePlugin }
    private var capabilities: AcquisitionCapabilities { app.acquisitionCapabilities }

    private var hasMinimumDraft: Bool {
        capabilities.configFields.allSatisfy { field in
            !field.required || !(drafts[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        List {
            pluginSummarySection
            sourceSection
            serverSection
            connectionSection
            if app.acquisitionConfigured {
                disconnectSection
            }
            activitySection
        }
        .onAppear {
            reloadDrafts()
            acquisition.beginLiveRefresh()
        }
        .onDisappear {
            saveDrafts()
            acquisition.endLiveRefresh()
        }
        .onChange(of: acquisition.activePlugin) { _, _ in
            saveDrafts()
            reloadDrafts()
            validateMessage = nil
            validateSucceeded = false
            Task { await acquisition.refreshFromServer() }
        }
        .navigationTitle("Music Requests")
        .settingsSubpageChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await acquisition.refreshFromServer() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh activity now")
            }
        }
    }

    // MARK: Sections

    private var pluginSummarySection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MusicDesign.accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: capabilities.iconName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(MusicDesign.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(capabilities.displayName)
                        .font(.title3.weight(.semibold))
                    Text(pluginSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Source", selection: pluginBinding) {
                ForEach(AcquisitionPluginKind.allCases) { kind in
                    Text(AcquisitionManager.capabilities(for: kind).displayName).tag(kind)
                }
            }
            .pickerStyle(.navigationLink)
        } footer: {
            Text(capabilities.blurb)
        }
    }

    private var serverSection: some View {
        Section {
            ForEach(capabilities.configFields) { field in
                configField(field)
            }
        } header: {
            Text("Server")
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                runValidation()
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "network")
                    Spacer(minLength: 8)
                    if isValidating {
                        ProgressView()
                    } else if validateSucceeded, validateMessage != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .disabled(isValidating || !hasMinimumDraft)
        } footer: {
            connectionFooter
        }
    }

    @ViewBuilder
    private var connectionFooter: some View {
        if let validateMessage, !validateSucceeded {
            Text(validateMessage)
                .foregroundStyle(.red)
        } else if let validateMessage {
            Text(validateMessage)
                .foregroundStyle(.secondary)
        } else if app.acquisitionConfigured {
            Text("Credentials saved. Requests use \(capabilities.displayName).")
        } else {
            Text("Enter your server details, then test the connection.")
        }
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect", role: .destructive) {
                app.disconnectAcquisitionPlugin(activeKind)
                reloadDrafts()
                validateMessage = nil
                validateSucceeded = false
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        let jobs = acquisition.displayJobs
        if jobs.isEmpty {
            if app.acquisitionConfigured {
                Section {
                    ContentUnavailableView(
                        "No Activity",
                        systemImage: "arrow.down.circle",
                        description: Text("Requests you make in Discover or on album pages will appear here.")
                    )
                    .listRowBackground(Color.clear)
                }
            }
        } else {
            Section {
                ForEach(jobs) { job in
                    acquisitionJobRow(job)
                }
            } header: {
                Text("Activity")
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func acquisitionJobRow(_ job: AcquisitionJob) -> some View {
        if let files = job.files, !files.isEmpty {
            DisclosureGroup {
                ForEach(files) { file in
                    acquisitionFileRow(file)
                }
            } label: {
                acquisitionJobSummary(job)
            }
        } else {
            acquisitionJobSummary(job)
        }
    }

    private func acquisitionJobSummary(_ job: AcquisitionJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title ?? "Request")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let artist = job.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let message = job.message, !message.isEmpty, job.status.isTerminal {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(acquisitionStatusTitle(job.status))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                acquisitionJobTrailing(job)
            }
            if !job.status.isTerminal {
                ProgressView(value: min(1, max(0, job.progress)))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func acquisitionJobTrailing(_ job: AcquisitionJob) -> some View {
        if job.status.isTerminal {
            Image(systemName: job.status == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(job.status == .done ? .green : .red)
        } else {
            Text("\(Int((min(1, job.progress) * 100).rounded()))%")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func acquisitionFileRow(_ file: AcquisitionFileProgress) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if let detail = file.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if !file.status.isTerminal {
                    ProgressView(value: min(1, max(0, file.progress)))
                }
            }
            if file.status == .done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if file.status == .failed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Text("\(Int((min(1, file.progress) * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func configField(_ field: AcquisitionConfigField) -> some View {
        switch field.kind {
        case .apiKey, .password:
            SecureField(field.label, text: binding(for: field), prompt: Text(field.placeholder))
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
        default:
            TextField(field.label, text: binding(for: field), prompt: Text(field.placeholder))
                .textContentType(field.kind == .url ? .URL : nil)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(field.kind == .url ? .URL : .default)
                #endif
        }
    }

    // MARK: Helpers

    private var pluginSubtitle: String {
        let mode = capabilities.granularity == .album ? "Album requests" : "Track downloads"
        let status = app.acquisitionConfigured ? "Ready" : "Not configured"
        return "\(mode) · \(status)"
    }

    private func acquisitionStatusTitle(_ status: AcquisitionJobStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .searching: return "Searching"
        case .downloading: return "Downloading"
        case .importing: return "Importing"
        case .done: return "Complete"
        case .failed: return "Failed"
        case .unknown: return "In progress"
        }
    }

    private var pluginBinding: Binding<AcquisitionPluginKind> {
        Binding(
            get: { acquisition.activePlugin },
            set: { acquisition.activePlugin = $0 }
        )
    }

    private func binding(for field: AcquisitionConfigField) -> Binding<String> {
        Binding(
            get: { drafts[field.id] ?? "" },
            set: { drafts[field.id] = $0 }
        )
    }

    private func reloadDrafts() {
        var next: [String: String] = [:]
        for field in capabilities.configFields {
            next[field.id] = AcquisitionConfigStore.value(activeKind, field.id)
        }
        drafts = next
    }

    private func saveDrafts() {
        for field in capabilities.configFields {
            app.setAcquisitionConfig(drafts[field.id] ?? "", for: activeKind, field: field.id)
        }
    }

    private func runValidation() {
        saveDrafts()
        isValidating = true
        validateMessage = nil
        let provider = AcquisitionManager.makeProvider(activeKind)
        Task {
            let result = await provider.validate()
            await MainActor.run {
                isValidating = false
                switch result {
                case .success(let message):
                    validateSucceeded = true
                    validateMessage = message
                case .failure(let error):
                    validateSucceeded = false
                    validateMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
