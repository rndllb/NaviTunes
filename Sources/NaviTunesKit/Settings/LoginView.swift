import SwiftUI

/// Sign-in colours, taken from the NaviTunes icon: its mint and aqua gradient on a deep teal ground.
private enum LoginPalette {
    static let canvas = Color(red: 0.012, green: 0.075, blue: 0.092)
    static let mint = Color(red: 0.58, green: 1.0, blue: 0.82)
    static let aqua = Color(red: 0.42, green: 0.96, blue: 1.0)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.72)
    static let captionText = Color.white.opacity(0.55)
    static let iconTint = Color.white.opacity(0.55)
    static let divider = Color.white.opacity(0.12)
    static let actionLabel = canvas
    static let success = Color(red: 0.22, green: 0.78, blue: 0.42)
    static let failure = Color(red: 1, green: 0.38, blue: 0.38)
}

/// White logo artwork bundled for the sign-in screen (`Resources/BackendLogos`).
private enum LoginLogoAsset {
    static func image(_ name: String) -> Image? {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "BackendLogos")
            ?? bundle.url(forResource: name, withExtension: "png")
        guard let url, let data = try? Data(contentsOf: url),
              let cg = ArtworkImageDecoder.cgImage(from: data, maxPixelSize: 1024)
        else { return nil }
        return ArtworkPlatformImage.swiftUIImage(cgImage: cg)
    }
}

/// Sign-in canvas: deep teal, lit from the top by the icon's mint and aqua.
private struct LoginCanvas: View, Equatable {
    var isRegularWidth: Bool

    var body: some View {
        GeometryReader { geo in
            let endRadius = isRegularWidth
                ? hypot(geo.size.width / 2, geo.size.height)
                : max(geo.size.width * 0.72, 220)

            ZStack {
                LoginPalette.canvas
                RadialGradient(
                    colors: [
                        LoginPalette.aqua.opacity(0.30),
                        LoginPalette.mint.opacity(0.14),
                        LoginPalette.canvas,
                    ],
                    center: .top,
                    startRadius: 12,
                    endRadius: endRadius,
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Login: always dark, like the rest of the first-run flow, with the icon's palette.
struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var forgotPasswordHint = false
    @State private var serverDraft = ServerConnectionDraft()
    @State private var isTestingConnection = false
    @State private var testResultMessage: String?
    @State private var testResultIsSuccess = false

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            LoginCanvas(isRegularWidth: isRegularWidth)
                .equatable()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    brandBlock
                        .padding(.top, isRegularWidth ? 56 : 28)
                        .padding(.bottom, 32)

                    credentialsCard
                        .padding(.bottom, 22)

                    errorText

                    VStack(spacing: 12) {
                        loginButton
                        testConnectionButton
                    }
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .tint(LoginPalette.aqua)
        .preferredColorScheme(.dark)
        .onAppear {
            SettingsFormDrafts.pullServer(from: app, into: &serverDraft)
        }
        .onChange(of: app.backendKind) { _, _ in
            app.errorMessage = nil
            testResultMessage = nil
        }
        .alert("Password help", isPresented: $forgotPasswordHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Reset your password in your Jellyfin or Navidrome web interface, or ask your server administrator.")
        }
    }

    // MARK: - Brand

    private var brandBlock: some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                // The white mark on its own, no tile behind it.
                LoginLogoAsset.image("navitunes-mark")?
                    .resizable()
                    .scaledToFit()
                    .frame(width: isRegularWidth ? 176 : 148)
                    .shadow(color: LoginPalette.aqua.opacity(0.4), radius: 26, y: 8)
                    .accessibilityHidden(true)
                Text("NaviTunes")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(LoginPalette.primaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("NaviTunes")

            serverTypePicker
        }
        .frame(maxWidth: .infinity)
    }

    /// Rounded-square tiles for the two servers, under the logo.
    private var serverTypePicker: some View {
        HStack(spacing: 18) {
            ForEach(BackendKind.allCases) { kind in
                serverTile(kind)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tileLogoName(_ kind: BackendKind) -> String {
        switch kind {
        case .jellyfin: "jellyfin"
        case .navidrome: "navidrome"
        }
    }

    /// Jellyfin's mark is a little heavier than Navidrome's vinyl, so it gets more breathing room in the tile.
    private func tileLogoPadding(_ kind: BackendKind, size: CGFloat) -> CGFloat {
        switch kind {
        case .jellyfin: size * 0.24
        case .navidrome: size * 0.2
        }
    }

    private func serverTile(_ kind: BackendKind) -> some View {
        let selected = app.backendKind == kind
        let size: CGFloat = isRegularWidth ? 96 : 86
        return Button {
            app.backendKind = kind
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.16 : 0.08))
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.9 : 0.22), lineWidth: selected ? 1.5 : 1)
                    LoginLogoAsset.image(tileLogoName(kind))?
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .padding(tileLogoPadding(kind, size: size))
                        .foregroundStyle(Color.white.opacity(selected ? 1 : 0.72))
                }
                .frame(width: size, height: size)

                Text(kind.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(selected ? LoginPalette.primaryText : LoginPalette.captionText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Use this server type to sign in")
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
                        .foregroundStyle(Color.white.opacity(0.55)),
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if os(iOS)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                #endif
                .accessibilityLabel("Server URL")
            }

            Divider()
                .background(LoginPalette.divider)
                .padding(.leading, 36)

            loginLabeledField(
                label: "USERNAME",
                systemImage: "person.fill",
            ) {
                TextField(
                    "",
                    text: $serverDraft.username,
                    prompt: Text("username").foregroundStyle(Color.white.opacity(0.55)),
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .musicTextInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textContentType(.username)
                #endif
            }

            Divider()
                .background(LoginPalette.divider)
                .padding(.leading, 36)

            passwordRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.08)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LoginPalette.divider, lineWidth: 1),
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
                .foregroundStyle(LoginPalette.captionText)
                .tracking(0.6)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LoginPalette.iconTint)
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
                    .foregroundStyle(LoginPalette.captionText)
                    .tracking(0.6)
                Spacer(minLength: 8)
                Button {
                    forgotPasswordHint = true
                } label: {
                    Text("FORGOT")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(LoginPalette.aqua)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LoginPalette.iconTint)
                    .frame(width: 22, alignment: .center)

                SecureField(
                    "",
                    text: $serverDraft.password,
                    prompt: Text("Password").foregroundStyle(Color.white.opacity(0.55)),
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                #if os(iOS)
                    .textContentType(.password)
                #endif

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(LoginPalette.divider)
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
                .foregroundStyle(LoginPalette.failure)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
        } else if let msg = testResultMessage {
            Text(msg)
                .font(.footnote.weight(.medium))
                .foregroundStyle(testResultIsSuccess ? LoginPalette.success : LoginPalette.failure)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
        }
    }

    // MARK: - Buttons

    private var loginButton: some View {
        let isDisabled = app.isAuthenticating
            || serverDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || serverDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            SettingsFormDrafts.pushServer(serverDraft, to: app)
            Task { await app.signIn() }
        } label: {
            HStack(spacing: 8) {
                if app.isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LoginPalette.actionLabel)
                }
                Text(app.isAuthenticating ? "SIGNING IN…" : "SIGN IN")
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
            }
            .foregroundStyle(LoginPalette.actionLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [LoginPalette.mint, LoginPalette.aqua],
                            startPoint: .leading,
                            endPoint: .trailing,
                        ),
                    ),
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel("Sign in with \(app.backendKind.title)")
    }

    private var testConnectionButton: some View {
        let isDisabled = isTestingConnection || app.isAuthenticating || trimmedBaseURL.isEmpty

        return Button {
            Task { await runConnectionTest() }
        } label: {
            HStack(spacing: 8) {
                if isTestingConnection {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(isTestingConnection ? "TESTING…" : "TEST CONNECTION")
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5),
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
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
        guard !ServerURL.candidates(raw).isEmpty else {
            testResultMessage = "Invalid server URL."
            testResultIsSuccess = false
            return
        }

        // Take over the message slot from any prior sign-in error.
        app.errorMessage = nil
        testResultMessage = nil
        isTestingConnection = true
        defer { isTestingConnection = false }
        guard let base = await ServerURL.resolved(raw) else {
            testResultMessage = "Invalid server URL."
            testResultIsSuccess = false
            return
        }

        let probeURL: URL
        let serverLabel: String
        switch app.backendKind {
        case .jellyfin:
            probeURL = base.appendingPathComponent("System/Info/Public")
            serverLabel = "Jellyfin"
        case .navidrome:
            var comps = URLComponents(url: base.appendingPathComponent("rest/ping.view"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "u", value: "navitunes-probe"),
                URLQueryItem(name: "p", value: "navitunes-probe"),
                URLQueryItem(name: "v", value: "1.16.1"),
                URLQueryItem(name: "c", value: "NaviTunesKit"),
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
