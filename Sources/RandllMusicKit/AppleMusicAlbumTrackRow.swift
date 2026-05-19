import SwiftUI
#if canImport(UIKit) && os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Visual phases for the trailing offline glyph (Apple Music–style ring / dot / arrow).
enum TrackOfflineIndicatorPhase: Equatable {
    /// In library, not stored for offline — hollow ring + centered dot.
    case notCached
    /// Known byte progress (0…1).
    case downloadingDeterminate(Double)
    /// Length unknown — spinning arc segment.
    case downloadingIndeterminate
    /// Cached locally — filled mist circle + arrow.
    case cached

    init(offlineDownload: OfflineDownloadUIState?, isOfflineCached: Bool) {
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
        case .notCached, .cached:
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

    @Environment(\.colorScheme) private var colorScheme

    private let ringDiameter: CGFloat = 17
    private let ringLineWidth: CGFloat = 1.35
    private let slot: CGFloat = 22

    var body: some View {
        ZStack {
            switch phase {
            case .notCached:
                notCachedRing
            case .downloadingDeterminate(let fraction):
                downloadingRing(fraction: min(1, max(0, fraction)))
            case .downloadingIndeterminate:
                indeterminateRing
            case .cached:
                cachedGlyph
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
        if phase.isDownloading, onCancelDownload != nil {
            traits.formUnion(.isButton)
        }
        return traits
    }

    private var accessibilityLabel: String {
        switch phase {
        case .notCached:
            return onTapStartDownload != nil ? "On server – tap to download" : "On server, not downloaded"
        case .downloadingDeterminate(let f):
            return "Downloading, \(Int((min(1, max(0, f)) * 100).rounded())) percent"
        case .downloadingIndeterminate:
            return "Downloading"
        case .cached:
            return "Downloaded"
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

    private var notCachedDiskVisual: some View {
        Image(systemName: "icloud.and.arrow.down")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(MusicDesign.secondaryLabel)
    }

    /// Filled circle + arrow (on device).
    private var cachedGlyph: some View {
        ZStack {
            Circle()
                .fill(MusicDesign.chromeCapsuleFill)
            Circle()
                .stroke(MusicDesign.separator, lineWidth: 1)
                .frame(width: ringDiameter, height: ringDiameter)
            Image(systemName: "arrow.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(MusicDesign.accent)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    private func downloadingRing(fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(MusicDesign.separator, lineWidth: ringLineWidth)
                .frame(width: ringDiameter, height: ringDiameter)

            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(
                    MusicDesign.accent,
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
                    .stroke(MusicDesign.separator, lineWidth: ringLineWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(
                        MusicDesign.accent,
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
        let stopFill = Color.primary
        if let onCancelDownload {
            Button(action: onCancelDownload) {
                ZStack {
                    Color.clear
                        .frame(width: slot, height: slot)
                        .contentShape(Rectangle())
                    RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                        .fill(stopFill.opacity(colorScheme == .dark ? 0.88 : 0.75))
                        .frame(width: 4.2, height: 4.2)
                }
            }
            .buttonStyle(.plain)
        } else {
            RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                .fill(stopFill.opacity(colorScheme == .dark ? 0.88 : 0.75))
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

/// Shared album tracklist layout — row padding, spacing, and divider alignment with title text.
private enum AlbumTrackRowLayout {
    static let horizontalPadding: CGFloat = 20
    /// Between track # and title — same as ★–# spacing for even rhythm (must match outer ``HStack`` spacing).
    static let indexToTitleSpacing: CGFloat = AlbumTrackIndexColumn.starToNumberSpacing
    static let verticalPadding: CGFloat = 8
    static let titleSubtitleSpacing: CGFloat = 3
    /// Screen-edge → title leading; dividers start here (past ★ + track number).
    static var titleLeadingFromScreenEdge: CGFloat {
        horizontalPadding + AlbumTrackIndexColumn.totalWidth + indexToTitleSpacing
    }
}

/// Track row matching Apple Music album pages (optional ★ beside index + title stack + trailing offline glyph + ⋯ menu).
struct AppleMusicAlbumTrackRow<MenuItems: View>: View {
    let index: Int
    let title: String
    let subtitle: String?
    /// Tiny star in a fixed leading slot — layout matches unfavorited rows (blank slot when no star).
    var isFavorite: Bool = false
    /// Live HTTP cache progress for this row (library offline download).
    var offlineDownload: OfflineDownloadUIState? = nil
    /// Local cache file exists for this track.
    var isOfflineCached: Bool = false
    /// Tap stop square while downloading — cooperatively cancels ``OfflineDownloadManager.cache``.
    var onCancelOfflineDownload: (() -> Void)? = nil
    /// Tap hollow dot to start the same download as the row Download menu action.
    var onTapStartOfflineDownload: (() -> Void)? = nil
    /// Hide the offline column (e.g. non-library browse placeholders).
    var showsOfflineIndicator: Bool = true
    /// Album page adaptive chrome (index / subtitle / ⋯ — not fixed grey ``MusicDesign.secondaryLabel``).
    var backdropPalette: ArtworkDynamicGradient.BackdropPalette = .fallback

    let onRowTap: () -> Void
    @ViewBuilder let menuContent: () -> MenuItems

    private var offlinePhase: TrackOfflineIndicatorPhase {
        TrackOfflineIndicatorPhase(offlineDownload: offlineDownload, isOfflineCached: isOfflineCached)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onRowTap) {
                HStack(alignment: .top, spacing: AlbumTrackRowLayout.indexToTitleSpacing) {
                    HStack(alignment: .top, spacing: AlbumTrackIndexColumn.starToNumberSpacing) {
                        Color.clear
                            .frame(width: AlbumTrackIndexColumn.starSlotWidth)
                            .overlay(alignment: .topLeading) {
                                if isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(backdropPalette.heroChromePrimary)
                                        .padding(.top, 4)
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
                            .padding(.top, 1)
                    }
                    .frame(width: AlbumTrackIndexColumn.totalWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: AlbumTrackRowLayout.titleSubtitleSpacing) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(backdropPalette.heroChromePrimary)
                            .multilineTextAlignment(.leading)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(backdropPalette.heroChromeSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsOfflineIndicator {
                TrackOfflineDownloadIndicator(
                    phase: offlinePhase,
                    onCancelDownload: offlinePhase.isDownloading ? onCancelOfflineDownload : nil,
                    onTapStartDownload: offlinePhase == .notCached ? onTapStartOfflineDownload : nil
                )
                .padding(.top, 1)
            }

            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(backdropPalette.heroChromeSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, AlbumTrackRowLayout.horizontalPadding)
        .padding(.vertical, AlbumTrackRowLayout.verticalPadding)
    }
}

/// Compact horizontal progress under a title (library song list).
struct TrackDownloadProgressStrip: View {
    let state: OfflineDownloadUIState

    var body: some View {
        switch state {
        case .indeterminate:
            ProgressView()
                .tint(MusicDesign.accent)
                .scaleEffect(x: 1, y: 0.72, anchor: .center)
                .padding(.top, 2)
        case .progress(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: min(1, fraction))
                    .tint(MusicDesign.accent)
                Text("\(Int((min(1, fraction) * 100).rounded()))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(MusicDesign.secondaryLabel)
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
    }
}
