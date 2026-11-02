import SwiftUI

/// **Radio** tab — user-added stations plus the Radio Browser directory.
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

    // Directory shelves
    @State private var popularStations: [RadioDirectoryStation] = []
    @State private var topStations: [RadioDirectoryStation] = []
    @State private var genreShelfStations: [RadioDirectoryStation] = []
    @State private var internationalStations: [RadioDirectoryStation] = []
    @State private var localBroadcastersStations: [RadioDirectoryStation] = []
    @State private var isLoadingDirectory = false
    @State private var directoryErrorMessage: String?

    private let floatingHeaderCollapseSlack = MusicTabFloatingHeaderScrollModifier.defaultSlack
    private var inset: CGFloat { MusicDesign.newTabHorizontalInset }

    private static let shelfStationCount = 12
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

    /// The Radio Browser directory is a public dataset — needs network, not sign-in.
    private var canLoadDirectory: Bool {
        !app.effectiveOfflineMode
    }

    private var localCountryName: String {
        RadioDirectoryCatalog.countryDisplayName(RadioDirectoryCatalog.preferredCountryCode)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hasCustomStations {
                        yourStationsSection
                        gap
                    }

                    if canLoadDirectory {
                        popularSection
                        gap

                        topStationsSection
                        gap

                        stationsByGenreSection

                        if !genreShelfStations.isEmpty {
                            gap
                        }

                        internationalSection
                        gap

                        localBroadcastersSection
                        gap

                        moreToExploreSection
                    }

                    if canLoadServerRadio {
                        if isLoading, !hasServerRadio, !hasCustomStations, !canLoadDirectory {
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
                                    .padding(.top, canLoadDirectory ? 0 : 8)
                            }
                            serverStationsSection
                        } else if !hasCustomStations, !canLoadDirectory {
                            ContentUnavailableView(
                                "No stations",
                                systemImage: "dot.radiowaves.left.and.right",
                                description: Text(loadError ?? "Add a station with the radio button above or configure internet radio in Navidrome.")
                            )
                            .padding(.top, 40)
                        }
                    } else if !canLoadDirectory {
                        secondaryServerHint
                    }

                    if !canLoadDirectory, !hasCustomStations, !canLoadServerRadio {
                        offlineDirectoryHint
                    }
                }
                .padding(.bottom, 40)
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
            .navigationDestination(for: RadioDirectoryDestination.self) { destination in
                directoryDestination(destination)
            }
            .task(id: radioLoadKey) { await load() }
            .task(id: canLoadDirectory) { await loadDirectoryShelves() }
            .refreshable {
                await load()
                await loadDirectoryShelves(force: true)
            }
            .deepLinkPush(tab: .radio, path: $navigationPath)
            .sheet(isPresented: $showAddStationSheet) {
                AddCustomRadioStationSheet()
            }
        }
        .tint(MusicDesign.accent)
    }

    // MARK: - Header

    private var radioHeaderBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Radio")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button {
                showAddStationSheet = true
            } label: {
                Image(systemName: "radio")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Add radio station")
            .musicGlassCapsuleInteractiveChrome()

            MusicToolbarSettingsAvatarLink(diameter: 45)
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.bottom, 10)
    }

    // MARK: - Your Stations

    private var yourStationsColumns: [GridItem] {
        MusicDesign.libraryHubGridColumns(count: 3)
    }

    private var yourStationsSection: some View {
        LazyVGrid(columns: yourStationsColumns, spacing: 20) {
            ForEach(app.customRadioStations) { custom in
                customStationGridCell(custom)
            }
        }
        .padding(.horizontal, 20)
    }

    private func customStationGridCell(_ custom: CustomRadioStation) -> some View {
        let station = custom.asInternetRadioStation()
        let isStarting = startingStationID == "live-\(station.id)"
        return Button {
            Task { await playLive(station) }
        } label: {
            LibraryHubGridCell(title: custom.name, style: .pinned) {
                AlbumArtworkView(
                    url: station.artworkURL,
                    meshArtworkSeed: station.artworkURL == nil
                        ? RadioStationMeshArtwork.seedKey(for: station)
                        : nil,
                    cornerRadius: MusicDesign.radioPinnedStationCorner,
                    maxDecodePixels: MusicDesign.shelfArtworkDecodePixels,
                )
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isStarting {
                        ZStack {
                            RoundedRectangle(cornerRadius: MusicDesign.radioPinnedStationCorner, style: .continuous)
                                .fill(.black.opacity(0.35))
                            ProgressView().tint(.white)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .contextMenu {
            Button {
                Task { await playLive(station) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button(role: .destructive) {
                app.removeCustomRadioStation(id: custom.id)
            } label: {
                Label("Remove Station", systemImage: "trash")
            }
        }
    }

    // MARK: - Directory shelves

    @ViewBuilder
    private var popularSection: some View {
        stationShelf(
            title: "Popular in \(localCountryName)",
            destination: .popular,
            stations: popularStations,
            isLoading: isLoadingDirectory && popularStations.isEmpty,
            errorMessage: directoryErrorMessage,
        )
    }

    @ViewBuilder
    private var topStationsSection: some View {
        stationShelf(
            title: "Top Stations",
            destination: .topStations,
            stations: topStations,
            isLoading: isLoadingDirectory && topStations.isEmpty && popularStations.isEmpty,
        )
    }

    @ViewBuilder
    private var stationsByGenreSection: some View {
        stationShelf(
            title: "Stations by Genre",
            stations: genreShelfStations,
            isLoading: isLoadingDirectory && genreShelfStations.isEmpty && popularStations.isEmpty,
        )
    }

    @ViewBuilder
    private var internationalSection: some View {
        stationShelf(
            title: "International Broadcasters",
            destination: .international,
            stations: internationalStations,
            isLoading: isLoadingDirectory && internationalStations.isEmpty && topStations.isEmpty,
        )
    }

    @ViewBuilder
    private var localBroadcastersSection: some View {
        stationShelf(
            title: "Local Broadcasters",
            subtitle: localCountryName,
            destination: .localBroadcasters,
            stations: localBroadcastersStations,
            isLoading: isLoadingDirectory && localBroadcastersStations.isEmpty && internationalStations.isEmpty,
        )
    }

    private var moreToExploreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("More to Explore")

            VStack(spacing: 8) {
                ForEach(RadioDirectoryCatalog.genres) { genre in
                    RadioExploreListRow(title: genre.title, destination: .genre(genre.id))
                }
                RadioExploreListRow(
                    title: "From Around the World",
                    destination: .countryList,
                )
            }
            .padding(.horizontal, inset)
        }
    }

    // MARK: - Shelf builders

    @ViewBuilder
    private func stationShelf(
        title: String,
        subtitle: String? = nil,
        destination: RadioDirectoryDestination? = nil,
        stations: [RadioDirectoryStation],
        isLoading: Bool = false,
        errorMessage: String? = nil,
    ) -> some View {
        if isLoading {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title, destination: destination)
                stationShelfSkeleton
            }
        } else if let errorMessage, stations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title, destination: destination)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .padding(.horizontal, inset)
            }
        } else if !stations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let subtitle {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader(title, destination: destination)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.horizontal, inset)
                            .padding(.top, -8)
                    }
                } else {
                    sectionHeader(title, destination: destination)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(stations) { station in
                            RadioDirectoryStationCard(
                                station: station,
                                isStarting: startingStationID == "directory-\(station.stationUUID)",
                                onPlay: { Task { await playDirectory(station) } },
                            )
                        }
                    }
                    .padding(.horizontal, inset)
                }
            }
        }
    }

    private var stationShelfSkeleton: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<4, id: \.self) { _ in
                    MusicShelfAlbumCardSkeleton()
                }
            }
            .padding(.horizontal, inset)
        }
        .scrollDisabled(true)
    }

    private func sectionHeader(_ title: String, destination: RadioDirectoryDestination? = nil) -> some View {
        Group {
            if let destination {
                NavigationLink(value: destination) {
                    sectionHeaderLabel(title, showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                sectionHeaderLabel(title, showsChevron: false)
            }
        }
        .padding(.horizontal, inset)
        .padding(.bottom, 14)
    }

    private func sectionHeaderLabel(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
            Spacer(minLength: 0)
        }
    }

    private var gap: some View {
        Spacer().frame(height: 36)
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func directoryDestination(_ destination: RadioDirectoryDestination) -> some View {
        switch destination {
        case .popular:
            RadioDirectoryListView(
                title: "Popular in \(localCountryName)",
                subtitle: "Ranked by plays reported across every app using the directory.",
                tags: [],
                fixedCountryCode: RadioDirectoryCatalog.preferredCountryCode,
                showsScopePicker: false,
            )
        case .topStations:
            RadioDirectoryListView(
                title: "Top Stations",
                subtitle: "The most-played stations worldwide.",
                tags: [],
                fixedCountryCode: nil,
                showsScopePicker: false,
            )
        case .international:
            RadioDirectoryListView(
                title: "International Broadcasters",
                subtitle: "Stations outside \(localCountryName).",
                tags: [],
                fixedCountryCode: nil,
                excludedCountryCode: RadioDirectoryCatalog.preferredCountryCode,
                showsScopePicker: false,
            )
        case .localBroadcasters:
            RadioDirectoryListView(
                title: "Local Broadcasters",
                subtitle: "Stations in \(localCountryName).",
                tags: [],
                fixedCountryCode: RadioDirectoryCatalog.preferredCountryCode,
                showsScopePicker: false,
            )
        case .genre(let id):
            if let genre = RadioDirectoryCatalog.genre(id: id) {
                RadioDirectoryListView(
                    title: genre.title,
                    subtitle: nil,
                    tags: genre.tags,
                    fixedCountryCode: nil,
                )
            }
        case .countryList:
            RadioDirectoryCountryListView()
        case .country(let code):
            RadioDirectoryListView(
                title: RadioDirectoryCatalog.countryDisplayName(code),
                subtitle: nil,
                tags: [],
                fixedCountryCode: code,
                showsScopePicker: false,
            )
        }
    }

    // MARK: - Directory loading

    private func loadDirectoryShelves(force: Bool = false) async {
        guard canLoadDirectory else {
            popularStations = []
            topStations = []
            genreShelfStations = []
            internationalStations = []
            localBroadcastersStations = []
            directoryErrorMessage = nil
            return
        }
        if !force,
           !popularStations.isEmpty,
           !topStations.isEmpty,
           !genreShelfStations.isEmpty {
            return
        }

        isLoadingDirectory = true
        directoryErrorMessage = nil
        defer { isLoadingDirectory = false }

        do {
            async let popular = fetchPopularStations()
            async let top = fetchTopStations()
            async let genres = fetchGenreShelfStations()
            async let international = fetchInternationalStations()

            let popularResult = try await popular
            async let local = fetchLocalBroadcasters(excluding: Set(popularResult.map(\.stationUUID)))

            let (topResult, genreResult, intlResult, localResult) = try await (
                top, genres, international, local
            )

            popularStations = popularResult
            topStations = topResult
            genreShelfStations = genreResult
            internationalStations = intlResult
            localBroadcastersStations = localResult
        } catch is CancellationError {
            return
        } catch {
            if popularStations.isEmpty {
                directoryErrorMessage = "Couldn't reach the radio directory."
            }
        }
    }

    private func fetchPopularStations() async throws -> [RadioDirectoryStation] {
        var query = RadioDirectoryQuery()
        query.countryCode = RadioDirectoryCatalog.preferredCountryCode
        query.limit = Self.shelfStationCount
        return try await RadioBrowserClient.shared.stations(query)
    }

    private func fetchTopStations() async throws -> [RadioDirectoryStation] {
        var query = RadioDirectoryQuery()
        query.limit = Self.shelfStationCount
        return try await RadioBrowserClient.shared.stations(query)
    }

    /// One top station per curated genre — a single horizontal "Stations by Genre" row.
    private func fetchGenreShelfStations() async throws -> [RadioDirectoryStation] {
        let genres = RadioDirectoryCatalog.genres
        return try await withThrowingTaskGroup(
            of: (Int, RadioDirectoryStation?).self,
        ) { group in
            for (index, genre) in genres.enumerated() {
                group.addTask {
                    let stations = try await RadioBrowserClient.shared.stations(
                        tags: genre.tags,
                        countryCode: nil,
                        limit: 1,
                    )
                    return (index, stations.first)
                }
            }
            var rows: [(Int, RadioDirectoryStation?)] = []
            for try await row in group {
                rows.append(row)
            }
            return rows
                .sorted { $0.0 < $1.0 }
                .compactMap(\.1)
        }
    }

    private func fetchInternationalStations() async throws -> [RadioDirectoryStation] {
        let homeCode = RadioDirectoryCatalog.preferredCountryCode.uppercased()
        var query = RadioDirectoryQuery()
        query.limit = 60
        let page = try await RadioBrowserClient.shared.stations(query)
        return Array(
            page
                .filter { $0.countryCode.uppercased() != homeCode }
                .prefix(Self.shelfStationCount)
        )
    }

    private func fetchLocalBroadcasters(excluding popularIDs: Set<String> = []) async throws -> [RadioDirectoryStation] {
        var query = RadioDirectoryQuery()
        query.countryCode = RadioDirectoryCatalog.preferredCountryCode
        query.order = .votes
        query.limit = 40
        let page = try await RadioBrowserClient.shared.stations(query)
        return Array(
            page
                .filter { !popularIDs.contains($0.stationUUID) }
                .prefix(Self.shelfStationCount)
        )
    }

    private func playDirectory(_ station: RadioDirectoryStation) async {
        startingStationID = "directory-\(station.stationUUID)"
        defer { startingStationID = nil }
        await app.playInternetRadioStation(station.asInternetRadioStation())
    }

    // MARK: - Server radio (Navidrome)

    private var serverStationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasCustomStations || canLoadDirectory {
                sectionHeader("Server Stations")
            }
            serverRadioContent
        }
    }

    @ViewBuilder
    private var serverRadioContent: some View {
        if !featuredStations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(featuredStations) { station in
                        RadioInternetStationCard(
                            station: station,
                            isStarting: startingStationID == "live-\(station.id)",
                            onPlay: { Task { await playLive(station) } },
                        )
                    }
                }
                .padding(.horizontal, inset)
            }
        }

        ForEach(liveRadioGroups) { group in
            if !group.stations.isEmpty {
                if !group.title.isEmpty {
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, inset)
                        .padding(.top, featuredStations.isEmpty ? 0 : 28)
                        .padding(.bottom, 14)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(group.stations) { station in
                            RadioInternetStationCard(
                                station: station,
                                isStarting: startingStationID == "live-\(station.id)",
                                onPlay: { Task { await playLive(station) } },
                            )
                        }
                    }
                    .padding(.horizontal, inset)
                }
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

    private var offlineDirectoryHint: some View {
        serverHintCard(
            title: "Radio needs a connection",
            message: "Live stations stream from the internet. Turn off offline mode to browse the directory.",
        )
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

// MARK: - Station cards

/// Square card for Navidrome / custom internet radio horizontal shelves.
private struct RadioInternetStationCard: View {
    let station: InternetRadioStation
    let isStarting: Bool
    let onPlay: () -> Void

    var body: some View {
        RadioShelfStationCard(
            artworkURL: station.artworkURL,
            meshArtworkSeed: RadioStationMeshArtwork.seedKey(for: station),
            title: station.name,
            subtitle: station.detailLine ?? "Live stream",
            isStarting: isStarting,
            onPlay: onPlay,
        )
    }
}
