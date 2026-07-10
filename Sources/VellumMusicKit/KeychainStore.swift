import Foundation
import Security

enum KeychainStore {
    private static let service = "com.randll.vellum"

    struct JellyfinCreds: Codable {
        var base: URL
        var secondaryBase: URL?
        var user: String
        var password: String
        var accessToken: String?
        var userId: String?
    }

    struct NavidromeCreds: Codable {
        var base: URL
        var secondaryBase: URL?
        var user: String
        var password: String
        var subsonicToken: String?
    }

    static func saveJellyfin(
        base: URL,
        secondaryBase: URL? = nil,
        user: String,
        password: String,
        accessToken: String? = nil,
        userId: String? = nil,
    ) throws {
        let data = try JSONEncoder().encode(
            JellyfinCreds(
                base: base,
                secondaryBase: secondaryBase,
                user: user,
                password: password,
                accessToken: accessToken,
                userId: userId,
            ),
        )
        try save(key: "jellyfin", data: data)
    }

    static func saveNavidrome(
        base: URL,
        secondaryBase: URL? = nil,
        user: String,
        password: String,
        subsonicToken: String? = nil,
    ) throws {
        let data = try JSONEncoder().encode(
            NavidromeCreds(
                base: base,
                secondaryBase: secondaryBase,
                user: user,
                password: password,
                subsonicToken: subsonicToken,
            ),
        )
        try save(key: "navidrome", data: data)
    }

    static func loadJellyfin() throws -> JellyfinCreds {
        let data = try load(key: "jellyfin")
        return try JSONDecoder().decode(JellyfinCreds.self, from: data)
    }

    static func loadNavidrome() throws -> NavidromeCreds {
        let data = try load(key: "navidrome")
        return try JSONDecoder().decode(NavidromeCreds.self, from: data)
    }

    /// Clears Jellyfin / Navidrome media library credentials.
    static func clear() {
        ["jellyfin", "navidrome"].forEach { delete(key: $0) }
    }


    private static func saveString(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: "KeychainStore", code: -1)
        }
        try save(key: key, data: data)
    }

    private static func loadString(key: String) -> String? {
        guard let data = try? load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(key: String, data: Data) throws {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func load(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }
        return data
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
