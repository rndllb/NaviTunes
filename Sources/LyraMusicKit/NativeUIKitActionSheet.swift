import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum DownloadedLibraryItemKind {
    case album
    case song

    var confirmationTitle: String {
        switch self {
        case .album:
            return "Do you want to remove this album from your downloads or delete it from your library?"
        case .song:
            return "Do you want to remove this song from your downloads or delete it from your library?"
        }
    }
}

/// Presents the **system** downloaded-library action sheet (`UIAlertController`, `.actionSheet`).
/// On current iOS versions a long title is laid out as a centered card by UIKit — no custom chrome.
struct DownloadedAlbumActionPresentation: ViewModifier {
    @Binding var isPresented: Bool
    var itemKind: DownloadedLibraryItemKind = .album
    let onRemoveDownload: () -> Void
    let onDeleteFromLibrary: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.background {
            NativeUIAlertActionSheetBridge(
                isPresented: $isPresented,
                title: itemKind.confirmationTitle,
                onRemoveDownload: onRemoveDownload,
                onDeleteFromLibrary: onDeleteFromLibrary,
            )
            .frame(width: 0, height: 0)
        }
        #else
        content
            .confirmationDialog(itemKind.confirmationTitle, isPresented: $isPresented, titleVisibility: .visible) {
                Button("Only Remove Download", action: onRemoveDownload)
                Button("Delete from Library", role: .destructive, action: onDeleteFromLibrary)
                Button("Cancel", role: .cancel) {}
            }
        #endif
    }
}

extension View {
    /// Presents the downloaded-song delete sheet from the screen root (reliable inside `List` rows).
    func downloadedTrackDeleteSheet(
        track: Binding<Track?>,
        app: AppModel,
        offline: OfflineDownloadManager
    ) -> some View {
        modifier(
            DownloadedAlbumActionPresentation(
                isPresented: Binding(
                    get: { track.wrappedValue != nil },
                    set: { isPresented in
                        if !isPresented { track.wrappedValue = nil }
                    }
                ),
                itemKind: .song,
                onRemoveDownload: {
                    guard let id = track.wrappedValue?.id else { return }
                    try? offline.remove(trackId: id)
                    track.wrappedValue = nil
                },
                onDeleteFromLibrary: {
                    guard let pending = track.wrappedValue else { return }
                    let trackToRemove = pending
                    Task { @MainActor in
                        try? offline.remove(trackId: trackToRemove.id)
                        await app.removeSongFromLibrary(trackToRemove)
                        track.wrappedValue = nil
                    }
                },
            )
        )
    }
}

#if os(iOS)
/// Presents `UIAlertController` from the key window — the only UI; no custom views or glass.
struct NativeUIAlertActionSheetBridge: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let onRemoveDownload: () -> Void
    let onDeleteFromLibrary: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        if isPresented {
            guard context.coordinator.alert == nil else { return }
            Task { @MainActor in
                guard self.isPresented, context.coordinator.alert == nil else { return }
                context.coordinator.present(from: host)
            }
        } else {
            Task { @MainActor in
                context.coordinator.dismiss(animated: true)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var parent: NativeUIAlertActionSheetBridge
        weak var alert: UIAlertController?

        init(parent: NativeUIAlertActionSheetBridge) {
            self.parent = parent
        }

        func present(from host: UIViewController) {
            guard let presenter = Self.topPresenter(anchoredTo: host) else { return }

            let sheet = UIAlertController(
                title: parent.title,
                message: nil,
                preferredStyle: .actionSheet,
            )

            sheet.addAction(
                UIAlertAction(title: "Only Remove Download", style: .default) { [weak self] _ in
                    self?.finish(dismissAnimated: true) {
                        self?.parent.onRemoveDownload()
                    }
                },
            )
            sheet.addAction(
                UIAlertAction(title: "Delete from Library", style: .destructive) { [weak self] _ in
                    self?.finish(dismissAnimated: true) {
                        self?.parent.onDeleteFromLibrary()
                    }
                },
            )
            sheet.addAction(
                UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.finish(dismissAnimated: true)
                },
            )

            if presenter.traitCollection.userInterfaceIdiom == .pad,
               let popover = sheet.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 0,
                    height: 0,
                )
                popover.permittedArrowDirections = []
            }

            sheet.presentationController?.delegate = self
            alert = sheet
            presenter.present(sheet, animated: true)
        }

        func dismiss(animated: Bool) {
            guard let alert else { return }
            alert.dismiss(animated: animated) { [weak self] in
                self?.alert = nil
            }
        }

        private func finish(dismissAnimated: Bool, action: (() -> Void)? = nil) {
            action?()
            parent.isPresented = false
            if dismissAnimated {
                dismiss(animated: true)
            } else {
                alert = nil
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            parent.isPresented = false
            alert = nil
        }

        private static func topPresenter(anchoredTo host: UIViewController) -> UIViewController? {
            if let window = host.view.window, let root = window.rootViewController {
                return topMost(from: root)
            }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                guard let window = windowScene.windows.first(where: \.isKeyWindow),
                      let root = window.rootViewController
                else { continue }
                return topMost(from: root)
            }
            return topMost(from: host)
        }

        private static func topMost(from root: UIViewController) -> UIViewController {
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
    }
}
#endif
