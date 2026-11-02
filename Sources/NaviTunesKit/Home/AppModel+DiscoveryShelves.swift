import Foundation

/// The stateless half of the Home/New-tab discovery shelves.
///
/// Everything here reads catalog and listening state and **returns a value**. Nothing in this file
/// writes `@Published` state, which is the whole reason it could be lifted out of `AppModel.swift`:
/// the shelf writers (`refreshNewTabBrowse`, `applyHomeDiscoveryShelvesRanking`,
/// `applyPersonalizedNewTabFeed`, `clearNewTabBrowseGrid`) mutate twelve `private(set)` properties
/// between them, and moving those would have had to trade away the write barrier on each one.
///
/// So the split here is not "the first 139 lines"; it is the boundary between computing a shelf and
/// publishing one. Keep it that way — a function added here that assigns to `homeTopPickAlbums`,
/// `homeNewReleaseAlbums` or any `newTab*` property belongs back in `AppModel.swift`.
///
/// These five were `private` in the class body. Crossing a file makes them `internal`, because Swift
/// `private` is file-scoped; they remain read-only computations, so no setter and no mutating path
/// is exposed by that change.
extension AppModel {
    /// The user's top genres for the New tab — canonicalised and ranked from the data that's
    /// reliably in memory: recently played tracks (strongest "what I listen to" signal),
    /// favorites, completed scrobbles, and the genres tagged on their library albums. This
    /// avoids the sparse discovery-track index, which is nearly empty at launch.
    func listeningTopGenres() -> [String] {
        var scores: [String: (name: String, score: Double)] = [:]

        func add(_ genres: [String], weight: Double) {
            for raw in genres {
                let canonical = GenreCanonicalizer.canonical(for: raw)
                let key = canonical.lowercased()
                guard !key.isEmpty else { continue }
                if var existing = scores[key] {
                    existing.score += weight
                    scores[key] = existing
                } else {
                    scores[key] = (canonical, weight)
                }
            }
        }

        // Actual listening — recentlyPlayedTracks is newest-first, so weight by position.
        for (index, track) in recentlyPlayedTracks.enumerated() {
            add(track.genres, weight: max(0.4, 1.0 - Double(index) / 120.0))
        }
        // Favorites resolved against whatever tracks are in memory.
        for trackId in favoriteTrackIds {
            if let track = cachedLibraryTrack(id: trackId)
                ?? recentlyPlayedTracks.first(where: { $0.id == trackId }) {
                add(track.genres, weight: 1.5)
            }
        }
        // Completed scrobbles that resolve to a known track.
        for scrobble in scrobbleService.store.completed {
            if let track = cachedLibraryTrack(id: scrobble.trackId) {
                add(track.genres, weight: 0.5)
            }
        }
        // Broad fallback: the genres tagged on the user's library albums.
        for album in libraryAlbums where !album.genres.isEmpty {
            add(album.genres, weight: 0.2)
        }

        return scores.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(10)
            .map(\.name)
    }

    func newTabPersonalizationContext(
        serverAlbums: [AlbumSummary] = [],
        catalogReleases: [AcquisitionRelease] = []
    ) -> NewTabPersonalizationEngine.Context {
        NewTabPersonalizationEngine.Context(
            completedScrobbles: scrobbleService.store.completed,
            favoriteTrackIds: favoriteTrackIds,
            followedArtists: subscriptions.followed,
            trackLookup: { [weak self] id in self?.cachedLibraryTrack(id: id) },
            indexedTracks: discoveryLibraryTracks,
            ownsAlbum: { [weak self] artist, title in
                self?.libraryAlbumReleaseIndex.firstMatch(artist: artist, albumTitle: title) != nil
            },
            ownsTrack: { [weak self] artist, title in
                guard let self else { return false }
                return LibraryTrackMatcher.matchesLibrary(
                    title: title,
                    artists: [artist],
                    titleIndex: self.libraryTrackTitleIndex
                )
            },
            topGenres: listeningTopGenres(),
            serverAlbums: serverAlbums,
            recentlyPlayedTracks: recentlyPlayedTracks,
            catalogReleases: catalogReleases
        )
    }

    func buildHomeTopPicksCandidatePool(extra: [AlbumSummary]) -> [AlbumSummary] {
        var pool: [AlbumSummary] = []
        var seenIDs = Set<String>()
        var seenReleases = Set<String>()

        func append(_ albums: [AlbumSummary]) {
            for album in albums {
                guard isEligibleForHomeTopPick(album) else { continue }
                guard seenIDs.insert(album.id).inserted else { continue }
                guard seenReleases.insert(album.catalogReleaseIdentityKey).inserted else { continue }
                pool.append(album)
            }
        }

        append(recentlyAddedAlbums)
        append(homeRecentlyPlayedServerAlbums)
        append(extra)
        // Cold-launch fallback: the recency sources aren't persisted, so on a fresh launch they
        // are empty until the network responds. The catalog IS restored from the snapshot, so
        // seed Top Picks from it to paint immediately instead of waiting; the network refresh
        // re-ranks against the proper recency pool once it lands.
        if pool.isEmpty {
            append(libraryAlbums)
        }
        return pool
    }

    /// Keeps visible Top Picks / New Releases rows in place when background refreshes
    /// expand the candidate pool — avoids the shelf reshuffling after first paint.
    func stabilizeHomeDiscoveryShelf(
        existing: [AlbumSummary],
        proposed: [AlbumSummary],
        limit: Int,
    ) -> [AlbumSummary] {
        guard !existing.isEmpty else { return Array(proposed.prefix(limit)) }
        let proposedByID = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, $0) })
        var result: [AlbumSummary] = []
        var usedIDs = Set<String>()

        for album in existing where result.count < limit {
            guard let fresh = proposedByID[album.id], usedIDs.insert(album.id).inserted else { continue }
            result.append(fresh)
        }
        for album in proposed where result.count < limit {
            guard usedIDs.insert(album.id).inserted else { continue }
            result.append(album)
        }
        return result
    }

    /// Split a newest-first release pool into two **disjoint** shelves: "New This Week"
    /// (releases in the last few weeks) and "Recent Releases" (everything older). When too
    /// few carry a fresh date, fall back to an even recency split so both shelves stay
    /// populated and never show the same albums.
    static func splitRecentReleases(
        _ pool: [ChartAlbum],
    ) -> (thisWeek: [ChartAlbum], recent: [ChartAlbum]) {
        let sorted = pool.sorted {
            ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast)
        }
        guard sorted.count > 1 else { return (sorted, []) }

        let cutoff = Date().addingTimeInterval(-21 * 86_400)
        let fresh = sorted.filter { ($0.releaseDate ?? .distantPast) >= cutoff }
        if fresh.count >= 2, fresh.count < sorted.count {
            let freshIds = Set(fresh.map(\.id))
            let rest = sorted.filter { !freshIds.contains($0.id) }
            return (Array(fresh.prefix(12)), Array(rest.prefix(12)))
        }

        let mid = (sorted.count + 1) / 2
        return (Array(sorted.prefix(mid).prefix(12)), Array(sorted.dropFirst(mid).prefix(12)))
    }
}
