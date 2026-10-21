import SwiftUI

// MARK: - Model

/// Version and build as the user should read them, from the app bundle's Info.plist.
///
/// Takes the dictionary rather than reading `Bundle.main` itself so tests can hand it a fixture:
/// the unit-test host's own bundle carries a different version from the app's.
struct AppVersionInfo: Equatable {
    let version: String?
    let build: String?

    init(infoDictionary: [String: Any]?) {
        version = Self.nonEmpty(infoDictionary?["CFBundleShortVersionString"])
        build = Self.nonEmpty(infoDictionary?["CFBundleVersion"])
    }

    static var current: AppVersionInfo { AppVersionInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// "1.1 (4)"; just the version when there is no build number; "Unknown" when there is neither.
    var displayString: String {
        switch (version, build) {
        case let (v?, b?) where v != b: return "\(v) (\(b))"
        case let (v?, _): return v
        case let (nil, b?): return "Build \(b)"
        case (nil, nil): return "Unknown"
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// The connected server as About shows it: host and port only, never the path or query
/// (a reverse-proxy path can carry a token, and the scheme is noise here).
enum AboutServerSummary {
    static func displayAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else {
            return trimmed
        }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
    }
}

/// A service or project the app depends on, credited on About.
struct AboutAcknowledgement: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let url: URL
}

/// A licence whose text the app must carry, shown in full on its own page.
struct AboutLicence: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let text: String
    let url: URL?
}

/// What About credits and which licence texts it carries. Data, not view code, so the
/// obligations can be checked by a test: Radio Browser and MusicBrainz attribution are
/// conditions of using those services, and the Beat This weights are MIT licensed, which
/// requires the copyright notice and permission notice to travel with the app.
enum AboutCredits {
    static let acknowledgements: [AboutAcknowledgement] = [
        AboutAcknowledgement(
            id: "radio-browser",
            name: "Radio Browser",
            detail: "The radio station directory comes from Radio Browser, a free, community-run database. Station names, logos and streams belong to their broadcasters.",
            url: URL(string: "https://www.radio-browser.info")!
        ),
        AboutAcknowledgement(
            id: "musicbrainz",
            name: "MusicBrainz",
            detail: "Artist and release metadata comes from MusicBrainz, the open music encyclopedia. MusicBrainz core data is released under CC0.",
            url: URL(string: "https://musicbrainz.org")!
        ),
        AboutAcknowledgement(
            id: "beat-this",
            name: "Beat This",
            detail: "AutoMix finds beats with the small Beat This model by the Institute of Computational Perception, JKU Linz, converted to Core ML.",
            url: URL(string: "https://github.com/CPJKU/beat_this")!
        ),
    ]

    static let licences: [AboutLicence] = [
        AboutLicence(
            id: "vellum",
            title: "Vellum Music",
            subtitle: "PolyForm Noncommercial 1.0.0",
            text: """
            Vellum Music is released under the PolyForm Noncommercial License 1.0.0.

            In plain words: you may use, study, change, and share this app's code for any noncommercial purpose, such as personal use, research, education, or a hobby project. You may not sell it, charge for it, build a paid product or service on it, or otherwise use it to make money without the copyright holders' permission. Keep the licence and its copyright notice with any copy you pass on.

            The full licence text is at polyformproject.org and in the LICENSE file of the source code.
            """,
            url: URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0")!
        ),
        AboutLicence(
            id: "beat-this",
            title: "Beat This",
            subtitle: "MIT License",
            text: """
            MIT License

            Copyright (c) 2024 Institute of Computational Perception, JKU Linz, Austria

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """,
            url: URL(string: "https://github.com/CPJKU/beat_this/blob/main/LICENSE")!
        ),
    ]
}

// MARK: - Views

/// Settings → About: version and build, the connected server, acknowledgements, licences.
struct SettingsAboutView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL

    private let versionInfo = AppVersionInfo.current

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionInfo.displayString)
            } header: {
                Text("Vellum Music")
            } footer: {
                Text("Vellum Music streams from your Jellyfin or Navidrome server. Offline cache stores encrypted-at-rest copies in Application Support.")
            }

            serverSection

            Section {
                ForEach(AboutCredits.acknowledgements) { credit in
                    // A plain button rather than `Link`: a `Link` tints its whole label, which
                    // turned two lines of attribution into a paragraph of accent colour.
                    Button {
                        openURL(credit.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(credit.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(credit.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(credit.url.host ?? "the website")")
                }
            } header: {
                Text("Acknowledgements")
            }

            Section {
                ForEach(AboutCredits.licences) { licence in
                    NavigationLink {
                        AboutLicenceView(licence: licence)
                    } label: {
                        LabeledContent(licence.title, value: licence.subtitle)
                    }
                }
            } header: {
                Text("Licences")
            }
        }
        .navigationTitle("About")
        .settingsSubpageChrome()
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            if app.isSignedIn {
                LabeledContent("Server", value: app.backendKind.title)
                if let address = AboutServerSummary.displayAddress(app.activeServerURLString) {
                    LabeledContent("Address", value: address)
                }
                let user = app.username.trimmingCharacters(in: .whitespacesAndNewlines)
                if !user.isEmpty {
                    LabeledContent("Account", value: user)
                }
                LabeledContent("Status", value: app.serverConnectionHealth.statusTitle)
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connected Server")
        }
    }
}

/// One licence's full text.
struct AboutLicenceView: View {
    let licence: AboutLicence

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(licence.text)
                    .font(.footnote)
                    .textSelection(.enabled)
                if let url = licence.url {
                    Link("View online", destination: url)
                        .font(.footnote.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(licence.title)
        .settingsSubpageChrome()
    }
}
