import Foundation

/// Maps playlist removal targets captured from a *snapshot* onto the playlist as the server
/// holds it right now.
///
/// Subsonic/Navidrome removes playlist songs by **position** (`songIndexToRemove`), and every
/// removal shifts every later position down by one. `PlaylistRowItem.navidromeIndex` is therefore
/// only valid against the exact fetch it came from: any surface that keeps its rows across a
/// removal — `PlaylistEditSheet`, the Kill Mode list — is holding indices that now point at a
/// *different song*. Sending one verbatim deletes whatever happens to sit at that position.
///
/// So positions are re-derived from stable track ids immediately before the delete, and this is
/// the part of that with no network in it. Jellyfin needs none of it (entry ids are stable) and is
/// here only so both backends answer the same question in the same shape.
enum PlaylistRemovalTargeting {
    struct Resolution {
        /// Rows carrying positions/ids valid against the playlist that was passed as `live`.
        var resolved: [PlaylistRowItem]
        /// Requested tracks that are no longer in the playlist — already in the desired end
        /// state, so they are reported rather than failing the batch.
        var goneTrackIds: Set<String>
    }

    /// Matches each requested row to a live row by track id, **consuming** each live row as it is
    /// matched so that N requested copies of a duplicated song resolve to N distinct positions
    /// instead of all collapsing onto the first one.
    static func resolveByTrackId(requested: [PlaylistRowItem], live: [PlaylistRowItem]) -> Resolution {
        var byId: [String: [PlaylistRowItem]] = [:]
        for row in live { byId[row.track.id, default: []].append(row) }
        var resolved: [PlaylistRowItem] = []
        var gone: Set<String> = []
        for row in requested {
            if var matches = byId[row.track.id], !matches.isEmpty {
                resolved.append(matches.removeFirst())
                byId[row.track.id] = matches
            } else {
                gone.insert(row.track.id)
            }
        }
        return Resolution(resolved: resolved, goneTrackIds: gone)
    }

    /// Jellyfin entry ids are stable across edits, so a requested row only has to still exist.
    /// A row with no entry id is passed through untouched: the caller's own guard is what reports
    /// it, and dropping it here would report success for a removal that never happened.
    static func resolveByEntryId(requested: [PlaylistRowItem], live: [PlaylistRowItem]) -> Resolution {
        let liveEntryIds = Set(live.compactMap(\.jellyfinEntryId))
        var resolved: [PlaylistRowItem] = []
        var gone: Set<String> = []
        for row in requested {
            if let entryId = row.jellyfinEntryId, !liveEntryIds.contains(entryId) {
                gone.insert(row.track.id)
            } else {
                resolved.append(row)
            }
        }
        return Resolution(resolved: resolved, goneTrackIds: gone)
    }

    /// Deletion order for a batch of already-resolved rows: **highest position first**, because
    /// removing a high position never shifts a lower one. The track id rides along so a caller
    /// interrupted mid-batch knows which songs actually left.
    static func navidromeDeletionOrder(_ rows: [PlaylistRowItem]) throws -> [(index: Int, trackId: String)] {
        try rows
            .map { row in
                guard let index = row.navidromeIndex else {
                    throw NSError(
                        domain: "VellumMusic",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Missing playlist index."],
                    )
                }
                return (index: index, trackId: row.track.id)
            }
            .sorted { $0.index > $1.index }
    }
}
