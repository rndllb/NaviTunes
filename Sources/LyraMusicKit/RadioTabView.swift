import SwiftUI

/// **Radio** tab — Navidrome genre stations (`getRandomSongs`) and server internet radio (`getInternetRadioStations`).
struct RadioTabView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showFloatingHeader = true
    @State private var genreStations: [RadioGenreStation] = []
    @State private var internetStations: [InternetRadioStation] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var startingStationID: String?

    private let floatingHeaderCollapseSlack: CGFloat = 72
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var inset: CGFloat { MusicDesign.newTabHorizontalInset }

    private static let tileGradients: [[Color]] = [
        [.red, .black],
        [Color(red: 0.2, green: 0.35, blue: 0.95), .black],
        [.yellow.opacity(0.9), .brown],
        [.cyan.opacity(0.5), .purple.opacity(0.6)],
        [.orange, .red.opacity(0.8)],
        [.indigo, .black],
        [.mint, .teal],
        [.pink, .purple],
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !app.isSignedIn {
                        signedOutHint
                    } else if app.backendKind != .navidrome {
                        jellyfinHint
                    } else if isLoading, genreStations.isEmpty, internetStations.isEmpty {
                        ProgressView()
                            .tint(MusicDesign.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        if let loadError, genreStations.isEmpty, internetStations.isEmpty {
                            Text(loadError)
                                .font(.footnote)
                                .foregroundStyle(MusicDesign.secondaryLabel)
                                .padding(.horizontal, inset)
                        }

                        if !internetStations.isEmpty {
                            sectionHeader("Live Radio")
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(internetStations) { station in
                                    stationTile(
                                        title: station.name,
                                        subtitle: "Live stream",
                                        colors: gradient(for: station.name),
                                        isStarting: startingStationID == "live-\(station.id)",
                                    ) {
                                        Task { await playLive(station) }
                                    }
                                }
                            }
                            .padding(.horizontal, inset)
                        }

                        sectionHeader("Stations by Genre")
                        Text("Shuffled tracks from your library matching each genre.")
                            .font(.footnote)
                            .foregroundStyle(MusicDesign.secondaryLabel)
                            .padding(.horizontal, inset)

                        LazyVGrid(columns: columns, spacing: 12) {
                            stationTile(
                                title: "Shuffle All",
                                subtitle: "Your library",
                                colors: [.purple, .black],
                                isStarting: startingStationID == "shuffle-all",
                            ) {
                                Task { await playGenre(nil) }
                            }

                            ForEach(genreStations) { station in
                                stationTile(
                                    title: station.genre.name,
                                    subtitle: genreSubtitle(station.genre),
                                    colors: gradient(for: station.genre.name),
                                    isStarting: startingStationID == station.id,
                                ) {
                                    Task { await playGenre(station.genre.name) }
                                }
                            }
                        }
                        .padding(.horizontal, inset)
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

    private var radioLoadKey: String {
        "\(app.isSignedIn)-\(app.backendKind.rawValue)-\(app.libraryCatalogEpoch)"
    }

    private var signedOutHint: some View {
        ContentUnavailableView(
            "Sign in to listen",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text("Connect to Navidrome to start genre and live radio stations.")
        )
        .padding(.top, 40)
    }

    private var jellyfinHint: some View {
        ContentUnavailableView(
            "Navidrome radio",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text("Genre and live radio stations are available when signed in to Navidrome.")
        )
        .padding(.top, 40)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, inset)
    }

    private func genreSubtitle(_ genre: LibraryGenreSummary) -> String {
        if let n = genre.albumCount, n > 0 {
            return n == 1 ? "1 album" : "\(n) albums"
        }
        return "Lyra Music"
    }

    private func gradient(for key: String) -> [Color] {
        let hash = abs(key.hashValue)
        return Self.tileGradients[hash % Self.tileGradients.count]
    }

    private func stationTile(
        title: String,
        subtitle: String,
        colors: [Color],
        isStarting: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                if isStarting {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
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
            genreStations = []
            internetStations = []
            loadError = nil
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let rawGenres = (try? await client.libraryGenres(limit: 200)) ?? []
        let sortedGenres = rawGenres.sorted { lhs, rhs in
            let lc = lhs.albumCount ?? 0
            let rc = rhs.albumCount ?? 0
            if lc != rc { return lc > rc }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let genres = sortedGenres.prefix(24).map { RadioGenreStation(genre: $0) }
        let live = (try? await client.fetchInternetRadioStations()) ?? []
        genreStations = genres
        internetStations = live
        if genres.isEmpty, live.isEmpty {
            loadError = "No genres or live stations found. Add genre tags to your music or configure internet radio in Navidrome."
        }
    }

    private func playGenre(_ genreName: String?) async {
        let key = genreName.map { "genre-\($0)" } ?? "shuffle-all"
        startingStationID = key
        defer { startingStationID = nil }
        await app.playNavidromeGenreRadio(genreName: genreName)
    }

    private func playLive(_ station: InternetRadioStation) async {
        startingStationID = "live-\(station.id)"
        defer { startingStationID = nil }
        await app.playInternetRadioStation(station)
    }
}
