import Foundation

/// Acquisition backend for Downtify (Spotify/YouTube downloader). Track-level:
/// searches by `artist title`, picks the best song, and POSTs a download by URL.
/// Progress comes from polling `/api/queue`.
struct DowntifyAcquisitionPlugin: AcquisitionProviding {
    let kind: AcquisitionPluginKind = .downtify

    private var base: String { AcquisitionConfigStore.value(.downtify, "baseURL") }
    private var credentials: DowntifyCredentials {
        DowntifyCredentials(
            username: AcquisitionConfigStore.value(.downtify, "username"),
            password: AcquisitionConfigStore.value(.downtify, "password")
        )
    }

    var isConfigured: Bool { !base.isEmpty }

    var capabilities: AcquisitionCapabilities {
        AcquisitionCapabilities(
            displayName: "Downtify",
            iconName: "arrow.down.to.line",
            blurb: "One-tap track downloads. Vellum searches Downtify, picks the best match, and queues a download.",
            requirementsSummary: "Use the address you open Downtify with, including the port, and the account you sign in to Downtify with. Leave the account empty only if accounts are turned off on that server.",
            granularity: .track,
            supportsTrackSearch: true,
            configFields: [
                AcquisitionConfigField(
                    id: "baseURL",
                    kind: .url,
                    label: "Server",
                    placeholder: "192.168.1.10:8000"
                ),
                AcquisitionConfigField(
                    id: "username",
                    kind: .username,
                    label: "Username",
                    placeholder: "username",
                    required: false
                ),
                AcquisitionConfigField(
                    id: "password",
                    kind: .password,
                    label: "Password",
                    placeholder: "password",
                    required: false
                ),
            ]
        )
    }

    /// Test Connection. It used to read the queue with no credentials at all, which a current
    /// Downtify refuses (every route but a handful needs a signed-in user) — so it failed on every
    /// server with accounts, and "passed" on anything that answered `/api/queue` with a 200.
    ///
    /// Now: the public server-info route says whether this is Downtify and whether it requires
    /// sign-in; if it does, sign in and ask the server who this session is. A server too old to
    /// have that route has no accounts, so a plain queue read is the check there.
    func validate() async -> Result<String, Error> {
        guard isConfigured else { return .failure(AcquisitionError("Enter your Downtify server URL.")) }
        do {
            guard let info = try await DowntifyClient.serverInfo(base: base) else {
                _ = try await DowntifyClient.queue(base: base, credentials: DowntifyCredentials(username: "", password: ""))
                return .success("Connected to Downtify (an older version without accounts).")
            }
            guard info.product.caseInsensitiveCompare("Downtify") == .orderedSame else {
                return .failure(AcquisitionError("That address answered as \(info.product), not Downtify. Check the Server Address and port."))
            }
            let label = info.version.map { "Downtify \($0)" } ?? "Downtify"
            guard info.requiresSignIn else {
                _ = try await DowntifyClient.queue(base: base, credentials: credentials)
                return .success("Connected to \(label). Accounts are turned off on this server.")
            }
            let user = try await DowntifyClient.verifySignIn(base: base, credentials: credentials)
            return .success("Signed in to \(label) as \(user).")
        } catch {
            return .failure(AcquisitionError((error as? LocalizedError)?.errorDescription ?? AcquisitionHTTP.userFacingMessage(for: error)))
        }
    }

    func search(query: String) async throws -> [AcquisitionResult] {
        guard isConfigured else { return [] }
        let songs = try await DowntifyClient.search(base: base, credentials: credentials, query: query)
        return songs.map { Self.result(from: $0) }
    }

    func enqueue(_ request: AcquisitionRequest) async throws -> String {
        guard isConfigured else { throw AcquisitionError("Configure Downtify in Settings first.") }
        let url: String
        if let direct = request.sourceURL, !direct.isEmpty {
            url = direct
        } else {
            let songs = try await DowntifyClient.search(base: base, credentials: credentials, query: request.searchTerm)
            let title = request.trackTitle ?? request.albumTitle ?? ""
            guard let best = DowntifyClient.pickBest(from: songs, artist: request.artist, title: title) else {
                throw AcquisitionError("No Downtify results for \"\(request.displayTitle)\".")
            }
            url = best.url
        }
        try await DowntifyClient.enqueue(base: base, credentials: credentials, url: url)
        return url
    }

    func activeJobs() async throws -> [AcquisitionJob] {
        guard isConfigured else { return [] }
        let jobs = try await DowntifyClient.queue(base: base, credentials: credentials)
        return jobs.map { job in
            AcquisitionJob(
                id: "downtify:\(job.id)",
                title: job.title,
                artist: job.artist,
                status: Self.status(from: job.status),
                progress: job.progress,
                message: job.message,
                kind: .downtify,
                nativeId: job.url.isEmpty ? nil : job.url,
                source: .server
            )
        }
    }

    private static func result(from song: DowntifySong) -> AcquisitionResult {
        AcquisitionResult(
            id: song.url.isEmpty ? song.songId : song.url,
            title: song.name,
            artists: song.artists,
            albumName: song.albumName,
            coverURL: song.coverURL,
            year: song.year,
            explicit: song.explicit,
            subtitle: nil,
            request: AcquisitionRequest(
                artist: song.artists.first ?? "",
                trackTitle: song.name,
                albumTitle: song.albumName.isEmpty ? nil : song.albumName,
                coverURL: song.coverURL,
                sourceURL: song.url.isEmpty ? nil : song.url
            )
        )
    }

    private static func status(from s: DowntifyJobStatus) -> AcquisitionJobStatus {
        switch s {
        case .queued: return .queued
        case .downloading: return .downloading
        case .done: return .done
        case .failed: return .failed
        case .unknown: return .unknown
        }
    }
}
