import SwiftUI

// MARK: - Navigation

enum RadioDirectoryDestination: Hashable {
    case popular
    case topStations
    case international
    case localBroadcasters
    case genre(String)
    case countryList
    case country(String)
}

/// Whether a browse screen is filtered to the user's country or the whole directory.
enum RadioDirectoryScope: Hashable, CaseIterable {
    case local
    case worldwide
}

// MARK: - Feed

/// What a browse screen is showing. Single queries paginate by offset; merged tag
/// queries can't (the offset would be per-tag), so they load one deep page.
enum RadioDirectoryFeedSource: Hashable {
    case query(RadioDirectoryQuery)
    case tags(tags: [String], countryCode: String?)
    /// Worldwide results with one country code removed client-side (no API exclude param).
    case excludingCountry(RadioDirectoryQuery, excludedCode: String)
}

/// Loads and pages one directory screen's worth of stations.
@MainActor
final class RadioDirectoryFeed: ObservableObject {
    @Published private(set) var stations: [RadioDirectoryStation] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private static let pageSize = 50
    private static let mergedLimit = 120

    private var source: RadioDirectoryFeedSource?
    private var reachedEnd = false
    private var generation: UInt = 0

    var isEmpty: Bool { stations.isEmpty }

    func start(_ source: RadioDirectoryFeedSource) async {
        generation &+= 1
        let generation = generation
        self.source = source
        reachedEnd = false
        isLoading = true
        errorMessage = nil
        defer { if generation == self.generation { isLoading = false } }

        do {
            let loaded = try await fetch(source, offset: 0)
            guard generation == self.generation else { return }
            stations = loaded
            reachedEnd = loaded.count < Self.pageSize
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            stations = []
            errorMessage = Self.message(for: error)
        }
    }

    /// Called from the trailing row. Guarded so a fast scroll can't stack requests.
    ///
    /// Deliberately does **not** bump `generation` — that token belongs to `start`, and
    /// invalidating it here would leave a concurrent first load stuck with `isLoading`
    /// pinned true and the skeleton on screen forever.
    func loadMoreIfNeeded(after station: RadioDirectoryStation) async {
        guard let source else { return }
        let paginatedQuery: RadioDirectoryQuery?
        switch source {
        case .query(let query):
            paginatedQuery = query
        case .excludingCountry(let query, _):
            paginatedQuery = query
        case .tags:
            paginatedQuery = nil
        }
        guard let paginatedQuery,
              !isLoading, !isLoadingMore, !reachedEnd,
              station.stationUUID == stations.last?.stationUUID
        else { return }

        let generation = generation
        isLoadingMore = true
        defer { if generation == self.generation { isLoadingMore = false } }

        do {
            let loaded: [RadioDirectoryStation]
            switch source {
            case .query:
                loaded = try await fetch(.query(paginatedQuery), offset: stations.count)
            case .excludingCountry(_, let excludedCode):
                loaded = try await fetch(
                    .excludingCountry(paginatedQuery, excludedCode: excludedCode),
                    offset: stations.count,
                )
            case .tags:
                return
            }
            guard generation == self.generation else { return }
            var seen = Set(stations.map(\.stationUUID))
            for station in loaded where seen.insert(station.stationUUID).inserted {
                stations.append(station)
            }
            reachedEnd = loaded.count < Self.pageSize
        } catch {
            reachedEnd = true
        }
    }

    private func fetch(_ source: RadioDirectoryFeedSource, offset: Int) async throws -> [RadioDirectoryStation] {
        switch source {
        case .query(var query):
            query.limit = Self.pageSize
            query.offset = offset
            return try await RadioBrowserClient.shared.stations(query)
        case .tags(let tags, let countryCode):
            return try await RadioBrowserClient.shared.stations(
                tags: tags,
                countryCode: countryCode,
                limit: Self.mergedLimit,
            )
        case .excludingCountry(var query, let excludedCode):
            query.limit = Self.pageSize
            query.offset = offset
            let page = try await RadioBrowserClient.shared.stations(query)
            return page.filter { $0.countryCode.uppercased() != excludedCode.uppercased() }
        }
    }

    private static func message(for error: Error) -> String {
        if let directory = error as? RadioDirectoryError { return directory.message }
        if let url = error as? URLError, url.code == .notConnectedToInternet {
            return "No internet connection."
        }
        return "Couldn't reach the radio directory."
    }
}

// MARK: - Station list screen

/// Shared screen for Popular / genre / country browse results.
struct RadioDirectoryListView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var feed = RadioDirectoryFeed()

    let title: String
    let subtitle: String?
    /// Tags to merge, when this screen is a genre. Empty for plain country/popular lists.
    let tags: [String]
    /// Fixed country for country screens; nil lets the scope picker choose.
    let fixedCountryCode: String?
    /// When set, results from a worldwide query drop stations in this country code.
    var excludedCountryCode: String? = nil
    var showsScopePicker: Bool = true

    @State private var scope: RadioDirectoryScope = .local
    @State private var startingStationUUID: String?

    private var localCountryCode: String { RadioDirectoryCatalog.preferredCountryCode }

    private var activeCountryCode: String? {
        if excludedCountryCode != nil { return nil }
        if let fixedCountryCode { return fixedCountryCode }
        return scope == .local ? localCountryCode : nil
    }

    private var source: RadioDirectoryFeedSource {
        if let excludedCountryCode {
            var query = RadioDirectoryQuery()
            query.countryCode = nil
            return .excludingCountry(query, excludedCode: excludedCountryCode)
        }
        if tags.isEmpty {
            var query = RadioDirectoryQuery()
            query.countryCode = activeCountryCode
            return .query(query)
        }
        return .tags(tags: tags, countryCode: activeCountryCode)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
                        .padding(.bottom, 12)
                }

                if showsScopePicker, fixedCountryCode == nil {
                    MusicGlassSegmentPillBar(
                        options: Array(RadioDirectoryScope.allCases),
                        selection: $scope,
                        title: scopeTitle,
                    )
                    .padding(.horizontal, MusicDesign.newTabHorizontalInset)
                    .padding(.bottom, 16)
                }

                if feed.isLoading, feed.isEmpty {
                    RadioDirectoryRowSkeleton()
                } else if let error = feed.errorMessage, feed.isEmpty {
                    RadioDirectoryUnavailableView(message: error) {
                        Task { await feed.start(source) }
                    }
                } else if feed.isEmpty {
                    ContentUnavailableView(
                        "No stations",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Nothing in the directory matched this."),
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(feed.stations) { station in
                        RadioDirectoryStationRow(
                            station: station,
                            isStarting: startingStationUUID == station.stationUUID,
                            onPlay: { play(station) },
                        )
                        .task { await feed.loadMoreIfNeeded(after: station) }
                    }

                    if feed.isLoadingMore {
                        ProgressView()
                            .tint(MusicDesign.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(MusicDesign.background)
        .navigationTitle(title)
        .task(id: source) { await feed.start(source) }
    }

    private func scopeTitle(_ scope: RadioDirectoryScope) -> String {
        switch scope {
        case .local: return RadioDirectoryCatalog.countryDisplayName(localCountryCode)
        case .worldwide: return "Worldwide"
        }
    }

    private func play(_ station: RadioDirectoryStation) {
        startingStationUUID = station.stationUUID
        Task {
            await app.playInternetRadioStation(station.asInternetRadioStation())
            startingStationUUID = nil
        }
    }
}

// MARK: - Country list

struct RadioDirectoryCountryListView: View {
    @State private var countries: [RadioDirectoryCountry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var filter = ""

    private var visibleCountries: [RadioDirectoryCountry] {
        let term = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return countries }
        return countries.filter { $0.displayName.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        List {
            if let errorMessage, countries.isEmpty {
                RadioDirectoryUnavailableView(message: errorMessage) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleCountries) { country in
                    NavigationLink(value: RadioDirectoryDestination.country(country.code)) {
                        HStack {
                            Text(country.displayName)
                            Spacer(minLength: 8)
                            Text("\(country.stationCount)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(MusicDesign.secondaryLabel)
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading, countries.isEmpty {
                ProgressView().tint(MusicDesign.accent)
            }
        }
        .navigationTitle("Countries")
        .searchable(text: $filter, prompt: "Country")
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            countries = try await RadioBrowserClient.shared.countries()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Couldn't load the country list."
        }
    }
}

// MARK: - Rows and cards

struct RadioDirectoryStationRow: View {
    @EnvironmentObject private var app: AppModel
    let station: RadioDirectoryStation
    let isStarting: Bool
    let onPlay: () -> Void

    private var isSaved: Bool { app.isDirectoryStationSaved(station.stationUUID) }

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtworkView(
                url: station.faviconURL,
                meshArtworkSeed: RadioStationMeshArtwork.seedKey(stationId: station.stationUUID),
                cornerRadius: 10,
                maxDecodePixels: 160,
            )
            .frame(width: 52, height: 52)
            .overlay {
                if isStarting {
                    ProgressView().tint(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !station.detailLine.isEmpty {
                    Text(station.detailLine)
                        .font(.caption)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                app.toggleSavedDirectoryStation(station)
            } label: {
                Image(systemName: isSaved ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isSaved ? MusicDesign.accent : MusicDesign.secondaryLabel)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isSaved ? "Remove from Your Stations" : "Save to Your Stations")
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isStarting else { return }
            onPlay()
        }
        .contextMenu {
            Section {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    app.toggleSavedDirectoryStation(station)
                } label: {
                    Label(
                        isSaved ? "Remove from Your Stations" : "Save to Your Stations",
                        systemImage: isSaved ? "minus.circle" : "plus.circle",
                    )
                }
                if let homepage = station.homepageURL {
                    Link(destination: homepage) {
                        Label("Station Website", systemImage: "safari")
                    }
                }
            }
            .menuSectionPrimaryTint()
        }
    }
}

/// Square card for horizontal Radio / Home-style shelves (168×168 + aligned label block).
struct RadioShelfStationCard: View {
    let artworkURL: URL?
    let meshArtworkSeed: String
    let title: String
    let subtitle: String
    let isStarting: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                AlbumArtworkView(
                    url: artworkURL,
                    meshArtworkSeed: artworkURL == nil ? meshArtworkSeed : nil,
                    cornerRadius: MusicDesign.heroCorner,
                    maxDecodePixels: MusicDesign.shelfArtworkDecodePixels,
                )
                .frame(width: MusicDesign.shelfCardWidth, height: MusicDesign.shelfCardHeight)
                .overlay {
                    if isStarting {
                        ZStack {
                            RoundedRectangle(cornerRadius: MusicDesign.heroCorner, style: .continuous)
                                .fill(.black.opacity(0.35))
                            ProgressView().tint(.white)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .lineLimit(1)
                }
                .frame(
                    minWidth: MusicDesign.shelfCardWidth,
                    idealWidth: MusicDesign.shelfCardWidth,
                    maxWidth: MusicDesign.shelfCardWidth,
                    minHeight: MusicDesign.libraryHubGridLabelBlockMinHeight,
                    alignment: .topLeading,
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
    }
}

/// Square card for the horizontal "Popular" shelf on the Radio tab.
struct RadioDirectoryStationCard: View {
    let station: RadioDirectoryStation
    let isStarting: Bool
    let onPlay: () -> Void

    var body: some View {
        RadioShelfStationCard(
            artworkURL: station.faviconURL,
            meshArtworkSeed: RadioStationMeshArtwork.seedKey(stationId: station.stationUUID),
            title: station.name,
            subtitle: station.detailLine.isEmpty ? "Live stream" : station.detailLine,
            isStarting: isStarting,
            onPlay: onPlay,
        )
    }
}

/// Full-width list row for the "More to Explore" section (Apple Music–style genre list).
struct RadioExploreListRow: View {
    let title: String
    let destination: RadioDirectoryDestination

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicDesign.accent)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(MusicDesign.accent.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                MusicDesign.tertiarySurfaceFill,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared states

struct RadioDirectoryUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.largeTitle)
                .foregroundStyle(MusicDesign.secondaryLabel)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(MusicDesign.secondaryLabel)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .tint(MusicDesign.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 48)
    }
}

/// Shimmer rows while a directory page loads, matching the row layout.
struct RadioDirectoryRowSkeleton: View {
    var count: Int = 8

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    MusicShimmerSurface(cornerRadius: 10)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        MusicShimmerSurface(cornerRadius: 4)
                            .frame(width: 160, height: 12)
                        MusicShimmerSurface(cornerRadius: 4)
                            .frame(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MusicDesign.newTabHorizontalInset)
                .padding(.vertical, 8)
            }
        }
        .accessibilityLabel("Loading stations")
    }
}
