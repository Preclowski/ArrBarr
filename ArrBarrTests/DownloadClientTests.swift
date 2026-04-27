import Testing
import Foundation
@testable import ArrBarr

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
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

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func mockSessionWithCookies() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    config.httpCookieStorage = HTTPCookieStorage()
    config.httpCookieAcceptPolicy = .always
    config.httpShouldSetCookies = true
    return URLSession(configuration: config)
}

private func bodyData(from request: URLRequest) -> Data? {
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

private func jsonBody(from request: URLRequest) -> [String: Any]? {
    guard let data = bodyData(from: request) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func jsonResponse(url: URL, json: Any, statusCode: Int = 200) -> (Data, HTTPURLResponse) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    return (data, response)
}

private func textResponse(url: URL, text: String, statusCode: Int = 200, headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
    let data = Data(text.utf8)
    let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
    return (data, response)
}

private let testConfig = ServiceConfig(
    enabled: true, baseURL: "http://localhost:6789",
    apiKey: "", username: "admin", password: "secret"
)

private let disabledConfig = ServiceConfig(
    enabled: false, baseURL: "http://localhost:6789",
    apiKey: "", username: "", password: ""
)

private let delugeConfig = ServiceConfig(
    enabled: true, baseURL: "http://localhost:8112",
    apiKey: "", username: "", password: "deluge"
)

// Serialized to prevent concurrent access to MockURLProtocol.handler
@Suite("Download Clients", .serialized)
struct DownloadClientTests {

    // MARK: - NZBGet

    @Suite("NzbgetClient")
    struct NzbgetClientTests {
        @Test("Pause sends GroupPause editqueue command")
        func pause() async throws {
            var capturedBody: [String: Any]?
            MockURLProtocol.handler = { request in
                capturedBody = jsonBody(from: request)
                return jsonResponse(url: request.url!, json: ["result": true])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, nzbId: "42")

            #expect(capturedBody?["method"] as? String == "editqueue")
            let params = capturedBody?["params"] as? [Any]
            #expect(params?.first as? String == "GroupPause")
        }

        @Test("Resume sends GroupResume command")
        func resume() async throws {
            var capturedMethod: String?
            MockURLProtocol.handler = { request in
                let body = jsonBody(from: request)
                let params = body?["params"] as? [Any]
                capturedMethod = params?.first as? String
                return jsonResponse(url: request.url!, json: ["result": true])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            try await client.perform(.resume, nzbId: "42")
            #expect(capturedMethod == "GroupResume")
        }

        @Test("Delete sends GroupDelete command")
        func delete() async throws {
            var capturedMethod: String?
            MockURLProtocol.handler = { request in
                let body = jsonBody(from: request)
                let params = body?["params"] as? [Any]
                capturedMethod = params?.first as? String
                return jsonResponse(url: request.url!, json: ["result": true])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            try await client.perform(.delete, nzbId: "42")
            #expect(capturedMethod == "GroupDelete")
        }

        @Test("Sends Basic auth header when credentials configured")
        func authHeader() async throws {
            var capturedAuth: String?
            MockURLProtocol.handler = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                return jsonResponse(url: request.url!, json: ["result": true])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, nzbId: "1")

            let expected = "Basic " + Data("admin:secret".utf8).base64EncodedString()
            #expect(capturedAuth == expected)
        }

        @Test("Invalid NZB ID throws error")
        func invalidId() async throws {
            MockURLProtocol.handler = { request in
                return jsonResponse(url: request.url!, json: ["result": true])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            await #expect(throws: NzbgetError.self) {
                try await client.perform(.pause, nzbId: "not-a-number")
            }
        }

        @Test("False result throws actionFailed")
        func falseResult() async throws {
            MockURLProtocol.handler = { request in
                return jsonResponse(url: request.url!, json: ["result": false])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            await #expect(throws: NzbgetError.self) {
                try await client.perform(.pause, nzbId: "42")
            }
        }

        @Test("Disabled config throws notConfigured")
        func notConfigured() async throws {
            let client = NzbgetClient(config: disabledConfig, session: mockSession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, nzbId: "1")
            }
        }

        @Test("Posts to /jsonrpc path")
        func correctPath() async throws {
            var capturedURL: URL?
            MockURLProtocol.handler = { request in
                capturedURL = request.url
                return jsonResponse(url: request.url!, json: ["result": true])
            }

            let client = NzbgetClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, nzbId: "1")
            #expect(capturedURL?.path == "/jsonrpc")
        }
    }

    // MARK: - Transmission

    @Suite("TransmissionClient")
    struct TransmissionClientTests {
        @Test("Pause sends torrent-stop method")
        func pause() async throws {
            var capturedBody: [String: Any]?
            MockURLProtocol.handler = { request in
                capturedBody = jsonBody(from: request)
                return jsonResponse(url: request.url!, json: ["result": "success"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "abc123")

            #expect(capturedBody?["method"] as? String == "torrent-stop")
            let args = capturedBody?["arguments"] as? [String: Any]
            #expect(args?["ids"] as? [String] == ["abc123"])
        }

        @Test("Resume sends torrent-start method")
        func resume() async throws {
            var capturedMethod: String?
            MockURLProtocol.handler = { request in
                capturedMethod = jsonBody(from: request)?["method"] as? String
                return jsonResponse(url: request.url!, json: ["result": "success"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            try await client.perform(.resume, hash: "abc123")
            #expect(capturedMethod == "torrent-start")
        }

        @Test("Delete sends torrent-remove method with delete-local-data false")
        func delete() async throws {
            var capturedBody: [String: Any]?
            MockURLProtocol.handler = { request in
                capturedBody = jsonBody(from: request)
                return jsonResponse(url: request.url!, json: ["result": "success"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            try await client.perform(.delete, hash: "abc123")

            #expect(capturedBody?["method"] as? String == "torrent-remove")
            let args = capturedBody?["arguments"] as? [String: Any]
            #expect(args?["delete-local-data"] as? Bool == false)
        }

        @Test("Handles 409 session ID handshake")
        func sessionIdHandshake() async throws {
            var requestCount = 0
            MockURLProtocol.handler = { request in
                requestCount += 1
                if requestCount == 1 {
                    return textResponse(
                        url: request.url!, text: "",
                        statusCode: 409,
                        headers: ["X-Transmission-Session-Id": "test-session-id"]
                    )
                }
                #expect(request.value(forHTTPHeaderField: "X-Transmission-Session-Id") == "test-session-id")
                return jsonResponse(url: request.url!, json: ["result": "success"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "abc123")
            #expect(requestCount == 2)
        }

        @Test("Non-success result throws actionFailed")
        func failedResult() async throws {
            MockURLProtocol.handler = { request in
                return jsonResponse(url: request.url!, json: ["result": "no such torrent"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            await #expect(throws: TransmissionError.self) {
                try await client.perform(.pause, hash: "abc123")
            }
        }

        @Test("Sends Basic auth header")
        func authHeader() async throws {
            var capturedAuth: String?
            MockURLProtocol.handler = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                return jsonResponse(url: request.url!, json: ["result": "success"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "abc123")

            let expected = "Basic " + Data("admin:secret".utf8).base64EncodedString()
            #expect(capturedAuth == expected)
        }

        @Test("Posts to /transmission/rpc path")
        func correctPath() async throws {
            var capturedURL: URL?
            MockURLProtocol.handler = { request in
                capturedURL = request.url
                return jsonResponse(url: request.url!, json: ["result": "success"])
            }

            let client = TransmissionClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "abc123")
            #expect(capturedURL?.path == "/transmission/rpc")
        }

        @Test("Disabled config throws notConfigured")
        func notConfigured() async throws {
            let client = TransmissionClient(config: disabledConfig, session: mockSession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, hash: "abc")
            }
        }
    }

    // MARK: - rTorrent

    @Suite("RtorrentClient")
    struct RtorrentClientTests {
        @Test("Pause sends d.stop method via XMLRPC")
        func pause() async throws {
            var capturedBody: String?
            MockURLProtocol.handler = { request in
                capturedBody = bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><params><param><value><i4>0</i4></value></param></params></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "ABC123DEF")

            #expect(capturedBody?.contains("<methodName>d.stop</methodName>") == true)
            #expect(capturedBody?.contains("<string>ABC123DEF</string>") == true)
        }

        @Test("Resume sends d.start method")
        func resume() async throws {
            var capturedBody: String?
            MockURLProtocol.handler = { request in
                capturedBody = bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><params></params></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            try await client.perform(.resume, hash: "ABC123DEF")
            #expect(capturedBody?.contains("<methodName>d.start</methodName>") == true)
        }

        @Test("Delete sends d.erase method")
        func delete() async throws {
            var capturedBody: String?
            MockURLProtocol.handler = { request in
                capturedBody = bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><params></params></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            try await client.perform(.delete, hash: "ABC123DEF")
            #expect(capturedBody?.contains("<methodName>d.erase</methodName>") == true)
        }

        @Test("XMLRPC body escapes special characters")
        func xmlEscaping() async throws {
            var capturedBody: String?
            MockURLProtocol.handler = { request in
                capturedBody = bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><params></params></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "a&b<c")
            #expect(capturedBody?.contains("a&amp;b&lt;c") == true)
        }

        @Test("Sends Basic auth header")
        func authHeader() async throws {
            var capturedAuth: String?
            MockURLProtocol.handler = { request in
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><params></params></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "abc")

            let expected = "Basic " + Data("admin:secret".utf8).base64EncodedString()
            #expect(capturedAuth == expected)
        }

        @Test("Sends text/xml Content-Type")
        func contentType() async throws {
            var capturedContentType: String?
            MockURLProtocol.handler = { request in
                capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><params></params></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            try await client.perform(.pause, hash: "abc")
            #expect(capturedContentType == "text/xml")
        }

        @Test("XMLRPC fault throws actionFailed")
        func faultResponse() async throws {
            MockURLProtocol.handler = { request in
                return textResponse(url: request.url!, text: "<?xml version=\"1.0\"?><methodResponse><fault><value><struct></struct></value></fault></methodResponse>")
            }

            let client = RtorrentClient(config: testConfig, session: mockSession())
            await #expect(throws: RtorrentError.self) {
                try await client.perform(.pause, hash: "abc")
            }
        }

        @Test("Disabled config throws notConfigured")
        func notConfigured() async throws {
            let client = RtorrentClient(config: disabledConfig, session: mockSession())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, hash: "abc")
            }
        }
    }

    // MARK: - Deluge

    @Suite("DelugeClient")
    struct DelugeClientTests {
        private func delugeHandler(dispatch: @escaping (String) -> Void) -> (URLRequest) throws -> (Data, HTTPURLResponse) {
            return { request in
                let body = jsonBody(from: request) ?? [:]
                let method = body["method"] as? String ?? ""
                dispatch(method)
                if method == "auth.login" {
                    return jsonResponse(url: request.url!, json: ["result": true, "error": NSNull(), "id": 1])
                }
                return jsonResponse(url: request.url!, json: ["result": NSNull(), "error": NSNull(), "id": 2])
            }
        }

        @Test("Pause sends core.pause_torrent method after auth")
        func pause() async throws {
            var methods: [String] = []
            MockURLProtocol.handler = delugeHandler { methods.append($0) }

            let client = DelugeClient(config: delugeConfig, session: mockSessionWithCookies())
            try await client.perform(.pause, hash: "abc123")

            #expect(methods.count == 2)
            #expect(methods[0] == "auth.login")
            #expect(methods[1] == "core.pause_torrent")
        }

        @Test("Resume sends core.resume_torrent method")
        func resume() async throws {
            var lastMethod: String?
            MockURLProtocol.handler = delugeHandler { lastMethod = $0 }

            let client = DelugeClient(config: delugeConfig, session: mockSessionWithCookies())
            try await client.perform(.resume, hash: "abc123")
            #expect(lastMethod == "core.resume_torrent")
        }

        @Test("Delete sends core.remove_torrent method")
        func delete() async throws {
            var lastMethod: String?
            MockURLProtocol.handler = delugeHandler { lastMethod = $0 }

            let client = DelugeClient(config: delugeConfig, session: mockSessionWithCookies())
            try await client.perform(.delete, hash: "abc123")
            #expect(lastMethod == "core.remove_torrent")
        }

        @Test("Auth failure throws authFailed")
        func authFailed() async throws {
            MockURLProtocol.handler = { request in
                return jsonResponse(url: request.url!, json: ["result": false, "error": NSNull(), "id": 1])
            }

            let client = DelugeClient(config: ServiceConfig(enabled: true, baseURL: "http://localhost:8112", apiKey: "", username: "", password: "wrong"), session: mockSessionWithCookies())
            await #expect(throws: DelugeError.self) {
                try await client.perform(.pause, hash: "abc")
            }
        }

        @Test("Error in action response throws actionFailed")
        func actionError() async throws {
            MockURLProtocol.handler = { request in
                let body = jsonBody(from: request) ?? [:]
                let method = body["method"] as? String ?? ""
                if method == "auth.login" {
                    return jsonResponse(url: request.url!, json: ["result": true, "error": NSNull(), "id": 1])
                }
                return jsonResponse(url: request.url!, json: [
                    "result": NSNull(),
                    "error": ["message": "Torrent not found", "code": 2],
                    "id": 2,
                ])
            }

            let client = DelugeClient(config: delugeConfig, session: mockSessionWithCookies())
            await #expect(throws: DelugeError.self) {
                try await client.perform(.pause, hash: "abc")
            }
        }

        @Test("Reuses auth session for subsequent calls")
        func sessionReuse() async throws {
            var authCount = 0
            MockURLProtocol.handler = delugeHandler { method in
                if method == "auth.login" { authCount += 1 }
            }

            let client = DelugeClient(config: delugeConfig, session: mockSessionWithCookies())
            try await client.perform(.pause, hash: "abc")
            try await client.perform(.resume, hash: "abc")

            #expect(authCount == 1)
        }

        @Test("Posts to /json path")
        func correctPath() async throws {
            var capturedURL: URL?
            MockURLProtocol.handler = { request in
                capturedURL = request.url
                let body = jsonBody(from: request) ?? [:]
                if (body["method"] as? String) == "auth.login" {
                    return jsonResponse(url: request.url!, json: ["result": true, "error": NSNull(), "id": 1])
                }
                return jsonResponse(url: request.url!, json: ["result": NSNull(), "error": NSNull(), "id": 2])
            }

            let client = DelugeClient(config: delugeConfig, session: mockSessionWithCookies())
            try await client.perform(.pause, hash: "abc")
            #expect(capturedURL?.path == "/json")
        }

        @Test("Disabled config throws notConfigured")
        func notConfigured() async throws {
            let client = DelugeClient(config: disabledConfig, session: mockSessionWithCookies())
            await #expect(throws: HTTPError.self) {
                try await client.perform(.pause, hash: "abc")
            }
        }
    }
}
