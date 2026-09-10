#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// Owns the lifetime of the playback Live Activity — the Dynamic Island presence and the Lock
/// Screen banner.
///
/// Driven from ``AppModel/writeWidgetData()``, which is already the one funnel every playback
/// change runs through (track change and play/pause both land there), so the activity cannot
/// drift out of step with the home-screen widgets.
///
/// Distinct from the system Now Playing control that `MPNowPlayingInfoCenter` drives. That one is
/// Apple's, appears on its own, and hands the app nothing when tapped. This one is ours, and its
/// tap carries `vellum://nowplaying`.
@MainActor
public enum NowPlayingLiveActivityController {
    private static var activity: Activity<NowPlayingActivityAttributes>?

    /// Reattaches to an activity that outlived the process. Live Activities survive app
    /// termination, so without this a relaunch would leave one stranded on the Lock Screen with
    /// no way to update or end it, and `start` would raise a second alongside it.
    public static func adoptExistingActivity() {
        guard activity == nil else { return }
        activity = Activity<NowPlayingActivityAttributes>.activities.first
    }

    /// Starts, updates, or ends the activity to match the current state. Passing `nil` for
    /// `title` means nothing is loaded, which ends it.
    public static func sync(title: String?, artist: String, isPlaying: Bool, artworkItemId: String?) {
        guard let title, !title.isEmpty else {
            end()
            return
        }
        let state = NowPlayingActivityAttributes.ContentState(
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            artworkItemId: artworkItemId,
        )
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        // The user can switch Live Activities off for the app in Settings, and asking anyway
        // throws every time playback starts.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: NowPlayingActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil,
        )
    }

    /// Ends the activity immediately rather than letting it linger in the default dismissal
    /// window — a music activity for a track that stopped is stale the moment it stops.
    public static func end() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
