import SwiftUI

/// **Radio** tab — Navidrome internet radio with a featured grid and genre-grouped stations.
struct RadioTabView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showFloatingHeader = true
    @State private var featuredStations: [InternetRadioStation] = []
    @State private var liveRadioGroups: [LiveRadioGroup] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var startingStationID: String?
    @State private var loadGeneration: UInt = 0

    private let floatingHeaderCollapseSlack: CGFloat = 72
    private let featuredColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]
    private let browseColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]
    private var inset: CGFloat { MusicDesign.newTabHorizontalInset }

    private static let featuredCount = 6

    private var hasLiveRadio: Bool {
        !featuredStations.isEmpty || liveRadioGroups.contains { !$0.stations.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !app.isSignedIn {
                        signedOutHint
                    } else if app.backendKind != .navidrome {
                        jellyfinHint
                    } else if isLoading, !hasLiveRadio {
                        ProgressView()
                            .tint(MusicDesign.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if !hasLiveRadio {
                        ContentUnavailableView(
                            "No stations",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text(loadError ?? "Add internet radio stations in the Navidrome web UI.")
                        )
                        .padding(.top, 40)
                    } else {
                        if let loadError, shouldShowLoadError(loadError) {
                            Text(loadError)
                                .font(.footnote)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                                .padding(.horizontal, inset)
                        }
                        radioContent
                    }
                }
                .padding(.bottom, 32)
            }
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: floatingHeaderCollapseSlack,
                showFloatingHeader: $showFloatingHeader,
            ))
            .safeAreaInset(edge: .top, spacing: 0) {
                if showFloatingHeader {
                    MusicTabTitleHeaderBar(title: "Radio") {
                        MusicToolbarSettingsAvatarLink(diameter: 45)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showFloatingHeader)
            .background(MusicDesign.background)
            .musicNewTabNavigationChrome()
            .musicNewTabRootHidesNavigationBar()
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .task(id: radioLoadKey) { await load() }
            .refreshable { await load() }
        }
        .tint(MusicDesign.accent)
    }

    @ViewBuilder
    private var radioContent: some View {
        if !featuredStations.isEmpty {
            LazyVGrid(columns: featuredColumns, spacing: 12) {
                ForEach(featuredStations) { station in
                    stationTile(
                        station: station,
                        isStarting: startingStationID == "live-\(station.id)",
                    ) {
                        Task { await playLive(station) }
                    }
                }
            }
            .padding(.horizontal, inset)
        }

        ForEach(liveRadioGroups) { group in
            if !group.stations.isEmpty {
                if !group.title.isEmpty {
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, inset)
                        .padding(.top, featuredStations.isEmpty ? 0 : 8)
                }

                LazyVGrid(columns: browseColumns, spacing: 12) {
                    ForEach(group.stations) { station in
                        stationTile(
                            station: station,
                            isStarting: startingStationID == "live-\(station.id)",
                        ) {
                            Task { await playLive(station) }
                        }
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }

    private var radioLoadKey: String {
        "\(app.isSignedIn)-\(app.backendKind.rawValue)-\(app.libraryCatalogEpoch)"
    }

    private var signedOutHint: some View {
        ContentUnavailableView(
            "Sign in to listen",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text("Connect to Navidrome to listen to your radio stations.")
        )
        .padding(.top, 40)
    }

    private var jellyfinHint: some View {
        ContentUnavailableView(
            "Navidrome radio",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text("Radio stations are available when signed in to Navidrome.")
        )
        .padding(.top, 40)
    }

    private func stationTile(
        station: InternetRadioStation,
        isStarting: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RadioStationMeshArtworkView(
                    seedKey: RadioStationMeshArtwork.seedKey(for: station),
                    cornerRadius: 14,
                )
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom,
                )
                if isStarting {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Live stream")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(12)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
    }

    private func load() async {
        guard app.isSignedIn, app.backendKind == .navidrome, let client = app.activeLibrary as? NavidromeClient else {
            featuredStations = []
            liveRadioGroups = []
            loadError = nil
            isLoading = false
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        let hadStations = hasLiveRadio

        isLoading = true
        if !hadStations { loadError = nil }
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        let genreNames: [String]
        do {
            genreNames = try await client.libraryGenres(limit: 200).map(\.name)
        } catch {
            genreNames = []
        }
        guard generation == loadGeneration else { return }

        let live: [InternetRadioStation]
        do {
            live = try await client.fetchInternetRadioStations()
        } catch {
            guard generation == loadGeneration else { return }
            if isBenignLoadInterruption(error) { return }
            let message = error.localizedDescription
            if hadStations {
                loadError = message
            } else {
                featuredStations = []
                liveRadioGroups = []
                loadError = message
            }
            return
        }
        guard generation == loadGeneration else { return }

        if live.isEmpty, hadStations {
            loadError = "No stations returned from the server."
            return
        }

        applyLoadedStations(live, genreNames: genreNames)

        guard generation == loadGeneration else { return }
        if !hasLiveRadio {
            loadError = "No stations found. Add internet radio in the Navidrome web UI."
        } else {
            loadError = nil
        }
    }

    private func applyLoadedStations(_ live: [InternetRadioStation], genreNames: [String]) {
        let featured = Array(live.shuffled().prefix(Self.featuredCount))
        let featuredIds = Set(featured.map(\.id))
        let remainder = live
            .filter { !featuredIds.contains($0.id) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        featuredStations = featured
        liveRadioGroups = LiveRadioGrouping.group(
            stations: remainder,
            libraryGenreNames: genreNames,
        )
    }

    private func playLive(_ station: InternetRadioStation) async {
        startingStationID = "live-\(station.id)"
        defer { startingStationID = nil }
        await app.playInternetRadioStation(station)
    }

    /// Pull-to-refresh / tab churn can cancel in-flight loads — not a user-visible failure.
    private func isBenignLoadInterruption(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue { return true }
        return false
    }

    private func shouldShowLoadError(_ message: String) -> Bool {
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        if lower == "cancelled" || lower == "canceled" { return false }
        if lower.contains("cancelled") || lower.contains("canceled") { return false }
        return true
    }
}
