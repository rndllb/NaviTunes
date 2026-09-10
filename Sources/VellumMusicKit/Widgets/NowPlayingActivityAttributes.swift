#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Shape of the playback Live Activity: the Lock Screen banner and the Dynamic Island.
///
/// Shared deliberately. The app starts and updates the activity, the VellumWidgets extension
/// draws it, and both need the same `ContentState` — so it lives here in the kit rather than in
/// either target, the same arrangement `WidgetDataStore` already uses.
///
/// A Live Activity is **not** WidgetKit. It has no timeline, no provider and no reload: the app
/// pushes each state change over ActivityKit. That is why the Dynamic Island could never be
/// fixed by anything done to a `TimelineProvider` or a `widgetURL` on a home-screen widget.
public struct NowPlayingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var isPlaying: Bool

        /// Key into the App Group artwork cache (``WidgetDataStore/cachedArtworkData(for:)``).
        ///
        /// The activity's views cannot fetch over the network, so they read the file the app has
        /// already written for the home-screen widgets. Passing the id rather than the bytes also
        /// keeps the state payload small, which matters: ActivityKit caps how much you may send.
        public var artworkItemId: String?

        public init(title: String, artist: String, isPlaying: Bool, artworkItemId: String?) {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.artworkItemId = artworkItemId
        }
    }

    public init() {}
}
#endif
