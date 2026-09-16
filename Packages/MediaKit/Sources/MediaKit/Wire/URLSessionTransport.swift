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
        let urlRequest = RequestBuilder.urlRequest(from: request)
        let task = session.dataTask(with: urlRequest)
        let box = TaskBox(task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                let delegate = DataDelegate { result in continuation.resume(with: result) }
                task.delegate = delegate
                task.resume()
            }
        } onCancel: {
            box.task.cancel()
        }
    }

    public func open(_ request: HTTPRequest) async throws -> any WireSocket {
        let task = session.webSocketTask(with: RequestBuilder.urlRequest(from: request))
        task.resume()
        return URLSessionSocket(task: task)
    }
}

private struct TaskBox: @unchecked Sendable { let task: URLSessionTask; init(_ task: URLSessionTask) { self.task = task } }

private final class DataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = Data()
    private let finish: (Result<HTTPResponse, any Error>) -> Void
    init(finish: @escaping (Result<HTTPResponse, any Error>) -> Void) { self.finish = finish }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { buffer.append(data) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) } else { finish(.failure(error)) }
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        var headers = HTTPHeaders()
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        finish(.success(HTTPResponse(status: http.statusCode, headers: headers, body: buffer)))
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
