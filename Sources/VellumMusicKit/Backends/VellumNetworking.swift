import Foundation
import Security

enum TrustedCertificateStore {
    private static let hostsKey = "vellumTrustedSSLHosts"

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
        // A user explicitly trusting a self-hosted server's certificate (per-host
        // opt-in via "Trust server certificate") means: accept the chain this host
        // presents, including self-signed / expired / hostname-mismatch — the exact
        // cases the feature exists for. Non-trusted hosts never reach here; they fall
        // through to `.performDefaultHandling` (normal system validation). Previously
        // this still required SecTrustEvaluateWithError to pass, which is false for
        // every cert the feature targets, so the option silently did nothing.
        return isHostTrusted(host)
    }
}

final class VellumURLSessionDelegate: NSObject, URLSessionDelegate {
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

enum VellumURLSession {
    private static let delegate = VellumURLSessionDelegate()

    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        // Self-hosted servers over flaky links (LAN / Tailscale / tunnels) can stall;
        // cap waits so a dead request fails fast instead of hanging on the default 60s.
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
}

extension URLSession {
    static var vellum: URLSession { VellumURLSession.shared }
}
