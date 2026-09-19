import SwiftUI

/// Settings → **History**: everything about listening history, in one place.
///
/// This was the "Listening History" section of Settings → Library. It is a top-level concern —
/// scrobble state, the listening analytics, and the exclusion list — rather than something about
/// the music library itself, so it earns its own row rather than sitting four sections down
/// inside another page.
struct SettingsHistoryView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Pending scrobbles")
                    Spacer()
                    Text("\(app.scrobbleService.store.pending.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Completed scrobbles")
                    Spacer()
                    Text("\(app.scrobbleService.store.completed.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Exclusions")
                    Spacer()
                    Text("\(app.scrobbleService.store.exclusions.count)")
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    MyListeningView()
                } label: {
                    Label("My Listening", systemImage: "chart.bar.fill")
                }
                NavigationLink {
                    ScrobbleBrowserView()
                } label: {
                    Label("Browse scrobbles", systemImage: "list.bullet")
                }
                NavigationLink {
                    ScrobbleExclusionBrowserView()
                } label: {
                    Label("Manage exclusions", systemImage: "eye.slash")
                }
            } footer: {
                Text("Scrobbles are submitted to your server when a track passes the playback threshold (~50% or 30 seconds).")
            }
        }
        .navigationTitle("History")
        .settingsSubpageChrome()
    }
}
