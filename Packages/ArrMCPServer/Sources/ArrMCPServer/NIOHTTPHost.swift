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

    /// How long a connection may stay silent before we hang up. Long enough to
    /// keep normal keep-alive reuse working; a response still in flight (an SSE
    /// stream is silent by design) vetoes the close — see `HTTPHandler`.
    private static let readIdleTimeout = TimeAmount.seconds(120)
    /// Ceiling on simultaneously open connections. A real MCP client uses one
    /// or two; this only bites on a client that opens sockets and never talks.
    private static let maxConcurrentConnections = 64

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
        // Starting twice would orphan the first group, and an orphaned group
        // never dies — see the shutdown note in `stop()`.
        guard group == nil else { throw MCPError.internalError("MCP HTTP host already started") }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group

        do {
            // One limiter per bind, shared by every child channel it accepts.
            let limiter = ConnectionLimiter(limit: Self.maxConcurrentConnections)
            let readIdleTimeout = Self.readIdleTimeout
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    // Idle handler goes in first so it sees raw reads on the
                    // socket, i.e. before HTTP framing has decided anything.
                    //
                    // Installed through `syncOperations` because NIO marks
                    // `IdleStateHandler` explicitly non-`Sendable`; the async
                    // `addHandler` would have to hand it to the event loop from
                    // outside, while this path runs inline on the loop the
                    // initializer is already on.
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
            logger.info("MCP HTTP host bound", metadata: [
                "host": "\(configuration.host)", "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)"])
        } catch {
            // The bind fails routinely — EADDRINUSE, because the default 8080
            // is also qBittorrent's (and Jenkins') WebUI port. The controller
            // drops this host when we throw, so `stop()` would never run and
            // the group we just spawned would leak its threads forever.
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
        // Shutting the group down explicitly is mandatory, not tidiness:
        // `MultiThreadedEventLoopGroup.deinit` only asserts — it does NOT reap
        // the threads — so a group that is merely dropped leaks
        // `System.coreCount` detached OS threads for the life of the process.
        try? await group?.shutdownGracefully()
        group = nil
        if wasBound { logger.info("MCP HTTP host stopped") }
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
            // Validate (bearer auth included) BEFORE spending a session on the
            // caller: `createSessionAndHandle` builds a tool backend and starts
            // a `Server` first, and the transport only runs the pipeline inside
            // its own `handleRequest` — i.e. after all that work. The transport
            // re-runs the pipeline on the same request; validators are pure
            // values, so it reaches the identical verdict.
            // `sessionID` is nil and `isInitializationRequest` true here, which
            // is exactly the context the transport builds pre-initialize.
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

// MARK: - Connection cap

/// Counts live child connections across the whole bind. Child channels are
/// spread over every event loop in the group, so this can't live on either the
/// actor or a single loop — hence the lock.
private final class ConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Takes a slot, or returns false when the cap is reached (caller hangs up).
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

/// Thin NIO adapter: converts NIO HTTP types to/from the SDK's framework-agnostic
/// `HTTPRequest`/`HTTPResponse`, delegating all logic to `NIOHTTPHost`.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: NIOHTTPHost
    private let limiter: ConnectionLimiter
    /// Hard cap on accumulated request-body size. MCP JSON-RPC payloads are
    /// tiny; this bounds the memory + pre-auth JSON parse a single request can
    /// drive — without it a client could stream a multi-GB body (buffered whole
    /// before any validation/auth runs) and exhaust memory.
    private static let maxBodyBytes = 1 * 1024 * 1024  // 1 MB
    private struct RequestState { var head: HTTPRequestHead; var bodyBuffer: ByteBuffer; var oversized = false }
    private var requestState: RequestState?
    /// True from the moment a complete request is handed off until its response
    /// has been written in full. Vetoes the idle close below: an SSE response
    /// legitimately sends nothing for hours while we hold the stream open.
    private var responseInFlight = false
    /// Whether this connection holds a slot in `limiter` — false when we were
    /// over the cap and closed immediately, which keeps the release exactly-once.
    private var holdsConnectionSlot = false

    // All mutable state above is touched only on the channel's event loop
    // (`channelRead` and the `eventLoop.execute` blocks in `writeResponse`).

    init(app: NIOHTTPHost, limiter: ConnectionLimiter) { self.app = app; self.limiter = limiter }

    func channelActive(context: ChannelHandlerContext) {
        guard limiter.acquire() else {
            // At the cap — hang up now rather than let sockets pile up.
            context.close(promise: nil)
            return
        }
        holdsConnectionSlot = true
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if holdsConnectionSlot { holdsConnectionSlot = false; limiter.release() }
        context.fireChannelInactive()
    }

    /// `IdleStateHandler` upstream tells us nothing has been read for a while.
    /// Reclaim the connection unless we still owe the client a response —
    /// otherwise a client that connects and never speaks pins a file descriptor
    /// (and whatever body we've buffered) for as long as the app runs.
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
                // Over the cap — stop buffering, free what we held, and reject
                // on `.end` (writing a response mid-stream here isn't clean).
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
                Task {
                    await self.writeResponse(
                        .error(statusCode: 413, .invalidRequest("Payload Too Large")),
                        version: state.head.version, context: ctx)
                }
                return
            }
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
