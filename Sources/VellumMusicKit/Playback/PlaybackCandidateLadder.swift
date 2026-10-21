import Foundation

/// The order of attempts `PlaybackEngine.startCurrentItem` makes for one track, and which of them
/// go through the custom-scheme caching loader.
///
/// The rule, as of T662: **none of them.** A remote stream is always a plain `AVURLAsset`.
///
/// History, because the rule has moved twice:
/// - T630 c15 attached `CachingResourceLoaderDelegate` to every stream while AutoMix was on, so
///   the playing song was assembled on disk and its own first boundary could blend. On the device
///   every streamed song then failed (T638: 22 of 22).
/// - T643 c2 narrowed it to the first range-servable raw stream (`servesByteRanges`), followed by
///   the same URL plain, on the reading that only transcoded streams (`Accept-Ranges: none`, no
///   length) were being rejected.
/// - T662 showed the reading was wrong. The owner's raw FLAC stream — no `format`, no
///   `maxBitRate`, Navidrome `transcoding=false`, served with byte ranges — was rejected the same
///   way: `NSURLErrorDomain -1002 ← CoreMediaErrorDomain -1002` (unsupported URL). The same asset
///   on the iOS 26 simulator against a loopback server that answers `206` + `Content-Range` +
///   `Accept-Ranges: bytes` fails identically, FLAC or M4A, with or without the MIME hint, while
///   the delegate's requests *do* reach the server and a plain `AVURLAsset` on the same URL loads.
///   AVFoundation's remote player (`PlayerRemoteXPC`, `-12860` in the owner's console) does not
///   route the custom scheme through the in-process delegate, whatever the server does. So the
///   loader is off for streams; the next queued stream is still fetched whole by
///   `AutoMixStreamPrefetcher`, so every boundary except a stream's very first can still blend.
/// - With AutoMix off nothing ever changed: one plain attempt per URL.
enum PlaybackCandidateLadder {
    struct Attempt: Equatable {
        let url: URL
        let headers: [String: String]
        /// Proxy this attempt through `CachingResourceLoaderDelegate` on the custom scheme.
        let viaLoader: Bool
    }

    /// Whether a URL may be proxied through the loader at all. The one gate
    /// `PlaybackEngine.shouldAttachCachingLoader` consults. Always `false` since T662 (see above);
    /// the parameters stay so the call sites and their tests read as the decision they are.
    static func mayUseLoader(autoMixEnabled: Bool, url: URL, isInternetRadio: Bool) -> Bool {
        false
    }

    /// The candidates that may be tried right now. With streaming blocked ("No streaming over
    /// cellular" on a cellular connection) only files already on the phone remain — offline
    /// downloads and committed stream-cache files — in their original order.
    static func allowedCandidates(
        _ candidates: [(url: URL, headers: [String: String])],
        streamingBlocked: Bool,
    ) -> [(url: URL, headers: [String: String])] {
        guard streamingBlocked else { return candidates }
        return candidates.filter { $0.url.isFileURL }
    }

    /// Expands the candidate URLs into attempts, in order.
    static func attempts(
        candidates: [(url: URL, headers: [String: String])],
        autoMixEnabled: Bool,
        isInternetRadio: Bool,
    ) -> [Attempt] {
        var out: [Attempt] = []
        out.reserveCapacity(candidates.count + 1)
        var loaderGiven = false
        for candidate in candidates {
            if !loaderGiven, mayUseLoader(autoMixEnabled: autoMixEnabled, url: candidate.url, isInternetRadio: isInternetRadio) {
                loaderGiven = true
                out.append(Attempt(url: candidate.url, headers: candidate.headers, viaLoader: true))
            }
            out.append(Attempt(url: candidate.url, headers: candidate.headers, viaLoader: false))
        }
        return out
    }
}
