import SwiftUI
#if canImport(UIKit)
import UIKit

/// Presents ``AddToPlaylistSheet`` as a UIKit sheet above the Now Playing
/// `fullScreenCover`. Any SwiftUI `.sheet` in the cover's view tree breaks the
/// mini-player `.navigationTransition(.zoom)` morph, so the over-player path must
/// stay outside SwiftUI's presentation chain.
@MainActor
final class OverPlayerSheetPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = OverPlayerSheetPresenter()

    private weak var hosting: UIViewController?
    private var presentedPayloadId: UUID?

    func present(payload: PlaylistPickerPayload, app: AppModel) {
        if presentedPayloadId == payload.id, hosting != nil { return }
        if hosting != nil { dismiss(animated: false) }

        guard let top = Self.topMostViewController() else { return }
        let root = AddToPlaylistSheet(tracks: payload.tracks)
            .environmentObject(app)
            .environmentObject(app.offline)
            .environmentObject(app.acquisition)
            .environmentObject(app.subscriptions)
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .pageSheet
        host.presentationController?.delegate = self
        hosting = host
        presentedPayloadId = payload.id
        top.present(host, animated: true)
    }

    func dismiss(animated: Bool = true) {
        presentedPayloadId = nil
        guard let hosting else { return }
        self.hosting = nil
        hosting.dismiss(animated: animated)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        hosting = nil
        presentedPayloadId = nil
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
