import Testing

@testable import VellumMusicKit

/// The policy behind answering a system Now Playing artwork tap.
///
/// The tap launches the app; iOS supplies no reason for the launch, so this fires on *every*
/// foreground while audio plays. These tests pin both halves — the case it exists to cover, and
/// the false positives it knowingly accepts — so the trade is visible rather than folded into a
/// commit message.
@Suite("NowPlayingAutoPresent")
struct NowPlayingAutoPresentTests {
    private static func shouldPresent(
        playing: Bool = true,
        hasTrack: Bool = true,
        presented: Bool = false,
    ) -> Bool {
        NowPlayingAutoPresent.shouldPresentOnBecomingActive(
            isPlaying: playing,
            hasActiveTrack: hasTrack,
            isAlreadyPresented: presented,
        )
    }

    // MARK: - The case it exists for

    @Test("foregrounding while a track plays raises the player")
    func playingRaisesPlayer() {
        #expect(Self.shouldPresent())
    }

    // MARK: - The guards

    /// Same reasoning as the widget deep link: already open means the tap has nothing to ask for.
    @Test("already showing the player does nothing")
    func alreadyPresented() {
        #expect(Self.shouldPresent(presented: true) == false)
    }

    /// Opening a blank player the user then has to dismiss is worse than not opening.
    @Test("nothing loaded does nothing")
    func noTrack() {
        #expect(Self.shouldPresent(hasTrack: false) == false)
        #expect(Self.shouldPresent(playing: false, hasTrack: false) == false)
    }

    /// Returning to a paused app is far more likely to be resuming what you were doing.
    @Test("paused does nothing")
    func paused() {
        #expect(Self.shouldPresent(playing: false) == false)
    }

    /// The guards are independent — any one of them is enough to decline.
    @Test(
        "every combination resolves the same way",
        arguments: [
            (true, true, false, true),    // playing, loaded, closed  -> present
            (true, true, true, false),    // already open
            (false, true, false, false),  // paused
            (true, false, false, false),  // nothing loaded
            (false, false, true, false),  // nothing true
        ],
    )
    func truthTable(playing: Bool, hasTrack: Bool, presented: Bool, expected: Bool) {
        #expect(Self.shouldPresent(playing: playing, hasTrack: hasTrack, presented: presented) == expected)
    }

    // MARK: - The false positives, pinned deliberately

    /// **This is the cost, not a bug.** With audio playing, these foregrounds are
    /// indistinguishable from the artwork tap, so they raise the player too:
    /// returning via the app switcher, tapping the home-screen icon, dismissing a notification.
    ///
    /// Written as a test so the trade is discoverable from the suite. If a way to attribute the
    /// launch ever appears, this expectation should flip and the policy should narrow.
    @Test("any foreground while playing presents — the launch reason is not knowable")
    func falsePositivesAreAccepted() {
        // Every one of these is the same call, because nothing distinguishes them at runtime.
        let appSwitcherReturn = Self.shouldPresent()
        let homeScreenIconTap = Self.shouldPresent()
        let notificationDismiss = Self.shouldPresent()
        let nowPlayingArtworkTap = Self.shouldPresent()
        #expect(appSwitcherReturn == nowPlayingArtworkTap)
        #expect(homeScreenIconTap == nowPlayingArtworkTap)
        #expect(notificationDismiss == nowPlayingArtworkTap)
    }
}
