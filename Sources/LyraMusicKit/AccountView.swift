import PhotosUI
import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isCheckingConnection = false
    @State private var connectionSuccess = false
    @State private var serverDraft = ServerConnectionDraft()
    @State private var profilePickerItem: PhotosPickerItem?

    var body: some View {
        Form {
            userProfileSection
            navidromeAccountSection
            serverSection
        }
        .navigationTitle("Account")
        .musicNavigationBarTitleDisplayMode(.inline)
        .musicNavigationBarVisibleWhenPushed()
        .scrollContentBackground(.hidden)
        .background(MusicDesign.background)
        .musicNavigationChrome()
        .onAppear {
            SettingsFormDrafts.pullServer(from: app, into: &serverDraft)
            app.prefetchAccountAvatar()
            Task { await app.refreshServerConnectionHealth() }
            Task { await app.refreshNavidromeUserMetadata() }
        }
        .onChange(of: app.isSignedIn) { _, _ in
            SettingsFormDrafts.pullServer(from: app, into: &serverDraft)
        }
    }

    // MARK: - User profile

    private var userProfileSection: some View {
        Section {
            VStack(spacing: 12) {
                profileAvatar

                VStack(spacing: 4) {
                    Text(profileDisplayName)
                        .font(.title3.weight(.semibold))
                    Text(profileRoleLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if app.isSignedIn {
                    connectionStatusPill
                }

                if let err = app.profilePictureUpdateError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        }
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if app.isSignedIn, app.backendKind == .navidrome {
            PhotosPicker(selection: $profilePickerItem, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    AccountProfileAvatarView(diameter: 110)
                        .opacity(app.isUpdatingProfilePicture ? 0.5 : 1)
                    if app.isUpdatingProfilePicture {
                        ProgressView()
                            .tint(MusicDesign.accent)
                    } else {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, MusicDesign.accent)
                            .background(Circle().fill(MusicDesign.background))
                            .offset(x: 4, y: 4)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(app.isUpdatingProfilePicture || app.libraryMagicPlaylistId == nil)
            .onChange(of: profilePickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        await app.updateProfilePictureFromImageData(data)
                    }
                    profilePickerItem = nil
                }
            }
        } else {
            AccountProfileAvatarView(diameter: 110)
        }
    }

    private var profileDisplayName: String {
        if app.isSignedIn {
            let user = app.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return user.isEmpty ? "Signed in" : user
        }
        return "Guest"
    }

    private var profileRoleLine: String {
        app.isSignedIn ? serverKindName : "Lyra Music"
    }

    private var trimmedServerURL: String {
        app.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectionStatusPill: some View {
        HStack(spacing: 6) {
            if app.serverConnectionHealth == .checking {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(MusicDesign.accent)
            } else {
                Circle()
                    .fill(serverHealthColor)
                    .frame(width: 7, height: 7)
            }
            Text(connectionPillText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))
    }

    private var connectionPillText: String {
        let host = trimmedServerURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let status = app.serverConnectionHealth.statusTitle
        if host.isEmpty {
            return "\(serverKindName) · \(status)"
        }
        return "\(serverKindName) · \(host) · \(status)"
    }

    // MARK: - Account (Navidrome)

    @ViewBuilder
    private var navidromeAccountSection: some View {
        if app.backendKind == .navidrome, app.isSignedIn, let user = app.navidromeUserMetadata {
            Section {
                accountRow(title: "Username", value: user.username)
                if let email = user.email, !email.isEmpty {
                    accountRow(title: "Email", value: email)
                }
                accountRow(title: "Scrobbling", value: user.scrobblingEnabled ? "Enabled" : "Disabled")
                if let maxBitRate = user.maxBitRate {
                    accountRow(title: "Max bit rate", value: "\(maxBitRate) kbps")
                }
                if let changed = user.avatarLastChanged {
                    accountRow(
                        title: "Avatar updated",
                        value: changed.formatted(date: .abbreviated, time: .shortened),
                    )
                }
                if !user.allowedFolderIds.isEmpty {
                    accountRow(title: "Music folders", value: "\(user.allowedFolderIds.count)")
                }

                DisclosureGroup("Roles") {
                    ForEach(navidromeRoleRows(for: user), id: \.title) { row in
                        roleRow(title: row.title, granted: row.granted)
                    }
                }
                .tint(MusicDesign.accent)
            } header: {
                Text("Account")
            } footer: {
                Text("Reported by Navidrome via the Subsonic getUser API.")
            }
        }
    }

    private func accountRow(title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func roleRow(title: String, granted: Bool) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Image(systemName: granted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(granted ? .green : .secondary)
        }
    }

    private func navidromeRoleRows(for user: NavidromeUserMetadata) -> [(title: String, granted: Bool)] {
        [
            ("Admin", user.adminRole),
            ("Settings", user.settingsRole),
            ("Stream", user.streamRole),
            ("Download", user.downloadRole),
            ("Upload", user.uploadRole),
            ("Playlist", user.playlistRole),
            ("Cover art", user.coverArtRole),
            ("Comment", user.commentRole),
            ("Podcast", user.podcastRole),
            ("Jukebox", user.jukeboxRole),
            ("Share", user.shareRole),
            ("Video conversion", user.videoConversionRole),
        ]
    }

    // MARK: - Server

    private var serverSection: some View {
        Group {
            Section {
                Picker("Server", selection: $app.backendKind) {
                    Text("Jellyfin").tag(BackendKind.jellyfin)
                    Text("Navidrome").tag(BackendKind.navidrome)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }

            Section {
                TextField("Server URL", text: $serverDraft.baseURL, prompt: Text(serverURLPlaceholder))
                    .textContentType(.URL)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif

                TextField("Username", text: $serverDraft.username)
                    .textContentType(.username)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $serverDraft.password)
                    .textContentType(.password)

                Button {
                    Task { await checkConnection() }
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        if isCheckingConnection {
                            ProgressView()
                                .tint(MusicDesign.accent)
                        } else if connectionSuccess {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                        } else {
                            Text(app.isSignedIn ? "Update connection" : "Sign in")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .disabled(
                    isCheckingConnection
                        || serverDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || serverDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                )
            } header: {
                Text("Connection")
            } footer: {
                if let footer = serverSectionFooter {
                    Text(footer)
                        .foregroundStyle(serverFooterIsError ? .red : .secondary)
                }
            }

            if app.isSignedIn {
                Section {
                    Button("Sign out", role: .destructive) {
                        app.signOut()
                    }
                }
            }
        }
    }

    private var serverURLPlaceholder: String {
        app.backendKind == .jellyfin ? "http://192.168.1.x:8096" : "http://192.168.1.x:4533"
    }

    private var serverKindName: String {
        app.backendKind == .jellyfin ? "Jellyfin" : "Navidrome"
    }

    private var serverHealthColor: Color {
        switch app.serverConnectionHealth {
        case .connected: return .green
        case .checking, .unknown: return .secondary
        case .noNetwork, .unreachable: return .orange
        }
    }

    private var serverSectionFooter: String? {
        if let err = app.errorMessage, !err.isEmpty, !app.isSignedIn {
            return err
        }
        if app.isSignedIn {
            let detail = app.serverConnectionHealth.detailText(serverName: serverKindName)
            return detail.isEmpty ? nil : detail
        }
        return "Use your Jellyfin or Navidrome address and account credentials."
    }

    private var serverFooterIsError: Bool {
        !app.isSignedIn && app.errorMessage != nil
    }

    private func checkConnection() async {
        SettingsFormDrafts.pushServer(serverDraft, to: app)
        isCheckingConnection = true
        connectionSuccess = false
        defer { isCheckingConnection = false }
        await app.signIn()
        await app.refreshServerConnectionHealth()
        connectionSuccess = app.serverConnectionHealth.isHealthy
    }
}
