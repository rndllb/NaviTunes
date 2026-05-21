import SwiftUI

#if os(iOS)
import UIKit

/// SwiftUI `Menu` often collapses multi-line custom `Button` labels to a single line. `UIMenu` + `UIAction` subtitles match Apple Music.
struct ArtistNowPlayingMenuButton: UIViewRepresentable {
    let artist: String
    let albumSubtitle: String
    let libraryAlbum: AlbumSummary?
    /// When set, artist line follows album hero **luminance handoff** (black/white vs backdrop).
    var heroBackdropPalette: ArtworkDynamicGradient.BackdropPalette? = nil
    /// When the current queue came from a playlist, adds a "Go to Playlist" action.
    var sourcePlaylist: PlaylistSummary? = nil
    /// Compact mode: subheadline font + secondaryLabel tint — for the Up Next page header.
    var compact: Bool = false
    /// Caller-controlled disable for the Go to Album action — true only when no nav path
    /// exists at all (neither a library album nor a usable catalog fallback). Defaults to
    /// disabling when `libraryAlbum == nil`, matching legacy behavior.
    var goToAlbumDisabled: Bool? = nil
    let onGoToAlbum: () -> Void
    let onGoToArtist: () -> Void
    var onGoToPlaylist: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .leading
        button.showsMenuAsPrimaryAction = true
        button.tintColor = .label
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let isDarkSystem = context.environment.colorScheme == .dark
        var cfg = UIButton.Configuration.plain()
        cfg.title = artist
        if heroBackdropPalette != nil {
            cfg.baseForegroundColor = UIColor.white.withAlphaComponent(0.55)
        } else {
            cfg.baseForegroundColor = isDarkSystem ? UIColor.white.withAlphaComponent(0.55) : UIColor.secondaryLabel
        }
        cfg.titleLineBreakMode = .byTruncatingTail
        let textStyle: UIFont.TextStyle = compact ? .subheadline : .title3
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.preferredFont(forTextStyle: textStyle)
            return out
        }
        cfg.contentInsets = .zero
        cfg.titlePadding = 0
        button.configuration = cfg
        if heroBackdropPalette != nil {
            button.tintColor = .white
        } else {
            button.tintColor = isDarkSystem ? .white : .label
        }

        let albumLine = albumSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistLine = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        let disabled = goToAlbumDisabled ?? (libraryAlbum == nil)
        let albumAction = UIAction(
            title: "Go to Album",
            subtitle: albumLine.isEmpty ? "—" : albumLine,
            image: UIImage(systemName: "square.stack.fill"),
            attributes: disabled ? [.disabled] : []
        ) { _ in
            DispatchQueue.main.async {
                onGoToAlbum()
            }
        }

        let artistAction = UIAction(
            title: "Go to Artist",
            subtitle: artistLine.isEmpty ? "—" : artistLine,
            image: UIImage(systemName: "music.mic")
        ) { _ in
            DispatchQueue.main.async {
                onGoToArtist()
            }
        }

        var children: [UIMenuElement] = [artistAction, albumAction]
        if let sourcePlaylist, let onGoToPlaylist {
            let playlistAction = UIAction(
                title: "Go to Playlist",
                subtitle: sourcePlaylist.name,
                image: UIImage(systemName: "music.note.list")
            ) { _ in
                DispatchQueue.main.async {
                    onGoToPlaylist()
                }
            }
            children.append(playlistAction)
        }

        button.menu = UIMenu(children: children)
    }
}

#else

/// macOS / non-UIKit: plain SwiftUI menu (subtitle styling differs from iOS `UIMenu`).
struct ArtistNowPlayingMenuButton: View {
    let artist: String
    let albumSubtitle: String
    let libraryAlbum: AlbumSummary?
    var heroBackdropPalette: ArtworkDynamicGradient.BackdropPalette? = nil
    var sourcePlaylist: PlaylistSummary? = nil
    var compact: Bool = false
    var goToAlbumDisabled: Bool? = nil
    let onGoToAlbum: () -> Void
    let onGoToArtist: () -> Void
    var onGoToPlaylist: (() -> Void)? = nil

    var body: some View {
        Menu {
            Button {
                onGoToArtist()
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
            Button {
                onGoToAlbum()
            } label: {
                Label("Go to Album", systemImage: "square.stack.fill")
            }
            .disabled(goToAlbumDisabled ?? (libraryAlbum == nil))
            if let sourcePlaylist, let onGoToPlaylist {
                Button {
                    onGoToPlaylist()
                } label: {
                    Label("Go to Playlist — \(sourcePlaylist.name)", systemImage: "music.note.list")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle((heroBackdropPalette?.heroChromeSecondary) ?? MusicDesign.secondaryLabel)
                Text(albumSubtitle)
                    .font(.subheadline)
                    .foregroundStyle((heroBackdropPalette?.heroChromeTertiary) ?? MusicDesign.secondaryLabel.opacity(0.85))
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }
}

#endif
