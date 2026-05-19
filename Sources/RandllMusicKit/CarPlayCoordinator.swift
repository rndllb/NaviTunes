#if canImport(CarPlay)
import CarPlay

/// Registers a minimal CarPlay hierarchy when a `CPTemplateApplicationScene` is configured in Info.plist.
@MainActor
final class CarPlayCoordinator: NSObject, CPTemplateApplicationSceneDelegate {
    static let shared = CarPlayCoordinator()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
    ) {
        let item = CPListItem(text: "Library", detailText: "Open Lyra Music on iPhone for full browsing")
        let section = CPListSection(items: [item])
        let template = CPListTemplate(title: "LyraMusic", sections: [section])
        interfaceController.setRootTemplate(template, animated: true, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
    ) {
        // no-op
    }
}

#endif
