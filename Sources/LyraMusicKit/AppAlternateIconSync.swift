import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Maps Lyra accent presets to **bundled** alternate home-screen icons.
///
/// - **Accent (logo color):** one alternate icon set per preset (`LyraIcon-blue`, …). Switched with ``apply(accentPresetId:)``.
/// - **Light / dark (background):** not handled here — use **Any** + **Dark** slots in each icon set in Xcode; iOS picks by system appearance.
enum AppAlternateIconSync {
    /// Asset catalog name for the primary icon (Settings accent `red` uses this — no alternate swap).
    static let primaryIconSetName = "AppIcon"

    /// Alternate set base name: `LyraIcon-{accentId}` (e.g. `LyraIcon-blue`).
    static func alternateIconName(forAccentPresetId id: String) -> String {
        "LyraIcon-\(id)"
    }

    /// All accent ids that require a matching `LyraIcon-*` set in the host target asset catalog.
    static var alternateAccentPresetIds: [String] {
        AppAccentPreset.presets.map(\.id).filter { $0 != AppAccentPreset.defaultId }
    }

    /// `nil` = primary ``primaryIconSetName``; otherwise ``alternateIconName(forAccentPresetId:)``.
    static func resolvedIconName(forAccentPresetId id: String) -> String? {
        guard AppAccentPreset.presets.contains(where: { $0.id == id }) else {
            return nil
        }
        if id == AppAccentPreset.defaultId {
            return nil
        }
        return alternateIconName(forAccentPresetId: id)
    }

    /// Reads `CFBundleAlternateIcons` from the installed app bundle (what iOS actually sees).
    static func bundledAlternateIconCount() -> Int {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let alternates = icons["CFBundleAlternateIcons"] as? [String: Any]
        else { return 0 }
        return alternates.count
    }

    #if canImport(UIKit)
    @MainActor
    static func apply(
        accentPresetId: String,
        completion: ((Bool, String?) -> Void)? = nil,
    ) {
        guard UIApplication.shared.supportsAlternateIcons else {
            let bundled = bundledAlternateIconCount()
            let message =
                bundled == 0
                ? "This install’s Info.plist has no alternate icons. Your Sideloadly IPA was probably built without LyraMusicHost/AppIcons — the Simulator Xcode run includes them, sideload often doesn’t."
                : "iOS reports alternate icons unsupported for this install (\(bundled) listed in plist). Try a fresh sideload of a LyraMusicHost IPA built after the icon assets were added."
            completion?(false, message)
            return
        }
        let target = resolvedIconName(forAccentPresetId: accentPresetId)
        guard UIApplication.shared.alternateIconName != target else {
            completion?(true, nil)
            return
        }
        UIApplication.shared.setAlternateIconName(target) { error in
            if let error {
                let message = error.localizedDescription
                print("Lyra: alternate icon \(target ?? "primary") failed: \(message)")
                completion?(false, message)
            } else {
                completion?(true, nil)
            }
        }
    }
    #endif
}
