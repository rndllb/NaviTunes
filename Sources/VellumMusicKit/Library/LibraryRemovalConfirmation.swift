import SwiftUI

/// One description of a pending removal, so every entry point that can take something out of
/// the user's library — swipe, context menu, overflow sheet, Now Playing menu — asks the same
/// question through the same presenter.
///
/// Two things the copy must always carry, because they are the two ways a confirmation lies:
///
/// - **What, by name and by count.** Removing one song and removing a fourteen-track album must
///   not read identically. ``LibraryRemovalCopy`` builds every string from a name plus a song
///   count for exactly this reason.
/// - **How far it reaches.** Three different acts pass through here, and no two of them share a
///   sentence: a *library* removal edits only this account's magic playlist and leaves the media
///   on the server; a *playlist* removal rewrites one playlist for everyone who can see it but
///   takes nothing out of the library; a *server delete* destroys media for everyone and cannot be
///   undone. A dialog that reads the same for two of those teaches the user to tap through the
///   dangerous one — and a dialog that overstates the damage is the same defect inverted, because
///   it trains them to disbelieve the wording. The reach is carried in the strings themselves;
///   there is no enum for it, because a field nothing reads is a field that drifts from the copy.
struct LibraryRemovalRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let perform: @MainActor () async -> Void
}

/// Every user-facing string for a library removal, in one place.
///
/// Call sites pass the thing being removed and get back a request; they never spell the wording
/// themselves. That is what keeps "album of fourteen" from rendering as the same sentence as
/// "one song" once a new surface is added.
enum LibraryRemovalCopy {
    /// "1 song" / "14 songs" — the scale the user is being asked to approve.
    static func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    private static func quoted(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this item" : "“\(trimmed)”"
    }

    /// Trailing "by Artist" clause, dropped when the server gave us no artist.
    private static func byArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " by \(trimmed)"
    }

    // MARK: - Personal library (magic playlist)

    static func song(
        _ track: Track,
        perform: @escaping @MainActor () async -> Void
    ) -> LibraryRemovalRequest {
        LibraryRemovalRequest(
            title: "Remove \(quoted(track.title)) from Your Library?",
            message: "1 song\(byArtist(track.artist)). \(libraryReachSentence)",
            confirmLabel: "Remove from Library",
            perform: perform
        )
    }

    static func album(
        _ album: AlbumSummary,
        songCount: Int?,
        perform: @escaping @MainActor () async -> Void
    ) -> LibraryRemovalRequest {
        let scale = songCount.map { "\(self.songCount($0))\(byArtist(album.artist))." }
            ?? "Every song on this album\(byArtist(album.artist))."
        return LibraryRemovalRequest(
            title: "Remove \(quoted(album.title)) from Your Library?",
            message: "\(scale) \(libraryReachSentence)",
            confirmLabel: "Remove Album",
            perform: perform
        )
    }

    static func playlist(
        _ playlist: PlaylistSummary,
        perform: @escaping @MainActor () async -> Void
    ) -> LibraryRemovalRequest {
        let scale = playlist.songCount.map { "The playlist and its \(songCount($0))" }
            ?? "The playlist and its songs"
        return LibraryRemovalRequest(
            title: "Remove \(quoted(playlist.name)) from Your Library?",
            message: "\(scale) stay on the server — only your library changes.",
            confirmLabel: "Remove Playlist",
            perform: perform
        )
    }

    // MARK: - Playlist contents (neither a library removal nor a server delete)

    /// Removing selected rows from one existing playlist.
    ///
    /// The message states all three things the songs survive, because they demonstrably do:
    /// `AppModel.removePlaylistRows` reaches only the backend's playlist-mutation endpoint and
    /// never touches `librarySongIds`, `libraryAlbumEntries`, `libraryPlaylistEntries` or the
    /// membership payload. Saying "removed from your library" here would be false, and a
    /// confirmation the user learns is overstated is one they learn to dismiss — which costs us
    /// the two dialogs above, where the warning is real.
    ///
    /// What it does *not* soften: the write is committed the moment the user confirms, not on
    /// Done, and there is no undo. Both are said plainly.
    static func playlistRows(
        playlistName: String,
        count: Int,
        perform: @escaping @MainActor () async -> Void
    ) -> LibraryRemovalRequest {
        LibraryRemovalRequest(
            title: "Remove \(songCount(count)) from \(quoted(playlistName))?",
            message: "\(count == 1 ? "It stays" : "They stay") in Your Library, on the server, and "
                + "in any other playlist. This playlist changes for everyone who can see it, and "
                + "the removal can’t be undone.",
            confirmLabel: "Remove \(songCount(count))",
            perform: perform
        )
    }

    /// Deliberately count-agnostic, so the same sentence is correct after "1 song" and after
    /// "14 songs" — and so no library removal ever borrows a word from the server copy below.
    private static let libraryReachSentence =
        "Nothing is deleted from the server — only your library changes."

    // MARK: - Server deletes (a different act, deliberately worded nothing like the above)

    static func serverTrackDelete(
        _ track: Track,
        perform: @escaping @MainActor () async -> Void
    ) -> LibraryRemovalRequest {
        LibraryRemovalRequest(
            title: "Delete \(quoted(track.title)) from the server?",
            message: "1 song\(byArtist(track.artist)), deleted from the server library for everyone. "
                + "Depending on your server’s settings the file on disk may be deleted too. "
                + "This can’t be undone.",
            confirmLabel: "Delete from Server",
            perform: perform
        )
    }

    static func serverPlaylistDelete(
        name: String,
        songCount: Int?,
        perform: @escaping @MainActor () async -> Void
    ) -> LibraryRemovalRequest {
        let scale = songCount.map { count in
            "Its \(self.songCount(count)) \(count == 1 ? "is" : "are") not deleted."
        } ?? "The songs in it are not deleted."
        return LibraryRemovalRequest(
            title: "Delete \(quoted(name)) from the server?",
            message: "The playlist is deleted for everyone on the server. \(scale) This can’t be undone.",
            confirmLabel: "Delete Playlist",
            perform: perform
        )
    }
}

/// The alert itself, driven by whichever binding owns the pending request.
///
/// Deliberately binding-based rather than reaching into ``AppModel``: a view presented inside a
/// `.sheet` cannot rely on the root's alert host — UIKit already has a presented controller there,
/// so a root-level alert raised from inside a sheet resolves to nothing. Such a view owns its own
/// `@State` request and applies this directly, and still gets its wording from
/// ``LibraryRemovalCopy`` so nothing drifts.
private struct LibraryRemovalAlert: ViewModifier {
    @Binding var request: LibraryRemovalRequest?

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: Binding(
                get: { request != nil },
                set: { presented in
                    if !presented { request = nil }
                }
            ),
            presenting: request,
            actions: { pending in
                Button(pending.confirmLabel, role: .destructive) {
                    request = nil
                    Task { await pending.perform() }
                }
                Button("Cancel", role: .cancel) {
                    request = nil
                }
            },
            message: { pending in
                Text(pending.message)
            }
        )
    }
}

/// App-wide presenter for ``AppModel/pendingLibraryRemoval``.
///
/// Applied at the app root **and** on the Now Playing cover: the cover is a UIKit presentation
/// that occludes the root's alert host, so a removal started from the player's ⋯ menu would
/// otherwise resolve to nothing at all (the same occlusion the toast chrome works around).
private struct AppLibraryRemovalChrome: ViewModifier {
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        content.modifier(LibraryRemovalAlert(request: $app.pendingLibraryRemoval))
    }
}

extension View {
    /// Hosts the app-wide removal confirmation. Only the app root and the Now Playing cover apply
    /// this — anywhere else and two alerts race for the same presentation host.
    func libraryRemovalConfirmationChrome() -> some View {
        modifier(AppLibraryRemovalChrome())
    }
}

extension View {
    /// Hosts a removal confirmation owned by this view, for screens the app-wide host cannot
    /// reach — today, anything inside a `.sheet`.
    func libraryRemovalConfirmation(request: Binding<LibraryRemovalRequest?>) -> some View {
        modifier(LibraryRemovalAlert(request: request))
    }
}
