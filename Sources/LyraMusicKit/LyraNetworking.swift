import Foundation
import Security

enum TrustedCertificateStore {
    private static let hostsKey = "lyraTrustedSSLHosts"

    static func trustedHosts() -> Set<String> {
        let list = UserDefaults.standard.stringArray(forKey: hostsKey) ?? []
        return Set(list.map { $0.lowercased() })
    }

    static func isHostTrusted(_ host: String) -> Bool {
        trustedHosts().contains(host.lowercased())
    }

    static func trustHost(_ host: String) {
        var hosts = trustedHosts()
        hosts.insert(host.lowercased())
        UserDefaults.standard.set(Array(hosts).sorted(), forKey: hostsKey)
    }

    static func removeTrustedHost(_ host: String) {
        var hosts = trustedHosts()
        hosts.remove(host.lowercased())
        UserDefaults.standard.set(Array(hosts).sorted(), forKey: hostsKey)
    }

    static func shouldAccept(serverTrust: SecTrust, host: String) -> Bool {
        guard isHostTrusted(host) else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(serverTrust, &error)
    }
}

final class LyraURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        if TrustedCertificateStore.shouldAccept(serverTrust: trust, host: host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

enum LyraURLSession {
    private static let delegate = LyraURLSessionDelegate()

    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
}

extension URLSession {
    static var lyra: URLSession { LyraURLSession.shared }
}
