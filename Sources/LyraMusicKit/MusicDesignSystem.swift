import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - Accent color presets

struct AppAccentPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color

    static let presets: [AppAccentPreset] = [
        .init(id: "red",    name: "Red",    color: Color(red: 250/255, green: 45/255,  blue: 72/255)),
        .init(id: "pink",   name: "Pink",   color: Color(red: 255/255, green: 55/255,  blue: 120/255)),
        .init(id: "orange", name: "Orange", color: Color(red: 255/255, green: 149/255, blue: 0/255)),
        .init(id: "yellow", name: "Yellow", color: Color(red: 255/255, green: 214/255, blue: 10/255)),
        .init(id: "green",  name: "Green",  color: Color(red: 52/255,  green: 199/255, blue: 89/255)),
        .init(id: "teal",   name: "Teal",   color: Color(red: 48/255,  green: 176/255, blue: 199/255)),
        .init(id: "blue",   name: "Blue",   color: Color(red: 10/255,  green: 132/255, blue: 255/255)),
        .init(id: "indigo", name: "Indigo", color: Color(red: 94/255,  green: 92/255,  blue: 230/255)),
        .init(id: "purple", name: "Purple", color: Color(red: 191/255, green: 90/255,  blue: 242/255)),
        .init(id: "lightgray", name: "Light Gray", color: Color(red: 172/255, green: 172/255, blue: 176/255)),
    ]

    static let defaultId = "red"

    static func preset(id: String) -> AppAccentPreset {
        presets.first { $0.id == id } ?? presets[0]
    }

    static var current: AppAccentPreset {
        preset(id: UserDefaults.standard.string(forKey: "lyraAccentPresetId") ?? defaultId)
    }
}

/// Accent swatch grid shared by Settings and Login (uses real Icon Composer artwork per accent).
struct AccentColorPickerGrid: View {
    @Binding var accentPresetId: String
    var showsLabels: Bool = true
    var swatchSize: CGFloat = 44
    var selectedLabelColor: Color = .white
    var unselectedLabelColor: Color = .secondary

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
            spacing: 14,
        ) {
            ForEach(AppAccentPreset.presets) { preset in
                Button {
                    accentPresetId = preset.id
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            LyraAccentLogoView(
                                accentPresetId: preset.id,
                                size: swatchSize,
                                cornerRadius: swatchSize * 0.22,
                                showsIconPlate: true,
                            )
                            if accentPresetId == preset.id {
                                RoundedRectangle(cornerRadius: swatchSize * 0.22, style: .continuous)
                                    .strokeBorder(.white, lineWidth: 2.5)
                                    .frame(width: swatchSize, height: swatchSize)
                                Image(systemName: "checkmark")
                                    .font(.system(size: swatchSize * 0.28, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            }
                        }
                        if showsLabels {
                            Text(preset.name)
                                .font(.caption2)
                                .foregroundStyle(
                                    accentPresetId == preset.id ? selectedLabelColor : unselectedLabelColor,
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Signed-in profile image (cached Jellyfin / Navidrome avatar or placeholder).
struct AccountProfileAvatarView: View {
    @EnvironmentObject private var app: AppModel
    var diameter: CGFloat = 96

    @State private var avatarCG: CGImage?

    private var decodePixelSize: CGFloat { max(diameter * 3, 120) }

    private var reloadToken: String {
        let identity = app.accountAvatarIdentity.map { "\($0.backend)|\($0.serverKey)|\($0.userKey)" } ?? "none"
        return "\(app.accountAvatarRevision)-\(identity)-\(app.accountAvatarURL?.absoluteString ?? "")"
    }

    var body: some View {
        Group {
            if app.accountAvatarIdentity != nil {
                Group {
                    if let cg = avatarCG {
                        ArtworkPlatformImage.swiftUIImage(cgImage: cg)
                            .resizable()
                            .scaledToFill()
                    } else {
                        profilePlaceholder
                            .opacity(0.55)
                    }
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().stroke(MusicDesign.separator, lineWidth: 1))
            } else {
                profilePlaceholder
            }
        }
        .frame(width: diameter, height: diameter)
        .task(id: reloadToken) {
            await refreshAvatarImage()
        }
        .onAppear {
            app.prefetchAccountAvatar()
        }
    }

    private func refreshAvatarImage() async {
        guard let identity = app.accountAvatarIdentity else {
            avatarCG = nil
            return
        }

        if let data = AccountAvatarCache.loadData(identity: identity) {
            let cached = await Task.detached(priority: .userInitiated) {
                ArtworkImageDecoder.cgImage(from: data, maxPixelSize: decodePixelSize)
            }.value
            if let cached {
                avatarCG = cached
            }
        }

        guard let url = app.accountAvatarURL else { return }
        await AccountAvatarCache.prefetch(url: url, identity: identity)
        if let data = AccountAvatarCache.loadData(identity: identity) {
            let refreshed = await Task.detached(priority: .userInitiated) {
                ArtworkImageDecoder.cgImage(from: data, maxPixelSize: decodePixelSize)
            }.value
            if let refreshed {
                avatarCG = refreshed
            }
        }
    }

    private var profilePlaceholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: diameter * 0.92, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(MusicDesign.secondaryLabel)
    }
}

/// Visual tokens aligned with Apple Music: adaptive canvas + accent-driven chrome.
enum MusicDesign {
    /// Dynamic accent — reads the user's chosen preset from UserDefaults each call.
    static var accent: Color { AppAccentPreset.current.color }

    /// Main screen canvas (adapts with Light / Dark / System).
    static var background: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.gray.opacity(0.06)
        #endif
    }

    static var secondaryLabel: Color {
        #if os(iOS)
        Color(UIColor.secondaryLabel)
        #elseif os(macOS)
        Color(nsColor: .secondaryLabelColor)
        #else
        Color.gray
        #endif
    }

    static var separator: Color {
        #if os(iOS)
        Color(UIColor.separator)
        #elseif os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color.gray.opacity(0.35)
        #endif
    }

    /// Placeholders, subtle row wells, artwork skeleton.
    static var tertiarySurfaceFill: Color {
        #if os(iOS)
        Color(UIColor.tertiarySystemFill)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.gray.opacity(0.12)
        #endif
    }

    /// Capsules / pills behind secondary actions (Play Next row chips, etc.).
    static var chromeCapsuleFill: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemFill)
        #elseif os(macOS)
        Color(nsColor: .quaternaryLabelColor).opacity(0.35)
        #else
        Color.gray.opacity(0.18)
        #endif
    }

    /// Thin translucent overlays on grouped controls (dark vs light).
    static func adaptiveOverlayFill(opacityDark: Double, opacityLight: Double) -> Color {
        #if os(iOS)
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(opacityDark)
                : UIColor.black.withAlphaComponent(opacityLight)
        })
        #else
        Color.primary.opacity(opacityLight)
        #endif
    }

    static let albumCorner: CGFloat = 10
    static let gridAlbumCorner: CGFloat = 10
    static let heroCorner: CGFloat = 12
    static let miniArtwork: CGFloat = 44
    /// Mini player row: smaller than grid mini so controls don’t clip in the glass capsule.
    static let miniPlayerArtwork: CGFloat = 30
    static let gridMinCell: CGFloat = 158
    static let shelfCardWidth: CGFloat = 168
    static let shelfCardHeight: CGFloat = 168

    // MARK: - New tab (Apple Music Browse-style)
    /// Leading inset for hero labels, shelves, and section headers (aligned with large navigation title).
    static let newTabHorizontalInset: CGFloat = 16
    /// Hero carousel: visible slice of the next card (horizontal peek).
    static let newTabHeroPeek: CGFloat = 44
    /// Hero image height as a fraction of card width (wide landscape-style card).
    static let newTabHeroImageHeightFactor: CGFloat = 10 / 16
    /// Continuous-corner “billboard” cards on the New tab hero rail.
    static let newTabHeroCardCorner: CGFloat = 14

    // MARK: - Now Playing scrubber / volume track (match each other; thin “volume” pill, no thumb)
    /// Track pill height for scrubber and simulator volume row (device `MPVolumeView` uses system sizing).
    static let nowPlayingSliderTrackHeight: CGFloat = 4
    static let nowPlayingSliderDimOpacity: Double = 0.18
    static let nowPlayingSliderFillOpacity: Double = 0.90
    static let nowPlayingSliderStrokeOpacity: Double = 0.16

    // MARK: - Album hero detail (Play / Request capsule)
    /// Fixed capsule width — keeps Play / Pause / Request from stretching wider than Apple Music–style library rows.
    static let albumHeroPrimaryCapsuleWidth: CGFloat = 158
}

struct AlbumArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = MusicDesign.albumCorner

    @State private var decoded: CGImage?
    @State private var loadFailed = false

    private var maxDecodePixels: CGFloat { 768 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(MusicDesign.tertiarySurfaceFill)
            if let url {
                Group {
                    if let decoded {
                        ArtworkPlatformImage.swiftUIImage(cgImage: decoded)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transaction { $0.animation = nil }
                    } else if loadFailed {
                        placeholder
                    } else {
                        Color.clear
                    }
                }
                .task(id: url.absoluteString) {
                    await load(url: url)
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func load(url: URL) async {
        loadFailed = false
        decoded = nil
        let cg: CGImage?
        if url.isFileURL, let data = try? Data(contentsOf: url) {
            cg = await Task.detached(priority: .utility) {
                ArtworkImageDecoder.cgImage(from: data, maxPixelSize: maxDecodePixels)
            }.value
        } else {
            cg = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: maxDecodePixels)
        }
        await MainActor.run {
            decoded = cg
            loadFailed = cg == nil
        }
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.title2)
            .foregroundStyle(MusicDesign.secondaryLabel)
    }
}

/// Profile control → **Settings** (cached Jellyfin / Navidrome avatar or SF Symbol fallback).
struct MusicToolbarSettingsAvatarLink: View {
    /// Circular artwork diameter (New tab uses 45; compact pills may use less).
    var diameter: CGFloat = 45

    var body: some View {
        NavigationLink {
            SettingsView()
        } label: {
            AccountProfileAvatarView(diameter: diameter)
                .frame(minWidth: max(44, diameter), minHeight: max(44, diameter))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

private struct MusicNavigationChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(MusicDesign.background, for: .navigationBar)
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        #else
        content
        #endif
    }
}

private struct MusicNewTabNavigationChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        #else
        content
        #endif
    }
}

extension View {
    /// Navigation bar matches app appearance (Light / Dark / System).
    @ViewBuilder
    func musicNavigationChrome() -> some View {
        modifier(MusicNavigationChromeModifier())
    }

    /// **New** tab only: transparent nav bar; toolbar appearance follows app theme.
    @ViewBuilder
    func musicNewTabNavigationChrome() -> some View {
        modifier(MusicNewTabNavigationChromeModifier())
    }

    /// Library / browse **album hero** screens: no opaque navigation bar fill—the hero tint fills the screen behind the bar (see ``AlbumHeroBackdropView``).
    @ViewBuilder
    func musicHeroAlbumNavigationChrome(palette: ArtworkDynamicGradient.BackdropPalette) -> some View {
        #if os(iOS)
        self
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(palette.prefersDarkHeroChrome ? .light : .dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// **New** tab root only: hide the system navigation bar so there is no duplicate centered inline “New” when scrolling.
    @ViewBuilder
    func musicNewTabRootHidesNavigationBar() -> some View {
        #if os(iOS)
        self.toolbarVisibility(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    func musicHidesTabBar() -> some View {
        #if os(iOS)
        self.toolbarVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// Pushed screens (detail, settings, …): restore a visible bar when the New tab root hides it.
    @ViewBuilder
    func musicNavigationBarVisibleWhenPushed() -> some View {
        #if os(iOS)
        self.toolbarVisibility(.visible, for: .navigationBar)
        #else
        self
        #endif
    }
}

// MARK: - Platform chrome (split from UIKit-only APIs for SwiftPM / Xcode)

enum MusicNavigationTitleDisplayMode {
    case large
    case inline
    case automatic
}

extension View {
    @ViewBuilder
    func musicNavigationBarTitleDisplayMode(_ mode: MusicNavigationTitleDisplayMode) -> some View {
        #if os(iOS)
        switch mode {
        case .large: self.navigationBarTitleDisplayMode(.large)
        case .inline: self.navigationBarTitleDisplayMode(.inline)
        case .automatic: self.navigationBarTitleDisplayMode(.automatic)
        }
        #else
        self
        #endif
    }
}

enum MusicTextAutocapitalization {
    case never
    case words
    case sentences
    case characters
}

extension View {
    @ViewBuilder
    func musicTextInputAutocapitalization(_ style: MusicTextAutocapitalization) -> some View {
        #if os(iOS)
        switch style {
        case .never: self.textInputAutocapitalization(.never)
        case .words: self.textInputAutocapitalization(.words)
        case .sentences: self.textInputAutocapitalization(.sentences)
        case .characters: self.textInputAutocapitalization(.characters)
        }
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder
    func musicGlassEffect<S: Shape>(in shape: S) -> some View {
        #if os(iOS)
        self.glassEffect(in: shape)
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }

    @ViewBuilder
    func musicGlassCapsuleInteractiveChrome() -> some View {
        #if os(iOS)
        self.glassEffect(.regular.interactive(), in: Capsule())
        #else
        self.background(.ultraThinMaterial, in: Capsule(style: .continuous))
        #endif
    }
}

enum MusicToolbar {
    /// Replaces `.topBarTrailing`, which is unavailable when compiling `LyraMusicKit` for macOS.
    static var trailingItemPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

// MARK: - Main-tab floating header (Home / New / Radio)

/// Observes vertical scroll so the custom large-title header can hide after scrolling (matches **New** tab).
struct MusicTabFloatingHeaderScrollModifier: ViewModifier {
    var slack: CGFloat
    @Binding var showFloatingHeader: Bool
    @State private var anchorContentOffsetY: CGFloat?

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
            if anchorContentOffsetY == nil {
                anchorContentOffsetY = y
            }
            let anchor = anchorContentOffsetY ?? y
            let nearTop = (y - anchor) < slack
            if showFloatingHeader != nearTop {
                showFloatingHeader = nearTop
            }
        }
    }
}

/// Large **Home** / **New** / **Radio** title row + trailing controls (profile ring, refresh, …).
struct MusicTabTitleHeaderBar<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, MusicDesign.newTabHorizontalInset)
        .padding(.bottom, 10)
    }
}

extension MusicTabTitleHeaderBar where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Library list chrome (Songs, playlists, favorites, downloads, artist detail)

/// Rounded search field used on library track lists (adapts fill in light/dark).
struct LibrarySearchPill: View {
    let prompt: String
    @Binding var text: String
    var showsMic: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MusicDesign.secondaryLabel)
            TextField(prompt, text: $text)
                .foregroundStyle(.primary)
                .musicTextInputAutocapitalization(.never)
            if showsMic {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicDesign.secondaryLabel.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))
    }
}

/// Play + Shuffle capsules for library track lists (theme-aware fill, accent labels).
struct LibraryPlayShuffleRow: View {
    var isDisabled: Bool = false
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicDesign.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }
}

// MARK: - Scroll-driven mini-player collapse

struct CollapseOnScrollModifier: ViewModifier {
    var collapseState: MiniPlayerCollapseState

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
            let delta = new - old
            guard abs(delta) > 4 else { return }
            if delta > 0, new > 40 {
                if !collapseState.isCollapsed { collapseState.collapse() }
            } else if delta < 0 {
                if collapseState.isCollapsed { collapseState.expand() }
            }
        }
    }
}

extension View {
    func collapsesMiniPlayerOnScroll(_ state: MiniPlayerCollapseState) -> some View {
        modifier(CollapseOnScrollModifier(collapseState: state))
    }
}
