import Foundation
import Testing

@testable import VellumMusicKit

/// #17: each request plugin's Test Connection must really check the credentials, against a fake
/// server that answers the way the real one does. Nothing here reaches a network: every request
/// goes through `FakeServer`, a `URLProtocol` installed on `AcquisitionHTTP.session`.
///
/// For each plugin: a wrong credential must report failure, naming the service; a good one must
/// pass; and the Activity read must either return the server's jobs or throw, never quietly
/// return nothing.
@Suite("Acquisition plugin Test Connection (#17)", .serialized)
struct AcquisitionPluginValidationTests {
    // MARK: Fake server

    /// Routes every request to `handler` and records what was asked.
    final class FakeServer: URLProtocol {
        struct Reply {
            var status: Int
            var headers: [String: String] = [:]
            var body: Data = Data()

            static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
                var h = headers
                h["Content-Type"] = "application/json"
                return Reply(status: status, headers: h, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            }
        }

        nonisolated(unsafe) static var handler: (URLRequest, Data) -> Reply = { _, _ in Reply(status: 404) }
        nonisolated(unsafe) static var requests: [URLRequest] = []
        private static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.readBody(request)
            Self.lock.lock()
            Self.requests.append(request)
            let handler = Self.handler
            Self.lock.unlock()
            let reply = handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func readBody(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }

        static func requested(path: String) -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0.url?.path == path }
        }
    }

    /// Installs the fake server and the plugin's settings for the length of `body`, then puts
    /// back the real session and whatever settings were there before.
    static func withServer(
        _ kind: AcquisitionPluginKind,
        config: [String: String],
        handler: @escaping (URLRequest, Data) -> FakeServer.Reply,
        _ body: () async throws -> Void
    ) async rethrows {
        let fields = ["baseURL", "apiKey", "username", "password", "loginMethod", "sessionToken"]
        let defaults = UserDefaults.standard
        let saved = fields.map { defaults.object(forKey: "acquisition.\(kind.rawValue).\($0)") }
        let savedSession = AcquisitionHTTP.session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        AcquisitionHTTP.session = URLSession(configuration: configuration)
        FakeServer.handler = handler
        FakeServer.requests = []
        for field in fields { defaults.removeObject(forKey: "acquisition.\(kind.rawValue).\(field)") }
        for (field, value) in config { AcquisitionConfigStore.set(value, kind, field) }
        defer {
            AcquisitionHTTP.session = savedSession
            for (field, value) in zip(fields, saved) {
                let key = "acquisition.\(kind.rawValue).\(field)"
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    /// A fresh host per test, so no session cached by an earlier test can answer for this one.
    static func uniqueBase(_ name: String) -> String { "http://\(name)-\(UUID().uuidString.prefix(8).lowercased()).test:8000" }

    static func message(_ result: Result<String, Error>) -> String {
        switch result {
        case .success(let text): return text
        case .failure(let error): return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func jsonBody(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Lidarr

    static let lidarrKey = "0123456789abcdef0123456789abcdef"

    static func lidarr(_ request: URLRequest, _: Data) -> FakeServer.Reply {
        guard request.value(forHTTPHeaderField: "X-Api-Key") == lidarrKey else {
            return FakeServer.Reply(status: 401)
        }
        switch request.url?.path {
        case "/api/v1/system/status":
            return .json(["appName": "Lidarr", "instanceName": "Lidarr", "version": "2.9.6.4552"])
        case "/api/v1/queue":
            return .json(["page": 1, "totalRecords": 1, "records": [[
                "id": 7, "title": "Artist.A-Album.A-WEB-2024", "status": "downloading",
                "trackedDownloadState": "downloading", "size": 100, "sizeleft": 25,
                "album": ["id": 3, "title": "Album A", "foreignAlbumId": "rg-a"],
                "artist": ["artistName": "Artist A"],
            ]]])
        case "/api/v1/command":
            return .json([] as [Any])
        default:
            return FakeServer.Reply(status: 404)
        }
    }

    @Test("Lidarr: a wrong API key fails and says Lidarr rejected the key")
    func lidarrWrongKey() async {
        await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("lidarr"), "apiKey": "wrong-key"], handler: Self.lidarr) {
            let result = await LidarrAcquisitionPlugin().validate()
            guard case .failure = result else { Issue.record("wrong key passed: \(Self.message(result))"); return }
            #expect(Self.message(result).contains("Lidarr"))
            #expect(Self.message(result).lowercased().contains("api key"))
            // It was an authenticated request: the key was sent, and refused.
            #expect(FakeServer.requested(path: "/api/v1/system/status").first?.value(forHTTPHeaderField: "X-Api-Key") == "wrong-key")
        }
    }

    @Test("Lidarr: the right key passes and reports the version")
    func lidarrGoodKey() async {
        await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("lidarr"), "apiKey": Self.lidarrKey], handler: Self.lidarr) {
            let result = await LidarrAcquisitionPlugin().validate()
            guard case .success = result else { Issue.record("good key failed: \(Self.message(result))"); return }
            #expect(Self.message(result).contains("2.9.6"))
        }
    }

    @Test("Lidarr: an address that answers 200 with a web page is not a connection")
    func lidarrWrongService() async {
        await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("notlidarr"), "apiKey": Self.lidarrKey], handler: { _, _ in
            FakeServer.Reply(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html><body>Router login</body></html>".utf8))
        }) {
            let result = await LidarrAcquisitionPlugin().validate()
            guard case .failure = result else { Issue.record("an HTML page passed as Lidarr: \(Self.message(result))"); return }
            #expect(Self.message(result).contains("Lidarr"))
        }
    }

    @Test("Lidarr: Activity lists the server's queue, and a refused read throws instead of looking empty")
    func lidarrActivity() async throws {
        try await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("lidarr"), "apiKey": Self.lidarrKey], handler: Self.lidarr) {
            let jobs = try await LidarrAcquisitionPlugin().activeJobs()
            #expect(jobs.count == 1)
            #expect(jobs.first?.title == "Album A")
            #expect(jobs.first?.artist == "Artist A")
            #expect(jobs.first?.status == .downloading)
            #expect(jobs.first?.progress == 0.75)
        }
        await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("lidarr"), "apiKey": "wrong-key"], handler: Self.lidarr) {
            await #expect(throws: (any Error).self) {
                try await LidarrAcquisitionPlugin().activeJobs()
            }
        }
    }

    // MARK: Downtify

    /// A current Downtify (3.x): accounts on, a web session cookie from `POST /api/auth/login`.
    static func downtify(_ request: URLRequest, _ body: Data) -> FakeServer.Reply {
        let signedIn = (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("downtify_session=sess-alice")
        switch request.url?.path {
        case "/api/server/info":
            return .json(["server_id": "abc", "name": "nas", "product": "Downtify", "version": "3.2.0", "api_version": 1, "require_sign_in": true])
        case "/api/auth/login":
            let creds = jsonBody(body)
            guard request.httpMethod == "POST",
                  (creds["username"] as? String)?.lowercased() == "alice",
                  creds["password"] as? String == "right-password"
            else { return .json(["detail": "Wrong username or password"], status: 401) }
            return .json(["signed_in": true, "user": ["username": "alice", "role": "user"]],
                         headers: ["Set-Cookie": "downtify_session=sess-alice; Path=/; HttpOnly; SameSite=Lax"])
        case "/api/auth/status":
            return .json(["require_sign_in": true, "auth_disabled": false, "signed_in": signedIn,
                          "via": signedIn ? "session" : NSNull(),
                          "user": signedIn ? ["username": "alice", "role": "user"] as Any : NSNull()])
        case "/api/queue":
            guard signedIn else { return .json(["detail": "Not authenticated"], status: 401, headers: ["WWW-Authenticate": "Bearer"]) }
            return .json([[
                "song": ["name": "Song B", "artists": ["Artist B"], "url": "https://music.youtube.com/watch?v=b"],
                "status": "downloading", "progress": 40, "message": "", "position": 1,
            ]])
        default:
            return FakeServer.Reply(status: 404)
        }
    }

    static func downtifyConfig(password: String) -> [String: String] {
        ["baseURL": uniqueBase("downtify"), "username": "alice", "password": password]
    }

    @Test("Downtify: a wrong password fails and says Downtify rejected it")
    func downtifyWrongPassword() async {
        await Self.withServer(.downtify, config: Self.downtifyConfig(password: "wrong-password"), handler: Self.downtify) {
            let result = await DowntifyAcquisitionPlugin().validate()
            guard case .failure = result else { Issue.record("wrong password passed: \(Self.message(result))"); return }
            #expect(Self.message(result).contains("Downtify"))
            #expect(Self.message(result).lowercased().contains("password"))
        }
    }

    @Test("Downtify: the right password signs in, and the check is made with the session it got")
    func downtifyGoodPassword() async {
        await Self.withServer(.downtify, config: Self.downtifyConfig(password: "right-password"), handler: Self.downtify) {
            let result = await DowntifyAcquisitionPlugin().validate()
            guard case .success = result else { Issue.record("good password failed: \(Self.message(result))"); return }
            #expect(Self.message(result).contains("alice"))
            #expect(!FakeServer.requested(path: "/api/auth/login").isEmpty)
        }
    }

    @Test("Downtify: Activity reads the signed-in user's queue, and a refused read throws")
    func downtifyActivity() async throws {
        try await Self.withServer(.downtify, config: Self.downtifyConfig(password: "right-password"), handler: Self.downtify) {
            let jobs = try await DowntifyAcquisitionPlugin().activeJobs()
            #expect(jobs.count == 1)
            #expect(jobs.first?.title == "Song B")
            #expect(jobs.first?.artist == "Artist B")
            #expect(jobs.first?.status == .downloading)
        }
        await Self.withServer(.downtify, config: Self.downtifyConfig(password: "wrong-password"), handler: Self.downtify) {
            await #expect(throws: (any Error).self) {
                try await DowntifyAcquisitionPlugin().activeJobs()
            }
        }
    }

    // MARK: DroppedNeedle

    /// Tokens the fake DroppedNeedle currently honours, and the next one it will issue.
    nonisolated(unsafe) static var droppedNeedleValidTokens: Set<String> = []
    nonisolated(unsafe) static var droppedNeedleNextToken = 1

    static func droppedNeedle(_ request: URLRequest, _ body: Data) -> FakeServer.Reply {
        let bearer = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        let authed = droppedNeedleValidTokens.contains(bearer)
        switch request.url?.path {
        case "/api/v1/auth/login":
            let creds = jsonBody(body)
            guard creds["username"] as? String == "alice", creds["password"] as? String == "right-password" else {
                return .json(["detail": "Invalid credentials"], status: 401)
            }
            let token = "tok-\(droppedNeedleNextToken)"
            droppedNeedleNextToken += 1
            droppedNeedleValidTokens.insert(token)
            return .json(["token": token])
        case "/api/v1/system/health":
            return authed ? .json(["status": "ok"]) : .json(["error": ["message": "Invalid or expired token"]], status: 401)
        case "/api/v1/downloads":
            guard authed else { return .json(["error": ["message": "Invalid or expired token"]], status: 401) }
            return .json(["items": [[
                "id": "task-9", "status": "downloading", "progress_percent": 30,
                "album_title": "Album C", "artist_name": "Artist C", "release_group_mbid": "rg-c",
            ]]])
        default:
            return FakeServer.Reply(status: 404)
        }
    }

    static func droppedNeedleConfig(password: String) -> [String: String] {
        ["baseURL": uniqueBase("droppedneedle"), "loginMethod": "local", "username": "alice", "password": password]
    }

    @Test("DroppedNeedle: a wrong password fails and says DroppedNeedle rejected it")
    func droppedNeedleWrongPassword() async {
        Self.droppedNeedleValidTokens = []
        await Self.withServer(.droppedNeedle, config: Self.droppedNeedleConfig(password: "wrong-password"), handler: Self.droppedNeedle) {
            let result = await DroppedNeedleAcquisitionPlugin().validate()
            guard case .failure = result else { Issue.record("wrong password passed: \(Self.message(result))"); return }
            #expect(Self.message(result).contains("DroppedNeedle"))
            #expect(Self.message(result).lowercased().contains("password"))
        }
    }

    @Test("DroppedNeedle: the right password passes, checked with an authenticated call")
    func droppedNeedleGoodPassword() async {
        Self.droppedNeedleValidTokens = []
        await Self.withServer(.droppedNeedle, config: Self.droppedNeedleConfig(password: "right-password"), handler: Self.droppedNeedle) {
            let result = await DroppedNeedleAcquisitionPlugin().validate()
            guard case .success = result else { Issue.record("good password failed: \(Self.message(result))"); return }
            let health = FakeServer.requested(path: "/api/v1/system/health")
            #expect(health.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer tok-") == true)
        }
    }

    @Test("DroppedNeedle: an expired session is renewed, so Activity still shows the server's downloads")
    func droppedNeedleExpiredSessionRenews() async throws {
        Self.droppedNeedleValidTokens = []
        try await Self.withServer(.droppedNeedle, config: Self.droppedNeedleConfig(password: "right-password"), handler: Self.droppedNeedle) {
            let plugin = DroppedNeedleAcquisitionPlugin()
            guard case .success = await plugin.validate() else { Issue.record("could not sign in"); return }
            // The server forgets every session it issued, as after a restart or token expiry.
            Self.droppedNeedleValidTokens = []
            let jobs = try await plugin.activeJobs()
            #expect(jobs.count == 1)
            #expect(jobs.first?.title == "Album C")
            #expect(jobs.first?.status == .downloading)
            #expect(FakeServer.requested(path: "/api/v1/auth/login").count == 2)
        }
    }

    // MARK: Activity in Settings

    @Test("Settings Activity: a refused queue read is reported, not shown as an empty queue")
    @MainActor
    func managerReportsUnreadableActivity() async {
        let defaults = UserDefaults.standard
        let savedPlugin = defaults.object(forKey: "acquisition.activePlugin")
        let savedJobs = defaults.object(forKey: "vellumAcquisitionJobs")
        defer {
            if let savedPlugin { defaults.set(savedPlugin, forKey: "acquisition.activePlugin") } else { defaults.removeObject(forKey: "acquisition.activePlugin") }
            if let savedJobs { defaults.set(savedJobs, forKey: "vellumAcquisitionJobs") } else { defaults.removeObject(forKey: "vellumAcquisitionJobs") }
        }
        await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("lidarr"), "apiKey": "wrong-key"], handler: Self.lidarr) {
            defaults.set(AcquisitionPluginKind.lidarr.rawValue, forKey: "acquisition.activePlugin")
            let manager = AcquisitionManager()
            await manager.refreshFromServer()
            #expect(manager.activityError?.contains("API key") == true)
            #expect(manager.serverJobs.isEmpty)
        }
        await Self.withServer(.lidarr, config: ["baseURL": Self.uniqueBase("lidarr"), "apiKey": Self.lidarrKey], handler: Self.lidarr) {
            defaults.set(AcquisitionPluginKind.lidarr.rawValue, forKey: "acquisition.activePlugin")
            let manager = AcquisitionManager()
            await manager.refreshFromServer()
            #expect(manager.activityError == nil)
            #expect(manager.displayJobs.contains { $0.title == "Album A" })
        }
    }

    // MARK: Field copy

    @Test("each setup form's one footer names the service and where its values come from")
    @MainActor
    func fieldCopyNamesTheSource() {
        for kind in AcquisitionPluginKind.allCases {
            let caps = AcquisitionManager.capabilities(for: kind)
            #expect(caps.requirementsSummary.contains(caps.displayName))
            #expect(caps.requirementsSummary.contains("address"))
            // A footer, not a manual: one or two sentences under the fields.
            #expect(caps.requirementsSummary.count < 200, "\(caps.displayName) footer is \(caps.requirementsSummary.count) characters")
        }
        #expect(AcquisitionManager.capabilities(for: .lidarr).requirementsSummary.contains("Settings → General → Security"))
    }
}
