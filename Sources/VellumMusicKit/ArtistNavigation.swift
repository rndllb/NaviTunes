import SwiftUI

/// Programmatic artist push — avoids nested ``NavigationLink`` conflicts on album detail.
struct ArtistNameNavigation: Identifiable, Hashable {
    let id: String
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
