import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// `AVAssetResourceLoaderDelegate` that transparently proxies a progressive audio
/// stream and opportunistically caches it to ``StreamingMediaDiskCache``.
///
/// Design goals, in order:
/// 1. **Playback correctness first.** Each `AVPlayer` loading request is served by
///    its own ranged `URLSession` task fetching exactly the bytes it asked for, so
///    behaviour matches a plain `AVURLAsset`.
/// 2. **No extra network bytes.** We never fetch anything the player didn't
///    request. A file is committed to the cache only if normal playback happens to
///    cover the whole `[0, contentLength)` range (i.e. the user listened through /
///    seeked across all of it). Partially-played tracks are simply not cached.
///
/// Only attach this to **progressive** (non-HLS) streams — see ``isCacheable``.
/// HLS would route playlist + segment requests through here, which this byte-range
/// proxy does not implement.
final class CachingResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    /// Single opaque scheme — must not embed "http"/"https" or AVFoundation's
    /// stream stack may try to open the asset URL with URLSession directly
    /// (unsupported URL / FigStreamPlayer errors) instead of the resource loader.
    private static let customScheme = "lyracache"
    /// AVFoundation option key — not always imported into Swift on all SDKs.
    static let outOfBandMIMETypeOptionKey = "AVURLAssetOutOfBandMIMETypeKey"

    /// Whether a URL is safe to route through this byte-range proxy: an http(s)
    /// progressive stream, never HLS or an endpoint likely to transcode to HLS.
    static func isCacheable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        let lower = url.absoluteString.lowercased()
        if lower.contains(".m3u8") || lower.contains("hls") || lower.contains("master") || lower.contains("/universal") {
            return false
        }
        return true
    }

    /// Rewrite an http(s) URL onto a private scheme so `AVURLAsset` hands loading
    /// to this delegate instead of fetching directly.
    static func customSchemeURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch url.scheme?.lowercased() {
        case "https", "http": components.scheme = customScheme
        default: return nil
        }
        return components.url
    }

    /// Hint content type so AVFoundation skips format sniffing on the custom-scheme
    /// URL (which would otherwise hit URLSession with an unsupported scheme).
    static func outOfBandMIMEType(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let format = components.queryItems?
            .first(where: { $0.name.lowercased() == "format" })?
            .value?
            .lowercased()
        else { return nil }
        switch format {
        case "aac": return "audio/aac"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return nil
        }
    }

    /// Serializes both resource-loader callbacks and all mutable state.
    let accessQueue = DispatchQueue(label: "com.lyra.caching-resource-loader")

    private let originalURL: URL
    private let headers: [String: String]
    private let cacheKey: String
    private let cache: StreamingMediaDiskCache

    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: queue)
    }()

    private struct TaskContext {
        let request: AVAssetResourceLoadingRequest
        let baseOffset: Int64
        var received: Int64 = 0
    }

    private var contextsByTaskId: [Int: TaskContext] = [:]
    private var taskByRequest: [ObjectIdentifier: URLSessionTask] = [:]
    private var contentLength: Int64?
    private var assembler: CacheAssembler?
    private var invalidated = false

    init(originalURL: URL, headers: [String: String], cache: StreamingMediaDiskCache = .shared) {
        self.originalURL = originalURL
        self.headers = headers
        self.cacheKey = StreamingMediaDiskCache.key(for: originalURL)
        self.cache = cache
        super.init()
    }

    /// Tear down the URLSession (and any in-progress cache assembly) when the owning
    /// player item goes away. Safe to call more than once.
    func invalidate() {
        accessQueue.async {
            guard !self.invalidated else { return }
            self.invalidated = true
            self.assembler?.discard()
            self.assembler = nil
            self.session.invalidateAndCancel()
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest,
    ) -> Bool {
        // Called on accessQueue.
        guard !invalidated else { return false }
        var request = URLRequest(url: originalURL)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        contextsByTaskId[task.taskIdentifier] = TaskContext(request: loadingRequest, baseOffset: offset)
        taskByRequest[ObjectIdentifier(loadingRequest)] = task
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest,
    ) {
        if let task = taskByRequest.removeValue(forKey: ObjectIdentifier(loadingRequest)) {
            contextsByTaskId.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        accessQueue.async {
            if let http = response as? HTTPURLResponse {
                if self.contentLength == nil {
                    self.contentLength = Self.totalLength(from: http)
                    if let len = self.contentLength, self.assembler == nil {
                        self.assembler = CacheAssembler(cache: self.cache, key: self.cacheKey, totalLength: len)
                    }
                }
                if let ctx = self.contextsByTaskId[dataTask.taskIdentifier],
                   let info = ctx.request.contentInformationRequest {
                    info.contentType = http.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.audio.identifier
                    info.isByteRangeAccessSupported = true
                    if let len = self.contentLength { info.contentLength = len }
                    // A content-information probe with no data request is satisfied
                    // by the headers alone — finish now instead of downloading the
                    // whole body just to throw it away.
                    if ctx.request.dataRequest == nil {
                        ctx.request.finishLoading()
                        self.contextsByTaskId.removeValue(forKey: dataTask.taskIdentifier)
                        self.taskByRequest.removeValue(forKey: ObjectIdentifier(ctx.request))
                        completionHandler(.cancel)
                        return
                    }
                }
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        accessQueue.async {
            guard var ctx = self.contextsByTaskId[dataTask.taskIdentifier], !ctx.request.isFinished else { return }
            let absoluteOffset = ctx.baseOffset + ctx.received
            ctx.request.dataRequest?.respond(with: data)
            ctx.received += Int64(data.count)
            self.contextsByTaskId[dataTask.taskIdentifier] = ctx

            self.assembler?.write(data, at: absoluteOffset)

            if let dataRequest = ctx.request.dataRequest, !dataRequest.requestsAllDataToEndOfResource {
                let requestedEnd = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
                if ctx.baseOffset + ctx.received >= requestedEnd {
                    ctx.request.finishLoading()
                    self.contextsByTaskId.removeValue(forKey: dataTask.taskIdentifier)
                    self.taskByRequest.removeValue(forKey: ObjectIdentifier(ctx.request))
                    dataTask.cancel()
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        accessQueue.async {
            guard let ctx = self.contextsByTaskId.removeValue(forKey: task.taskIdentifier) else { return }
            self.taskByRequest.removeValue(forKey: ObjectIdentifier(ctx.request))
            if ctx.request.isFinished {
                // already satisfied + finished by didReceive
            } else if let error, (error as? URLError)?.code != .cancelled {
                ctx.request.finishLoading(with: error)
            } else {
                ctx.request.finishLoading()
            }
            self.assembler?.commitIfComplete()
        }
    }

    /// Total resource length from a (possibly ranged) response: prefer the total in
    /// `Content-Range`, else the full length of a non-ranged 200.
    private static func totalLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let total = Int64(totalPart) {
            return total
        }
        if response.statusCode == 200, response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return nil
    }
}

/// Assembles streamed byte ranges into a temp file and commits it to the cache
/// once the whole `[0, totalLength)` range is covered. Confined to the delegate's
/// `accessQueue`, so it needs no internal locking.
private final class CacheAssembler {
    private let cache: StreamingMediaDiskCache
    private let key: String
    private let totalLength: Int64
    private let tempURL: URL?
    private let handle: FileHandle?
    /// Sorted, merged covered byte ranges as half-open `[start, end)` pairs.
    private var covered: [(start: Int64, end: Int64)] = []
    private var committed = false
    private var failed = false

    init(cache: StreamingMediaDiskCache, key: String, totalLength: Int64) {
        self.cache = cache
        self.key = key
        self.totalLength = totalLength
        if let url = cache.makeTemporaryFileURL() {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.tempURL = url
            self.handle = try? FileHandle(forWritingTo: url)
        } else {
            self.tempURL = nil
            self.handle = nil
        }
    }

    func write(_ data: Data, at offset: Int64) {
        guard !committed, !failed, !data.isEmpty, let handle else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            failed = true
            return
        }
        addCovered(start: offset, end: offset + Int64(data.count))
    }

    func commitIfComplete() {
        guard !committed, !failed, let tempURL, let handle else { return }
        guard covered.count == 1, covered[0].start <= 0, covered[0].end >= totalLength else { return }
        committed = true
        try? handle.close()
        cache.commit(temporaryFileURL: tempURL, forKey: key)
    }

    func discard() {
        guard !committed else { return }
        failed = true
        try? handle?.close()
        if let tempURL { cache.discardTemporaryFile(tempURL) }
    }

    private func addCovered(start: Int64, end: Int64) {
        guard end > start else { return }
        covered.append((start, end))
        covered.sort { $0.start < $1.start }
        var merged: [(start: Int64, end: Int64)] = []
        for range in covered {
            if var last = merged.last, range.start <= last.end {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        covered = merged
    }
}
