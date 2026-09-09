import SwiftUI

/// Programmatic artist push — avoids nested ``NavigationLink`` conflicts on album detail.
struct ArtistNameNavigation: Identifiable, Hashable {
    /// The artist's display name. Also the `Identifiable` id, which is why it keeps this name.
    let id: String
    /// The server's id for this artist, when the row that opened the menu had one.
    ///
    /// This is what stops "Go to Artist" being a guess. With only a name, the destination is
    /// whichever artist a name lookup happens to return, and same-named acts are common enough
    /// that this is a routine wrong answer rather than a rare one. With the id, the destination
    /// is that artist and no other.
    var serverArtistId: String?

    init(id: String, serverArtistId: String? = nil) {
        self.id = id
        self.serverArtistId = serverArtistId
    }

    /// The page input this navigation should open.
    ///
    /// Prefers the id. Falls back to the name only when no id was available at the tap site,
    /// which is a genuine wrong-artist risk rather than a neutral default.
    var artistPageInput: ArtistPageInput {
        if let serverArtistId, !serverArtistId.isEmpty {
            return .libraryArtist(LibraryArtistSummary(id: serverArtistId, name: id, artworkURL: nil))
        }
        return .named(id)
    }
}

enum ArtistNavigation {
    /// Apple Music treats "Various Artists" as non-navigable on album pages.
    static func isTappable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.lowercased() != "various artists"
    }
}

/// Tappable artist label — static text for "Various Artists" and empty names.
struct ArtistNameButton: View {
    let name: String
    var font: Font = .subheadline
    var foreground: Color = MusicDesign.secondaryLabel
    var lineLimit: Int? = 1
    var multilineTextAlignment: TextAlignment = .leading
    let onTap: () -> Void

    var body: some View {
        Group {
            if ArtistNavigation.isTappable(name) {
                Button(action: onTap) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        Text(name)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(lineLimit)
            .multilineTextAlignment(multilineTextAlignment)
    }
}
