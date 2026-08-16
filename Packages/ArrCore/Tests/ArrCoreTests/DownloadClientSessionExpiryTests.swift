import Foundation
import Testing
@testable import ArrCore

// MARK: - Mock URL protocol

/// File-private stub; the process-wide handler is why the suite below is
/// `.serialized`, same arrangement as `DownloadClientTests`. Installed via
/// `protocolClasses` on a session we build ourselves, so nothing outside this
/// file is affected.
private final class ExpiryMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    // Scoped to this suite's hosts. Answering every request — suites run in
    // parallel — serves other suites their neighbour's fixture, and the victim
    // sees impossible values (zero requests for a call it definitely made).
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "dl-expiry.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func expirySession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ExpiryMockProtocol.self]
    config.httpCookieStorage = HTTPCookieStorage()
    config.httpCookieAcceptPolicy = .always
    config.httpShouldSetCookies = true
    return URLSession(configuration: config)
}

/// Tally of what the client actually sent. Reference type + `@unchecked
/// Sendable` because the handler runs on URLSession's own queue; the test only
/// reads it after awaiting the call, which is the ordering that matters. Same
/// shape as `RequestLog` in `DownloadClientTests`.
private final class CallLog: @unchecked Sendable {
    var calls: [String] = []
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }
}

/// Hands out one scripted response code per call, then `fallback` forever.
/// Reference type so the escaping `URLProtocol` handler can advance it.
private final class ScriptedCodes: @unchecked Sendable {
    private let scripted: [Int]
    private let fallback: Int
    private var index = 0

    init(_ scripted: [Int], then fallback: Int) {
        self.scripted = scripted
        self.fallback = fallback
    }

    func next() -> Int {
        defer { index += 1 }
        return index < scripted.count ? scripted[index] : fallback
    }
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

private func rpcMethod(_ request: URLRequest) -> String {
    let body = requestBody(request).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    return (body["method"] as? String) ?? ""
}

private func jsonResponse(_ url: URL, _ object: Any) -> (Data, HTTPURLResponse) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

private func textResponse(_ url: URL, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

// MARK: - Tests

/// Both clients are cached for the app's lifetime by `QueueAggregator` /
/// `DownloadProgressService`, but their sessions are not: qBittorrent expires a
/// SID after an hour idle (and drops every session on restart), Deluge's cookie
/// dies with the daemon. Before the fix the first rejection after that was
/// terminal — every pause/resume failed and the progress overlay went blank
/// until ArrBarr was relaunched, while the Settings health dot (which builds a
/// *fresh* client each minute and logs in fine) stayed reassuringly green.
@Suite("Download-client session expiry", .serialized)
struct DownloadClientSessionExpiryTests {

    // MARK: qBittorrent — rejects with HTTP 403

    @Suite("qBittorrent")
    struct QbittorrentSessionExpiryTests {
        private static let loginConfig = ServiceConfig(
            enabled: true, baseURL: "http://dl-expiry.test:8080",
            apiKey: "", username: "admin", password: "secret"
        )

        /// Answers `/auth/login` with "Ok." and hands out `actionCodes` one per
        /// non-login request, so a test can script "reject once, then fine" or
        /// "reject forever".
        private func install(_ log: CallLog, actionCodes: [Int]) {
            let codes = ScriptedCodes(actionCodes, then: 200)
            ExpiryMockProtocol.handler = { request in
                let path = request.url!.path
                log.calls.append(path)
                if path == "/api/v2/auth/login" { return textResponse(request.url!, "Ok.") }
                let code = codes.next()
                guard code < 400 else { return textResponse(request.url!, "Forbidden", status: code) }
                return textResponse(request.url!, "")
            }
        }

        @Test("A 403 mid-session re-logs-in and retries once, then succeeds")
        func reloginAndRetry() async throws {
            let log = CallLog()
            install(log, actionCodes: [403, 200])

            let client = QbittorrentClient(config: Self.loginConfig, session: expirySession())
            // Must NOT throw — the point of the fix is that the user's pause works.
            try await client.perform(.pause, hash: "abc")

            #expect(log.count("/api/v2/auth/login") == 2)    // initial + refresh
            #expect(log.count("/api/v2/torrents/stop") == 2) // rejected + retried
        }

        /// Retrying exactly once is what bounds the recursion. A second
        /// rejection means the credentials are wrong, not the cookie stale, and
        /// that has to reach the user instead of spinning.
        @Test("A permanent 403 surfaces after exactly one retry — it does not loop")
        func permanentRejectionDoesNotLoop() async throws {
            let log = CallLog()
            install(log, actionCodes: [403, 403, 403, 403, 403])

            let client = QbittorrentClient(config: Self.loginConfig, session: expirySession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, hash: "abc")
            }

            #expect(log.count("/api/v2/auth/login") == 2)
            #expect(log.count("/api/v2/torrents/stop") == 2)
        }

        /// A reverse proxy doing the auth in front of qBittorrent answers 401
        /// rather than 403 — same expired-session story, same recovery.
        @Test("A 401 from a fronting proxy recovers the same way")
        func proxy401AlsoRecovers() async throws {
            let log = CallLog()
            install(log, actionCodes: [401, 200])

            let client = QbittorrentClient(config: Self.loginConfig, session: expirySession())
            try await client.perform(.pause, hash: "abc")

            #expect(log.count("/api/v2/auth/login") == 2)
            #expect(log.count("/api/v2/torrents/stop") == 2)
        }

        /// The progress fetch shares the same choke point — an expired session
        /// used to blank the download overlay silently, which is how the bug
        /// got noticed at all.
        @Test("The progress fetch recovers from an expired session too")
        func progressFetchRecovers() async throws {
            let log = CallLog()
            let codes = ScriptedCodes([403], then: 200)
            let torrents = #"[{"hash":"ABC","name":"n","state":"downloading","progress":0.5,"dlspeed":10,"eta":60,"size":100}]"#
            ExpiryMockProtocol.handler = { request in
                let path = request.url!.path
                log.calls.append(path)
                if path == "/api/v2/auth/login" { return textResponse(request.url!, "Ok.") }
                let code = codes.next()
                guard code < 400 else { return textResponse(request.url!, "Forbidden", status: code) }
                return textResponse(request.url!, torrents)
            }

            let client = QbittorrentClient(config: Self.loginConfig, session: expirySession())
            let progress = try await client.fetchProgress()

            #expect(progress["abc"]?.progress == 0.5)
            #expect(log.count("/api/v2/auth/login") == 2)
        }

        /// API-key mode has no session to refresh — the key travels on every
        /// request — so a 403 there means the key is wrong and must surface
        /// immediately rather than burning a pointless login round-trip.
        @Test("API-key mode does not attempt a re-login")
        func apiKeyModeDoesNotRelogin() async throws {
            let log = CallLog()
            install(log, actionCodes: [403, 200])

            let apiKeyConfig = ServiceConfig(
                enabled: true, baseURL: "http://dl-expiry.test:8080",
                apiKey: "", username: "", password: "mykey"
            )
            let client = QbittorrentClient(config: apiKeyConfig, session: expirySession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, hash: "abc")
            }

            #expect(log.count("/api/v2/auth/login") == 0)
            #expect(log.count("/api/v2/torrents/stop") == 1)
        }
    }

    // MARK: Deluge — rejects in-band, with HTTP 200

    @Suite("Deluge")
    struct DelugeSessionExpiryTests {
        private static let config = ServiceConfig(
            enabled: true, baseURL: "http://dl-expiry.test:8112",
            apiKey: "", username: "", password: "deluge"
        )

        /// Deluge answers an expired session with **HTTP 200** carrying an
        /// `error` envelope, so the HTTP layer never sees a bad status and the
        /// body has to be inspected. `rejections` is how many of the leading
        /// `core.*` RPCs come back rejected.
        private func install(_ log: CallLog, rejections: Int, envelope: [String: Any], result: Any = NSNull()) {
            let codes = ScriptedCodes(Array(repeating: 1, count: rejections), then: 0)
            ExpiryMockProtocol.handler = { request in
                let method = rpcMethod(request)
                log.calls.append(method)
                if method == "auth.login" {
                    return jsonResponse(request.url!, ["result": true, "error": NSNull(), "id": 1])
                }
                if codes.next() == 1 {
                    return jsonResponse(request.url!, ["result": NSNull(), "error": envelope, "id": 2])
                }
                return jsonResponse(request.url!, ["result": result, "error": NSNull(), "id": 3])
            }
        }

        /// Deluge sets both fields, but a daemon that sets only one still has
        /// to recover — hence three envelope shapes. Passed as JSON text
        /// because `[String: Any]` isn't `Sendable` and so can't be a test
        /// argument.
        @Test("A rejected RPC re-authenticates and retries once, then succeeds",
              arguments: [
                #"{"message": "Not authenticated", "code": 1}"#,
                #"{"message": "Not authenticated"}"#,
                #"{"code": 1}"#,
              ])
        func reauthenticateAndRetry(_ envelopeJSON: String) async throws {
            let decoded = try JSONSerialization.jsonObject(with: Data(envelopeJSON.utf8))
            let envelope = try #require(decoded as? [String: Any])
            let log = CallLog()
            install(log, rejections: 1, envelope: envelope)

            let client = DelugeClient(config: Self.config, session: expirySession())
            try await client.perform(.pause, hash: "abc")

            #expect(log.count("auth.login") == 2)
            #expect(log.count("core.pause_torrent") == 2)
        }

        @Test("A permanently rejected RPC surfaces after exactly one retry")
        func permanentRejectionDoesNotLoop() async throws {
            let log = CallLog()
            install(log, rejections: 5, envelope: ["message": "Not authenticated", "code": 1])

            let client = DelugeClient(config: Self.config, session: expirySession())
            await #expect(throws: DelugeError.self) {
                try await client.perform(.pause, hash: "abc")
            }

            #expect(log.count("auth.login") == 2)
            #expect(log.count("core.pause_torrent") == 2)
        }

        /// A non-auth error must NOT be mistaken for an expired session: it
        /// would cost a needless login and delay the real reason by a round-trip.
        @Test("An ordinary RPC error is reported, not retried as an auth failure")
        func nonAuthErrorIsNotRetried() async throws {
            let log = CallLog()
            install(log, rejections: 5, envelope: ["message": "Torrent not found", "code": 2])

            let client = DelugeClient(config: Self.config, session: expirySession())
            await #expect(throws: DelugeError.self) {
                try await client.perform(.pause, hash: "abc")
            }

            #expect(log.count("auth.login") == 1)
            #expect(log.count("core.pause_torrent") == 1)
        }

        @Test("The progress fetch recovers from a rejected session too")
        func progressFetchRecovers() async throws {
            let log = CallLog()
            install(
                log, rejections: 1,
                envelope: ["message": "Not authenticated", "code": 1],
                result: ["ABC": ["progress": 50.0, "download_payload_rate": 100]]
            )

            let client = DelugeClient(config: Self.config, session: expirySession())
            let progress = try await client.fetchProgress()

            #expect(progress["abc"]?.progress == 0.5)
            #expect(log.count("auth.login") == 2)
            #expect(log.count("core.get_torrents_status") == 2)
        }
    }
}
