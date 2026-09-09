import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the downloaded-item sheet is being asked about.
///
/// The associated values are not decoration: this sheet is the confirmation for its
/// "Delete from Library" action, so it has to name the thing and state how many songs go with
/// it. A title that reads "this album" is exactly the generic are-you-sure that lets a
/// fourteen-track removal look like a one-track one.
enum DownloadedLibraryItemKind {
    case album(name: String, songCount: Int?)
    case song(title: String, artist: String)
    case playlist(name: String, songCount: Int?)
    /// A bulk set that is not one album — today, the Favorites screen's "download / library" sheet.
    case songs(sourceName: String, songCount: Int)

    private static func quoted(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this item" : "“\(trimmed)”"
    }

    private static func scale(_ count: Int?) -> String {
        count.map { " (\(LibraryRemovalCopy.songCount($0)))" } ?? ""
    }

    var confirmationTitle: String {
        switch self {
        case .album(let name, let songCount):
            return "\(Self.quoted(name))\(Self.scale(songCount)) — remove the downloads from this "
                + "device, or remove the album from Your Library?"
        case .song(let title, let artist):
            let by = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = by.isEmpty ? Self.quoted(title) : "\(Self.quoted(title)) by \(by)"
            return "\(subject) — remove the download from this device, or remove the song from "
                + "Your Library?"
        case .playlist(let name, let songCount):
            return "Remove the \(songCount.map(LibraryRemovalCopy.songCount) ?? "songs") "
                + "downloaded from \(Self.quoted(name)) from this device?"
        case .songs(let sourceName, let songCount):
            return "\(LibraryRemovalCopy.songCount(songCount)) in \(Self.quoted(sourceName)) — "
                + "remove the downloads from this device, or remove them from Your Library?"
        }
    }
}

/// Presents the **system** downloaded-library action sheet (`UIAlertController`, `.actionSheet`).
/// On current iOS versions a long title is laid out as a centered card by UIKit — no custom chrome.
struct DownloadedAlbumActionPresentation: ViewModifier {
    @Binding var isPresented: Bool
    /// No default: a caller that forgets to say what it is removing would otherwise inherit
    /// someone else's noun (the Favorites sheet used to describe itself as "this album").
    let itemKind: DownloadedLibraryItemKind
    var includeDeleteFromLibrary: Bool = true
    let onRemoveDownload: () -> Void
    let onDeleteFromLibrary: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.background {
            NativeUIAlertActionSheetBridge(
                isPresented: $isPresented,
                title: itemKind.confirmationTitle,
                includeDeleteFromLibrary: includeDeleteFromLibrary,
                onRemoveDownload: onRemoveDownload,
                onDeleteFromLibrary: onDeleteFromLibrary,
            )
            .frame(width: 0, height: 0)
        }
        #else
        content
            .confirmationDialog(itemKind.confirmationTitle, isPresented: $isPresented, titleVisibility: .visible) {
                Button(
                    includeDeleteFromLibrary ? "Only Remove Download" : "Remove Download",
                    action: onRemoveDownload
                )
                if includeDeleteFromLibrary {
                    Button("Delete from Library", role: .destructive, action: onDeleteFromLibrary)
                }
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
                itemKind: .song(
                    title: track.wrappedValue?.title ?? "",
                    artist: track.wrappedValue?.artist ?? ""
                ),
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
    var includeDeleteFromLibrary: Bool = true
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
        // The coordinator is made once and outlives every re-render, so without this it keeps the
        // first `self` forever — its title and its action closures. That was survivable while the
        // title was a constant sentence; now the title names the item being removed, and a stale
        // one would ask about whatever the user swiped a moment ago.
        context.coordinator.parent = self
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
                UIAlertAction(
                    title: parent.includeDeleteFromLibrary ? "Only Remove Download" : "Remove Download",
                    style: .default,
                ) { [weak self] _ in
                    self?.finish(dismissAnimated: true) {
                        self?.parent.onRemoveDownload()
                    }
                },
            )
            if parent.includeDeleteFromLibrary {
                sheet.addAction(
                    UIAlertAction(title: "Delete from Library", style: .destructive) { [weak self] _ in
                        self?.finish(dismissAnimated: true) {
                            self?.parent.onDeleteFromLibrary()
                        }
                    },
                )
            }
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
