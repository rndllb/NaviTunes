import SwiftUI

/// Apple Music **Radio** tab layout (decorative stations + hint text).
struct RadioTabView: View {
    @Environment(MiniPlayerCollapseState.self) private var collapseState
    @State private var showFloatingHeader = true

    private let floatingHeaderCollapseSlack: CGFloat = 72

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var inset: CGFloat { MusicDesign.newTabHorizontalInset }

    private let tiles: [(title: String, colors: [Color])] = [
        ("Apple Music 1", [.red, .black]),
        ("Hits Radio", [Color(red: 0.2, green: 0.35, blue: 0.95), .black]),
        ("Country", [.yellow.opacity(0.9), .brown]),
        ("Chill", [.cyan.opacity(0.5), .purple.opacity(0.6)]),
        ("Rock", [.orange, .red.opacity(0.8)]),
        ("Jazz", [.indigo, .black]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Live stations are not wired to your server yet — this tab matches the Music layout.")
                        .font(.footnote)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .padding(.horizontal, inset)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                            stationTile(title: tile.title, colors: tile.colors)
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .padding(.bottom, 32)
            }
            .modifier(MusicTabFloatingHeaderScrollModifier(
                slack: floatingHeaderCollapseSlack,
                showFloatingHeader: $showFloatingHeader,
            ))
            .collapsesMiniPlayerOnScroll(collapseState)
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
        }
        .tint(MusicDesign.accent)
    }

    private func stationTile(title: String, colors: [Color]) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Lyra Music")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(12)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
