import Foundation

/// Turns whatever a person typed or pasted for a server address into a usable URL.
///
/// Keyboards capitalise the first letter, `https:/` and `https//` are easy slips, and most people leave
/// the scheme off. `URL(string:)` accepts all of those and hands back something with no host, which
/// fails later with an unhelpful error. Used by sign-in, the connection test and the request plugins.
enum ServerURL {
    /// A typed address as an http(s) URL with no trailing slash. No scheme means HTTPS.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = repairScheme(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }
        let hasScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        // Some other scheme (`ftp://…`) is not a server address; prefixing it would invent a host.
        guard hasScheme || !trimmed.contains("://") else { return nil }
        let prefixed = hasScheme ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: prefixed),
              let scheme = components.scheme, scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" { components.path = "" }
        return components.url
    }

    /// Like ``normalize(_:)``, but a LAN address typed without a scheme defaults to HTTP, since a home
    /// server rarely has a certificate. Public hosts still default to HTTPS.
    static func normalizeLanAddress(_ raw: String) -> URL? {
        let trimmed = repairScheme(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return normalize(trimmed) }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let host = hostPart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostPart
        return normalize(isInternalHost(host) ? "http://\(trimmed)" : trimmed)
    }

    /// Addresses to try for what was typed, in order. A typed scheme is the only candidate. Without one,
    /// HTTPS comes first; LAN and Tailscale hosts then fall back to plain HTTP. Public hosts never do:
    /// a blocked HTTPS would otherwise send the password in the clear.
    static func candidates(_ raw: String) -> [URL] {
        let trimmed = repairScheme(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return normalize(trimmed).map { [$0] } ?? []
        }
        guard let secure = normalize(trimmed), let host = secure.host else { return [] }
        guard allowsPlainHTTPFallback(host), let plain = normalize("http://\(trimmed)") else { return [secure] }
        return [secure, plain]
    }

    /// The candidate the server actually answers on. Only a scheme-less LAN or Tailscale address has a
    /// second candidate; anything that connects, whatever the status, counts as an answer.
    static func resolved(_ raw: String, session: URLSession = .shared) async -> URL? {
        let all = candidates(raw)
        guard let last = all.last else { return nil }
        for url in all.dropLast() {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                _ = try await session.data(for: request)
                return url
            } catch is URLError {
                continue
            } catch {
                continue
            }
        }
        return last
    }

    /// LAN hosts, and Tailscale hosts, whose traffic the tailnet already encrypts.
    static func allowsPlainHTTPFallback(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return isInternalHost(value) || isTailscaleIPv4(value) || value.hasSuffix(".ts.net")
    }

    /// Tailscale hands out addresses from the carrier-grade NAT range.
    static func isTailscaleIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".")
        let parts = pieces.compactMap { UInt8($0) }
        guard parts.count == 4, pieces.count == 4 else { return false }
        return parts[0] == 100 && (64 ... 127).contains(parts[1])
    }

    static func isInternalHost(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if value == "localhost" || value == "::1" || value.hasPrefix("127.") || value == "0.0.0.0" { return true }
        if [".local", ".lan", ".internal", ".home"].contains(where: value.hasSuffix) { return true }
        if !value.contains("."), !value.contains(":") { return true }
        return isPrivateIPv4(value)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".")
        let parts = pieces.compactMap { UInt8($0) }
        guard parts.count == 4, pieces.count == 4 else { return false }
        switch parts[0] {
        case 10, 127: return true
        case 169: return parts[1] == 254
        case 172: return (16 ... 31).contains(parts[1])
        case 192: return parts[1] == 168
        default: return false
        }
    }

    /// `Https://host`, `https:/host` and `https//host` all become `https://host`.
    private static func repairScheme(_ value: String) -> String {
        guard let match = value.range(of: #"^(https?)(:/{0,3}|/{1,3})"#, options: [.regularExpression, .caseInsensitive]) else {
            return value
        }
        let scheme = value[match].lowercased().hasPrefix("https") ? "https" : "http"
        return scheme + "://" + value[match.upperBound...]
    }
}
