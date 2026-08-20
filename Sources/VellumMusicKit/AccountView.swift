import PhotosUI
import SwiftUI

/// Identifiable wrapper so a freshly-picked profile image can drive a `.sheet(item:)`
/// crop step before it's uploaded as the magic playlist's cover.
private struct ProfileCropSubject: Identifiable {
    let id = UUID()
    let imageData: Data
}

struct AccountView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isCheckingConnection = false
    @State private var connectionSuccess = false
    @State private var serverDraft = ServerConnectionDraft()
    @State private var profilePickerItem: PhotosPickerItem?
    /// Picked-but-not-yet-framed profile image; drives the crop/rotate sheet (the same
    /// ``SquareImageCropView`` the playlist cover editor uses) before upload.
    @State private var profileCropSubject: ProfileCropSubject?
    /// Presents the photo picker directly when there is no current picture to edit.
    @State private var showProfilePicker = false
    @State private var showProfilePhotoOptions = false

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
            Button {
                // With a picture to edit, offer the options; otherwise go straight to
                // the picker. An action sheet rather than a context menu: UIKit gives no
                // control over menu direction and kept covering the avatar with it.
                if hasCurrentProfilePicture {
                    showProfilePhotoOptions = true
                } else {
                    showProfilePicker = true
                }
            } label: {
                profileAvatarLabel
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(app.isUpdatingProfilePicture || app.libraryMagicPlaylistId == nil)
            .confirmationDialog("Profile Picture", isPresented: $showProfilePhotoOptions, titleVisibility: .hidden) {
                Button("Edit Photo") { editCurrentProfilePicture() }
                Button("Choose Photo") { showProfilePicker = true }
                if app.navidromeMagicPlaylistAvatarURL != nil {
                    Button("Remove Photo", role: .destructive) {
                        Task { await app.clearProfilePicture() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showProfilePicker, selection: $profilePickerItem, matching: .images, photoLibrary: .shared())
            .onChange(of: profilePickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    defer { profilePickerItem = nil }
                    guard let data = try? await newItem.loadTransferable(type: Data.self), !data.isEmpty else {
                        app.errorMessage = "Could not read the selected image."
                        return
                    }
                    // Frame it first — move / scale / rotate — exactly like a playlist cover.
                    profileCropSubject = ProfileCropSubject(imageData: data)
                }
            }
            .sheet(item: $profileCropSubject) { subject in
                profileCropSheet(for: subject)
            }
        } else {
            AccountProfileAvatarView(diameter: 110)
        }
    }

    private var profileAvatarLabel: some View {
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

    /// Only a magic-playlist cover counts as an editable picture (the legacy `getAvatar`
    /// fallback isn't something the user set here). Deliberately *not* gated on the avatar
    /// cache file: the picture can be on screen from the in-memory decoded cache while the
    /// on-disk copy is absent, which made the options sheet never appear.
    private var hasCurrentProfilePicture: Bool {
        app.navidromeMagicPlaylistAvatarURL != nil
    }

    /// Current picture bytes: the avatar cache when it has them, else fetched from the
    /// avatar URL (same approach the playlist cover editor uses).
    private func currentProfilePictureData() async -> Data? {
        if let identity = app.accountAvatarIdentity,
           let data = AccountAvatarCache.loadData(identity: identity),
           !data.isEmpty {
            return data
        }
        guard let url = app.accountAvatarURL,
              let data = await ArtworkURLCache.data(for: url),
              !data.isEmpty else { return nil }
        return data
    }

    /// Opens the crop / rotate editor pre-loaded with the current profile picture.
    private func editCurrentProfilePicture() {
        Task {
            guard let data = await currentProfilePictureData() else {
                showProfilePicker = true
                return
            }
            profileCropSubject = ProfileCropSubject(imageData: data)
        }
    }

    @ViewBuilder
    private func profileCropSheet(for subject: ProfileCropSubject) -> some View {
        #if canImport(UIKit)
        if let uiImage = UIImage(data: subject.imageData) {
            SquareImageCropView(
                image: uiImage,
                onCancel: { profileCropSubject = nil },
                onCrop: { cropped in
                    profileCropSubject = nil
                    Task { await app.updateProfilePictureFromImageData(cropped) }
                },
            )
        } else {
            Color.clear.onAppear {
                profileCropSubject = nil
                Task { await app.updateProfilePictureFromImageData(subject.imageData) }
            }
        }
        #else
        Color.clear.onAppear {
            profileCropSubject = nil
            Task { await app.updateProfilePictureFromImageData(subject.imageData) }
        }
        #endif
    }

    private var profileDisplayName: String {
        if app.isSignedIn {
            let user = app.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return user.isEmpty ? "Signed in" : user
        }
        return "Guest"
    }

    private var profileRoleLine: String {
        app.isSignedIn ? serverKindName : "Vellum Music"
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
                MusicGlassSegmentPillBar(
                    options: Array(BackendKind.allCases),
                    selection: $app.backendKind,
                    title: { $0.title }
                )
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

                TextField("Secondary URL (optional)", text: $serverDraft.secondaryURL, prompt: Text(serverURLPlaceholder))
                    .textContentType(.URL)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif

                Picker("Failover", selection: $app.serverFailoverMode) {
                    ForEach(ServerFailoverMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .tint(MusicDesign.accent)

                if app.isSignedIn,
                   app.serverFailoverMode == .manual,
                   !serverDraft.secondaryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Picker("Active server", selection: $app.activeServerURLRole) {
                        Text("Primary").tag(ActiveServerURLRole.primary)
                        Text("Secondary").tag(ActiveServerURLRole.secondary)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: app.activeServerURLRole) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        Task { await app.switchActiveServerURL(to: newValue) }
                    }
                } else if app.isSignedIn,
                          !serverDraft.secondaryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent("Active server") {
                        Text(app.activeServerURLRole == .primary ? "Primary" : "Secondary")
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    app.trustCurrentServerCertificate()
                } label: {
                    Label("Trust server certificate", systemImage: "lock.shield")
                }

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
