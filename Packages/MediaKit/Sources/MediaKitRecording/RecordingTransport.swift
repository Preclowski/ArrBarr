import Foundation
import MediaKit

/// Never linked by an app: gates every live request through the allow-list and writes scrubbed corpus rows.
public struct RecordingTransport: Transport, SocketTransport {
    private let inner: any Transport & SocketTransport
    private let allowList: AllowList
    private let output: URL
    private let redaction: Redaction
    private let kind: @Sendable (HTTPRequest) -> InstanceKind

    public init(wrapping inner: any Transport & SocketTransport, allowList: AllowList = .section5, output: URL,
                redaction: Redaction = .standard, kind: @escaping @Sendable (HTTPRequest) -> InstanceKind = { $0.operation.kind }) {
        self.inner = inner; self.allowList = allowList; self.output = output; self.redaction = redaction; self.kind = kind
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard allowList.permits(request, kind: kind(request)) else { throw MediaKitError.notPermitted(request.operation) }
        let response = try await inner.send(request)
        try record(request, response)
        return response
    }

    public func open(_ request: HTTPRequest) async throws -> any WireSocket {
        guard allowList.permits(request, kind: kind(request)) else { throw MediaKitError.notPermitted(request.operation) }
        return try await inner.open(request)
    }

    private func record(_ request: HTTPRequest, _ response: HTTPResponse) throws {
        let scrubbed = redaction.scrub(request)
        let dir = output.appendingPathComponent(request.operation.kind.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = request.operation.name.lowercased()
        var headers: [String: String] = [:]
        for h in response.headers.names where !redaction.headerNames.contains(h.lowercased()) { headers[h] = response.headers[h] }
        let meta: [String: Any] = [
            "operation": request.operation.name, "status": response.status, "headers": headers,
            "method": request.method, "path": scrubbed.pathTemplate, "url": redaction.loggableURL(scrubbed.url).replacingOccurrences(of: request.url.host ?? "\u{0}", with: "<host>"),
            "rpc_method": request.rpcMethod ?? NSNull(),
        ]
        try response.body.write(to: dir.appendingPathComponent("\(name).json"))
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("\(name).meta.json"))
    }
}
