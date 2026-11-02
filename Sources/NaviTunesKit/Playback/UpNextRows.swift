import Foundation

/// One up-next row as Now Playing lists it.
///
/// A queue can hold the same id more than once — a playlist with a repeated song, or Play Next /
/// Add to Queue used on the track already playing — so rows are never addressed by id. `rowId` is
/// the id plus which occurrence it is, so identity survives rows shifting position when something
/// above them is removed. `queueIndex` and `upNextOffset` carry the *position*, which is what the
/// engine is told to act on.
struct UpNextEntry: Identifiable {
    let rowId: String
    /// Absolute index into `PlaybackEngine.queue`.
    let queueIndex: Int
    /// Offset from the start of up-next in the **raw** queue — the coordinate space
    /// `PlaybackEngine.moveUpNextItem` and `removeUpNextItems` both use. Not the row's position in
    /// the list: rows Kill Mode will pass over are not listed, so the two differ.
    let upNextOffset: Int
    let track: Track
    var id: String { rowId }
}

/// Builds the listed up-next rows and maps list gestures back onto the raw queue.
///
/// Swipe-to-remove and drag-to-reorder both address the raw queue after the cursor. Once some rows
/// are hidden, a row's position in the list is no longer its offset in that queue, and passing the
/// list position straight through removes or moves a *different* song. Every entry therefore
/// carries its raw offset, and every gesture goes through it.
enum UpNextRows {
    /// Rows after `currentIndex`, minus those `isHidden` rejects. Occurrence numbering counts hidden
    /// rows too, so a row keeps its identity when the rows around it change visibility.
    static func entries(queue: [Track], currentIndex: Int, isHidden: (Int) -> Bool) -> [UpNextEntry] {
        let start = currentIndex + 1
        guard start < queue.count else { return [] }
        var occurrences: [String: Int] = [:]
        var result: [UpNextEntry] = []
        for index in queue.indices.dropFirst(start) {
            let track = queue[index]
            let n = occurrences[track.id, default: 0]
            occurrences[track.id] = n + 1
            guard !isHidden(index) else { continue }
            result.append(UpNextEntry(rowId: "\(track.id)#\(n)", queueIndex: index, upNextOffset: index - start, track: track))
        }
        return result
    }

    /// Translates an `onMove` source + destination, given in the positions of `entries` (one list
    /// section), into raw up-next offsets for `PlaybackEngine.moveUpNextItem(from:to:)`.
    ///
    /// The destination is "insert before the entry now at `destination`", so it maps to that entry's
    /// raw offset; past the end, it maps to just after the section's last entry. Hidden rows between
    /// listed ones keep their place relative to the rows they were not dragged past.
    static func moveArguments(entries: [UpNextEntry], source: IndexSet, destination: Int) -> (source: IndexSet, destination: Int)? {
        guard !entries.isEmpty else { return nil }
        let mappedSource = IndexSet(source.compactMap { entries.indices.contains($0) ? entries[$0].upNextOffset : nil })
        guard !mappedSource.isEmpty else { return nil }
        let mappedDestination: Int
        if destination < entries.count {
            mappedDestination = entries[max(0, destination)].upNextOffset
        } else {
            mappedDestination = entries[entries.count - 1].upNextOffset + 1
        }
        return (mappedSource, mappedDestination)
    }
}
