import WidgetKit
import SwiftUI

@main
struct VellumWidgetsBundle: WidgetBundle {
    var body: some Widget {
        VellumRecentlyPlayedWidget()
        VellumNowPlayingWidget()
        // Lock Screen banner + Dynamic Island. A Live Activity, not a WidgetKit timeline —
        // it ships in this bundle but shares nothing with the two above.
        VellumNowPlayingLiveActivity()
    }
}
