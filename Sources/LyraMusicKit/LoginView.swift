import SwiftUI

/// Login with accent blobs and CTA — follows system appearance (dark matches ``MusicDesign`` black chrome).
struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var forgotPasswordHint = false
    @State private var serverDraft = ServerConnectionDraft()
    @State private var isTestingConnection = false
    @State private var testResultMessage: String?
    @State private var testResultIsSuccess = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            canvasBackground
                .ignoresSafeArea()

            loginAccentBlobs

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    logoBlock
                        .padding(.top, 36)
                        .padding(.bottom, 28)

                    headerBlock
                        .padding(.bottom, 24)

                    appearanceBlock
                        .padding(.bottom, 28)

                    serverTypePicker
                        .padding(.bottom, 18)

                    credentialsCard
                        .padding(.bottom, 22)

                    errorText

                    HStack(spacing: 0) {
                        testConnectionButton
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 14)

                    loginButton
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 44)
            }
        }
        .id("\(app.accentPresetId)-\(app.themePreference.rawValue)")
        .onAppear {
            SettingsFormDrafts.pullServer(from: app, into: &serverDraft)
        }
        .alert("Password help", isPresented: $forgotPasswordHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Reset your password in your Jellyfin or Navidrome web interface, or ask your server administrator.")
        }
    }

    // MARK: - Colors (dark / light)

    private var canvasBackground: Color {
        isDark ? MusicDesign.background : Color(red: 0.98, green: 0.98, blue: 0.99)
    }

    private var primaryText: Color {
        isDark ? .white : Color(white: 0.1)
    }

    private var secondaryText: Color {
        isDark ? MusicDesign.secondaryLabel : Color(white: 0.44)
    }

    private var captionText: Color {
        isDark ? MusicDesign.secondaryLabel : Color(white: 0.52)
    }

    private var iconTint: Color {
        isDark ? Color.white.opacity(0.55) : Color(white: 0.62)
    }

    private var fieldValueText: Color {
        isDark ? .white : Color(white: 0.12)
    }

    private var dividerLine: Color {
        isDark ? MusicDesign.separator : Color(white: 0.9)
    }

    private var passwordUnderline: Color {
        isDark ? MusicDesign.separator : Color(white: 0.88)
    }

    // MARK: - Accent ornaments

    private var loginAccentBlobs: some View {
        GeometryReader { geo in
            ZStack {
                accentBlob
                    .frame(width: geo.size.width * 0.62, height: geo.size.width * 0.52)
                    .position(x: geo.size.width * 0.88, y: geo.size.height * 0.08)

                accentBlob
                    .frame(width: geo.size.width * 0.72, height: geo.size.width * 0.58)
                    .position(x: geo.size.width * 0.82, y: geo.size.height * 0.94)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var accentBlob: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        MusicDesign.accent.opacity(isDark ? 0.42 : 0.5),
                        MusicDesign.accent.opacity(isDark ? 0.14 : 0.18),
                        MusicDesign.accent.opacity(0),
                    ],
                    center: .center,
                    startRadius: 8,
                    endRadius: 140,
                ),
            )
            .blur(radius: 26)
    }

    // MARK: - Logo & header

    private var logoBlock: some View {
        VStack(spacing: 14) {
            LyraAccentLogoView(accentPresetId: app.accentPresetId, size: 88, showsIconPlate: true)
                .animation(.easeInOut(duration: 0.2), value: app.accentPresetId)
            Text("Lyra Music")
                .font(.title2.weight(.bold))
                .foregroundStyle(primaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Login")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(primaryText)

            Text("Please sign in to continue.")
                .font(.subheadline)
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceBlock: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                loginSectionLabel("THEME")
                Picker("Theme", selection: $app.themePreference) {
                    ForEach(AppThemePreference.allCases) { pref in
                        Text(pref.title).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(isDark ? MusicDesign.accent : nil)
            }

            VStack(alignment: .leading, spacing: 12) {
                loginSectionLabel("ACCENT COLOR")
                AccentColorPickerGrid(
                    accentPresetId: $app.accentPresetId,
                    showsLabels: false,
                    swatchSize: 52,
                    selectedLabelColor: primaryText,
                    unselectedLabelColor: secondaryText,
                )
            }
        }
    }

    private func loginSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(captionText)
            .tracking(0.6)
    }

    private var serverTypePicker: some View {
        Picker("Server", selection: $app.backendKind) {
            ForEach(BackendKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .tint(isDark ? MusicDesign.accent : nil)
    }

    private var serverURLPlaceholder: String {
        app.backendKind == .jellyfin ? "http://192.168.1.x:8096" : "http://192.168.1.x:4533"
    }

    // MARK: - Fields

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            loginLabeledField(
                label: "SERVER URL",
                systemImage: "link",
            ) {
                TextField(
                    "",
                    text: $serverDraft.baseURL,
                    prompt: Text(serverURLPlaceholder)
                        .foregroundStyle(MusicDesign.accent.opacity(isDark ? 0.82 : 0.78)),
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(fieldValueText)
                .tint(MusicDesign.accent)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if os(iOS)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                #endif
                .accessibilityLabel("Server URL")
            }

            Divider()
                .background(dividerLine)
                .padding(.leading, 36)

            loginLabeledField(
                label: "USERNAME",
                systemImage: "person.fill",
            ) {
                TextField("Username", text: $serverDraft.username)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(fieldValueText)
                    .tint(MusicDesign.accent)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textContentType(.username)
                    #endif
            }

            Divider()
                .background(dividerLine)
                .padding(.leading, 36)

            passwordRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color.white.opacity(0.08) : Color.white)
                .shadow(
                    color: isDark ? Color.clear : Color.black.opacity(0.07),
                    radius: 18,
                    x: 0,
                    y: 10,
                ),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDark ? MusicDesign.separator : Color.clear, lineWidth: 1),
        )
    }

    private func loginLabeledField<Content: View>(
        label: String,
        systemImage: String,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(captionText)
                .tracking(0.6)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 22, alignment: .center)

                content()
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.vertical, 12)
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PASSWORD")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(captionText)
                    .tracking(0.6)
                Spacer(minLength: 8)
                Button {
                    forgotPasswordHint = true
                } label: {
                    Text("FORGOT")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(MusicDesign.accent)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 22, alignment: .center)

                SecureField("Password", text: $serverDraft.password)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(fieldValueText)
                    .tint(MusicDesign.accent)
                    #if os(iOS)
                        .textContentType(.password)
                    #endif

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(passwordUnderline)
                .frame(height: 1)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var errorText: some View {
        // Sign-in errors always win the slot. Test-connection results take the slot while
        // there is no sign-in error; success renders green, failure renders red.
        if let err = app.errorMessage {
            Text(err)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(red: 1, green: 0.38, blue: 0.38))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
        } else if let msg = testResultMessage {
            Text(msg)
                .font(.footnote.weight(.medium))
                .foregroundStyle(testResultIsSuccess
                    ? Color(red: 0.22, green: 0.78, blue: 0.42)
                    : Color(red: 1, green: 0.38, blue: 0.38))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
        }
    }

    private var loginButtonGradient: LinearGradient {
        LinearGradient(
            colors: [
                MusicDesign.accent,
                MusicDesign.accent.opacity(0.78),
            ],
            startPoint: .leading,
            endPoint: .trailing,
        )
    }

    private var loginButton: some View {
        Button {
            SettingsFormDrafts.pushServer(serverDraft, to: app)
            Task { await app.signIn() }
        } label: {
            HStack(spacing: 10) {
                if app.isAuthenticating {
                    ProgressView()
                        .tint(.white)
                }
                Text(app.isAuthenticating ? "SIGNING IN…" : "LOGIN")
                    .font(.subheadline.weight(.bold))
                    .tracking(1.1)
                if !app.isAuthenticating {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(loginButtonGradient),
            )
            .shadow(color: MusicDesign.accent.opacity(isDark ? 0.45 : 0.35), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(
            app.isAuthenticating
                || serverDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || serverDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        )
        .opacity(
            app.isAuthenticating
                || serverDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || serverDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? 0.42
                : 1,
        )
    }

    private var testConnectionButton: some View {
        Button {
            Task { await runConnectionTest() }
        } label: {
            HStack(spacing: 8) {
                if isTestingConnection {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MusicDesign.accent)
                }
                Text(isTestingConnection ? "TESTING…" : "TEST CONNECTION")
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(MusicDesign.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .strokeBorder(MusicDesign.accent.opacity(isDark ? 0.55 : 0.45), lineWidth: 1.2),
            )
        }
        .buttonStyle(.plain)
        .disabled(isTestingConnection || app.isAuthenticating || trimmedBaseURL.isEmpty)
        .opacity(isTestingConnection || app.isAuthenticating || trimmedBaseURL.isEmpty ? 0.42 : 1)
        .accessibilityLabel("Test server connection")
    }

    private var trimmedBaseURL: String {
        serverDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No-auth reachability probe: hits a public endpoint matching the selected backend
    /// (`/System/Info/Public` for Jellyfin, `/rest/ping.view` for Navidrome). Surfaces the
    /// outcome in the same slot the sign-in error uses, in green on success and red on failure.
    private func runConnectionTest() async {
        guard !isTestingConnection else { return }
        let raw = trimmedBaseURL
        guard !raw.isEmpty else { return }
        guard let base = URL(string: raw), base.scheme != nil, base.host != nil else {
            testResultMessage = "Invalid server URL."
            testResultIsSuccess = false
            return
        }

        // Take over the message slot from any prior sign-in error.
        app.errorMessage = nil
        testResultMessage = nil
        isTestingConnection = true
        defer { isTestingConnection = false }

        let probeURL: URL
        let serverLabel: String
        switch app.backendKind {
        case .jellyfin:
            probeURL = base.appendingPathComponent("System/Info/Public")
            serverLabel = "Jellyfin"
        case .navidrome:
            var comps = URLComponents(url: base.appendingPathComponent("rest/ping.view"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "u", value: "lyra-probe"),
                URLQueryItem(name: "p", value: "lyra-probe"),
                URLQueryItem(name: "v", value: "1.16.1"),
                URLQueryItem(name: "c", value: "LyraMusicKit"),
                URLQueryItem(name: "f", value: "json"),
            ]
            probeURL = comps?.url ?? base.appendingPathComponent("rest/ping.view")
            serverLabel = "Navidrome"
        }

        var req = URLRequest(url: probeURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                testResultMessage = "Server responded with an unexpected reply."
                testResultIsSuccess = false
                return
            }
            switch app.backendKind {
            case .jellyfin:
                // Jellyfin's public-info endpoint should always return 200 with a JSON body
                // containing ServerName / Version. 401/403 here would mean someone fronted
                // the server with auth, but the server itself is still reachable.
                if (200 ..< 300).contains(http.statusCode),
                   let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = (body["ServerName"] as? String) ?? (body["serverName"] as? String) {
                    let version = (body["Version"] as? String) ?? (body["version"] as? String) ?? "?"
                    testResultMessage = "Connected to \(name) (Jellyfin \(version))."
                    testResultIsSuccess = true
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    testResultMessage = "Reached the server, but it requires auth at the public-info endpoint."
                    testResultIsSuccess = true
                } else {
                    testResultMessage = "Server reached, but it doesn't look like a \(serverLabel) server (HTTP \(http.statusCode))."
                    testResultIsSuccess = false
                }
            case .navidrome:
                if (200 ..< 300).contains(http.statusCode),
                   let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sub = body["subsonic-response"] as? [String: Any] {
                    let version = (sub["version"] as? String) ?? "?"
                    // Wrong-credentials is a successful connection — the server replied with a Subsonic
                    // error payload, which proves it's a Subsonic-compatible server we reached.
                    testResultMessage = "Connected to Navidrome / Subsonic API \(version)."
                    testResultIsSuccess = true
                } else {
                    testResultMessage = "Server reached, but it doesn't look like a \(serverLabel) server (HTTP \(http.statusCode))."
                    testResultIsSuccess = false
                }
            }
        } catch let urlError as URLError {
            testResultMessage = friendlyMessage(for: urlError)
            testResultIsSuccess = false
        } catch {
            testResultMessage = "Connection failed: \(error.localizedDescription)"
            testResultIsSuccess = false
        }
    }

    private func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "Connection timed out."
        case .cannotFindHost:
            return "Couldn't find that host."
        case .cannotConnectToHost:
            return "Couldn't connect to that host."
        case .notConnectedToInternet:
            return "Not connected to the internet."
        case .networkConnectionLost:
            return "Network connection lost."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "TLS handshake failed — check the server certificate."
        case .badURL, .unsupportedURL:
            return "Invalid server URL."
        case .appTransportSecurityRequiresSecureConnection:
            return "App Transport Security blocked this URL."
        default:
            return "Connection failed: \(error.localizedDescription)"
        }
    }
}
