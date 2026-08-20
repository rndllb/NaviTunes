import SwiftUI

/// **Radio** tab — user-added stations plus Navidrome internet radio.
struct RadioTabView: View {
    @EnvironmentObject private var app: AppModel
    @State private var navigationPath = NavigationPath()
    @State private var showFloatingHeader = true
    @State private var showAddStationSheet = false
    @State private var featuredStations: [InternetRadioStation] = []
    @State private var liveRadioGroups: [LiveRadioGroup] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var startingStationID: String?
    @State private var loadGeneration: UInt = 0

    private let floatingHeaderCollapseSlack = MusicTabFloatingHeaderScrollModifier.defaultSlack
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

    private var hasCustomStations: Bool {
        !app.customRadioStations.isEmpty
    }

    private var hasServerRadio: Bool {
        !featuredStations.isEmpty || liveRadioGroups.contains { !$0.stations.isEmpty }
    }

    private var canLoadServerRadio: Bool {
        app.isSignedIn && app.backendKind == .navidrome
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if hasCustomStations {
                        yourStationsSection
                    }

                    if canLoadServerRadio {
                        if isLoading, !hasServerRadio, !hasCustomStations {
                            ProgressView()
                                .tint(MusicDesign.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                        } else if hasServerRadio {
                            if let loadError, shouldShowLoadError(loadError) {
                                Text(loadError)
                                    .font(.footnote)
                                    .foregroundStyle(MusicDesign.secondaryLabel)
                                    .padding(.horizontal, inset)
                            }
                            serverStationsSection
                        } else if !hasCustomStations {
                            ContentUnavailableView(
                                "No stations",
                                systemImage: "dot.radiowaves.left.and.right",
                                description: Text(loadError ?? "Add a station with the radio button above or configure internet radio in Navidrome.")
                            )
                            .padding(.top, 40)
                        }
                    } else {
                        secondaryServerHint
                    }
                }
                .padding(.bottom, 32)
            }
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: floatingHeaderCollapseSlack,
                showFloatingHeader: $showFloatingHeader,
            ))
            .musicTabFloatingHeaderInset(isVisible: showFloatingHeader) {
                radioHeaderBar
            }
            .background(MusicDesign.background)
            .musicNewTabNavigationChrome()
            .musicNewTabRootHidesNavigationBar()
            .navigationTitle("")
            .musicNavigationBarTitleDisplayMode(.inline)
            .task(id: radioLoadKey) { await load() }
            .refreshable { await load() }
            .deepLinkPush(tab: .radio, path: $navigationPath)
            .sheet(isPresented: $showAddStationSheet) {
                AddCustomRadioStationSheet()
            }
        }
        .tint(MusicDesign.accent)
    }

    private var radioHeaderBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Radio")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button {
                    showAddStationSheet = true
                } label: {
                    Image(systemName: "radio")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Add radio station")
            }
            .musicGlassCapsuleInteractiveChrome()

            MusicToolbarSettingsAvatarLink(diameter: 45)
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.bottom, 10)
    }

    private var yourStationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Stations")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, inset)

            LazyVGrid(columns: browseColumns, spacing: 12) {
                ForEach(app.customRadioStations) { custom in
                    CustomRadioStationTile(
                        custom: custom,
                        isStarting: startingStationID == "live-\(custom.asInternetRadioStation().id)",
                        onPlay: { Task { await playLive(custom.asInternetRadioStation()) } },
                    )
                }
            }
            .padding(.horizontal, inset)
        }
    }

    private var serverStationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasCustomStations {
                Text("Server Stations")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, inset)
            }

            serverRadioContent
        }
    }

    @ViewBuilder
    private var serverRadioContent: some View {
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

    @ViewBuilder
    private var secondaryServerHint: some View {
        if !app.isSignedIn {
            serverHintCard(
                title: "Sign in for server stations",
                message: "Your custom stations work now. Sign in to Navidrome to browse stations from your server.",
            )
        } else if app.backendKind != .navidrome {
            serverHintCard(
                title: "Navidrome server stations",
                message: "Your custom stations work now. Internet radio from your server is available when signed in to Navidrome.",
            )
        }
    }

    private func serverHintCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, hasCustomStations ? 0 : 40)
    }

    private var radioLoadKey: String {
        "\(app.isSignedIn)-\(app.backendKind.rawValue)-\(app.libraryCatalogEpoch)"
    }

    private func stationTile(
        station: InternetRadioStation,
        isStarting: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            RadioStationTileBody(station: station, isStarting: isStarting)
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
    }

    private func load() async {
        guard canLoadServerRadio, let client = app.activeLibrary as? NavidromeClient else {
            featuredStations = []
            liveRadioGroups = []
            loadError = nil
            isLoading = false
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        let hadStations = hasServerRadio

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
        if !hasServerRadio {
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

// MARK: - Custom station tile

private struct CustomRadioStationTile: View {
    @EnvironmentObject private var app: AppModel
    let custom: CustomRadioStation
    let isStarting: Bool
    let onPlay: () -> Void

    private var station: InternetRadioStation { custom.asInternetRadioStation() }

    var body: some View {
        RadioStationTileBody(station: station, isStarting: isStarting)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isStarting else { return }
                onPlay()
            }
            .contextMenu {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    removeStation()
                } label: {
                    Label("Remove Station", systemImage: "trash")
                }
            }
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button(role: .destructive) {
                        removeStation()
                    } label: {
                        Label("Remove Station", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(8)
                }
                .accessibilityLabel("Station options")
            }
            .disabled(isStarting)
    }

    private func removeStation() {
        app.removeCustomRadioStation(id: custom.id)
    }
}

private struct RadioStationTileBody: View {
    let station: InternetRadioStation
    let isStarting: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AlbumArtworkView(
                url: station.artworkURL,
                meshArtworkSeed: station.artworkURL == nil
                    ? RadioStationMeshArtwork.seedKey(for: station)
                    : nil,
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
}
