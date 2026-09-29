import Foundation
import Logging
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1

/// A swift-nio HTTP host fronting the MCP SDK's `StatefulHTTPServerTransport`, adapted
/// from the SDK's conformance host. Unlike it, `start()` returns once bound.
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
    private var sessions: [String: SessionContext] = [:]
    private var cleanupTask: Task<Void, Never>?

    /// A response still in flight (an SSE stream is silent by design) vetoes the close.
    private static let readIdleTimeout = TimeAmount.seconds(120)
    /// A real MCP client uses one or two; this only bites on a client that
    /// opens sockets and never talks.
    private static let maxConcurrentConnections = 64

    nonisolated let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
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

    /// Binds and starts accepting connections, then returns.
    func start() async throws {
        guard channel == nil else { throw MCPError.internalError("MCP HTTP host already started") }
        do {
            let limiter = ConnectionLimiter(limit: Self.maxConcurrentConnections)
            let readIdleTimeout = Self.readIdleTimeout
            // The process-wide group: a localhost server needs no threads of its own, and restarts create none.
            let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    // Idle handler first, so it sees raw reads. `syncOperations` because
                    // `IdleStateHandler` is non-`Sendable` and this runs inline on the loop.
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations
                            .addHandler(IdleStateHandler(readTimeout: readIdleTimeout))
                    }
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(HTTPHandler(app: self, limiter: limiter)) }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

            let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
            self.channel = channel
            cleanupTask = Task { [weak self] in await self?.sessionCleanupLoop() }
            // `.notice`: swift-log `.info` maps to os `.info`, which is never persisted.
            logger.notice("MCP HTTP host bound", metadata: [
                "host": "\(configuration.host)", "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)"])
        } catch {
            // The bind fails routinely (8080 is also qBittorrent's WebUI port).
            await stop()
            throw error
        }
    }

    /// Idempotent: safe on a host that never bound, and safe to call twice.
    func stop() async {
        let wasBound = channel != nil
        cleanupTask?.cancel(); cleanupTask = nil
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        if wasBound { logger.notice("MCP HTTP host stopped") }
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
            // Validate (bearer auth included) before `createSessionAndHandle` builds a
            // backend and a `Server`; the transport's own validation only runs after that.
            let context = HTTPValidationContext(httpMethod: "POST", sessionID: nil,
                                                isInitializationRequest: true)
            if let rejection = validationPipeline?.validate(request, context: context) {
                return rejection
            }
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
                server: server, transport: transport, lastAccessedAt: Date())
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
        logger.debug("Closed session", metadata: ["sessionID": "\(sessionID)"])
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
                logger.debug("Session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - Connection cap

/// Child channels span every event loop in the group, hence a lock rather
/// than actor or loop confinement.
private final class ConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        if count > 0 { count -= 1 }
    }
}

// MARK: - NIO HTTP handler

private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: NIOHTTPHost
    private let limiter: ConnectionLimiter
    /// Bounds memory and the pre-auth JSON parse; the body is buffered whole
    /// before any validation runs.
    private static let maxBodyBytes = 1 * 1024 * 1024  // 1 MB
    private struct RequestState { var head: HTTPRequestHead; var bodyBuffer: ByteBuffer; var oversized = false }
    private var requestState: RequestState?
    /// Vetoes the idle close: an SSE response legitimately sends nothing for hours.
    private var responseInFlight = false
    /// False when over the cap and closed at once, keeping the release exactly-once.
    private var holdsConnectionSlot = false
    /// Cancelled when the peer goes away, so an abandoned SSE stream doesn't pin its task until the session expires.
    private var requestTask: Task<Void, Never>?

    // All mutable state above is touched only on the channel's event loop
    // (`channelRead` and the `eventLoop.execute` blocks in `writeResponse`).

    init(app: NIOHTTPHost, limiter: ConnectionLimiter) { self.app = app; self.limiter = limiter }

    func channelActive(context: ChannelHandlerContext) {
        guard limiter.acquire() else {
            context.close(promise: nil)
            return
        }
        holdsConnectionSlot = true
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestTask?.cancel()
        requestTask = nil
        if holdsConnectionSlot { holdsConnectionSlot = false; limiter.release() }
        context.fireChannelInactive()
    }

    /// Reclaims a silent connection unless a response is still owed, so a client
    /// that never speaks can't pin a file descriptor.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idle = event as? IdleStateHandler.IdleStateEvent, case .read = idle, !responseInFlight {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestState = RequestState(head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            guard let state = requestState, !state.oversized else { return }
            if state.bodyBuffer.readableBytes + buffer.readableBytes > Self.maxBodyBytes {
                // Reject on `.end`; writing a response mid-stream isn't clean.
                requestState?.oversized = true
                requestState?.bodyBuffer.clear()
                return
            }
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            responseInFlight = true
            nonisolated(unsafe) let ctx = context
            if state.oversized {
                requestTask = Task {
                    await self.writeResponse(
                        .error(statusCode: 413, .invalidRequest("Payload Too Large")),
                        version: state.head.version, context: ctx)
                }
                return
            }
            requestTask = Task { await self.handleRequest(state: state, context: ctx) }
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
            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                self.responseInFlight = false
            }

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
                self.responseInFlight = false
            }
        }
    }
}
