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
    @State private var isReadingCurrentWifi = false
    @State private var homeWifiReadMessage: String?

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
                // Signed in, this bar wrote straight through to `app.backendKind` — swapping the
                // active backend under a live session, with the previous server's library,
                // playlists and magic-playlist id still loaded. Signing out is the way to change
                // it, so the control reflects that rather than accepting a tap it can't honour.
                .disabled(app.isSignedIn)
            } footer: {
                if app.isSignedIn {
                    Text("Sign out to connect to a different server.")
                }
            }

            Section {
                LabeledContent {
                    TextField("Primary address", text: $serverDraft.baseURL, prompt: Text(serverURLPlaceholder))
                        .textContentType(.URL)
                        .musicTextInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                } label: {
                    Label("Primary", systemImage: "globe")
                }
                .disabled(app.isSignedIn)

                LabeledContent {
                    TextField("Local IP address", text: $serverDraft.secondaryURL, prompt: Text(localServerURLPlaceholder))
                        .textContentType(.URL)
                        .musicTextInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                } label: {
                    Label("Fallback", systemImage: "wifi.router")
                }
                .disabled(app.isSignedIn)

                Button {
                    app.trustCurrentServerCertificate()
                } label: {
                    Label("Trust server certificate", systemImage: "lock.shield")
                }
            } header: {
                Text("Server addresses")
            } footer: {
                Text(localFallbackFooter)
            }

            Section {
                Picker("Use fallback", selection: $app.serverFailoverMode) {
                    ForEach(ServerFailoverMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .tint(MusicDesign.accent)

                if app.isSignedIn, hasFallbackURL, app.serverFailoverMode != .disabled {
                    Picker("Connected to", selection: $app.activeServerURLRole) {
                        Text("Primary").tag(ActiveServerURLRole.primary)
                        Text("Fallback").tag(ActiveServerURLRole.secondary)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: app.activeServerURLRole) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        Task { await app.switchActiveServerURL(to: newValue) }
                    }
                }
            } header: {
                Text("Fallback")
            } footer: {
                Text(failoverFooter)
            }

            if showsHomeWifiSection {
                Section {
                    if app.homeWifiSSIDs.isEmpty {
                        Text("Add the Wi‑Fi name you use at home. Vellum checks it before switching to a local fallback address.")
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
                    if let homeWifiReadMessage {
                        Text(homeWifiReadMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button {
                        Task { await addCurrentWifiAsHome() }
                    } label: {
                        HStack {
                            Label("Use current Wi‑Fi", systemImage: "wifi")
                            if isReadingCurrentWifi {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isReadingCurrentWifi)
                } header: {
                    Text("Home Wi‑Fi")
                } footer: {
                    Text("Location access (including Precise Location when prompted) is required so Vellum can read your network name and confirm you're home before using a local fallback address.")
                }
            }

            Section {
                TextField("Username", text: $serverDraft.username)
                    .textContentType(.username)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(app.isSignedIn)

                SecureField("Password", text: $serverDraft.password)
                    .textContentType(.password)
                    .disabled(app.isSignedIn)

                // Hidden rather than disabled while signed in: with every field above locked, the
                // only thing it could submit is the credentials already in use. A button that is
                // present, enabled and incapable of changing anything is the same defect as a
                // control that silently does nothing.
                if !app.isSignedIn {
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
                                Text("Sign in")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .disabled(
                        isCheckingConnection
                            || serverDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || serverDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    )
                }
            } header: {
                Text("Account")
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

    private var serverURLPlaceholder: String { "https://music.example.com" }

    /// Deliberately a LAN address so the field reads as "put your home IP here".
    private var localServerURLPlaceholder: String {
        app.backendKind == .jellyfin ? "http://192.168.1.10:8096" : "http://192.168.1.10:4533"
    }

    private var hasFallbackURL: Bool {
        !serverDraft.secondaryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var failoverFooter: String {
        var lines = [app.serverFailoverMode.detail]
        if app.serverFailoverMode != .disabled, !hasFallbackURL {
            lines.append("Add a fallback address above to use this.")
        } else if app.isSignedIn, hasFallbackURL, let host = activeServerDisplayHost {
            lines.append("Connected to \(host).")
        }
        if hasLocalNetworkFallback {
            lines.append("Local fallback addresses only work on your home Wi‑Fi. Add your network name in Home Wi‑Fi below, and allow location access when prompted.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var hasLocalNetworkFallback: Bool {
        HomePresenceHelper.isLocalNetworkServerURL(app.normalizedServerURL(from: serverDraft.secondaryURL))
            || app.secondaryURLIsLocalNetwork
    }

    /// Home Wi‑Fi names are only relevant when a LAN fallback is configured (or already saved).
    private var showsHomeWifiSection: Bool {
        hasLocalNetworkFallback || !app.homeWifiSSIDs.isEmpty
    }

    private var localFallbackFooter: String {
        if hasLocalNetworkFallback {
            return "Vellum normally connects to the primary address. The local fallback is only used on your home Wi‑Fi — add your network name below and allow location access so Vellum can verify you're home."
        }
        return "Vellum normally connects to the primary address. Add your server's local IP as the fallback so it keeps working on your home Wi‑Fi when the primary address is down or unreachable."
    }

    private func addCurrentWifiAsHome() async {
        guard !isReadingCurrentWifi else { return }
        isReadingCurrentWifi = true
        homeWifiReadMessage = nil
        defer { isReadingCurrentWifi = false }

        switch await HomePresenceHelper.fetchCurrentHomeSSID() {
        case .ssid(let ssid):
            app.addHomeWifiSSID(ssid)
            homeWifiReadMessage = nil
            app.showTransientToast("Added “\(ssid)”")
        case .locationDenied:
            let message = "Allow Location access in Settings → Privacy → Location Services, then try again — or type your Wi‑Fi name above."
            homeWifiReadMessage = message
            app.showTransientToast("Location access is required to read your Wi‑Fi name")
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
            #endif
        case .locationRestricted:
            let message = "Location access is restricted on this device. Type your home Wi‑Fi name above."
            homeWifiReadMessage = message
            app.showTransientToast(message)
        case .preciseLocationRequired:
            let message = "Turn on Precise Location for Vellum in Settings → Privacy → Location Services, then try again — or type your Wi‑Fi name above."
            homeWifiReadMessage = message
            app.showTransientToast("Precise Location is required to read your Wi‑Fi name")
        case .wifiInfoUnavailable:
            let message = "Couldn't read your Wi‑Fi name. Connect to Wi‑Fi (not cellular), confirm Location is allowed, then try again — or type the name from Settings → Wi‑Fi above."
            homeWifiReadMessage = message
            app.showTransientToast("Couldn't read Wi‑Fi name — enter it manually")
        case .unavailable:
            #if targetEnvironment(simulator)
            let message = "Wi‑Fi name isn't available in the Simulator. Type your network name above."
            #else
            let message = "Couldn't read your Wi‑Fi name right now. Type it from Settings → Wi‑Fi above."
            #endif
            homeWifiReadMessage = message
            app.showTransientToast(message)
        }
    }

    private var activeServerDisplayHost: String? {
        let raw = app.activeServerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let components = URLComponents(string: raw), let host = components.host else { return raw }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
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
        if HomePresenceHelper.isLocalNetworkServerURL(app.normalizedServerURL(from: app.secondaryURLString)) {
            await HomePresenceHelper.ensureLocationAccessForHomeDetection()
        }
        isCheckingConnection = true
        connectionSuccess = false
        defer { isCheckingConnection = false }
        await app.signIn()
        await app.refreshServerConnectionHealth()
        connectionSuccess = app.serverConnectionHealth.isHealthy
    }
}
