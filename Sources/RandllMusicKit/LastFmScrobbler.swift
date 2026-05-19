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

    func restoreSession() {
        sessionKey = UserDefaults.standard.string(forKey: "lastfm_session")
        apiKey = UserDefaults.standard.string(forKey: "lastfm_api_key")
        secret = UserDefaults.standard.string(forKey: "lastfm_secret")
    }

    func configure(apiKey: String, secret: String, sessionKey: String) {
        self.apiKey = apiKey
        self.secret = secret
        self.sessionKey = sessionKey
        UserDefaults.standard.set(apiKey, forKey: "lastfm_api_key")
        UserDefaults.standard.set(secret, forKey: "lastfm_secret")
        UserDefaults.standard.set(sessionKey, forKey: "lastfm_session")
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
