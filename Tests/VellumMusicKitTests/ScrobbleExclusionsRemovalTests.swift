import Foundation
import Testing

@testable import VellumMusicKit

/// #7: the unfinished Exclusions feature is gone. Its stored list is deleted on launch, so a
/// track from a once-excluded album is scrobbled like any other, and a backup file written while
/// the feature existed still restores.
@Suite("Listening History without Exclusions (#7)", .serialized)
@MainActor
struct ScrobbleExclusionsRemovalTests {
    static let legacyKey = "vellumScrobbleExclusions"

    @Test("the stored exclusion list is deleted when the store loads")
    func legacyListIsDeleted() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Self.legacyKey)
        defer { if let saved { defaults.set(saved, forKey: Self.legacyKey) } else { defaults.removeObject(forKey: Self.legacyKey) } }
        let legacy = #"[{"id":"al-1","kind":"album","name":"Turn On The Bright Lights"}]"#
        defaults.set(Data(legacy.utf8), forKey: Self.legacyKey)

        _ = ScrobbleStore()

        #expect(defaults.object(forKey: Self.legacyKey) == nil)
    }

    @Test("a backup written with exclusions still decodes, and its scrobbles are kept")
    func oldBackupStillDecodes() throws {
        let old = """
        {
          "completedScrobbles" : [ { "artist" : "Interpol", "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF", "timestamp" : "2026-10-01T12:00:00Z", "title" : "Untitled", "trackId" : "t-1" } ],
          "meta" : { "completedScrobbleCount" : 1, "createdAt" : "2026-10-02T12:00:00Z", "exclusionCount" : 1, "version" : 1 },
          "scrobbleExclusions" : [ { "id" : "al-1", "kind" : "album", "name" : "Turn On The Bright Lights" } ]
        }
        """
        let payload = try VellumClientBackupService.decode(Data(old.utf8))
        #expect(payload.completedScrobbles.map(\.trackId) == ["t-1"])
    }
}
