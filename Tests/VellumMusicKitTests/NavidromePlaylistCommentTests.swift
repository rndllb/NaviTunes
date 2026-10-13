import Foundation
import Testing

@testable import VellumMusicKit

/// T643 c4. The edit sheet's Description field used to be dropped on Save (T638 issue 3). The
/// Subsonic `updatePlaylist` request now carries the comment, and `PlaylistSummary` carries the
/// current one so the field opens populated. Navidrome imposes no length limit, so none is added.
@Suite("Navidrome playlist comment")
struct NavidromePlaylistCommentTests {
    @Test("name, comment and visibility all travel on one updatePlaylist request")
    func fullUpdate() {
        let query = NavidromeClient.updatePlaylistQuery(playlistId: "pl1", name: "indiepunk", comment: "late nights", isPublic: false)
        #expect(query == [
            "playlistId": "pl1",
            "name": "indiepunk",
            "comment": "late nights",
            "public": "false",
        ])
    }

    @Test("a nil comment leaves the server's comment alone (the parameter is omitted, not blanked)")
    func nilCommentOmitted() {
        let query = NavidromeClient.updatePlaylistQuery(playlistId: "pl1", name: "indiepunk", comment: nil, isPublic: nil)
        #expect(query == ["playlistId": "pl1", "name": "indiepunk"])
    }

    @Test("an empty comment is sent as empty, so the user can clear a description")
    func emptyCommentClears() {
        let query = NavidromeClient.updatePlaylistQuery(playlistId: "pl1", name: "indiepunk", comment: "", isPublic: nil)
        #expect(query["comment"] == "")
    }

    @Test("no length limit: a 10,000-character comment is passed through untouched")
    func noLengthLimit() {
        let long = String(repeating: "x", count: 10_000)
        let query = NavidromeClient.updatePlaylistQuery(playlistId: "pl1", name: "n", comment: long, isPublic: nil)
        #expect(query["comment"]?.count == 10_000)
    }

    @Test("a snapshot written before the comment field existed still decodes, with no comment")
    func decodesWithoutCommentKey() throws {
        let json = """
        {"id":"pl1","name":"indiepunk","songCount":82,"artworkURL":null,"coverArtId":null,"isPublic":false,"libraryAddedDate":null,"serverUpdatedDate":null}
        """
        let summary = try JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
        #expect(summary.name == "indiepunk")
        #expect(summary.comment == nil)
    }

    @Test("the comment round-trips through the snapshot")
    func commentRoundTrips() throws {
        let original = PlaylistSummary(id: "pl1", name: "n", comment: "late nights")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaylistSummary.self, from: data)
        #expect(decoded.comment == "late nights")
        #expect(decoded == original)
    }
}
