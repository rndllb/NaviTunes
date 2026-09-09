import SwiftUI
#if canImport(UIKit)
import UIKit

/// UIKit anchor for the mini-player zoom source.
///
/// Vestigial: the player's transition is now `CoverZoomAnimator`, which takes its origin rect
/// from the `coverZoomCellAnchor` on the pill's artwork instead. This stays because the
/// accessory still marks itself as a `matchedTransitionSource`, and a concrete view is cheaper
/// to keep than to re-derive if the system pairing is ever wanted again.
@MainActor
enum MiniPlayerZoomSourceRegistry {
    weak static var sourceView: UIView?
}

struct MiniPlayerZoomSourceAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        MiniPlayerZoomSourceRegistry.sourceView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        MiniPlayerZoomSourceRegistry.sourceView = uiView
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        if MiniPlayerZoomSourceRegistry.sourceView === uiView {
            MiniPlayerZoomSourceRegistry.sourceView = nil
        }
    }
}

#endif
