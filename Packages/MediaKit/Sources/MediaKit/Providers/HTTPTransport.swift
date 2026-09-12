import Foundation

/// Everything a provider is allowed to know about networking.
///
/// Injected rather than reached for, so every client is testable against
/// fixtures with no server and no `URLProtocol` trickery — and so the debug
/// mode can count bytes in exactly one place.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
        return HTTPResponse(status: http?.statusCode ?? 0, data: data, headers: headers)
    }
}

/// Shared request plumbing: build, send, count, decode — with the failure
/// mapped to a `MediaError` the planner can reason about (a rate limit is not
/// a decoding bug, and neither is an unconfigured key).
extension MediaProvider {
    func perform<T: Decodable>(
        _ request: URLRequest,
        as type: T.Type,
        transport: HTTPTransport,
        telemetry: MediaTelemetry?,
        identity: MediaIdentity,
        fields: MediaFieldSet,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let started = Date()
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            if error is CancellationError { throw MediaError.cancelled }
            await telemetry?.record(.init(kind: .failure, provider: id,
                                          identity: identity.cacheKey, fields: fields,
                                          duration: Date().timeIntervalSince(started),
                                          note: "transport"))
            throw MediaError.unreachable(id)
        }

        // A 401 is not an answer. Counting it as one is how a provider that
        // never worked still reads as "3/3 ok" in the debug report.
        await telemetry?.record(.init(kind: response.isSuccess ? .response : .failure,
                                      provider: id,
                                      identity: identity.cacheKey, fields: fields,
                                      duration: Date().timeIntervalSince(started),
                                      bytes: response.data.count,
                                      note: "HTTP \(response.status)"))

        switch response.status {
        case 200..<300: break
        case 401, 403: throw MediaError.unauthorized(id)
        case 404: throw MediaError.notFound(id)
        case 429:
            let retry = response.header("Retry-After").flatMap(TimeInterval.init)
            throw MediaError.rateLimited(id, retryAfter: retry)
        default: throw MediaError.unreachable(id)
        }

        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            throw MediaError.decoding(id, "\(error)")
        }
    }
}
