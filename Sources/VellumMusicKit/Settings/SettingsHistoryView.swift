import SwiftUI

/// Settings → **History**: everything about listening history, in one place.
///
/// This was the "Listening History" section of Settings → Library. It is a top-level concern —
/// scrobble state, the listening analytics, and the exclusion list — rather than something about
/// the music library itself, so it earns its own row rather than sitting four sections down
/// inside another page.
///
/// **Grouping is deliberate and was specified.** Four groups, not one list of six rows:
/// the two scrobble counts; My Listening on its own; the scrobble browser on its own; and
/// the exclusions count with its Manage button **directly beneath it**, as one connected set —
/// the count and the screen that edits it belong together, unlike the other two buttons.
struct SettingsHistoryView: View {
    @EnvironmentObject private var app: AppModel

    /// Breathing room for a screen that used to be a cramped section inside Library and now has
    /// the whole view. `rowPadding` is added above and below each row's content; `sectionSpacing`
    /// is the gap between the four groups.
    private static let rowPadding: CGFloat = 6
    private static let sectionSpacing: CGFloat = 28

    var body: some View {
        List {
            Section {
                countRow("Pending scrobbles", app.scrobbleService.store.pending.count)
                countRow("Completed scrobbles", app.scrobbleService.store.completed.count)
            } footer: {
                Text("Scrobbles are submitted to your server when a track passes the playback threshold (~50% or 30 seconds).")
            }

            Section {
                NavigationLink {
                    MyListeningView()
                } label: {
                    Label("My Listening", systemImage: "chart.bar.fill")
                        .padding(.vertical, Self.rowPadding)
                }
            }

            Section {
                NavigationLink {
                    ScrobbleBrowserView()
                } label: {
                    Label("Browse scrobbles", systemImage: "list.bullet")
                        .padding(.vertical, Self.rowPadding)
                }
            }

            // The connected set: the count, and directly below it the screen that edits it.
            Section {
                countRow("Exclusions", app.scrobbleService.store.exclusions.count)
                NavigationLink {
                    ScrobbleExclusionBrowserView()
                } label: {
                    Label("Manage exclusions", systemImage: "eye.slash")
                        .padding(.vertical, Self.rowPadding)
                }
            } footer: {
                Text("Excluded albums, artists and playlists are never scrobbled to your server.")
            }
        }
        .listSectionSpacing(Self.sectionSpacing)
        .navigationTitle("History")
        .settingsSubpageChrome()
    }

    private func countRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Self.rowPadding)
    }
}
