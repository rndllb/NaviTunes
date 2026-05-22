import Foundation
import SwiftUI

/// Kind of item pinned to the Library hub grid (under **Library**, above category rows).
enum LibraryPinnedKind: String, Codable, CaseIterable {
    case album
    case playlist
    case track
}

struct LibraryPinnedRef: Codable, Equatable, Identifiable {
    var id: String { "\(kind.rawValue):\(itemId)" }
    let kind: LibraryPinnedKind
    let itemId: String
}

/// Resolved pin ready for display/navigation (dropped when the catalog no longer has the id).
enum LibraryPinnedItem: Identifiable, Equatable {
    case album(AlbumSummary)
    case playlist(PlaylistSummary)
    case track(Track)

    var id: String {
        switch self {
        case .album(let a): return "album:\(a.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        case .track(let t): return "track:\(t.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let a): return a.title
        case .playlist(let p): return p.name
        case .track(let t): return t.title
        }
    }

    var subtitle: String? {
        switch self {
        case .album(let a): return a.artist
        case .playlist(let p):
            if let n = p.songCount { return n == 1 ? "1 song" : "\(n) songs" }
            return "Playlist"
        case .track(let t):
            let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            return artist.isEmpty ? nil : artist
        }
    }

    var artworkURL: URL? {
        switch self {
        case .album(let a): return a.artworkURL
        case .playlist(let p): return p.artworkURL
        case .track(let t): return t.artworkURL
        }
    }

    var pinRef: LibraryPinnedRef {
        switch self {
        case .album(let a): return LibraryPinnedRef(kind: .album, itemId: a.id)
        case .playlist(let p): return LibraryPinnedRef(kind: .playlist, itemId: p.id)
        case .track(let t): return LibraryPinnedRef(kind: .track, itemId: t.id)
        }
    }
}

enum LibraryPinStore {
    static let storageKey = "pinnedLibraryItemRefs"

    /// Menu copy for pin actions (album / playlist / song).
    static func menuLabel(kind: LibraryPinnedKind, isPinned: Bool) -> String {
        switch (kind, isPinned) {
        case (.album, false): return "Pin Album"
        case (.album, true): return "Unpin Album"
        case (.playlist, false): return "Pin Playlist"
        case (.playlist, true): return "Unpin Playlist"
        case (.track, false): return "Pin Song"
        case (.track, true): return "Unpin Song"
        }
    }

    static func menuLabel(for item: LibraryPinnedItem, isPinned: Bool) -> String {
        menuLabel(kind: item.pinRef.kind, isPinned: isPinned)
    }
    private static let legacyMigrationKey = "pinnedLibraryMigratedFromFavoritedPlaylists"
    private static let favoriteSongsPlaylistId = "__favorite_songs__"

    static func decode(_ raw: String) -> [LibraryPinnedRef] {
        guard let data = raw.data(using: .utf8),
              let refs = try? JSONDecoder().decode([LibraryPinnedRef].self, from: data)
        else { return [] }
        return refs
    }

    static func encode(_ refs: [LibraryPinnedRef]) -> String {
        guard let data = try? JSONEncoder().encode(refs),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    static func contains(_ ref: LibraryPinnedRef, in raw: String) -> Bool {
        decode(raw).contains(ref)
    }

    static func toggle(_ ref: LibraryPinnedRef, storage raw: inout String) {
        var refs = decode(raw)
        if let idx = refs.firstIndex(of: ref) {
            refs.remove(at: idx)
        } else {
            refs.append(ref)
        }
        raw = encode(refs)
    }

    static func remove(_ ref: LibraryPinnedRef, storage raw: inout String) {
        var refs = decode(raw)
        refs.removeAll { $0 == ref }
        raw = encode(refs)
    }

    /// One-time: copy legacy ``favoritedPlaylistIds`` into the pin grid so existing pins still appear.
    static func migrateLegacyPlaylistPinsIfNeeded(storage raw: inout String) {
        guard !UserDefaults.standard.bool(forKey: legacyMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: legacyMigrationKey)
        let legacy = UserDefaults.standard.string(forKey: "favoritedPlaylistIds") ?? ""
        let legacyIds = legacy.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !legacyIds.isEmpty else { return }
        var refs = decode(raw)
        var seen = Set(refs.map(\.id))
        for id in legacyIds {
            let ref = LibraryPinnedRef(kind: .playlist, itemId: id)
            guard !seen.contains(ref.id) else { continue }
            refs.append(ref)
            seen.insert(ref.id)
        }
        raw = encode(refs)
    }

    @MainActor
    static func resolvedItems(raw: String, app: AppModel) -> [LibraryPinnedItem] {
        let albumsById = Dictionary(uniqueKeysWithValues: app.libraryAlbums.map { ($0.id, $0) })
        let playlistsById = Dictionary(uniqueKeysWithValues: app.libraryPlaylists.map { ($0.id, $0) })
        let tracksById = Dictionary(uniqueKeysWithValues: app.discoveryLibraryTracks.map { ($0.id, $0) })

        return decode(raw).compactMap { ref in
            switch ref.kind {
            case .album:
                guard let album = albumsById[ref.itemId] else { return nil }
                return .album(album)
            case .playlist:
                if ref.itemId == favoriteSongsPlaylistId {
                    let count = app.favoriteTrackIds.count
                    guard count > 0 else { return nil }
                    return .playlist(
                        PlaylistSummary(
                            id: favoriteSongsPlaylistId,
                            name: "Favorite Songs",
                            songCount: count,
                            artworkURL: nil
                        )
                    )
                }
                guard let playlist = playlistsById[ref.itemId] else { return nil }
                return .playlist(playlist)
            case .track:
                guard let track = tracksById[ref.itemId] else { return nil }
                return .track(track)
            }
        }
    }
}
