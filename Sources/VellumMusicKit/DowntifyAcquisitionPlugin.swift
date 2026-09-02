import Foundation

/// Acquisition backend for Downtify (Spotify/YouTube downloader). Track-level:
/// searches by `artist title`, picks the best song, and POSTs a download by URL.
/// Progress comes from polling `/api/queue`.
struct DowntifyAcquisitionPlugin: AcquisitionProviding {
    let kind: AcquisitionPluginKind = .downtify

    private var base: String { AcquisitionConfigStore.value(.downtify, "baseURL") }

    var isConfigured: Bool { !base.isEmpty }

    var capabilities: AcquisitionCapabilities {
        AcquisitionCapabilities(
            displayName: "Downtify",
            iconName: "arrow.down.to.line",
            blurb: "One-tap track downloads. Vellum searches Downtify, picks the best match, and queues a download.",
            requirementsSummary: "Downtify only needs its server address. No API key.",
            granularity: .track,
            supportsTrackSearch: true,
            configFields: [
                AcquisitionConfigField(
                    id: "baseURL",
                    kind: .url,
                    label: "Server Address",
                    placeholder: "http://192.168.1.10:8000",
                    helpText: "The same address you use to open Downtify in a browser, including the port."
                )
            ]
        )
    }

    func validate() async -> Result<String, Error> {
        guard isConfigured else { return .failure(AcquisitionError("Enter your Downtify server URL.")) }
        do {
            _ = try await DowntifyClient.queue(base: base)
            return .success("Connected to Downtify.")
        } catch {
            return .failure(AcquisitionError(AcquisitionHTTP.userFacingMessage(for: error)))
        }
    }

    func search(query: String) async throws -> [AcquisitionResult] {
        guard isConfigured else { return [] }
        let songs = try await DowntifyClient.search(base: base, query: query)
        return songs.map { Self.result(from: $0) }
    }

    func enqueue(_ request: AcquisitionRequest) async throws -> String {
        guard isConfigured else { throw AcquisitionError("Configure Downtify in Settings first.") }
        let url: String
        if let direct = request.sourceURL, !direct.isEmpty {
            url = direct
        } else {
            let songs = try await DowntifyClient.search(base: base, query: request.searchTerm)
            let title = request.trackTitle ?? request.albumTitle ?? ""
            guard let best = DowntifyClient.pickBest(from: songs, artist: request.artist, title: title) else {
                throw AcquisitionError("No Downtify results for \"\(request.displayTitle)\".")
            }
            url = best.url
        }
        try await DowntifyClient.enqueue(base: base, url: url)
        return url
    }

    func activeJobs() async -> [AcquisitionJob] {
        guard isConfigured, let jobs = try? await DowntifyClient.queue(base: base) else { return [] }
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
