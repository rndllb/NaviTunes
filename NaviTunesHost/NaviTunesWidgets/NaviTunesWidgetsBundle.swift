import WidgetKit
import SwiftUI

@main
struct NaviTunesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NaviTunesRecentlyPlayedWidget()
        NaviTunesNowPlayingWidget()
    }
}
