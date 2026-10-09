import SwiftUI

/// Two strings crossfading on AutoMix's equal-power curve, so the name changes at the same pace as
/// the sound. With Reduce Motion the incoming string appears at the midpoint with no animation.
/// `incoming == nil` renders `outgoing` alone (no blend in progress).
struct AutoMixCrossfadeText: View {
    let outgoing: String
    let incoming: String?
    /// 0…1 through the audible overlap.
    let progress: Double
    let reduceMotion: Bool

    /// Opacity of the incoming string; the outgoing one gets the complement.
    static func incomingOpacity(progress: Double, reduceMotion: Bool) -> Double {
        let p = min(1, max(0, progress))
        if reduceMotion { return p >= 0.5 ? 1 : 0 }
        return sin(p * .pi / 2)
    }

    var body: some View {
        if let incoming {
            let p = Self.incomingOpacity(progress: progress, reduceMotion: reduceMotion)
            ZStack(alignment: .leading) {
                Text(outgoing).opacity(1 - p)
                Text(incoming).opacity(p)
            }
            .animation(reduceMotion ? nil : .linear(duration: 0.35), value: progress)
        } else {
            Text(outgoing)
        }
    }
}
