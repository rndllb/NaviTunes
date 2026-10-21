import SwiftUI

/// Settings → **History**: everything about listening history, in one place.
///
/// This was the "Listening History" section of Settings → Library. It is a top-level concern —
/// scrobble state and the listening analytics — rather than something about
/// the music library itself, so it earns its own row rather than sitting four sections down
/// inside another page.
///
/// **Grouping is deliberate and was specified.** Three groups: the two scrobble counts; My
/// Listening on its own; the scrobble browser on its own. (A fourth, the Exclusions count and its
/// Manage screen, went with the Exclusions feature in #7.)
struct SettingsHistoryView: View {
    @EnvironmentObject private var app: AppModel

    /// Breathing room for a screen that used to be a cramped section inside Library and now has
    /// the whole view. `rowPadding` is added above and below each row's content; `sectionSpacing`
    /// is the gap between the groups.
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
