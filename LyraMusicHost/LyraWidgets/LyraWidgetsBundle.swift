import WidgetKit
import SwiftUI

@main
struct LyraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LyraRecentlyPlayedWidget()
        LyraNowPlayingWidget()
    }
}
