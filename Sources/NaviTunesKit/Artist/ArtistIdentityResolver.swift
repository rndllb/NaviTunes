import Foundation

/// Decides *which* MusicBrainz artist a bare name refers to, using the albums the user owns.
///
/// The problem this solves is not that name matching is fuzzy — it is that name matching can be
/// exactly right and still pick the wrong artist. Eighteen acts are named exactly "Rocket". Every
/// one of them ties on the name, so the tie falls to MusicBrainz's own relevance score, and
/// relevance is a measure of textual match rather than of which artist this listener means. For
/// "Rocket" that hands the page to a Russian rapper scoring 95 over the Los Angeles indie band
/// scoring 91, and no amount of better string comparison would change it: both names are perfect.
///
/// The disambiguating signal is not in the name at all — it is in the library. The user owns
/// *R is for Rocket*, and exactly one of those eighteen artists released it. So when the name ties,
/// this asks each candidate what they have released and picks the one whose catalogue actually
/// contains the records on the server.
///
/// Cost is paid only where the ambiguity is real: one browse per candidate, capped, and only when
/// two or more artists share the exact name *and* the user owns something to compare against. An
/// unambiguous artist costs nothing beyond the search that was already happening.
enum ArtistIdentityResolver {
    struct Resolution {
        let artist: MusicBrainzArtist
        /// True when owned albums decided this, rather than MusicBrainz's relevance ranking.
        var decidedByOwnedAlbums: Bool = false
        /// True when the request backend's own MusicBrainz id named one of the candidates.
        var decidedByRequestBackend: Bool = false
        /// How many owned albums the winning candidate's catalogue accounted for.
        var matchedAlbumCount: Int = 0

        /// Anything but the relevance ranking. Only a decided answer is durable enough to cache.
        var isDecided: Bool { decidedByOwnedAlbums || decidedByRequestBackend }
    }

    /// Candidates to interrogate when a name ties. Three covers the realistic case without
    /// turning a page open into a long wait — MusicBrainz allows one request per second, so each
    /// extra candidate is another second the reader spends looking at a skeleton.
    private static let candidateLimit = 3

    static func resolve(
        name: String,
        ownedAlbums: [AlbumSummary],
        pluginArtistMBID: String? = nil
    ) async -> Resolution? {
        let target = LibraryTrackMatcher.normalize(name)
        guard !target.isEmpty else { return nil }

        // A previously *decided* answer is reusable. A previous guess is not, and is deliberately
        // never written, so re-opening the page re-derives it rather than inheriting a coin flip.
        if let cached = await cachedDecision(target: target) {
            return Resolution(artist: cached, decidedByOwnedAlbums: true, matchedAlbumCount: 0)
        }

        let candidates = await MusicBrainzService.shared.searchArtists(query: name).rows
        guard !candidates.isEmpty else { return nil }

        let exact = candidates.filter { LibraryTrackMatcher.normalize($0.name) == target }

        // The request backend's own answer, when it has one and it names a candidate.
        //
        // Adding an artist to a MusicBrainz-backed backend is itself an act of identification —
        // the user picked one act out of the eighteen sharing the name, and the backend recorded
        // its MBID. That is better evidence than any ranking, and it costs nothing: the profile
        // this comes from is already fetched for the artist header.
        //
        // Deliberately a *vote among the candidates* rather than an override. It can only select
        // an artist who already matches the name exactly, so if the backend resolved its own
        // artist loosely and landed somewhere unrelated, the worst case is that the vote is
        // ignored rather than followed off a cliff.
        if let pluginArtistMBID = pluginArtistMBID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pluginArtistMBID.isEmpty,
           let backed = exact.first(where: { $0.id == pluginArtistMBID }) {
            await cacheDecision(target: target, artist: backed)
            return Resolution(artist: backed, decidedByRequestBackend: true, matchedAlbumCount: 0)
        }

        // No tie, or nothing to compare against: fall back to the ranking. This is the same answer
        // as before, and it is still a guess — reported as one rather than cached as a fact.
        guard exact.count > 1, !ownedAlbums.isEmpty else {
            guard let best = MusicBrainzArtistMatcher.bestMatch(for: name, in: candidates) else { return nil }
            return Resolution(artist: best, decidedByOwnedAlbums: false, matchedAlbumCount: 0)
        }

        let ownedKeys = Set(ownedAlbums.flatMap { AlbumSummary.discographyTitleKeys(for: $0.title) })
        guard !ownedKeys.isEmpty else {
            guard let best = MusicBrainzArtistMatcher.bestMatch(for: name, in: candidates) else { return nil }
            return Resolution(artist: best, decidedByOwnedAlbums: false, matchedAlbumCount: 0)
        }

        // Highest-relevance candidates first, so the common case decides on the first probe and
        // the remaining requests are never made.
        let ordered = exact.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        var best: (artist: MusicBrainzArtist, matches: Int)?

        for candidate in ordered.prefix(candidateLimit) {
            guard let discography = await MusicBrainzService.shared.discography(artistMBID: candidate.id) else {
                continue
            }
            var matches = 0
            for group in discography.releaseGroups {
                let keys = AlbumSummary.discographyTitleKeys(for: group.title)
                if keys.contains(where: { ownedKeys.contains($0) }) { matches += 1 }
            }
            if matches > (best?.matches ?? 0) {
                best = (candidate, matches)
                // Every owned album accounted for — no later candidate can beat that, so stop
                // rather than spend another second per remaining candidate.
                if matches >= ownedKeys.count { break }
            }
        }

        if let best, best.matches > 0 {
            await cacheDecision(target: target, artist: best.artist)
            return Resolution(artist: best.artist, decidedByOwnedAlbums: true, matchedAlbumCount: best.matches)
        }

        // Nobody's catalogue contained anything owned. That is still a guess, so it is returned
        // as one and left uncached.
        guard let fallback = MusicBrainzArtistMatcher.bestMatch(for: name, in: candidates) else { return nil }
        return Resolution(artist: fallback, decidedByOwnedAlbums: false, matchedAlbumCount: 0)
    }

    // MARK: - Decided-only cache

    /// Deliberately a different key from the general name-resolution cache.
    ///
    /// That one stores whatever the ranking returned, for a week, with no record of how confident
    /// it was — so a wrong pick for an ambiguous name becomes sticky and survives restarts,
    /// rebuilds and reinstalls of the binary. Only decided answers land here, so nothing this
    /// reads back was ever a coin flip.
    private static func key(target: String) -> String {
        "artistidentity:\(target)|decided-by-owned-albums"
    }

    private static func cachedDecision(target: String) async -> MusicBrainzArtist? {
        guard let entry = await MusicBrainzCacheStore.loadAsync(key(target: target)),
              !entry.isExpired,
              let raw = entry.rawPages.first,
              let decoded = try? JSONDecoder().decode(MusicBrainzArtist.self, from: raw)
        else { return nil }
        return decoded
    }

    private static func cacheDecision(target: String, artist: MusicBrainzArtist) async {
        guard let raw = try? JSONEncoder().encode(artist) else { return }
        await MusicBrainzCacheStore.saveAsync(
            MusicBrainzCacheEntry(
                key: key(target: target),
                fetchedAt: Date(),
                totalCount: nil,
                heldOffsets: [0],
                rawPages: [raw],
                isComplete: true
            )
        )
    }
}
