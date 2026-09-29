import Foundation

public struct URLSessionTransport: Transport, SocketTransport {
    private let session: URLSession

    public init(session: URLSession) { self.session = session }

    /// No URLCache; a private cookie jar only for the session-cookie clients (qBittorrent, Deluge).
    public static func makeSession(cookies: Bool, timeout: Duration = .seconds(15)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = cookies ? HTTPCookieStorage() : nil
        config.httpShouldSetCookies = cookies
        config.httpCookieAcceptPolicy = cookies ? .always : .never
        config.timeoutIntervalForRequest = timeout.seconds
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.data(for: RequestBuilder.urlRequest(from: request))
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers = HTTPHeaders()
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }

    public func open(_ request: HTTPRequest) async throws -> any WireSocket {
        let task = session.webSocketTask(with: RequestBuilder.urlRequest(from: request))
        task.resume()
        return URLSessionSocket(task: task)
    }
}

private struct URLSessionSocket: WireSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> WireFrame {
        do {
            switch try await task.receive() {
            case let .string(s): return .text(s)
            case let .data(d): return .binary(d)
            @unknown default: return .closed(code: nil)
            }
        } catch {
            if task.closeCode != .invalid { return .closed(code: task.closeCode.rawValue) }
            throw error
        }
    }

    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}
