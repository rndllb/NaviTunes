import CryptoKit
import Foundation

@MainActor
final class LastFmScrobbler {
    private var sessionKey: String?
    private var apiKey: String?
    private var secret: String?

    init() {
        restoreSession()
    }

    private static let migrationFlagKey = "lastfm_keychain_migrated_v1"

    func restoreSession() {
        migrateLegacyDefaultsIfNeeded()
        apiKey = UserDefaults.standard.string(forKey: "lastfm_api_key")
        secret = KeychainStore.loadLastFmSecret()
        sessionKey = KeychainStore.loadLastFmSession()
    }

    func configure(apiKey: String, secret: String, sessionKey: String) {
        self.apiKey = apiKey
        self.secret = secret
        self.sessionKey = sessionKey
        UserDefaults.standard.set(apiKey, forKey: "lastfm_api_key")
        do {
            try KeychainStore.saveLastFmSecret(secret)
            try KeychainStore.saveLastFmSession(sessionKey)
        } catch {
            self.secret = nil
            self.sessionKey = nil
        }
        UserDefaults.standard.removeObject(forKey: "lastfm_secret")
        UserDefaults.standard.removeObject(forKey: "lastfm_session")
    }

    /// One-time migration: move legacy plaintext `lastfm_secret` / `lastfm_session`
    /// from UserDefaults into the Keychain, then scrub the UserDefaults entries.
    private func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationFlagKey) else { return }
        if let legacySecret = defaults.string(forKey: "lastfm_secret"),
           (try? KeychainStore.saveLastFmSecret(legacySecret)) != nil {
            defaults.removeObject(forKey: "lastfm_secret")
        }
        if let legacySession = defaults.string(forKey: "lastfm_session"),
           (try? KeychainStore.saveLastFmSession(legacySession)) != nil {
            defaults.removeObject(forKey: "lastfm_session")
        }
        defaults.set(true, forKey: Self.migrationFlagKey)
    }

    func scrobble(track: Track, timestamp: Date) async {
        guard let apiKey, let secret, let sessionKey else { return }
        let ts = String(Int(timestamp.timeIntervalSince1970))
        let sigBase =
            "api_key\(apiKey)artist\(track.artist)methodtrack.scrobblesk\(sessionKey)timestamp\(ts)track\(track.title)"
        let sig = (sigBase + secret).md5Lowercased()
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "track.scrobble"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "api_sig", value: sig),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "sk", value: sessionKey),
            URLQueryItem(name: "artist", value: track.artist),
            URLQueryItem(name: "track", value: track.title),
            URLQueryItem(name: "timestamp", value: ts),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }
}

private extension String {
    func md5Lowercased() -> String {
        let digest = Insecure.MD5.hash(data: Data(utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
