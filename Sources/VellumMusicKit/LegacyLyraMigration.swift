import Foundation
import Security

/// One-time migration of device-local state written before the Lyra → Vellum
/// rename. The rename changed the `lyra.*` and `com.randll.lyra.*` UserDefaults
/// keys and the Keychain service name but shipped no migration, so an install
/// upgrading in place from Lyra loses its kill-mode progress and saved server
/// login. Copies that state to the new names once; existing new-name values
/// always win. No-op (beyond the marker write) on fresh installs.
enum LegacyLyraMigration {
    private static let markerKey = "vellum.migration.lyraLocalState.done"
    private static let legacyKeychainService = "com.randll.lyra"
    private static let keychainService = "com.randll.vellum"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        migrateDefaults(defaults, fromPrefix: "lyra.", toPrefix: "vellum.")
        migrateDefaults(defaults, fromPrefix: "com.randll.lyra.", toPrefix: "com.randll.vellum.")
        migrateKeychainItems(accounts: ["jellyfin", "navidrome"])
        defaults.set(true, forKey: markerKey)
    }

    private static func migrateDefaults(_ defaults: UserDefaults, fromPrefix: String, toPrefix: String) {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(fromPrefix) {
            let newKey = toPrefix + key.dropFirst(fromPrefix.count)
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    /// Copies the generic-password items `KeychainStore` wrote under the old
    /// service name. `SecItemAdd` fails with `errSecDuplicateItem` when the
    /// new-service item already exists, which keeps newer credentials intact.
    private static func migrateKeychainItems(accounts: [String]) {
        for account in accounts {
            let read: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyKeychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { continue }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
