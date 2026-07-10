import SwiftUI

/// Three animated vertical bars shown in place of a track number (or overlaid on artwork)
/// to indicate the currently playing song. Bars animate while playback is active and
/// freeze at resting heights when paused.
struct NowPlayingBarsIndicator: View {
    @ObservedObject var player: PlaybackEngine
    var color: Color = Color.accentColor

    @State private var h1: CGFloat = 4
    @State private var h2: CGFloat = 8
    @State private var h3: CGFloat = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            bar(height: h1)
            bar(height: h2)
            bar(height: h3)
        }
        .frame(width: 10, height: 11)
        // Buffering means no audio is flowing — freeze the bars so the row
        // doesn't claim active playback during a stall.
        .onChange(of: player.isPlaying && !player.isBuffering, initial: true) { _, playing in
            if playing {
                withAnimation(.easeInOut(duration: 0.50).repeatForever(autoreverses: true)) { h1 = 11 }
                withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) { h2 = 5 }
                withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) { h3 = 10 }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    h1 = 4; h2 = 7; h3 = 5
                }
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2.5, height: height)
    }
}
