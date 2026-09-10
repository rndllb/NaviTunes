import Foundation

/// Whether becoming active should raise the Now Playing cover.
///
/// **What this works around, stated precisely.** Tapping the artwork in the system Now Playing
/// control *does* launch the owning app — that part works. What iOS does not provide is any
/// signal saying *why* the app was foregrounded: no URL, no `NSUserActivity`, no launch reason,
/// and tapping artwork is not a `MPRemoteCommandCenter` command. So the tap is indistinguishable
/// from tapping the home-screen icon, returning through the app switcher, or coming back from a
/// notification.
///
/// That makes any implementation a heuristic over "became active", not a handler for that tap.
/// This one trades false positives for covering the case: every foreground while audio is
/// playing raises the player, including the ones the user did not mean.
///
/// Pulled out as a pure function so the policy is testable and so the false-positive set is
/// written down somewhere other than a commit message.
enum NowPlayingAutoPresent {
    static func shouldPresentOnBecomingActive(
        isPlaying: Bool,
        hasActiveTrack: Bool,
        isAlreadyPresented: Bool,
    ) -> Bool {
        // Already up: raising it again is the same no-op the widget deep link guards against,
        // and re-entering the cover-zoom transition while it is showing has no upside.
        guard !isAlreadyPresented else { return false }
        // Nothing loaded means nothing to show — the player would open blank and have to be
        // dismissed, which is worse than not opening.
        guard hasActiveTrack else { return false }
        // Paused counts as not playing. A user returning to a paused app is far more likely to
        // be resuming what they were doing than asking for the player, and the system control's
        // artwork tap is only reachable while there is something to control.
        return isPlaying
    }
}
