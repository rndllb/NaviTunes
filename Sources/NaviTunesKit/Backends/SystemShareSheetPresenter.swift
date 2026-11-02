import Foundation
#if canImport(UIKit)
import UIKit

/// Presents the stock system share sheet for a URL that only exists after an `async` round-trip.
///
/// SwiftUI's `ShareLink` is the right tool wherever the item is known at view-build time, and it
/// is what the shares list and the plain title/artist shares already use. It cannot serve the
/// share-creation path: those call sites are `contextMenu` buttons, and the URL is produced by a
/// server request made *after* the tap. This wraps `UIActivityViewController` — the same thing
/// `ShareLink` builds — so the created link lands in a real share sheet instead of silently on
/// the pasteboard.
///
/// Presented from the top-most view controller, matching ``OverPlayerSheetPresenter``, so it also
/// works when the Now Playing `fullScreenCover` is up.
@MainActor
enum SystemShareSheetPresenter {
    /// - Returns: `true` when the sheet was presented; `false` when no presenter could be found,
    ///   which is the caller's cue to fall back to the pasteboard rather than drop the link.
    @discardableResult
    static func present(url: URL) -> Bool {
        // `topMostViewController` walks to the deepest presented controller, so this is the one
        // thing on screen with nothing already over it.
        guard let top = topMostViewController() else { return false }

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad has no automatic anchor for a sheet presented outside a view's own action, so
        // give the popover the presenter's own centre rather than letting it assert.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX,
                y: top.view.bounds.midY,
                width: 0,
                height: 0,
            )
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
        return true
    }

    private static func topMostViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
