import Foundation

/// In-memory search over the **personal library** (the per-user Lyra "My Library"
/// magic playlist) — songs the user added (`librarySongIds`), albums they added
/// (`libraryAlbumEntries`), playlists they added (`libraryPlaylistEntries`), and
/// artists derived from those. Strictly local; never hits the network.
///
/// Treats `query` as substring matches against title/name/artist, case- and
/// diacritic-insensitive, with simple whitespace tokenization (every token must
/// appear somewhere in the searchable string).
struct PersonalLibrarySearchResults {
    var songs: [Track]
    var albums: [AlbumSummary]
    var playlists: [PlaylistSummary]
    var artists: [LibraryArtistSummary]

    static let empty = PersonalLibrarySearchResults(songs: [], albums: [], playlists: [], artists: [])
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty }
}

enum PersonalLibrarySearch {
    /// All-personal pass-through when `query` is empty (used by the Library tab's idle state).
    static func snapshot(
        songIds: Set<String>,
        albumIds: Set<String>,
        playlistIds: Set<String>,
        trackCache: [Track],
        albumCache: [String: AlbumSummary],
        playlistCache: [String: PlaylistSummary]
    ) -> PersonalLibrarySearchResults {
        let songs = trackCache.filter { songIds.contains($0.id) }
        let albums = albumIds.compactMap { albumCache[$0] }
        let playlists = playlistIds.compactMap { playlistCache[$0] }
        let artists = derivedArtists(from: songs, albums: albums)
        return PersonalLibrarySearchResults(songs: songs, albums: albums, playlists: playlists, artists: artists)
    }

    static func search(
        query: String,
        songIds: Set<String>,
        albumIds: Set<String>,
        playlistIds: Set<String>,
        trackCache: [Track],
        albumCache: [String: AlbumSummary],
        playlistCache: [String: PlaylistSummary]
    ) -> PersonalLibrarySearchResults {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else {
            return snapshot(
                songIds: songIds,
                albumIds: albumIds,
                playlistIds: playlistIds,
                trackCache: trackCache,
                albumCache: albumCache,
                playlistCache: playlistCache,
            )
        }

        let songs = trackCache
            .filter { songIds.contains($0.id) }
            .filter { matches(tokens: tokens, in: "\($0.title) \($0.artist) \($0.albumTitle)") }

        let albums = albumIds
            .compactMap { albumCache[$0] }
            .filter { matches(tokens: tokens, in: "\($0.title) \($0.artist)") }

        let playlists = playlistIds
            .compactMap { playlistCache[$0] }
            .filter { matches(tokens: tokens, in: $0.name) }

        let artists = derivedArtists(from: songs, albums: albums)
            .filter { matches(tokens: tokens, in: $0.name) }

        return PersonalLibrarySearchResults(songs: songs, albums: albums, playlists: playlists, artists: artists)
    }

    /// Returns the set of unique artist names across personal songs + albums as
    /// synthetic ``LibraryArtistSummary`` rows (no server id, just a display row).
    private static func derivedArtists(from songs: [Track], albums: [AlbumSummary]) -> [LibraryArtistSummary] {
        var seen = Set<String>()
        var out: [LibraryArtistSummary] = []
        for source in [songs.map(\.artist), albums.map(\.artist)] {
            for name in source {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                if seen.insert(key).inserted {
                    out.append(LibraryArtistSummary(id: "synthetic:\(key)", name: trimmed, artworkURL: nil))
                }
            }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }

    private static func tokenize(_ raw: String) -> [String] {
        raw.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func matches(tokens: [String], in haystack: String) -> Bool {
        let normalized = haystack.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        for t in tokens where !normalized.contains(t) { return false }
        return true
    }
}
