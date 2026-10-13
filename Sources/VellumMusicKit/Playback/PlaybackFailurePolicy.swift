import AVFoundation
import Foundation

/// Why a track produced no audio, at the granularity the listener is told about.
///
/// AVFoundation reports almost everything as a generic `AVFoundationErrorDomain` error with the
/// real cause buried in `NSUnderlyingErrorKey`, so the reason a user sees has to be recovered by
/// unwrapping that chain and — for anything the server actually answered — by reading the HTTP
/// status out of the item's error log. Guessing from the top-level error alone puts a dead file
/// and a dead server in the same bucket, which is the failure this whole policy exists to avoid.
enum PlaybackFailureReason: Equatable, Sendable {
    /// The server answered and there is no playable file behind this track id — a 404, a
    /// Subsonic JSON error body served as audio, or an id that died in a library rescan.
    case missingOnServer
    /// Bytes arrived and the decoder rejected them: an unsupported container (Opus / Ogg /
    /// WebM), a truncated cache file, or a corrupt download.
    case undecodable
    /// The server was never reached — no route, DNS failure, refused connection, timeout.
    case unreachable
    /// The server was reached and answered badly (5xx, 408, 429, or a mid-flight media
    /// services reset). The track is probably fine; the server is not.
    case serverError
    /// The server was reached and refused the credentials (401 / 403).
    case unauthorized
    /// No cause could be recovered from the error chain.
    case unknown

    /// Transient failures get one retry before the track is given up on. Permanent ones do
    /// not: re-requesting bytes a decoder already rejected is theatre that costs the listener
    /// another full load timeout.
    ///
    /// `unknown` counts as transient deliberately. A wrong retry costs about a second; a wrong
    /// skip silently loses a song the user asked for, and unrecovered errors are the bucket most
    /// likely to be an ordinary network blip.
    var isTransient: Bool {
        switch self {
        case .unreachable, .serverError, .unknown: return true
        case .missingOnServer, .undecodable, .unauthorized: return false
        }
    }

    /// True when the failure says something about the *server*, not about this one track.
    /// Drives the halt message, so a server that is down never reads as "these songs are bad".
    var isServerSide: Bool {
        switch self {
        case .unreachable, .serverError, .unauthorized: return true
        case .missingOnServer, .undecodable, .unknown: return false
        }
    }

    /// Trailing clause for the per-skip toast: "Skipped “Title” — <this>".
    var skipClause: String {
        switch self {
        case .missingOnServer: return "the file is missing on the server"
        case .undecodable: return "iPhone can't play this file's format"
        case .unreachable: return "the server didn't respond"
        case .serverError: return "the server returned an error"
        case .unauthorized: return "the server refused access"
        case .unknown: return "it wouldn't load"
        }
    }
}

/// Everything the app needs to explain why playback stopped instead of continuing to skip.
struct PlaybackHaltSummary: Equatable, Sendable {
    /// How many consecutive tracks failed (equals ``PlaybackFailurePolicy/haltThreshold``).
    let failureCount: Int
    /// The reason on the failure that tripped the guard.
    let lastReason: PlaybackFailureReason
    /// True when most of the streak looked like a server problem rather than bad files.
    let isServerSide: Bool

    /// Alert copy. The server-side branch names the cause outright: the whole point of the
    /// guard is that a server being down must not present as "there is nothing here to play".
    var message: String {
        if isServerSide {
            return """
            Playback stopped: \(failureCount) songs in a row couldn't be loaded from your server.

            This is a connection problem, not an empty playlist — the songs are still there. \
            Check that the server is running and reachable, then press play again.
            """
        }
        return """
        Playback stopped: \(failureCount) songs in a row couldn't be played.

        They're either missing from the server or in a format iPhone can't decode. \
        The rest of the queue is untouched — press play again to continue past them.
        """
    }
}

/// Decides what to do about a track that produced no audio: retry it, skip past it, or stop.
///
/// Kept out of `PlaybackEngine` on purpose — it is pure decision logic over an error and a
/// counter, so it can be reasoned about (and exercised) without an `AVPlayer`.
enum PlaybackFailurePolicy {
    /// Consecutive failed tracks tolerated before playback stops and says why.
    ///
    /// Three, not two: two dead files next to each other is ordinary in a real library (a
    /// partial import, one bad album side), and stopping on those would make the app feel
    /// broken. Three in a row is not a coincidence — it is a systemic problem, and continuing
    /// past it would tear through the queue faster than the user can read a toast.
    static let haltThreshold = 3

    /// Retries allowed per track before it is given up on. One: enough to ride out a blip,
    /// few enough that a genuinely dead track doesn't hold the queue for two load timeouts.
    static let transientRetryLimit = 1

    /// Backoff before the retry. Long enough for a Wi-Fi hiccup or a server hiccup to clear,
    /// short enough that it reads as a pause rather than a hang.
    static let retryBackoff: Duration = .milliseconds(1200)

    /// Recovers the cause from an AVFoundation error chain plus, when the server answered, the
    /// HTTP status from `AVPlayerItem.errorLog()`.
    ///
    /// - Parameters:
    ///   - error: the error the load path threw, if any.
    ///   - httpStatus: status code from the item's error log, or nil when the request never
    ///     got a response. Checked **first**: it is the only thing that separates a 404 (this
    ///     track is gone — permanent) from a 503 (the server is sick — transient), which
    ///     `NSURLErrorDomain` collapses into a single `.badServerResponse`.
    static func classify(_ error: Error?, httpStatus: Int? = nil) -> PlaybackFailureReason {
        if let httpStatus, httpStatus > 0, let fromStatus = reason(forHTTPStatus: httpStatus) {
            return fromStatus
        }
        for ns in underlyingChain(of: error) {
            if let reason = reason(for: ns) { return reason }
        }
        return .unknown
    }

    private static func reason(forHTTPStatus status: Int) -> PlaybackFailureReason? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        // 408 (timeout) and 429 (rate limited) are the two 4xx that mean "come back", not
        // "this is gone" — Navidrome throttles under load and Jellyfin returns 429 mid-scan.
        case 408, 429: return .serverError
        case 404, 410: return .missingOnServer
        case 400..<500: return .missingOnServer
        case 500..<600: return .serverError
        default: return nil
        }
    }

    /// The error plus everything under `NSUnderlyingErrorKey`, outermost first. AVFoundation
    /// nests two or three deep (`AVFoundationErrorDomain` → `NSURLErrorDomain` /
    /// `NSOSStatusErrorDomain`), and the useful code is always the innermost one.
    /// One line for the log: every domain and code in the underlying chain, outermost first, with
    /// the outermost description. This is what the device test reads to learn *why* a candidate
    /// was rejected — the classification above is too coarse for that question.
    static func describe(_ error: Error?) -> String {
        let chain = underlyingChain(of: error).reversed()
        guard !chain.isEmpty else { return "no error object" }
        let links = chain.map { "\($0.domain) \($0.code)" }.joined(separator: " ← ")
        let description = error.map { ($0 as NSError).localizedDescription } ?? ""
        return description.isEmpty ? links : "\(links) (\(description))"
    }

    private static func underlyingChain(of error: Error?, limit: Int = 5) -> [NSError] {
        guard let error else { return [] }
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let ns = current, chain.count < limit {
            chain.append(ns)
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // Innermost first: the wrapper says "playback failed", the leaf says why.
        return chain.reversed()
    }

    private static func reason(for ns: NSError) -> PlaybackFailureReason? {
        switch ns.domain {
        // The decoder returned an OSStatus — the bytes are not audio this device can read.
        case NSOSStatusErrorDomain:
            return .undecodable
        case NSURLErrorDomain:
            return reason(forURLErrorCode: ns.code)
        case NSPOSIXErrorDomain:
            // ENOENT / EISDIR on a download that was deleted or half-written under us.
            return (ns.code == 2 || ns.code == 21) ? .missingOnServer : nil
        case AVFoundationErrorDomain:
            return reason(forAVErrorCode: ns.code)
        case NSCocoaErrorDomain:
            return (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError)
                ? .missingOnServer
                : nil
        default:
            return nil
        }
    }

    private static func reason(forURLErrorCode code: Int) -> PlaybackFailureReason? {
        switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
             .dataNotAllowed, .callIsActive, .secureConnectionFailed,
             .cannotLoadFromNetwork, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return .unreachable
        case .fileDoesNotExist, .resourceUnavailable, .zeroByteResource, .badURL,
             .unsupportedURL, .fileIsDirectory, .noPermissionsToReadFile:
            return .missingOnServer
        case .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse,
             .dataLengthExceedsMaximum:
            return .undecodable
        case .userAuthenticationRequired, .userCancelledAuthentication,
             .clientCertificateRejected, .clientCertificateRequired:
            return .unauthorized
        case .badServerResponse:
            // Non-2xx with no status code recovered. Could be either; treated as a server
            // problem so it earns a retry rather than costing the user a song.
            return .serverError
        default:
            return nil
        }
    }

    /// `AVError.Code` is not the same set on iOS and macOS, and this file has to compile for
    /// both (`Package.swift` builds VellumMusicKit for macOS too). Anything platform-specific is
    /// matched by raw value with the name in a comment rather than by case.
    private static let avErrorMediaServicesWereReset = -11819

    private static func reason(forAVErrorCode code: Int) -> PlaybackFailureReason? {
        // iOS-only: mediaServicesWereReset. The audio stack died under us — the track is fine.
        if code == avErrorMediaServicesWereReset { return .serverError }
        switch AVError.Code(rawValue: code) {
        case .fileFormatNotRecognized, .failedToParse, .decodeFailed, .formatUnsupported,
             .undecodableMediaData, .contentIsUnavailable:
            return .undecodable
        case .noLongerPlayable, .serverIncorrectlyConfigured:
            return .serverError
        case .contentIsNotAuthorized, .applicationIsNotAuthorized:
            return .unauthorized
        default:
            return nil
        }
    }
}

/// Consecutive-failure counter behind the runaway-skip guard.
///
/// Counts *tracks given up on*, not load attempts — a track that failed, was retried and failed
/// again is one entry, so the threshold means what it says.
struct PlaybackFailureStreak {
    private(set) var count = 0
    private var serverSideCount = 0
    private var lastReason: PlaybackFailureReason = .unknown

    /// Records a track the engine has given up on.
    /// - Returns: a summary when the streak has hit the halt threshold, otherwise nil.
    mutating func recordFailure(_ reason: PlaybackFailureReason) -> PlaybackHaltSummary? {
        count += 1
        lastReason = reason
        if reason.isServerSide { serverSideCount += 1 }
        guard count >= PlaybackFailurePolicy.haltThreshold else { return nil }
        let summary = PlaybackHaltSummary(
            failureCount: count,
            lastReason: reason,
            // Majority rule rather than "any": one dead file inside a server outage must not
            // flip the message away from the outage, and vice versa.
            isServerSide: serverSideCount * 2 > count,
        )
        reset()
        return summary
    }

    /// Any track that reaches confirmed playback clears the streak — the queue is healthy again.
    mutating func reset() {
        count = 0
        serverSideCount = 0
        lastReason = .unknown
    }
}
