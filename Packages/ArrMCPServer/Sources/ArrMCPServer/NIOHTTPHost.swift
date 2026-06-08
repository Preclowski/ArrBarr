import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// A swift-nio HTTP host that fronts the MCP SDK's `StatefulHTTPServerTransport`.
///
/// Adapted from the SDK's own conformance host (`MCPConformance/HTTPApp.swift`):
/// it binds `host:port`, routes each request by `Mcp-Session-Id` to a per-session
/// transport, creates a session on `initialize`, and streams SSE responses. The
/// two notable deviations: `start()` returns once bound (it does not block on the
/// channel's close future, so the controller can manage lifecycle), and request
/// handling is not pinned to the main actor.
actor NIOHTTPHost {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var endpoint: String
        var sessionTimeout: TimeInterval
        var retryInterval: Int?
        init(host: String = "127.0.0.1", port: Int = 8080, endpoint: String = "/mcp",
             sessionTimeout: TimeInterval = 3600, retryInterval: Int? = nil) {
            self.host = host; self.port = port; self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout; self.retryInterval = retryInterval
        }
    }

    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var sessions: [String: SessionContext] = [:]
    private var cleanupTask: Task<Void, Never>?

    nonisolated let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(host: String, port: Int, endpoint: String = "/mcp",
         validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
         logger: Logger,
         serverFactory: @escaping ServerFactory) {
        self.configuration = Configuration(host: host, port: port, endpoint: endpoint)
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
        self.logger = logger
    }

    var endpoint: String { configuration.endpoint }

    // MARK: - Lifecycle

    /// Binds and starts accepting connections, then RETURNS (does not block).
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel
        cleanupTask = Task { [weak self] in await self?.sessionCleanupLoop() }
        logger.info("MCP HTTP host bound", metadata: [
            "host": "\(configuration.host)", "port": "\(configuration.port)",
            "endpoint": "\(configuration.endpoint)"])
    }

    func stop() async {
        cleanupTask?.cancel(); cleanupTask = nil
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
        logger.info("MCP HTTP host stopped")
    }

    // MARK: - Routing

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST", let body = request.body, Self.isInitialize(body: body) {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(statusCode: 400,
                      .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    /// `JSONRPCMessageKind` is package-internal to the SDK, so detect the
    /// initialize request ourselves by inspecting the JSON-RPC `method`.
    private static func isInitialize(body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return (obj["method"] as? String) == "initialize"
    }

    // MARK: - Sessions

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger)
        do {
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(
                server: server, transport: transport, createdAt: Date(), lastAccessedAt: Date())
            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500,
                          .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
        logger.info("Closed session", metadata: ["sessionID": "\(sessionID)"])
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys { await closeSession(sessionID) }
    }

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            let expired = sessions.filter {
                now.timeIntervalSince($0.value.lastAccessedAt) > configuration.sessionTimeout
            }
            for (sessionID, _) in expired {
                logger.info("Session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - NIO HTTP handler

/// Thin NIO adapter: converts NIO HTTP types to/from the SDK's framework-agnostic
/// `HTTPRequest`/`HTTPResponse`, delegating all logic to `NIOHTTPHost`.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: NIOHTTPHost
    private struct RequestState { var head: HTTPRequestHead; var bodyBuffer: ByteBuffer }
    private var requestState: RequestState?

    init(app: NIOHTTPHost) { self.app = app }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            Task { await self.handleRequest(state: state, context: ctx) }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await app.endpoint
        guard path == endpoint else {
            await writeResponse(.error(statusCode: 404, .invalidRequest("Not Found")),
                                version: head.version, context: context)
            return
        }
        let response = await app.handleHTTPRequest(makeHTTPRequest(from: state))
        await writeResponse(response, version: head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] { headers[name] = existing + ", " + value }
            else { headers[name] = value }
        }
        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes) {
            body = Data(bytes)
        } else { body = nil }
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(method: state.head.method.rawValue, headers: headers, body: body, path: path)
    }

    private func writeResponse(_ response: HTTPResponse, version: HTTPVersion,
                               context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch { /* stream ended with error — close below */ }
            eventLoop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
