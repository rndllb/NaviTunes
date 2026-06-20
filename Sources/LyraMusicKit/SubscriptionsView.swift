import SwiftUI

/// Toolbar toggle to follow / unfollow an artist for discography completeness.
/// Always available — without a download plugin, follows become a wishlist
/// (see ``SubscriptionsView``), so the affordance never hard-disables.
struct ArtistFollowButton: View {
    @EnvironmentObject private var app: AppModel
    let name: String
    var mbid: String? = nil
    var coverURL: URL? = nil

    private var isFollowing: Bool { app.subscriptions.isFollowing(name: name, mbid: mbid) }

    var body: some View {
        Button {
            app.subscriptions.toggle(name: name, mbid: mbid, coverURL: coverURL)
            // `isFollowing` recomputes from the engine, so it already reflects the new state.
            app.showTransientToast(isFollowing ? "Following \(name)" : "Unfollowed \(name)")
        } label: {
            Image(systemName: isFollowing ? "bell.fill" : "bell")
        }
        .tint(MusicDesign.accent)
        .accessibilityLabel(isFollowing ? "Unfollow \(name)" : "Follow \(name)")
    }
}

/// Manage followed artists and review what the completeness brain found: which releases
/// are in the library, which were requested through the active plugin, and which are
/// wishlisted because no plugin can fetch them.
struct SubscriptionsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showAddArtistAlert = false
    @State private var addArtistName = ""
    @State private var browseArtist: BrowseArtistTarget?

    private struct BrowseArtistTarget: Identifiable {
        let id = UUID()
        let name: String
    }

    var body: some View {
        List {
            if app.subscriptions.followed.isEmpty {
                ContentUnavailableView(
                    "No followed artists",
                    systemImage: "bell",
                    description: Text("Follow an artist from their page to automatically request albums that are missing from your library.")
                )
            } else {
                if !app.acquisitionConfigured {
                    Section {
                        Label(
                            "No download plugin is configured, so missing albums are saved as a wishlist. Set one up in Plugins → Downloads to fetch them automatically.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                ForEach(app.subscriptions.followed) { artist in
                    Section {
                        let statuses = app.subscriptions.statusByArtist[artist.id] ?? []
                        if statuses.isEmpty {
                            Text(artist.lastChecked == nil ? "Not checked yet" : "Nothing missing")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(statuses) { status in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(status.title)
                                        if let year = status.year {
                                            Text(String(year))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    statusBadge(status.state)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            app.subscriptions.unfollow(id: artist.id)
                        } label: {
                            Label("Unfollow", systemImage: "bell.slash")
                        }
                    } header: {
                        Text(artist.name)
                    }
                }
            }
        }
        .navigationTitle("Following")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    addArtistName = ""
                    showAddArtistAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await app.refreshSubscriptions() }
                } label: {
                    if app.subscriptions.isChecking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(app.subscriptions.isChecking || app.subscriptions.followed.isEmpty)
            }
        }
        .alert("Request Artist", isPresented: $showAddArtistAlert) {
            TextField("Artist name", text: $addArtistName)
            Button("Browse") {
                let name = addArtistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { browseArtist = BrowseArtistTarget(name: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Find any artist on MusicBrainz to browse and request their albums — even ones not in your library.")
        }
        .sheet(item: $browseArtist) { target in
            NavigationStack {
                ArtistPageView(input: .named(target.name))
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { browseArtist = nil }
                        }
                    }
            }
        }
        .task { await app.refreshSubscriptions() }
    }

    @ViewBuilder
    private func statusBadge(_ state: SubscriptionReleaseStatus.State) -> some View {
        switch state {
        case .have:
            Text("In Library")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .requested:
            Label("Requested", systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(MusicDesign.accent)
        case .pending:
            Label("Wishlist", systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
