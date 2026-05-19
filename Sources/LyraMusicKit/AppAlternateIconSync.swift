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

    #if canImport(UIKit)
    @MainActor
    static func apply(accentPresetId: String, completion: ((Bool) -> Void)? = nil) {
        guard UIApplication.shared.supportsAlternateIcons else {
            completion?(false)
            return
        }
        let target = resolvedIconName(forAccentPresetId: accentPresetId)
        guard UIApplication.shared.alternateIconName != target else {
            completion?(true)
            return
        }
        UIApplication.shared.setAlternateIconName(target) { error in
            if let error {
                #if DEBUG
                print("Lyra: alternate icon \(target ?? "primary") failed: \(error.localizedDescription)")
                #endif
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }
    #endif
}
