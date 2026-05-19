import Foundation
import Security

enum KeychainStore {
    private static let service = "com.randll.musicclient"

    struct JellyfinCreds: Codable {
        var base: URL
        var user: String
        var password: String
        var accessToken: String?
        var userId: String?
    }

    struct NavidromeCreds: Codable {
        var base: URL
        var user: String
        var password: String
        var subsonicToken: String?
    }

    static func saveJellyfin(
        base: URL,
        user: String,
        password: String,
        accessToken: String? = nil,
        userId: String? = nil,
    ) throws {
        let data = try JSONEncoder().encode(
            JellyfinCreds(base: base, user: user, password: password, accessToken: accessToken, userId: userId),
        )
        try save(key: "jellyfin", data: data)
    }

    static func saveNavidrome(
        base: URL,
        user: String,
        password: String,
        subsonicToken: String? = nil,
    ) throws {
        let data = try JSONEncoder().encode(
            NavidromeCreds(base: base, user: user, password: password, subsonicToken: subsonicToken),
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

    private static func save(key: String, data: Data) throws {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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
        ]
        SecItemDelete(query as CFDictionary)
    }
}
