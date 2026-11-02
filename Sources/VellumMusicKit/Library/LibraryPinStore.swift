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

    /// Last decode, memoized on the exact raw string it came from.
    ///
    /// `decode` is reached from `contains`, which `LibrarySongRow`'s `==` calls for *both* sides
    /// — and the row's body calls it a third time. So the JSON was being parsed from scratch two
    /// or three times per row per diff pass, inside the `Equatable` conformance whose entire
    /// purpose is to *avoid* work. The pin list changes only when the user pins something, so
    /// one entry keyed on the raw string collapses all of that to a single parse.
    /// Same single-slot memo shape as `OfflineDownloadManager.manifestCache`.
    private static var decodedCacheRaw: String?
    private static var decodedCacheRefs: [LibraryPinnedRef] = []

    static func decode(_ raw: String) -> [LibraryPinnedRef] {
        if decodedCacheRaw == raw { return decodedCacheRefs }
        let refs: [LibraryPinnedRef]
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([LibraryPinnedRef].self, from: data) {
            refs = parsed
        } else {
            // Cache the failure too, so malformed storage is not re-parsed on every diff.
            refs = []
        }
        decodedCacheRaw = raw
        decodedCacheRefs = refs
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
    /// Resolves the (typically 1–6) pinned refs against the in-memory catalogs.
    ///
    /// Uses ``AppModel``'s prebuilt id indexes rather than mapping `libraryAlbums` /
    /// `discoveryLibraryTracks` into fresh dictionaries — those arrays are the whole
    /// server catalog and track index, and this runs from a SwiftUI `body`.
    static func resolvedItems(raw: String, app: AppModel) -> [LibraryPinnedItem] {
        decode(raw).compactMap { ref in
            switch ref.kind {
            case .album:
                guard let album = app.catalogAlbum(id: ref.itemId) else { return nil }
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
                guard let playlist = app.libraryPlaylist(id: ref.itemId) else { return nil }
                return .playlist(playlist)
            case .track:
                guard let track = app.indexedTrack(id: ref.itemId) else { return nil }
                return .track(track)
            }
        }
    }
}
