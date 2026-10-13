import SwiftUI

/// Two strings crossfading in half a second when the incoming song takes over.
/// With Reduce Motion the incoming string appears immediately with no animation. The target
/// flips when the incoming song first becomes audible (overlap start).
/// `incoming == nil` renders `outgoing` alone (no blend in progress).
struct AutoMixCrossfadeText: View {
    let outgoing: String
    let incoming: String?
    /// Visual target: 0 before the audio midpoint, 1 after it.
    let progress: Double
    let reduceMotion: Bool

    /// Opacity of the incoming string; the outgoing one gets the complement.
    static func incomingOpacity(progress: Double, reduceMotion: Bool) -> Double {
        let p = min(1, max(0, progress))
        if reduceMotion { return p > 0 ? 1 : 0 }
        return sin(p * .pi / 2)
    }

    var body: some View {
        if let incoming {
            let p = Self.incomingOpacity(progress: progress, reduceMotion: reduceMotion)
            ZStack(alignment: .leading) {
                Text(outgoing).opacity(1 - p)
                Text(incoming).opacity(p)
            }
            .animation(reduceMotion ? nil : .linear(duration: AutoMixVisualState.crossfadeDuration), value: progress)
        } else {
            Text(outgoing)
        }
    }
}

/// The cover's drop shadow (T681).
struct AutoMixCoverShadow: Equatable {
    var color: Color
    var radius: CGFloat
    var y: CGFloat
}

/// The cover during a blend: the base cover, the outgoing cover held on top of it, and the
/// incoming cover fading in over half a second when the incoming song takes over. Outside a
/// blend just the base. Generic over the artwork views so a test can render it with plain
/// shapes and measure its shadow (T681).
///
/// The drop shadow is cast by the base cover alone, *before* the blend layers are laid over
/// it, so it is the same view's shadow before, during and after a blend by construction.
/// `.shadow` on the finished stack was the owner's "drop shadow gets bigger during the
/// transition": it draws one shadow per layer, and the three added up (measured: extent 48 →
/// 56 pt, darkest row 0.69 → 0.33 luminance). Flattening the stack first (`compositingGroup`)
/// removed the stacking but still left the shadow 5 % denser whenever the overlay existed,
/// even with the overlay fully transparent — the renderer's group path, not the layers — so
/// the shadow is simply not computed from the stack at all.
struct AutoMixCoverCrossfade<Base: View, Outgoing: View, Incoming: View>: View {
    let isBlending: Bool
    /// Visual target: 0 before the incoming song is audible, 1 after.
    let progress: Double
    let reduceMotion: Bool
    var shadow: AutoMixCoverShadow? = nil
    @ViewBuilder let base: () -> Base
    @ViewBuilder let outgoing: () -> Outgoing
    @ViewBuilder let incoming: () -> Incoming

    /// Opacity of the incoming cover; the outgoing one stays opaque underneath it, so the cover
    /// never jumps at the promotion whichever side the queue cursor is on.
    static func incomingOpacity(progress: Double, reduceMotion: Bool) -> Double {
        AutoMixCrossfadeText.incomingOpacity(progress: progress, reduceMotion: reduceMotion)
    }

    var body: some View {
        shadowed(base())
            .overlay {
                if isBlending {
                    outgoing()
                        .allowsHitTesting(false)
                    incoming()
                        .opacity(Self.incomingOpacity(progress: progress, reduceMotion: reduceMotion))
                        .animation(reduceMotion ? nil : .linear(duration: AutoMixVisualState.crossfadeDuration), value: progress)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func shadowed(_ view: Base) -> some View {
        if let shadow {
            view.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
        } else {
            view
        }
    }
}
