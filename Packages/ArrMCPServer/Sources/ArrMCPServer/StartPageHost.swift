import Foundation
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// A deliberately tiny, read-only NIO HTTP host for the experimental start page.
///
/// It is *not* the MCP host: no sessions, no SSE, no bearer, no request bodies —
/// just GET routing to a `Router` closure that returns a fully-formed response.
/// The start page only ever serves loopback, so the security surface the MCP
/// host carries (Origin checks, auth, DNS-rebinding defences) doesn't apply; the
/// controller refuses to bind anything but 127.0.0.1.
actor StartPageHost {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Parsed, percent-decoded query parameters (`?a=1&b=2`).
        let query: [String: String]
    }

    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: [UInt8]
        let extraHeaders: [(String, String)]
        init(status: Int, contentType: String, body: [UInt8],
             extraHeaders: [(String, String)] = []) {
            self.status = status; self.contentType = contentType
            self.body = body; self.extraHeaders = extraHeaders
        }
        static func html(_ s: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "text/html; charset=utf-8", body: Array(s.utf8))
        }
        static func json(_ data: Data, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: Array(data))
        }
        static func image(_ data: Data, contentType: String) -> Response {
            // Posters are immutable for a given URL — let the browser cache them
            // so a 10 s meta-refresh doesn't re-fetch every card every tick.
            Response(status: 200, contentType: contentType, body: Array(data),
                     extraHeaders: [("Cache-Control", "private, max-age=3600")])
        }
        static func notFound() -> Response {
            .html("<h1>404</h1>", status: 404)
        }
    }

    /// Split `key=value&…` into a percent-decoded dictionary. Bare keys map to "".
    private static func parseQuery(_ raw: Substring) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    typealias Router = @Sendable (Request) async -> Response

    private let host: String
    private let port: Int
    private let router: Router
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?

    nonisolated let logger: Logger

    /// Hang up a connection that's said nothing for this long. A browser opens a
    /// socket, fetches, and (with our `Connection: close`) we drop it — this only
    /// reclaims a client that connects and never speaks.
    private static let readIdleTimeout = TimeAmount.seconds(30)

    init(host: String, port: Int, logger: Logger, router: @escaping Router) {
        self.host = host; self.port = port; self.logger = logger; self.router = router
    }

    func start() async throws {
        guard group == nil else { throw StartPageError.alreadyStarted }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        do {
            let readIdleTimeout = Self.readIdleTimeout
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations
                            .addHandler(IdleStateHandler(readTimeout: readIdleTimeout))
                    }
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(Handler(host: self)) }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let channel = try await bootstrap.bind(host: host, port: port).get()
            self.channel = channel
            logger.info("start-page host bound", metadata: ["host": "\(host)", "port": "\(port)"])
        } catch {
            // Bind failed (EADDRINUSE is routine — the default port may already be
            // taken). Reap the group we just spawned so it doesn't leak threads.
            await stop()
            throw error
        }
    }

    /// Idempotent: safe on a host that never bound, and safe to call twice.
    func stop() async {
        let wasBound = channel != nil
        try? await channel?.close()
        channel = nil
        // Mandatory, not tidiness: a dropped `MultiThreadedEventLoopGroup` only
        // asserts in deinit — it never reaps its threads — so skipping this leaks
        // the event-loop thread for the life of the process.
        try? await group?.shutdownGracefully()
        group = nil
        if wasBound { logger.info("start-page host stopped") }
    }

    fileprivate func route(_ request: Request) async -> Response {
        await router(request)
    }

    // MARK: - NIO glue

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let host: StartPageHost
        private var head: HTTPRequestHead?
        private var responseInFlight = false

        init(host: StartPageHost) { self.host = host }

        /// Reclaim a connection that opened and then went silent — unless we still
        /// owe it a response (we never stream, so that window is momentary).
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
                self.head = head
            case .body:
                break // read-only page — request bodies are ignored (drained)
            case .end:
                guard let head = head else { return }
                self.head = nil
                responseInFlight = true
                let uriParts = head.uri.split(separator: "?", maxSplits: 1)
                let request = Request(
                    method: head.method.rawValue,
                    path: String(uriParts.first ?? Substring(head.uri)),
                    query: uriParts.count > 1 ? StartPageHost.parseQuery(uriParts[1]) : [:])
                let version = head.version
                nonisolated(unsafe) let ctx = context
                Task {
                    let response = await self.host.route(request)
                    await self.write(response, version: version, context: ctx)
                }
            }
        }

        private func write(_ response: Response, version: HTTPVersion,
                           context: ChannelHandlerContext) async {
            nonisolated(unsafe) let ctx = context
            ctx.eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version, status: HTTPResponseStatus(statusCode: response.status))
                head.headers.add(name: "Content-Type", value: response.contentType)
                head.headers.add(name: "Content-Length", value: String(response.body.count))
                for (name, value) in response.extraHeaders { head.headers.add(name: name, value: value) }
                // Close after each response — no keep-alive bookkeeping to get
                // wrong, and a status page is hit occasionally, not in bursts.
                head.headers.add(name: "Connection", value: "close")
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if !response.body.isEmpty {
                    var buffer = ctx.channel.allocator.buffer(capacity: response.body.count)
                    buffer.writeBytes(response.body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                    ctx.close(promise: nil)
                }
                self.responseInFlight = false
            }
        }
    }
}

enum StartPageError: Error { case alreadyStarted }
