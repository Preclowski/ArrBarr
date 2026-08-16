import Testing
import Foundation
@testable import ArrCore

// MARK: - Fake transport

/// The same fake-transport approach as `DownloadClientTests`: a `URLProtocol`
/// subclass wired into an ephemeral session that answers from a per-test
/// closure. Deliberately a *separate* class from that file's — the handler is
/// one static slot per class, so its own class lets this suite run next to the
/// download-client suite without the two clobbering each other's fixture.
private final class SabMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    // Scoped to this suite's hosts. Answering every request — suites run in
    // parallel — serves other suites their neighbour's fixture, and the victim
    // sees impossible values (zero requests for a call it definitely made).
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
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

private func sabSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SabMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// SAB is asked for `output=json` on every call, so every fixture is a body +
/// status code. `text` is deliberately untyped so tests can hand back things
/// that aren't JSON at all (a reverse-proxy login page).
private func sabReply(_ request: URLRequest, _ text: String, statusCode: Int = 200) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    return (Data(text.utf8), response)
}

/// Every SAB call is a GET whose entire payload lives in the query string.
private func sabQuery(_ request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
}

/// `HTTPError` and `SabnzbdError` aren't Equatable, so `#expect(throws:)` can
/// only prove the error's *type*. Tests that care which failure they got —
/// "service off" and "service on, key blank" are different problems with
/// different fixes — match on the value this returns.
private func thrownError(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

// MARK: - Fixtures

private let sabConfig = ServiceConfig(
    enabled: true, baseURL: "http://localhost:8080",
    apiKey: "sab-key", username: "", password: ""
)

/// Enabled with a URL but no key. `ServiceConfig.isConfigured` passes on this
/// (it only checks the URL), so it's the shape that has to be caught by the
/// client's own key guard.
private let keylessConfig = ServiceConfig(
    enabled: true, baseURL: "http://localhost:8080",
    apiKey: "", username: "", password: ""
)

private let disabledConfig = ServiceConfig(
    enabled: false, baseURL: "http://localhost:8080",
    apiKey: "sab-key", username: "", password: ""
)

/// A realistic two-slot SAB 4.x queue. Every number on the wire is a
/// **string** — SAB pre-formats them for its own web UI — which is why
/// `SabSlot` decodes `mb` / `mbleft` / `percentage` as `String`. The second
/// slot omits `timeleft`, as SAB does for anything that hasn't started.
private let sabQueueJSON = """
{
  "queue": {
    "status": "Downloading",
    "paused": false,
    "speedlimit": "0",
    "noofslots_total": 2,
    "version": "4.3.1",
    "mb": "6144.00",
    "mbleft": "1024.00",
    "slots": [
      {
        "index": 0,
        "nzo_id": "SABnzbd_nzo_AbC123",
        "filename": "Show.S01E01.1080p.WEB-DL",
        "status": "Downloading",
        "cat": "tv",
        "priority": "Normal",
        "mb": "4096.00",
        "mbleft": "1024.00",
        "percentage": "75",
        "timeleft": "0:04:31"
      },
      {
        "index": 1,
        "nzo_id": "SABnzbd_nzo_XyZ789",
        "filename": "Movie.2024.2160p.WEB-DL",
        "status": "Queued",
        "cat": "movies",
        "priority": "Normal",
        "mb": "2048.00",
        "mbleft": "2048.00",
        "percentage": "0"
      }
    ]
  }
}
"""

private let emptyQueueJSON = """
{"queue": {"status": "Idle", "paused": false, "version": "4.3.1", "slots": []}}
"""

// Serialized: `SabMockURLProtocol.handler` is a single static slot, so
// parallel tests inside the suite would overwrite each other's fixture.
@Suite("SabnzbdClient", .serialized)
struct SabnzbdClientTests {

    // MARK: - Auth gate

    @Suite("Auth gate")
    struct AuthGateTests {
        @Test("A disabled service fails before it touches the network")
        func disabledNeverCallsOut() async throws {
            var requestCount = 0
            SabMockURLProtocol.handler = { request in
                requestCount += 1
                return sabReply(request, #"{"status": true}"#)
            }

            let client = SabnzbdClient(config: disabledConfig, session: sabSession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, nzoId: "SABnzbd_nzo_AbC123")
            }
            #expect(requestCount == 0)
        }

        /// SAB's API key isn't optional the way a torrent client's password
        /// is: every mode we call is key-gated, so a blank key can only ever
        /// produce a rejected round-trip. Fail locally instead.
        @Test("A blank API key is refused locally rather than sent and rejected")
        func blankKeyNeverCallsOut() async throws {
            var requestCount = 0
            SabMockURLProtocol.handler = { request in
                requestCount += 1
                return sabReply(request, #"{"status": true}"#)
            }

            let client = SabnzbdClient(config: keylessConfig, session: sabSession())
            let error = await thrownError { try await client.perform(.resume, nzoId: "x") }
            #expect((error as? HTTPError)?.errorDescription == "Service not configured")
            #expect(requestCount == 0)
        }

        /// `testConnection` is the one call that can distinguish the two —
        /// it's reached from Settings, where "you haven't filled the URL in"
        /// and "you haven't filled the key in" need different copy.
        @Test("testConnection reports a blank key as a missing key, not as unconfigured")
        func blankKeyIsItsOwnErrorInSettings() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, emptyQueueJSON) }

            let client = SabnzbdClient(config: keylessConfig, session: sabSession())
            let error = await thrownError { _ = try await client.testConnection() }
            #expect((error as? HTTPError)?.errorDescription == "API key is missing")
        }

        @Test("Every call carries the API key and asks for JSON")
        func keyAndOutputOnEveryCall() async throws {
            var captured: [String: String] = [:]
            SabMockURLProtocol.handler = { request in
                captured = sabQuery(request)
                return sabReply(request, #"{"status": true}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            try await client.perform(.pause, nzoId: "SABnzbd_nzo_AbC123")

            #expect(captured["apikey"] == "sab-key")
            #expect(captured["output"] == "json")
        }
    }

    // MARK: - Actions

    @Suite("Queue actions")
    struct ActionTests {
        @Test("Pause posts mode=queue&name=pause with the nzo id as the value")
        func pause() async throws {
            var captured: [String: String] = [:]
            var path: String?
            SabMockURLProtocol.handler = { request in
                captured = sabQuery(request)
                path = request.url?.path
                return sabReply(request, #"{"status": true}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            try await client.perform(.pause, nzoId: "SABnzbd_nzo_AbC123")

            #expect(path == "/api")
            #expect(captured["mode"] == "queue")
            #expect(captured["name"] == "pause")
            #expect(captured["value"] == "SABnzbd_nzo_AbC123")
        }

        @Test("Resume sends name=resume")
        func resume() async throws {
            var captured: [String: String] = [:]
            SabMockURLProtocol.handler = { request in
                captured = sabQuery(request)
                return sabReply(request, #"{"status": true}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            try await client.perform(.resume, nzoId: "SABnzbd_nzo_AbC123")
            #expect(captured["name"] == "resume")
        }

        /// SAB's delete is `mode=queue&name=delete`, not the `mode=delete` a
        /// reader might expect — the mode names the *collection*, the name
        /// names the verb.
        @Test("Delete sends name=delete against the queue collection")
        func delete() async throws {
            var captured: [String: String] = [:]
            SabMockURLProtocol.handler = { request in
                captured = sabQuery(request)
                return sabReply(request, #"{"status": true}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            try await client.perform(.delete, nzoId: "SABnzbd_nzo_AbC123")
            #expect(captured["mode"] == "queue")
            #expect(captured["name"] == "delete")
        }

        @Test("A status:false body surfaces SAB's own error text")
        func statusFalseCarriesTheReason() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, #"{"status": false, "error": "nzo_id not found"}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let error = await thrownError { try await client.perform(.delete, nzoId: "gone") }
            #expect((error as? SabnzbdError)?.errorDescription == "SABnzbd: nzo_id not found")
        }

        @Test("A status:false body with no error text still fails, with a placeholder")
        func statusFalseWithoutReason() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, #"{"status": false}"#) }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            await #expect(throws: SabnzbdError.self) {
                try await client.perform(.pause, nzoId: "SABnzbd_nzo_AbC123")
            }
        }

        /// The regression this guards: `try?` around the decode reported the
        /// action as done for anything that wasn't SAB JSON — a reverse-proxy
        /// login page, a truncated reply — while the queue never moved.
        @Test("A body that isn't SAB JSON fails the action instead of reporting success")
        func nonJSONBodyIsAFailure() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, "<html><body>Please sign in</body></html>")
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, nzoId: "SABnzbd_nzo_AbC123")
            }
        }

        /// SAB answers a successful queue action with `{"status": true}`, but
        /// older builds and some proxied setups answer `{}`. Only an explicit
        /// `false` is a failure — absence isn't.
        @Test("A body with no status field counts as success")
        func absentStatusIsSuccess() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, "{}") }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            try await client.perform(.resume, nzoId: "SABnzbd_nzo_AbC123")
        }

        @Test("A non-2xx reply surfaces as an HTTP status error")
        func httpFailure() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, "", statusCode: 403)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let error = await thrownError { try await client.perform(.pause, nzoId: "x") }
            #expect((error as? HTTPError)?.errorDescription?.hasPrefix("HTTP 403") == true)
        }
    }

    // MARK: - Queue parsing

    @Suite("Queue parsing")
    struct QueueParsingTests {
        /// The SAB quirk `SabSlot` exists for: sizes and percentages arrive
        /// pre-formatted as strings, so the model can't declare them numeric.
        @Test("SAB's string-typed numbers decode as strings, not as numbers")
        func stringTypedNumbers() throws {
            let resp = try JSONDecoder().decode(SabQueueResponse.self, from: Data(sabQueueJSON.utf8))

            #expect(resp.queue.paused == false)
            #expect(resp.queue.slots.count == 2)

            let first = resp.queue.slots[0]
            #expect(first.nzo_id == "SABnzbd_nzo_AbC123")
            #expect(first.filename == "Show.S01E01.1080p.WEB-DL")
            #expect(first.status == "Downloading")
            #expect(first.mb == "4096.00")
            #expect(first.mbleft == "1024.00")
            #expect(first.percentage == "75")
            #expect(first.timeleft == "0:04:31")
        }

        /// SAB omits `timeleft` for anything it hasn't started, so the slot
        /// model has to tolerate its absence — the queued second slot is the
        /// common case, not an edge one.
        @Test("A slot with no timeleft still decodes")
        func slotWithoutTimeleft() throws {
            let resp = try JSONDecoder().decode(SabQueueResponse.self, from: Data(sabQueueJSON.utf8))
            #expect(resp.queue.slots[1].timeleft == nil)
            #expect(resp.queue.slots[1].percentage == "0")
        }

        /// Keys are lowercased to match `QueueItem.downloadId` the same
        /// case-insensitive way as the torrent clients — SAB's own ids are
        /// mixed case, so a verbatim key would never match.
        @Test("fetchProgress keys progress by lowercased nzo id")
        func progressIsKeyedLowercased() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, sabQueueJSON) }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let progress = try await client.fetchProgress()

            #expect(progress.count == 2)
            #expect(progress["sabnzbd_nzo_abc123"]?.progress == 0.75)
            #expect(progress["sabnzbd_nzo_xyz789"]?.progress == 0)
            #expect(progress["SABnzbd_nzo_AbC123"] == nil)
        }

        /// SAB exposes no trustworthy per-slot speed (its `speed` is a
        /// formatted server-wide figure), so the source leaves it nil rather
        /// than inventing one.
        @Test("fetchProgress reports no per-slot speed")
        func noPerSlotSpeed() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, sabQueueJSON) }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let progress = try await client.fetchProgress()
            #expect(progress["sabnzbd_nzo_abc123"]?.downloadSpeed == nil)
        }

        /// A slot mid-verify or mid-repair can carry a percentage that isn't a
        /// number. That degrades to 0 for the one row instead of throwing away
        /// the whole refresh.
        @Test("A non-numeric percentage degrades to zero instead of failing the refresh")
        func unparseablePercentage() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, """
                {"queue": {"paused": false, "slots": [
                  {"nzo_id": "nzo_1", "filename": "a", "status": "Verifying",
                   "mb": "100.00", "mbleft": "50.00", "percentage": ""},
                  {"nzo_id": "nzo_2", "filename": "b", "status": "Downloading",
                   "mb": "100.00", "mbleft": "10.00", "percentage": "90"}
                ]}}
                """)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let progress = try await client.fetchProgress()

            #expect(progress["nzo_1"]?.progress == 0)
            #expect(progress["nzo_2"]?.progress == 0.9)
        }

        @Test("An empty queue yields no progress entries")
        func emptyQueue() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, emptyQueueJSON) }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let progress = try await client.fetchProgress()
            #expect(progress.isEmpty)
        }

        @Test("An undecodable queue body fails the fetch rather than reporting an empty queue")
        func undecodableQueueBody() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, "<html><body>Please sign in</body></html>")
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            await #expect(throws: HTTPError.self) {
                _ = try await client.fetchProgress()
            }
        }
    }

    // MARK: - Connection test

    @Suite("Connection test")
    struct ConnectionTests {
        /// SAB exempts only `version` and `auth` from the API key, so probing
        /// `mode=version` returns 200 for a wrong key — a false "connected".
        /// The probe has to be an auth-gated mode.
        @Test("testConnection probes the auth-gated queue mode, never the exempt version mode")
        func probesAnAuthGatedMode() async throws {
            var captured: [String: String] = [:]
            SabMockURLProtocol.handler = { request in
                captured = sabQuery(request)
                return sabReply(request, emptyQueueJSON)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            _ = try await client.testConnection()

            #expect(captured["mode"] == "queue")
            #expect(captured["apikey"] == "sab-key")
        }

        @Test("testConnection reports the server version from the queue payload")
        func reportsVersion() async throws {
            SabMockURLProtocol.handler = { request in sabReply(request, sabQueueJSON) }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let banner = try await client.testConnection()
            #expect(banner == "SABnzbd 4.3.1")
        }

        /// A 200 that doesn't carry a version is still a working connection —
        /// the key was accepted, which is what the Test button is asking.
        @Test("testConnection falls back to OK when the payload carries no version")
        func versionlessButReachable() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, #"{"queue": {"paused": false, "slots": []}}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let banner = try await client.testConnection()
            #expect(banner == "OK")
        }

        /// SAB answers a wrong key with HTTP 200 and `status: false` — the
        /// reason the probe reads the body instead of trusting the status code.
        @Test("A wrong API key fails the connection test despite the 200")
        func wrongKeyIsNotAPass() async throws {
            SabMockURLProtocol.handler = { request in
                sabReply(request, #"{"status": false, "error": "API Key Incorrect"}"#)
            }

            let client = SabnzbdClient(config: sabConfig, session: sabSession())
            let error = await thrownError { _ = try await client.testConnection() }
            #expect((error as? SabnzbdError)?.errorDescription == "SABnzbd: API Key Incorrect")
        }
    }
}
