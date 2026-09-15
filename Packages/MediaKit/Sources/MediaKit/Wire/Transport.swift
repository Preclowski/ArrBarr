/// One request in, one response out. No retries, no limits, no credentials, no logging.
public protocol Transport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A socket is not a request: a transport that cannot open one says so by not conforming.
public protocol SocketTransport: Sendable {
    func open(_ request: HTTPRequest) async throws -> any WireSocket
}
