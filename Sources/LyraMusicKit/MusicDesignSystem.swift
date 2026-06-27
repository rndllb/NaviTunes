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

    static let customId = "custom"
    static let defaultId = "red"
    static let accentPresetIdKey = "lyraAccentPresetId"
    static let appIconPresetIdKey = "lyraAppIconPresetId"
    static let customAccentHexKey = "lyraCustomAccentHex"
    static let defaultCustomHex = "#FA2D48"

    /// Icon sets only exist for bundled presets — never ``customId``.
    static func validIconPresetId(_ id: String) -> String {
        presets.contains(where: { $0.id == id }) ? id : defaultId
    }

    static func preset(id: String) -> AppAccentPreset {
        if id == customId {
            let hex = UserDefaults.standard.string(forKey: customAccentHexKey) ?? defaultCustomHex
            return .init(id: customId, name: "Custom", color: color(fromHex: hex) ?? presets[0].color)
        }
        return presets.first { $0.id == id } ?? presets[0]
    }

    static var current: AppAccentPreset {
        preset(id: UserDefaults.standard.string(forKey: accentPresetIdKey) ?? defaultId)
    }

    static func color(fromHex hex: String) -> Color? {
        guard let rgb = rgbComponents(fromHex: hex) else { return nil }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func hex(from color: Color) -> String {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return defaultCustomHex }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #elseif os(macOS)
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return defaultCustomHex }
        return String(
            format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255),
        )
        #else
        return defaultCustomHex
        #endif
    }

    static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(s)"
    }

    private static func rgbComponents(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let normalized = normalizedHex(hex) else { return nil }
        let digits = normalized.dropFirst()
        let scanner = Scanner(string: String(digits))
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return (r, g, b)
    }
}

/// Accent swatch grid — solid color tiles per preset plus a custom eyedropper slot.
struct AccentColorPickerGrid: View {
    @Binding var accentPresetId: String
    @Binding var customAccentHex: String
    var showsLabels: Bool = true
    var swatchSize: CGFloat = 44
    var selectedLabelColor: Color = .white
    var unselectedLabelColor: Color = .secondary

    private var customColor: Color {
        AppAccentPreset.color(fromHex: customAccentHex) ?? AppAccentPreset.preset(id: AppAccentPreset.defaultId).color
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
            spacing: 14,
        ) {
            ForEach(AppAccentPreset.presets) { preset in
                accentPresetButton(preset)
            }
            customAccentButton
        }
    }

    private func accentPresetButton(_ preset: AppAccentPreset) -> some View {
        Button {
            accentPresetId = preset.id
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    colorSwatch(fill: preset.color)
                    if accentPresetId == preset.id {
                        selectionChrome
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

    private func colorSwatch(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: swatchSize * 0.22, style: .continuous)
            .fill(fill)
            .frame(width: swatchSize, height: swatchSize)
    }

    private var customAccentButton: some View {
        Button {
            accentPresetId = AppAccentPreset.customId
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    colorSwatch(fill: customColor)
                        .overlay {
                            Image(systemName: "eyedropper.halffull")
                                .font(.system(size: swatchSize * 0.34, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        }
                    if accentPresetId == AppAccentPreset.customId {
                        selectionChrome
                    }
                }
                if showsLabels {
                    Text("Custom")
                        .font(.caption2)
                        .foregroundStyle(
                            accentPresetId == AppAccentPreset.customId ? selectedLabelColor : unselectedLabelColor,
                        )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var selectionChrome: some View {
        Group {
            RoundedRectangle(cornerRadius: swatchSize * 0.22, style: .continuous)
                .strokeBorder(.white, lineWidth: 2.5)
                .frame(width: swatchSize, height: swatchSize)
            Image(systemName: "checkmark")
                .font(.system(size: swatchSize * 0.28, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
    }
}

/// Color wheel + hex field shown when the custom accent preset is active.
struct CustomAccentColorControls: View {
    @Binding var accentPresetId: String
    @Binding var customAccentHex: String
    @State private var hexDraft = ""

    private var pickerColor: Binding<Color> {
        Binding(
            get: {
                AppAccentPreset.color(fromHex: customAccentHex)
                    ?? AppAccentPreset.preset(id: AppAccentPreset.defaultId).color
            },
            set: { newColor in
                customAccentHex = AppAccentPreset.hex(from: newColor)
                accentPresetId = AppAccentPreset.customId
                hexDraft = customAccentHex
            },
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ColorPicker("Color", selection: pickerColor, supportsOpacity: false)
                .tint(MusicDesign.accent)

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(pickerColor.wrappedValue)
                    .frame(width: 36, height: 36)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                TextField("Hex code", text: $hexDraft)
                    .musicTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.asciiCapable)
                    #endif
                    .onSubmit { commitHexDraft() }
                    .onChange(of: hexDraft) { _, newValue in
                        guard let normalized = AppAccentPreset.normalizedHex(newValue) else { return }
                        customAccentHex = normalized
                        accentPresetId = AppAccentPreset.customId
                    }
            }
        }
        .onAppear {
            hexDraft = customAccentHex
        }
        .onChange(of: customAccentHex) { _, newValue in
            if hexDraft != newValue {
                hexDraft = newValue
            }
        }
    }

    private func commitHexDraft() {
        if let normalized = AppAccentPreset.normalizedHex(hexDraft) {
            customAccentHex = normalized
            accentPresetId = AppAccentPreset.customId
            hexDraft = normalized
        } else {
            hexDraft = customAccentHex
        }
    }
}

/// Home-screen icon picker — preset artwork only (no custom slot).
struct AppIconPickerGrid: View {
    @Binding var appIconPresetId: String
    var showsLabels: Bool = true
    var swatchSize: CGFloat = 44
    var selectedLabelColor: Color = .primary
    var unselectedLabelColor: Color = .secondary

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
            spacing: 14,
        ) {
            ForEach(AppAccentPreset.presets) { preset in
                Button {
                    appIconPresetId = preset.id
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            LyraAccentLogoView(
                                accentPresetId: preset.id,
                                size: swatchSize,
                                cornerRadius: swatchSize * 0.22,
                                showsIconPlate: true,
                            )
                            if appIconPresetId == preset.id {
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
                                    appIconPresetId == preset.id ? selectedLabelColor : unselectedLabelColor,
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
        .onAppear {
            hydrateAvatarFromCacheIfNeeded()
            app.prefetchAccountAvatar()
        }
        .task(id: reloadToken) {
            await refreshAvatarImage()
        }
    }

    /// Synchronous cache hit so scroll-to-top header reveal does not flash the placeholder.
    private func hydrateAvatarFromCacheIfNeeded() {
        guard avatarCG == nil, let identity = app.accountAvatarIdentity else { return }
        avatarCG = AccountAvatarCache.cachedDecodedImage(identity: identity, maxPixelSize: decodePixelSize)
    }

    private func refreshAvatarImage() async {
        guard let identity = app.accountAvatarIdentity else {
            avatarCG = nil
            return
        }

        if let cached = AccountAvatarCache.cachedDecodedImage(identity: identity, maxPixelSize: decodePixelSize) {
            await MainActor.run { avatarCG = cached }
        }

        guard let url = app.accountAvatarURL else { return }
        await AccountAvatarCache.prefetch(url: url, identity: identity)
        if let refreshed = AccountAvatarCache.cachedDecodedImage(identity: identity, maxPixelSize: decodePixelSize) {
            await MainActor.run { avatarCG = refreshed }
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

    /// Grouped-list background for Settings (light gray in light mode, like iOS Settings) so the
    /// white grouped cells/sections stand out. `systemBackground` flattened everything to white.
    static var settingsBackground: Color {
        #if os(iOS)
        Color(UIColor.systemGroupedBackground)
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

    /// Delete-from-library actions — always system red, never artwork/luminance-adaptive.
    static var destructiveAction: Color {
        #if os(iOS)
        Color(uiColor: .systemRed)
        #elseif os(macOS)
        Color(nsColor: .systemRed)
        #else
        Color.red
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
    /// Library hub / Recently Added / Recently Downloaded — keeps row mates aligned when titles wrap.
    static let libraryHubGridLabelBlockMinHeight: CGFloat = 56
    static let libraryHubGridLabelSpacing: CGFloat = 8
    static let heroCorner: CGFloat = 12
    static let miniArtwork: CGFloat = 44
    /// Mini player row: smaller than grid mini so controls don’t clip in the glass capsule.
    static let miniPlayerArtwork: CGFloat = 26
    static let gridMinCell: CGFloat = 158
    static let shelfCardWidth: CGFloat = 168
    static let shelfCardHeight: CGFloat = 168
    /// Circular artist avatar in horizontal shelves (Home “New Artists Added”, New tab “Artists You're Into”).
    static let artistCircleTileSize: CGFloat = 110
    static let artistCircleTileLabelWidth: CGFloat = 120

    // MARK: - Home Top Picks editorial card
    static let homeTopPickCardWidth: CGFloat = 250
    static let homeTopPickCardHeight: CGFloat = 325
    /// Square cover — full card width, flush to the top edge.
    static let homeTopPickArtworkSize: CGFloat = homeTopPickCardWidth
    static let homeTopPickBleedBandHeight: CGFloat = homeTopPickCardHeight - homeTopPickArtworkSize
    /// Bottom strip of cover art sampled for the vertical stretch bleed.
    static let homeTopPickBleedSourceRatio: CGFloat = 0.05
    /// Soft blur at the bleed top — eases the seam with cover art.
    static let homeTopPickBleedBlurRadiusTop: CGFloat = 2.5
    /// Stronger blur from ~mid-band downward.
    static let homeTopPickBleedBlurRadiusBottom: CGFloat = 11
    /// Bleed draws upward under the cover bottom for a seamless blend.
    static let homeTopPickBleedSeamOverlap: CGFloat = 44
    /// Cover art fades out over this height at its bottom edge.
    static let homeTopPickArtSeamFadeHeight: CGFloat = 48
    static let homeTopPickCardCorner: CGFloat = 14

    // MARK: - New tab (Apple Music Browse-style)
    /// Leading inset for hero labels, shelves, and section headers (aligned with large navigation title).
    static let newTabHorizontalInset: CGFloat = 16
    /// Hero carousel: visible slice of the next card (horizontal peek).
    static let newTabHeroPeek: CGFloat = 44
    /// Hero image height as a fraction of card width (wide landscape editorial card).
    static let newTabHeroImageHeightFactor: CGFloat = 0.56
    /// Continuous-corner “billboard” cards on the New tab hero rail.
    static let newTabHeroCardCorner: CGFloat = 14

    // MARK: - Now Playing scrubber / volume track (match each other; thin “volume” pill, no thumb)
    /// Track pill height for scrubber and simulator volume row (device `MPVolumeView` uses system sizing).
    /// Apple Music's bars sit around 8pt at rest, expanding while scrubbing.
    static let nowPlayingSliderTrackHeight: CGFloat = 8
    static let nowPlayingSliderDimOpacity: Double = 0.18
    static let nowPlayingSliderFillOpacity: Double = 0.90
    static let nowPlayingSliderStrokeOpacity: Double = 0.16

    // MARK: - Album hero detail (Play / Request capsule)
    /// Fixed capsule width — keeps Play / Pause / Request from stretching wider than Apple Music–style library rows.
    static let albumHeroPrimaryCapsuleWidth: CGFloat = 158
    /// Icon–title gap inside the primary Play capsule (``ServerPlaylistDetailView`` hero).
    static let albumHeroPlayLabelSpacing: CGFloat = 5
    /// Tighter icon–title gap for library section Play / Shuffle capsules.
    static let libraryPlayShuffleLabelSpacing: CGFloat = 2
    /// Icon–title gap for **Request** actions (overflow menus + browse hero capsule).
    static let requestActionLabelSpacing: CGFloat = 2

    /// Hairline around song-list artwork (Apple Music–style, barely visible).
    static func songRowArtworkBorder(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }
}

struct AlbumArtworkView: View {
    let url: URL?
    /// When ``url`` is nil (e.g. Navidrome internet radio), show a deterministic mesh gradient for this seed.
    var meshArtworkSeed: String? = nil
    var cornerRadius: CGFloat = MusicDesign.albumCorner
    var maxDecodePixels: CGFloat = 768
    /// Faint outline on thumbnails; off on Now Playing hero/queue art only.
    var showsSubtleBorder: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var decoded: CGImage?
    @State private var loadFailed = false
    @State private var loadedArtworkID: String?

    private var artworkID: String {
        guard let url else { return "none" }
        return DecodedArtworkCache.stableID(for: url, maxPixelSize: maxDecodePixels)
    }

    var body: some View {
        // Square placeholder + overlay: keeps a 1:1 box and crops non-square art (aspect fill).
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(MusicDesign.tertiarySurfaceFill)
                    artworkContent
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showsSubtleBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            MusicDesign.songRowArtworkBorder(for: colorScheme),
                            lineWidth: 0.5
                        )
                }
            }
    }

    @ViewBuilder
    private var artworkContent: some View {
        if let url {
            Group {
                if let decoded {
                    ArtworkPlatformImage.swiftUIImage(cgImage: decoded)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else if loadFailed {
                    placeholder
                } else {
                    Color.clear
                }
            }
            .task(id: url.absoluteString) {
                await load(url: url)
            }
        } else if let meshArtworkSeed {
            RadioStationMeshArtworkView(seedKey: meshArtworkSeed, cornerRadius: cornerRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder
        }
    }

    private func load(url: URL) async {
        let loadKey = url.absoluteString
        if loadedArtworkID == loadKey, decoded != nil {
            return
        }
        // Suppress animation only for image-load state changes — the previous
        // `.transaction { $0.animation = nil }` on the Image itself also blocked
        // the Image from participating in the parent's frame morph, which made
        // resizes look like the container was cropping a fixed-size image
        // instead of scaling the image itself.
        if let cached = DecodedArtworkCache.image(for: url, maxPixelSize: maxDecodePixels) {
            withTransaction(Transaction(animation: nil)) {
                decoded = cached
                loadFailed = false
                loadedArtworkID = loadKey
            }
            ArtworkDynamicGradient.prefetchBackdrop(for: url)
            return
        }
        withTransaction(Transaction(animation: nil)) {
            loadFailed = false
            if loadedArtworkID != loadKey {
                decoded = nil
            }
        }
        let cg = await RemoteArtworkLoad.cgImage(from: url, maxPixelSize: maxDecodePixels)
        await MainActor.run {
            withTransaction(Transaction(animation: nil)) {
                decoded = cg
                loadFailed = cg == nil
                loadedArtworkID = loadKey
            }
            if cg != nil {
                ArtworkDynamicGradient.prefetchBackdrop(for: url)
            }
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
                .id("lyra-account-profile-avatar")
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

/// Library track/artist lists with a large title: keep the bar chrome transparent while scrolling
/// so content doesn’t flash a solid black/white slab behind the collapsing title.
private struct MusicLibraryListNavigationChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        #else
        content
        #endif
    }
}

#if os(iOS)
private enum MusicLibraryNavigationBarAppearance {
    static func hideCollapsedInlineTitle(on bar: UINavigationBar) {
        let hiddenTitle: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]

        func applyingHiddenInlineTitle(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            let copy = appearance.copy()
            copy.titleTextAttributes = hiddenTitle
            return copy
        }

        bar.standardAppearance = applyingHiddenInlineTitle(bar.standardAppearance)
        bar.compactAppearance = applyingHiddenInlineTitle(bar.compactAppearance ?? UINavigationBarAppearance())
    }

    static func restoreDefaultInlineTitle(on bar: UINavigationBar) {
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label]

        func restoringInlineTitle(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            let copy = appearance.copy()
            copy.titleTextAttributes = attrs
            return copy
        }

        bar.standardAppearance = restoringInlineTitle(bar.standardAppearance)
        bar.compactAppearance = restoringInlineTitle(bar.compactAppearance ?? UINavigationBarAppearance())
    }
}

/// Hides the small centered nav title after the large title collapses on scroll.
private struct MusicLibraryHideCollapsedNavTitleInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyHide()
        }

        private func applyHide() {
            guard let bar = resolveNavigationBar() else { return }
            MusicLibraryNavigationBarAppearance.hideCollapsedInlineTitle(on: bar)
        }

        private func resolveNavigationBar() -> UINavigationBar? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if let bar = current.navigationController?.navigationBar {
                    return bar
                }
                candidate = current.parent
            }
            return nil
        }
    }
}

/// Restores visible inline nav titles on pushed detail screens (genre/album grids, etc.).
private struct MusicLibraryRestoreInlineNavTitleInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let bar = navigationController?.navigationBar else { return }
            MusicLibraryNavigationBarAppearance.restoreDefaultInlineTitle(on: bar)
        }
    }
}

private struct MusicLibraryHideCollapsedNavTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(MusicLibraryHideCollapsedNavTitleInstaller().frame(width: 0, height: 0))
    }
}

private struct MusicLibraryRestoreInlineNavTitleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(MusicLibraryRestoreInlineNavTitleInstaller().frame(width: 0, height: 0))
    }
}
#endif

/// Fixed white backdrop — never inherit app dark-mode nav fill (opaque black slab + white glyphs).
private struct MusicFavoriteSongsNavigationChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
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

    /// Large-title library lists (Songs, Artists, …): transparent nav bar while scrolling.
    @ViewBuilder
    func musicLibraryListNavigationChrome() -> some View {
        modifier(MusicLibraryListNavigationChromeModifier())
    }

    /// Library category screens: system large title above search; no collapsing inline nav label.
    @ViewBuilder
    func musicLibrarySectionScreen(title: String) -> some View {
        navigationTitle(title)
            .musicNavigationBarTitleDisplayMode(.large)
            .musicLibraryListNavigationChrome()
            .musicNavigationBarVisibleWhenPushed()
            #if os(iOS)
            .modifier(MusicLibraryHideCollapsedNavTitleModifier())
            #endif
    }

    /// Pushed library detail with an inline nav title — undo large-list inline-title hiding.
    @ViewBuilder
    func musicInlineNavigationTitleScreen() -> some View {
        #if os(iOS)
        modifier(MusicLibraryRestoreInlineNavTitleModifier())
        #else
        self
        #endif
    }

    /// ``FavoritePlaylistView`` — white hero wash: transparent bar (no dark slab on scroll), dark controls.
    @ViewBuilder
    func musicFavoriteSongsNavigationChrome() -> some View {
        modifier(MusicFavoriteSongsNavigationChromeModifier())
    }

    /// Plain lists on the search tab.
    @ViewBuilder
    func musicDiscoverySearchListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listSectionSeparator(.hidden)
            .listRowSeparator(.hidden)
            .listRowSpacing(5)
    }

    /// iOS 26+ Liquid Glass search field (bottom toolbar on iPhone). Library submenus and detail screens.
    @ViewBuilder
    func musicNativeSearchable(text: Binding<String>, prompt: Text) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .automatic, prompt: prompt)
            .searchToolbarBehavior(.automatic)
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }

    /// Search tab header — native ``UISearchBar`` under the top edge. Regular ``Tab`` only;
    /// never combine with ``TabRole/search`` or ``placement: .automatic`` (those use the tab bar / bottom toolbar).
    @ViewBuilder
    func musicNativeSearchableTop(text: Binding<String>, prompt: Text) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .searchToolbarBehavior(.automatic)
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }

    @ViewBuilder
    func musicNativeSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        musicNativeSearchable(text: text, prompt: Text(prompt))
    }

    @ViewBuilder
    func musicNativeSearchableTop(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        musicNativeSearchableTop(text: text, prompt: Text(prompt))
    }

    @ViewBuilder
    func musicNativeSearchable<S: StringProtocol>(text: Binding<String>, prompt: S) -> some View {
        musicNativeSearchable(text: text, prompt: Text(prompt))
    }

    @ViewBuilder
    func musicNativeSearchableTop<S: StringProtocol>(text: Binding<String>, prompt: S) -> some View {
        musicNativeSearchableTop(text: text, prompt: Text(prompt))
    }
}

extension View {
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

    /// Native liquid-glass tab bar + Now Playing bottom accessory (iOS 26.1+).
    /// The modifier chain is always applied — `isEnabled` only gates the accessory visibility.
    /// Wrapping in an `if/else` changes the view identity when `isEnabled` flips, which would
    /// tear down the entire `TabView` subtree (losing pushed navigation state and triggering
    /// SwiftUI's "misplaced navigationDestination" warning the moment playback begins).
    @ViewBuilder
    func musicNativeTabChrome<Accessory: View>(
        isEnabled: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        #if os(iOS)
        self
            .tabViewBottomAccessory(isEnabled: isEnabled, content: accessory)
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

/// Liquid Glass segmented pill — selected segment is a darker inset capsule (Discover / Library, Jellyfin / Navidrome, …).
struct MusicGlassSegmentPillBar<Selection: Hashable>: View {
    let options: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.smooth(duration: 0.22)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == option ? Color.primary : MusicDesign.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selection == option {
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.28))
                                    .matchedGeometryEffect(id: "pillSelection", in: ns)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .musicGlassEffect(in: Capsule(style: .continuous))
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
    /// Scroll down past ``slack`` + this before hiding (avoids flicker near the threshold).
    private let hideHysteresis: CGFloat = 20
    /// Scroll up to ``slack`` − this before showing again (wider dead band than hide).
    private let showHysteresis: CGFloat = 28

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
            if anchorContentOffsetY == nil {
                anchorContentOffsetY = y
            }
            let anchor = anchorContentOffsetY ?? y
            // Rubber-band overscroll reports y < anchor; clamp so the header stays stable at the top.
            let delta = max(0, y - anchor)
            let expandThreshold = max(0, slack - showHysteresis)
            let collapseThreshold = slack + hideHysteresis

            if delta < expandThreshold {
                guard !showFloatingHeader else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    showFloatingHeader = true
                }
            } else if delta > collapseThreshold {
                guard showFloatingHeader else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFloatingHeader = false
                }
            }
        }
    }
}

extension View {
    /// Top inset for Home / New / Radio / Library large titles. Avoid animating the ``ScrollView`` itself —
    /// that fights `safeAreaInset` layout and causes jitter when rubber-banding at the top.
    func musicTabFloatingHeaderInset<Header: View>(
        isVisible: Bool,
        @ViewBuilder header: () -> Header,
    ) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            // Keep the header (and profile avatar) mounted — conditional removal was
            // re-running AccountProfileAvatarView's load task on every scroll-to-top.
            header()
                .opacity(isVisible ? 1 : 0)
                .frame(maxHeight: isVisible ? nil : 0, alignment: .top)
                .clipped()
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
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

// MARK: - Chevron navigation rows (Library, Genres, Playlists, Search, …)

/// Shared insets for list rows with a trailing `chevron.right` (divider stops at the chevron’s right edge).
enum MusicChevronRowMetrics {
    static let leadingPadding: CGFloat = 20
    static let rowTrailingPadding: CGFloat = 17
    static let chevronTrailingPadding: CGFloat = 9
    /// Row trailing pad + chevron’s own trailing pad (see ``LibraryArtistRowLabel``).
    static let dividerTrailingInset: CGFloat = rowTrailingPadding + chevronTrailingPadding

    static let symbolColumnWidth: CGFloat = 28
    /// Divider starts after the leading SF Symbol column (Library hub, Genres, Downloaded hub).
    static let symbolDividerLeading: CGFloat = leadingPadding + symbolColumnWidth + 8

    static func artworkDividerLeading(side: CGFloat, spacing: CGFloat) -> CGFloat {
        leadingPadding + side + spacing
    }

    static let playlistArtworkDividerLeading = artworkDividerLeading(side: 52, spacing: 16)
    static let artistArtworkDividerLeading = artworkDividerLeading(side: 52, spacing: 14)
}

/// Trailing disclosure chevron for navigation rows — keep padding aligned with ``MusicChevronRowMetrics``.
struct MusicNavigationChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(white: 0.35))
            .padding(.trailing, MusicChevronRowMetrics.chevronTrailingPadding)
    }
}

extension View {
    /// Standard horizontal insets for rows that use ``MusicNavigationChevron``.
    func musicChevronRowPadding() -> some View {
        padding(.leading, MusicChevronRowMetrics.leadingPadding)
            .padding(.trailing, MusicChevronRowMetrics.rowTrailingPadding)
    }
}

/// Hairline under navigation rows — inset so it does not run past the chevron’s right edge.
struct MusicChevronRowDivider: View {
    enum Kind {
        case symbolIcon
        case playlistArtwork
        case artistArtwork
        case custom(leading: CGFloat, trailing: CGFloat = MusicChevronRowMetrics.dividerTrailingInset)
    }

    let kind: Kind
    var color: Color = MusicDesign.separator

    private var leadingInset: CGFloat {
        switch kind {
        case .symbolIcon: return MusicChevronRowMetrics.symbolDividerLeading
        case .playlistArtwork: return MusicChevronRowMetrics.playlistArtworkDividerLeading
        case .artistArtwork: return MusicChevronRowMetrics.artistArtworkDividerLeading
        case .custom(let leading, _): return leading
        }
    }

    private var trailingInset: CGFloat {
        switch kind {
        case .custom(_, let trailing): return trailing
        default: return MusicChevronRowMetrics.dividerTrailingInset
        }
    }

    var body: some View {
        MusicInsetHairlineDivider(
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            color: color,
        )
    }
}

/// Inset horizontal rule (library songs, chevron rows, album tracklists).
struct MusicInsetHairlineDivider: View {
    var leadingInset: CGFloat
    var trailingInset: CGFloat
    var color: Color = MusicDesign.separator

    private var hairlineHeight: CGFloat {
        #if os(iOS)
        max(1.0 / UIScreen.main.scale, 1.0 / 3.0)
        #elseif os(macOS)
        max(1.0 / (NSScreen.main?.backingScaleFactor ?? 2), 1.0 / 3.0)
        #else
        1.0 / 3.0
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            Rectangle()
                .fill(color)
                .frame(maxWidth: .infinity)
                .frame(height: hairlineHeight)
        }
        .padding(.trailing, trailingInset)
        .frame(height: hairlineHeight)
    }
}

extension View {
    /// Bottom hairline for chevron navigation rows; omit on the last row in a section.
    @ViewBuilder
    func musicChevronRowDivider(_ kind: MusicChevronRowDivider.Kind, shows: Bool) -> some View {
        listRowSeparator(.hidden)
            .overlay(alignment: .bottom) {
                if shows {
                    MusicChevronRowDivider(kind: kind)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Library list chrome (Songs, playlists, favorites, downloads, artist detail)

/// Filter / sort / overflow glyph in a library navigation bar — always black or white, never accent.
struct MusicLibraryToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
    }
}

extension View {
    /// Library list screens: toolbar buttons use primary (black/white), not ``MusicDesign/accent``.
    @ViewBuilder
    func musicLibraryToolbarMonochromeControls() -> some View {
        tint(Color.primary)
    }
}

/// Vertical A–Z index strip (Apple Music–style) for grouped library lists.
struct MusicAlphabetIndexScrubber: View {
    let letters: [String]
    var selectedLetter: String?
    /// Height of the visible track the letters are centered in (viewport minus safe area).
    var trackHeight: CGFloat
    var onSelect: (String) -> Void
    var onScrubEnd: (() -> Void)?

    private let rowHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let containerHeight = geo.size.height

            VStack(spacing: 1) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 11, weight: selectedLetter == letter ? .bold : .semibold))
                        .foregroundStyle(
                            selectedLetter == letter
                                ? MusicDesign.accent
                                : MusicDesign.accent.opacity(0.88)
                        )
                        .frame(width: 18, height: rowHeight)
                }
            }
            .frame(width: 18, height: trackHeight, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard let letter = letter(
                            at: value.location.y,
                            containerHeight: containerHeight,
                            count: letters.count
                        ) else {
                            return
                        }
                        onSelect(letter)
                    }
                    .onEnded { _ in onScrubEnd?() }
            )
        }
        .animation(nil, value: selectedLetter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Alphabetical index")
    }

    private func letter(at y: CGFloat, containerHeight: CGFloat, count: Int) -> String? {
        guard count > 0, containerHeight > 0 else { return nil }
        let stackHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1))
        let originY = (containerHeight - stackHeight) / 2
        let relativeY = y - originY
        guard relativeY >= 0, relativeY < stackHeight else { return nil }
        let slot = rowHeight + 1
        let index = min(count - 1, max(0, Int(relativeY / slot)))
        return letters[index]
    }
}

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

/// Request pill / menu label — tighter icon–title gap than stock ``Label``.
struct RequestActionLabel: View {
    var font: Font = .body

    var body: some View {
        HStack(spacing: MusicDesign.requestActionLabelSpacing) {
            Image(systemName: "arrow.down.circle.fill")
            Text("Request")
        }
        .font(font)
    }
}

/// Play + Shuffle capsules — monochrome hero styling (``FavoritePlaylistView`` search pills).
struct AlbumHeroPlayShuffleCluster: View {
    let palette: ArtworkDynamicGradient.BackdropPalette
    var isDisabled: Bool = false
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            heroCapsuleButton(
                systemImage: "shuffle",
                title: "Shuffle",
                action: onShuffle
            )
            heroCapsuleButton(
                systemImage: "play.fill",
                title: "Play",
                action: onPlay
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func heroCapsuleButton(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MusicDesign.libraryPlayShuffleLabelSpacing) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(palette.heroPlayCapsuleForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule().fill(palette.heroPlayCapsuleBackground))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
                HStack(spacing: MusicDesign.libraryPlayShuffleLabelSpacing) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(MusicDesign.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule(style: .continuous).fill(MusicDesign.chromeCapsuleFill))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            Button(action: onShuffle) {
                HStack(spacing: MusicDesign.libraryPlayShuffleLabelSpacing) {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
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

// MARK: - Library hub grids (pinned, recently added, recently downloaded)

enum LibraryHubGridCellStyle {
    /// 3-up pins under **Library** — centered labels, full-width square art (original hub look).
    case pinned
    /// 2-up shelves — leading title + artist with fixed label blocks for row alignment.
    case shelf
}

/// Library grid tile. ``AlbumArtworkView`` is already 1:1; do not wrap it in another aspect ratio.
struct LibraryHubGridCell<Artwork: View>: View {
    let title: String
    var subtitle: String? = nil
    var style: LibraryHubGridCellStyle = .shelf
    @ViewBuilder var artwork: () -> Artwork

    private var stackAlignment: HorizontalAlignment {
        style == .pinned ? .center : .leading
    }

    private var textAlignment: TextAlignment {
        style == .pinned ? .center : .leading
    }

    private var titleFrameAlignment: Alignment {
        style == .pinned ? .top : .topLeading
    }

    var body: some View {
        VStack(alignment: stackAlignment, spacing: MusicDesign.libraryHubGridLabelSpacing) {
            artwork()
                .frame(maxWidth: .infinity)

            if style == .shelf {
                shelfLabelBlock
            } else {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: .infinity, alignment: titleFrameAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Title + subtitle sit directly adjacent; reserved height applies to the combined block
    /// so short titles don't leave a gap above the artist line.
    private var shelfLabelBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                        .lineLimit(1)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .topLeading)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: MusicDesign.libraryHubGridLabelBlockMinHeight,
            alignment: .topLeading
        )
    }
}

extension MusicDesign {
    /// Top-aligned flexible columns for library hub grids (2-up or 3-up).
    static func libraryHubGridColumns(count: Int, spacing: CGFloat = 12) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: count
        )
    }
}

// MARK: - Transient toast (snackbar)

/// Bottom-anchored brief notification ("Added to Queue", etc.). Driven by
/// ``AppModel/transientToast``; auto-dismisses on a timer set inside
/// ``AppModel/showTransientToast``. Render once at the app root.
struct MusicTransientToastChrome: ViewModifier {
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = app.transientToast {
                HStack(spacing: 10) {
                    if let artworkURL = toast.artworkURL {
                        AlbumArtworkView(url: artworkURL, cornerRadius: 5)
                            .frame(width: 34, height: 34)
                    }
                    VStack(alignment: toast.subtitle == nil ? .center : .leading, spacing: 1) {
                        Text(toast.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if let subtitle = toast.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, toast.artworkURL == nil ? 18 : 12)
                .padding(.vertical, toast.subtitle == nil ? 12 : 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.85))
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 110)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(toast.subtitle.map { "\(toast.title), \($0)" } ?? toast.title)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: app.transientToast)
    }
}

extension View {
    /// Renders the app-wide transient toast above this view (used at the root).
    func musicTransientToastChrome() -> some View {
        modifier(MusicTransientToastChrome())
    }
}
