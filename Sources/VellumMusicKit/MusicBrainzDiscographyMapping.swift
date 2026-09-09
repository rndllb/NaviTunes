import Foundation

extension MusicBrainzReleaseGroup {
    /// Cover Art Archive front cover for this release group.
    ///
    /// A different host from the MusicBrainz web service, with its own (far looser) limits, so
    /// artwork does not consume the one-request-per-second budget. Groups with no uploaded art
    /// answer 404, which ``AlbumArtworkView`` already handles by falling back to its mesh tile.
    var coverArtURL: URL? {
        URL(string: "https://coverartarchive.org/release-group/\(id)/front-500")
    }

    /// This release group as the app's backend-agnostic release row.
    ///
    /// Mapping into ``AcquisitionRelease`` rather than introducing a parallel model is what
    /// keeps the discography UI, the context menus and the request flow untouched: the cards
    /// cannot tell where a release came from, and the acquisition request already carries both
    /// MBIDs, so a request built from one of these reaches the plugin fully identified.
    ///
    /// `nativeAlbumId` stays nil on purpose — there is no plugin-side id here. Track lookups
    /// fall through to the plugin's release-group-MBID path, which is the same id
    /// MusicBrainz gave us.
    func asAcquisitionRelease(
        artist: String,
        artistMBID: String?,
        artistArtworkURL: URL? = nil,
        artistOverview: String? = nil
    ) -> AcquisitionRelease {
        AcquisitionRelease(
            id: id,
            title: title,
            artist: artist,
            // The row's own credit, which for a browsed discography is the only place the other
            // credited artists appear at all — the browse query knows one artist, the one being
            // browsed, and passing that down as the label is what erases a collaborator.
            artistCreditLine: artistCredit?.creditLine,
            releaseDate: releaseDate,
            artworkURL: coverArtURL,
            albumType: primaryType,
            secondaryTypes: secondaryTypes ?? [],
            trackCount: nil,
            releaseGroupMBID: id,
            artistMBID: artistMBID,
            nativeAlbumId: nil,
            overview: nil,
            artistOverview: artistOverview,
            artistArtworkURL: artistArtworkURL,
            monitored: false,
            wanted: false
        )
    }
}

extension MusicBrainzReleaseGroup {
    /// The **primary** credited artist's name for a search row — a name, not a credit line.
    ///
    /// This is a matching key, not a label: it keys `seenReleaseKeys` and `serverAlbumsByReleaseKey`
    /// against the server's own album artist, and it becomes `AcquisitionRequest.artist`. It used
    /// to be ``searchRowCreditLine``, which is the string `AcquisitionRelease` documents must never
    /// go here — a two-artist credit matches no server album and is not an artist any lookup can
    /// resolve. The credit is still rendered; it travels in ``AcquisitionResult/artistCreditLine``.
    ///
    /// Falls back to the credit line only when the payload carries no artist object at all, which
    /// is worse than a name and better than an empty row.
    var searchRowArtist: String { artistCredit?.primaryArtistName ?? searchRowCreditLine }

    /// The full credited line for a search row ("Rich Brian feat. Charlotte Day Wilson & DAISY
    /// WORLD"). A browsed discography has none — the artist is the thing being browsed.
    var searchRowCreditLine: String { artistCredit?.creditLine ?? "" }

    /// This search row as an enqueue-able request candidate.
    ///
    /// Routes through the same ``AcquisitionRelease`` the plugin discography produces, so an
    /// album found by searching MusicBrainz reaches ``AcquireResultDetailView`` and the request
    /// flow with no new view and no new model. The request carries both MBIDs, so whichever
    /// plugin is active receives a fully-identified release rather than a name to guess at.
    var asSearchAcquisitionRelease: AcquisitionRelease {
        asAcquisitionRelease(
            artist: searchRowArtist,
            artistMBID: artistCredit?.primaryArtistMBID
        )
    }
}

extension MusicBrainzSongRow {
    /// Cover art for the song, taken from its parent release group.
    ///
    /// Cover Art Archive is keyed by release group, not by recording, so a song with no
    /// resolvable parent release has no artwork — ``AlbumArtworkView`` falls back to its
    /// placeholder, which is the same treatment a server track with no cover gets.
    var coverArtURL: URL? {
        guard let groupId = recording.releaseGroupMBID else { return nil }
        return URL(string: "https://coverartarchive.org/release-group/\(groupId)/front-500")
    }

    /// This song as an enqueue-able request candidate.
    ///
    /// `trackTitle` is set, which is what tells a track-granularity plugin (Downtify) to fetch
    /// this one song. Album-granularity plugins (Lidarr, DroppedNeedle) ignore it and act on
    /// `releaseGroupMBID` / `albumTitle` instead — requesting the parent release, which is the
    /// only thing they can do and is already how missing-track rows behave elsewhere in the app.
    var asAcquisitionResult: AcquisitionResult {
        let credit = recording.artistCredit
        let artistName = credit?.primaryArtistName ?? artist
        return AcquisitionResult(
            id: recording.id,
            title: recording.title,
            // The primary credited artist, not ``artist`` — which is the credit line and was
            // being handed to "Go to Artist" as though it were somebody's name.
            artists: artistName.isEmpty ? [] : [artistName],
            albumName: albumTitle ?? "",
            coverURL: coverArtURL,
            year: recording.releaseYear,
            explicit: false,
            subtitle: nil,
            kindLabel: "Song",
            request: AcquisitionRequest(
                artist: artistName,
                trackTitle: recording.title,
                albumTitle: albumTitle,
                artistMBID: credit?.primaryArtistMBID,
                releaseGroupMBID: recording.releaseGroupMBID,
                coverURL: coverArtURL
            ),
            // ``artist`` is the credit line. It is still what the reader sees — it just no longer
            // pretends to be a name.
            artistCreditLine: artist
        )
    }
}

extension MusicBrainzDiscography {
    /// The whole discography as release rows.
    func asAcquisitionReleases(
        artist: String,
        artistArtworkURL: URL? = nil,
        artistOverview: String? = nil
    ) -> [AcquisitionRelease] {
        releaseGroups.map {
            $0.asAcquisitionRelease(
                artist: artist,
                artistMBID: artistMBID,
                artistArtworkURL: artistArtworkURL,
                artistOverview: artistOverview
            )
        }
    }
}
