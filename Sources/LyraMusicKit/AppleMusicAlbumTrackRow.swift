import SwiftUI
#if canImport(UIKit) && os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Visual phases for the trailing row glyph. Combines library-membership state with
/// offline-cache state into one four-way switch so each row only renders one chip.
///
/// Apple-Music-style mapping (per locked design):
/// - ``addToLibrary``    — server has the song, user hasn't added it → `plus`
/// - ``notCached``       — in library, not yet on this device → `icloud.and.arrow.down`
/// - ``downloading*``    — fetching offline copy now
/// - ``cached``          — in library + on device → filled "downloaded" glyph
/// - ``missing``         — in library but server no longer resolves it → greyed exclamation
/// - ``request``         — neither in library nor in server (off-server discovery rows) → `icloud.and.arrow.down`
enum TrackOfflineIndicatorPhase: Equatable {
    case addToLibrary
    case notCached
    case downloadingDeterminate(Double)
    case downloadingIndeterminate
    case cached
    case missing
    case request

    /// Convenience initializer that derives the phase from the four orthogonal inputs.
    /// `isInLibrary` / `isInServerCatalog` default to `true` to preserve legacy behavior
    /// at call sites that haven't been threaded through yet.
    init(
        offlineDownload: OfflineDownloadUIState?,
        isOfflineCached: Bool,
        isInLibrary: Bool = true,
        isInServerCatalog: Bool = true,
    ) {
        if !isInServerCatalog {
            self = isInLibrary ? .missing : .request
            return
        }
        if !isInLibrary {
            self = .addToLibrary
            return
        }
        if let s = offlineDownload {
            switch s {
            case .indeterminate:
                self = .downloadingIndeterminate
            case .progress(let fraction):
                self = .downloadingDeterminate(fraction)
            }
            return
        }
        self = isOfflineCached ? .cached : .notCached
    }

    var isDownloading: Bool {
        switch self {
        case .downloadingDeterminate, .downloadingIndeterminate:
            return true
        case .addToLibrary, .notCached, .cached, .missing, .request:
            return false
        }
    }
}

/// Trailing column glyph matching Apple Music offline affordances (dot / progress + stop / downloaded arrow).
struct TrackOfflineDownloadIndicator: View {
    let phase: TrackOfflineIndicatorPhase
    var onCancelDownload: (() -> Void)?
    /// Tapping the “not cached” dot starts a library download (same as menu Download).
    var onTapStartDownload: (() -> Void)?
    /// Tapping the "Add to Library" plus glyph adds the song to the user's library.
    var onAddToLibrary: (() -> Void)?
    /// Tapping the "Request" cloud glyph forwards to Downtify (off-server discovery rows).
    var onRequest: (() -> Void)?
    /// When `nil`, resolves from ``listSurface(colorScheme:)`` (library lists). Album rows pass the hero palette.
    var backdropPalette: ArtworkDynamicGradient.BackdropPalette? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var chrome: ArtworkDynamicGradient.BackdropPalette {
        backdropPalette ?? .listSurface(colorScheme: colorScheme)
    }

    private let ringDiameter: CGFloat = 17
    private let ringLineWidth: CGFloat = 1.35
    private let slot: CGFloat = 22

    var body: some View {
        ZStack {
            switch phase {
            case .addToLibrary:
                addToLibraryGlyph
            case .notCached:
                notCachedRing
            case .downloadingDeterminate(let fraction):
                downloadingRing(fraction: min(1, max(0, fraction)))
            case .downloadingIndeterminate:
                indeterminateRing
            case .cached:
                cachedGlyph
            case .missing:
                missingGlyph
            case .request:
                requestGlyph
            }
        }
        .frame(width: slot, height: slot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(interactionTraits)
    }

    private var interactionTraits: AccessibilityTraits {
        var traits = AccessibilityTraits()
        if phase == .notCached, onTapStartDownload != nil {
            traits.formUnion(.isButton)
        }
        if phase == .addToLibrary, onAddToLibrary != nil {
            traits.formUnion(.isButton)
        }
        if phase == .request, onRequest != nil {
            traits.formUnion(.isButton)
        }
        if phase.isDownloading, onCancelDownload != nil {
            traits.formUnion(.isButton)
        }
        return traits
    }

    private var accessibilityLabel: String {
        switch phase {
        case .addToLibrary:
            return "Add to library"
        case .notCached:
            return onTapStartDownload != nil ? "Tap to download" : "Not downloaded"
        case .downloadingDeterminate(let f):
            return "Downloading, \(Int((min(1, max(0, f)) * 100).rounded())) percent"
        case .downloadingIndeterminate:
            return "Downloading"
        case .cached:
            return "Downloaded"
        case .missing:
            return "Missing from server"
        case .request:
            return "Request"
        }
    }

    /// Thin ring + subtle center dot (tracks available but not on device).
    @ViewBuilder
    private var notCachedRing: some View {
        if let onTapStartDownload {
            Button(action: onTapStartDownload) {
                notCachedDiskVisual
            }
            .buttonStyle(.plain)
        } else {
            notCachedDiskVisual
        }
    }

    /// In library, available to download — cloud + arrow (Apple Music library download affordance).
    private var notCachedDiskVisual: some View {
        Image(systemName: "icloud.and.arrow.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(chrome.trackOfflineActionPrimary)
    }

    /// Plus glyph — adds the song (and its album as a unit) to the user's library.
    @ViewBuilder
    private var addToLibraryGlyph: some View {
        if let onAddToLibrary {
            Button(action: onAddToLibrary) {
                addToLibraryVisual
            }
            .buttonStyle(.plain)
        } else {
            addToLibraryVisual
        }
    }

    private var addToLibraryVisual: some View {
        Image(systemName: "plus")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(chrome.trackOfflineActionPrimary)
    }

    /// Greyed exclamation — server lost the file but the user's library still references it.
    /// Read-only per the locked design.
    private var missingGlyph: some View {
        Image(systemName: "exclamationmark.circle")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(chrome.trackOfflineActionSecondary.opacity(0.5))
    }

    /// Cloud + arrow — Request the song via Downtify when it's not on the server at all.
    @ViewBuilder
    private var requestGlyph: some View {
        if let onRequest {
            Button(action: onRequest) {
                requestVisual
            }
            .buttonStyle(.plain)
        } else {
            requestVisual
        }
    }

    private var requestVisual: some View {
        Image(systemName: "icloud.and.arrow.down")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(chrome.trackOfflineActionSecondary)
    }

    /// Filled circle + arrow (on device).
    private var cachedGlyph: some View {
        ZStack {
            Circle()
                .fill(chrome.trackOfflineCachedDiskFill)
            Circle()
                .stroke(chrome.trackOfflineRingTrack, lineWidth: 1)
                .frame(width: ringDiameter, height: ringDiameter)
            Image(systemName: "arrow.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(chrome.trackOfflineActionPrimary)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    private func downloadingRing(fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(chrome.trackOfflineRingTrack, lineWidth: ringLineWidth)
                .frame(width: ringDiameter, height: ringDiameter)

            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(
                    chrome.trackOfflineProgressStroke,
                    style: StrokeStyle(lineWidth: ringLineWidth + 0.35, lineCap: .round)
                )
                .frame(width: ringDiameter, height: ringDiameter)
                .rotationEffect(.degrees(-90))

            stopControl
        }
    }

    private var indeterminateRing: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 1.15)) / 1.15 * 360
            ZStack {
                Circle()
                    .stroke(chrome.trackOfflineRingTrack, lineWidth: ringLineWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(
                        chrome.trackOfflineProgressStroke,
                        style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round)
                    )
                    .frame(width: ringDiameter, height: ringDiameter)
                    .rotationEffect(.degrees(angle))

                stopControl
            }
        }
    }

    /// Apple Music uses a small square “stop” while a download is active.
    @ViewBuilder
    private var stopControl: some View {
        let stopFill = chrome.trackOfflineProgressStroke
        if let onCancelDownload {
            Button(action: onCancelDownload) {
                ZStack {
                    Color.clear
                        .frame(width: slot, height: slot)
                        .contentShape(Rectangle())
                    RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                        .fill(stopFill.opacity(0.88))
                        .frame(width: 4.2, height: 4.2)
                }
            }
            .buttonStyle(.plain)
        } else {
            RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                .fill(stopFill.opacity(0.88))
                .frame(width: 4.2, height: 4.2)
        }
    }
}

/// Leading metrics for the track index + optional star.
private enum AlbumTrackIndexColumn {
    /// Fixed slot so favorited rows don’t shift the number or title vs other tracks.
    static let starSlotWidth: CGFloat = 12
    static let starToNumberSpacing: CGFloat = 4
    static let numberWidth: CGFloat = 22
    static var totalWidth: CGFloat { starSlotWidth + starToNumberSpacing + numberWidth }
}

/// Compact pill behind album track swipe icons (width > height → capsule, not a circle).
enum AlbumTrackSwipeChipMetrics {
    static let width: CGFloat = 40
    static let height: CGFloat = 22
    static let iconFont: Font = .caption2.weight(.semibold)
    static let playNextTint: Color = .indigo
    static let downloadTint: Color = .blue
    static let deleteTint: Color = .red
}

/// Shared album tracklist layout — row padding, spacing, and divider alignment with title text.
/// Exposed module-wide so list-based hosts (e.g. ``ServerPlaylistDetailView``) can align row separators.
enum AlbumTrackRowLayout {
    /// Inset of each track list row from the screen edge.
    static let listHorizontalInset: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    /// Between track # and title — same as ★–# spacing for even rhythm (must match outer ``HStack`` spacing).
    static let indexToTitleSpacing: CGFloat = AlbumTrackIndexColumn.starToNumberSpacing
    /// Per-track vertical padding — balanced density (not cramped, not airy).
    static let verticalRowPadding: CGFloat = 8
    static let rowMinHeight: CGFloat = 40
    static let titleSubtitleSpacing: CGFloat = 2
    /// Screen-edge → title leading; dividers start here (past ★ + track number).
    static var titleLeadingFromScreenEdge: CGFloat {
        horizontalPadding + AlbumTrackIndexColumn.totalWidth + indexToTitleSpacing
    }
}

/// Track row matching Apple Music album pages (optional ★ beside index + title stack + trailing offline glyph + ⋯ menu).
struct AppleMusicAlbumTrackRow<MenuItems: View>: View {
    @EnvironmentObject private var app: AppModel

    let index: Int
    let title: String
    let subtitle: String?
    /// Tiny star in a fixed leading slot — layout matches unfavorited rows (blank slot when no star).
    var isFavorite: Bool = false
    /// Live HTTP cache progress for this row (library offline download).
    var offlineDownload: OfflineDownloadUIState? = nil
    /// Local cache file exists for this track.
    var isOfflineCached: Bool = false
    /// `true` if the song is in the user's Lyra library (magic-playlist membership).
    /// Drives the row chip into Add-to-Library vs Download states. Defaults to `true`
    /// so legacy call sites in library-only views keep their current behavior.
    var isInLibrary: Bool = true
    /// Tap stop square while downloading — cooperatively cancels ``OfflineDownloadManager.cache``.
    var onCancelOfflineDownload: (() -> Void)? = nil
    /// Tap hollow dot to start the same download as the row Download menu action.
    var onTapStartOfflineDownload: (() -> Void)? = nil
    /// Tap the plus chip — adds the song's album to the user's Lyra library.
    var onTapAddToLibrary: (() -> Void)? = nil
    /// Hide the offline column (e.g. non-library browse placeholders).
    var showsOfflineIndicator: Bool = true
    /// Album page adaptive chrome (index / subtitle / ⋯ — not fixed grey ``MusicDesign.secondaryLabel``).
    var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback
    /// When set, enables native leading/trailing swipe actions (requires parent `List`).
    var onPlayNext: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    /// User-level remove from library (trash swipe).
    var onRemoveFromLibrary: (() -> Void)? = nil
    /// Hairline under the row (drawn inside the row, not a separate list cell).
    var showsBottomDivider: Bool = false

    let onRowTap: () -> Void
    @ViewBuilder let menuContent: () -> MenuItems

    private var offlinePhase: TrackOfflineIndicatorPhase {
        TrackOfflineIndicatorPhase(
            offlineDownload: offlineDownload,
            isOfflineCached: isOfflineCached,
            isInLibrary: isInLibrary,
        )
    }

    /// In library but not on device — hide cloud; download via overflow menu.
    private var showsTrailingOfflineGlyph: Bool {
        guard showsOfflineIndicator else { return false }
        if isInLibrary, offlinePhase == .notCached { return false }
        return true
    }

    private var itemSize: SongListItemSize { app.songListItemSize }

    private var showsDownloadSwipeAction: Bool {
        isInLibrary
            && !isOfflineCached
            && offlineDownload == nil
            && onDownload != nil
    }

    private var hasSubtitle: Bool {
        guard let subtitle else { return false }
        return !subtitle.isEmpty
    }

    private var rowVerticalAlignment: VerticalAlignment {
        hasSubtitle ? .top : .center
    }

    var body: some View {
        Group {
            if let onPlayNext {
                trackRowContent
                    .librarySongSwipeActions(
                        showsDownload: showsDownloadSwipeAction,
                        onPlayNext: onPlayNext,
                        onDownload: onDownload,
                        onRemoveFromLibrary: onRemoveFromLibrary,
                        chipMetrics: .albumTrack
                    )
            } else {
                trackRowContent
            }
        }
    }

    private var trackRowContent: some View {
        trackRowBody
            .frame(minHeight: AlbumTrackRowLayout.rowMinHeight)
            .background(alignment: .bottom) {
                if showsBottomDivider {
                    AppleMusicAlbumTrackDivider(palette: backdropPalette)
                        .allowsHitTesting(false)
                }
            }
    }

    private var trackRowBody: some View {
        HStack(alignment: rowVerticalAlignment, spacing: 6) {
            Button(action: onRowTap) {
                HStack(alignment: rowVerticalAlignment, spacing: AlbumTrackRowLayout.indexToTitleSpacing) {
                    HStack(alignment: rowVerticalAlignment, spacing: AlbumTrackIndexColumn.starToNumberSpacing) {
                        Color.clear
                            .frame(width: AlbumTrackIndexColumn.starSlotWidth)
                            .overlay(alignment: hasSubtitle ? .topLeading : .center) {
                                if isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(backdropPalette.heroChromePrimary)
                                        .padding(.top, hasSubtitle ? 4 : 0)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }

                        Text("\(index)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(backdropPalette.heroChromeSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: AlbumTrackIndexColumn.numberWidth, alignment: .leading)
                    }
                    .frame(width: AlbumTrackIndexColumn.totalWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: AlbumTrackRowLayout.titleSubtitleSpacing) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(backdropPalette.heroChromePrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                        if hasSubtitle, let subtitle {
                            Text(subtitle)
                                .font(itemSize.albumSubtitleFont)
                                .foregroundStyle(backdropPalette.heroChromeSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsTrailingOfflineGlyph {
                TrackOfflineDownloadIndicator(
                    phase: offlinePhase,
                    onCancelDownload: offlinePhase.isDownloading ? onCancelOfflineDownload : nil,
                    onTapStartDownload: nil,
                    onAddToLibrary: offlinePhase == .addToLibrary ? onTapAddToLibrary : nil,
                    backdropPalette: backdropPalette,
                )
            }

            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, AlbumTrackRowLayout.horizontalPadding)
        .padding(.vertical, AlbumTrackRowLayout.verticalRowPadding)
    }
}

/// Compact horizontal progress under a title (library song list).
struct TrackDownloadProgressStrip: View {
    let state: OfflineDownloadUIState
    var backdropPalette: ArtworkDynamicGradient.BackdropPalette? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var chrome: ArtworkDynamicGradient.BackdropPalette {
        backdropPalette ?? .listSurface(colorScheme: colorScheme)
    }

    var body: some View {
        switch state {
        case .indeterminate:
            ProgressView()
                .tint(chrome.trackOfflineProgressStroke)
                .scaleEffect(x: 1, y: 0.72, anchor: .center)
                .padding(.top, 2)
        case .progress(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: min(1, fraction))
                    .tint(chrome.trackOfflineProgressStroke)
                Text("\(Int((min(1, fraction) * 100).rounded()))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(chrome.trackOfflineActionSecondary)
            }
            .padding(.top, 2)
        }
    }
}

/// Hairline between hero controls and track list, and between rows — aligns with title text (past ★ + index), same thickness throughout.
struct AppleMusicAlbumTrackDivider: View {
    let palette: ArtworkDynamicGradient.BackdropPalette

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
            Color.clear.frame(width: AlbumTrackRowLayout.titleLeadingFromScreenEdge)
            Rectangle()
                .fill(palette.heroTracklistSeparator)
                .frame(maxWidth: .infinity)
                .frame(height: hairlineHeight)
        }
        .padding(.trailing, AlbumTrackRowLayout.horizontalPadding)
        .frame(height: hairlineHeight)
    }
}
