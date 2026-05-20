import SwiftUI
#if canImport(UIKit) && os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Library song ⋯ sheet styled like Apple Music (palette strip + inset-divided list).
struct SongOverflowPanel: View {
    @EnvironmentObject private var app: AppModel

    let track: Track
    let onDismiss: () -> Void
    let onDownload: () -> Void
    let onFavorite: () -> Void
    let onPlayNext: () -> Void
    let onGoToAlbum: () -> Void
    var onDeleteLibrary: () -> Void = {}
    var onAddToPlaylist: (() -> Void)? = nil

    private let rowHPadding: CGFloat = 16
    private let iconColumnWidth: CGFloat = 24
    private let iconTextGap: CGFloat = 12
    private let panelCorner: CGFloat = 14
    private let panelWidth: CGFloat = 250

    private var albumLine: String {
        let t = track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Album" : t
    }

    private var isFavorite: Bool {
        app.favoriteTrackIds.contains(track.id)
    }

    private var isOfflineCached: Bool {
        app.offline.downloadedTrackIds.contains(track.id)
    }

    private var isInLibrary: Bool {
        app.isSongInLibrary(track.id)
    }

    private var showsDownloadInPalette: Bool {
        isInLibrary && !isOfflineCached
    }

    private var showsRemoveDownloadRow: Bool {
        isInLibrary && isOfflineCached
    }

    var body: some View {
        VStack(spacing: 0) {
            paletteStrip
            separator
            listPlaceholderRow(icon: "pin", title: "Pin Song")
            if let onAddToPlaylist {
                listActionRow(icon: "rectangle.stack.badge.plus", title: "Add to Playlist") {
                    onAddToPlaylist()
                    onDismiss()
                }
            } else {
                listPlaceholderRow(icon: "rectangle.stack.badge.plus", title: "Add to Playlist")
            }
            listDivider
            listActionRow(icon: "text.line.first.and.arrowtriangle.forward", title: "Play Next") {
                onPlayNext(); onDismiss()
            }
            listDivider
            goToAlbumRow
            listDivider
            listPlaceholderRow(icon: "hand.thumbsdown", title: "Suggest Less")
            if showsRemoveDownloadRow {
                listDivider
                listActionRow(icon: "arrow.down.circle.dotted", title: "Remove Download") {
                    try? app.offline.remove(trackId: track.id)
                    onDismiss()
                }
            }
            listDivider
            deleteRow
        }
        .frame(width: panelWidth)
        .panelChrome(cornerRadius: panelCorner)
    }

    // MARK: - Palette strip

    @ViewBuilder
    private var paletteStrip: some View {
        HStack(spacing: 0) {
            if showsDownloadInPalette {
                Button(action: onDownload) {
                    paletteColumnLabel(icon: "arrow.down.circle", title: "Download")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            paletteColumn(icon: isFavorite ? "star.fill" : "star", title: "Favorite") { onFavorite() }
            ShareLink(item: "\(track.title) — \(track.artist)") {
                paletteColumnLabel(icon: "square.and.arrow.up", title: "Share")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func paletteColumn(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { paletteColumnLabel(icon: icon, title: title) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
    }

    private func paletteColumnLabel(icon: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Dividers

    private var separator: some View {
        Rectangle()
            .fill(MusicDesign.separator.opacity(0.55))
            .frame(height: hairline)
    }

    private var listDivider: some View {
        Rectangle()
            .fill(MusicDesign.separator.opacity(0.55))
            .frame(height: hairline)
    }

    private var hairline: CGFloat {
#if os(iOS)
        1 / max(UIScreen.main.scale, 2)
#else
        1
#endif
    }

    // MARK: - List rows

    private func listPlaceholderRow(icon: String, title: String) -> some View {
        HStack(alignment: .center, spacing: iconTextGap) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: iconColumnWidth, alignment: .center)
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, rowHPadding)
        .padding(.vertical, 13)
    }

    private func listActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: iconTextGap) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: iconColumnWidth, alignment: .center)
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, rowHPadding)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var goToAlbumRow: some View {
        Button {
            onGoToAlbum(); onDismiss()
        } label: {
            HStack(alignment: .center, spacing: iconTextGap) {
                Image(systemName: "music.note.square")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: iconColumnWidth, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go to Album")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.primary)
                    Text(albumLine)
                        .font(.footnote)
                        .foregroundStyle(MusicDesign.secondaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, rowHPadding)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deleteRow: some View {
        Button(role: .destructive) {
            guard app.canDeleteFromLibrary else { return }
            onDeleteLibrary()
            onDismiss()
        } label: {
            HStack(spacing: iconTextGap) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: iconColumnWidth, alignment: .center)
                Text("Delete from Library")
                    .font(.system(size: 17, weight: .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(app.canDeleteFromLibrary ? MusicDesign.destructiveAction : MusicDesign.secondaryLabel.opacity(0.45))
            .padding(.horizontal, rowHPadding)
            .padding(.vertical, 13)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!app.canDeleteFromLibrary)
    }
}

// MARK: - Downtify variant

struct DowntifySongOverflowPanel: View {
    let song: DowntifySong
    let isDownloading: Bool
    let onDownload: () -> Void
    let onDismiss: () -> Void

    private let rowHPadding: CGFloat = 16
    private let iconColumnWidth: CGFloat = 24
    private let iconTextGap: CGFloat = 12
    private let panelCorner: CGFloat = 14
    private let panelWidth: CGFloat = 250

    private var albumLine: String {
        let t = song.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Album" : t
    }

    var body: some View {
        VStack(spacing: 0) {
            paletteStrip
            separator
            listPlaceholderRow(icon: "pin", title: "Pin Song")
            listPlaceholderRow(icon: "rectangle.stack.badge.plus", title: "Add to Playlist")
            listDivider
            listActionRow(icon: "arrow.down.circle.fill", title: "Request") {
                onDownload(); onDismiss()
            }
            listDivider
            albumRow
            listDivider
            listPlaceholderRow(icon: "hand.thumbsdown", title: "Suggest Less")
        }
        .frame(width: panelWidth)
        .panelChrome(cornerRadius: panelCorner)
    }

    // MARK: - Palette strip

    private var paletteStrip: some View {
        HStack(spacing: 0) {
            Button(action: { onDownload(); onDismiss() }) {
                paletteColumnLabel(icon: "arrow.down.circle", title: "Request")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(isDownloading)

            paletteColumnLabel(icon: "star", title: "Favorite")
                .frame(maxWidth: .infinity)
                .opacity(0.35)

            ShareLink(item: "\(song.name) — \(song.artists.joined(separator: ", "))") {
                paletteColumnLabel(icon: "square.and.arrow.up", title: "Share")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func paletteColumnLabel(icon: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Dividers

    private var separator: some View {
        Rectangle().fill(MusicDesign.separator.opacity(0.55)).frame(height: hairline)
    }

    private var listDivider: some View {
        Rectangle().fill(MusicDesign.separator.opacity(0.55)).frame(height: hairline)
    }

    private var hairline: CGFloat {
#if os(iOS)
        1 / max(UIScreen.main.scale, 2)
#else
        1
#endif
    }

    // MARK: - List rows

    private func listPlaceholderRow(icon: String, title: String) -> some View {
        HStack(alignment: .center, spacing: iconTextGap) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: iconColumnWidth, alignment: .center)
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, rowHPadding)
        .padding(.vertical, 13)
    }

    private func listActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: iconTextGap) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: iconColumnWidth, alignment: .center)
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, rowHPadding)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var albumRow: some View {
        HStack(alignment: .center, spacing: iconTextGap) {
            Image(systemName: "music.note.square")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: iconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Go to Album")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)
                Text(albumLine)
                    .font(.footnote)
                    .foregroundStyle(MusicDesign.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, rowHPadding)
        .padding(.vertical, 13)
    }
}

// MARK: - Chrome (SongOverflowPanel & DowntifySongOverflowPanel)

private extension View {
    @ViewBuilder
    func panelChrome(cornerRadius: CGFloat) -> some View {
        self.musicGlassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
