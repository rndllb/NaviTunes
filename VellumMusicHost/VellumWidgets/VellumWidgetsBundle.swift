import WidgetKit
import SwiftUI

@main
struct VellumWidgetsBundle: WidgetBundle {
    var body: some Widget {
        VellumRecentlyPlayedWidget()
        VellumNowPlayingWidget()
    }
}
