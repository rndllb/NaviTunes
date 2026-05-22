import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Section grouping (Artists list + Albums grid)

enum LibraryAlphabetIndex {
    static func sectionLetter(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        if first.isNumber { return "#" }
        if first.isLetter {
            let folded = String(first)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard let foldedFirst = folded.first else { return "#" }
            let upper = String(foldedFirst).uppercased()
            if let scalar = upper.unicodeScalars.first,
               scalar.isASCII,
               (65...90).contains(scalar.value) {
                return upper
            }
            return upper
        }
        return "#"
    }

    static func orderedSectionKeys(_ keys: Set<String>) -> [String] {
        let alphabet = (0..<26).map { String(UnicodeScalar(65 + $0)!) }
        return alphabet.filter { keys.contains($0) } + (keys.contains("#") ? ["#"] : [])
    }

    static func groupedSections<T>(
        _ items: [T],
        letter: (T) -> String
    ) -> [(id: String, items: [T])] {
        var grouped: [String: [T]] = [:]
        for item in items {
            let key = letter(item)
            grouped[key, default: []].append(item)
        }
        return orderedSectionKeys(Set(grouped.keys)).compactMap { key in
            guard let bucket = grouped[key], !bucket.isEmpty else { return nil }
            return (id: key, items: bucket)
        }
    }

    static func albumScrollSectionID(_ letter: String) -> String {
        "album-section-\(letter)"
    }

    static func artistScrollSectionID(_ letter: String) -> String {
        "artist-section-\(letter)"
    }
}

struct LibraryAlbumGridSection: Identifiable, Equatable {
    let id: String
    let albums: [AlbumSummary]
}

// MARK: - Trailing A–Z scrubber (Artists + Albums)

/// Trailing A–Z index — anchored to absolute screen coordinates.
///
/// See ``LibraryArtistAlphabetScrubberHost`` notes in git history; shared by Artists list
/// and Albums grid so scroll / nav-bar transitions don't shift the strip.
struct LibraryAlphabetScrubberHost: View {
    let letters: [String]
    var selectedLetter: String?
    let onSelect: (String) -> Void
    let onScrubEnd: () -> Void

    private let hitWidth: CGFloat = 40
    private let letterWidth: CGFloat = 18
    private let rowHeight: CGFloat = 14
    private let rowSpacing: CGFloat = 1
    private let trailingMargin: CGFloat = -1
    private let navBarHeight: CGFloat = 44

    @State private var lastReportedLetter: String?

    private let deviceTopInset: CGFloat
    private let deviceBottomInset: CGFloat

    init(
        letters: [String],
        selectedLetter: String?,
        onSelect: @escaping (String) -> Void,
        onScrubEnd: @escaping () -> Void
    ) {
        self.letters = letters
        self.selectedLetter = selectedLetter
        self.onSelect = onSelect
        self.onScrubEnd = onScrubEnd
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene?.keyWindow ?? scene?.windows.first
        self.deviceTopInset = window?.safeAreaInsets.top ?? 0
        self.deviceBottomInset = window?.safeAreaInsets.bottom ?? 0
        #else
        self.deviceTopInset = 0
        self.deviceBottomInset = 0
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let contentTop = deviceTopInset + navBarHeight
            let contentBottom = geo.size.height - deviceBottomInset
            let contentCenterY = (contentTop + contentBottom) / 2
            let trailingX = geo.size.width - trailingMargin - letterWidth / 2

            let stackHeight = Self.stackHeight(
                count: letters.count,
                rowHeight: rowHeight,
                rowSpacing: rowSpacing
            )
            let stackOriginGlobalY = geo.frame(in: .global).minY + contentCenterY - stackHeight / 2

            VStack(spacing: rowSpacing) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 11, weight: selectedLetter == letter ? .bold : .semibold))
                        .foregroundStyle(
                            selectedLetter == letter
                                ? MusicDesign.accent
                                : MusicDesign.accent.opacity(0.88)
                        )
                        .frame(width: letterWidth, height: rowHeight)
                }
            }
            .frame(width: hitWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard let index = Self.letterIndex(
                            atGlobalY: value.location.y,
                            stackOriginGlobalY: stackOriginGlobalY,
                            count: letters.count,
                            rowHeight: rowHeight,
                            rowSpacing: rowSpacing
                        ),
                        letters.indices.contains(index) else {
                            return
                        }
                        let letter = letters[index]
                        guard lastReportedLetter != letter else { return }
                        lastReportedLetter = letter
                        onSelect(letter)
                    }
                    .onEnded { _ in
                        lastReportedLetter = nil
                        onScrubEnd()
                    }
            )
            .position(x: trailingX, y: contentCenterY)
        }
        .ignoresSafeArea()
        .transaction { $0.animation = nil }
        .animation(nil, value: selectedLetter)
    }

    private static func stackHeight(count: Int, rowHeight: CGFloat, rowSpacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowSpacing
    }

    private static func letterIndex(
        atGlobalY globalY: CGFloat,
        stackOriginGlobalY: CGFloat,
        count: Int,
        rowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> Int? {
        guard count > 0 else { return nil }
        let stackHeight = stackHeight(count: count, rowHeight: rowHeight, rowSpacing: rowSpacing)
        guard stackHeight > 0 else { return nil }
        let relativeY = globalY - stackOriginGlobalY
        guard relativeY >= 0, relativeY < stackHeight else { return nil }
        let slot = rowHeight + rowSpacing
        return min(count - 1, max(0, Int(relativeY / slot)))
    }
}
