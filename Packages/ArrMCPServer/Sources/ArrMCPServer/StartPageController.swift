import ArrCore
import Logging
import Foundation

/// Owns the lifecycle of the experimental start-page HTTP host: (re)binds it on
/// loopback from a config snapshot and publishes status back to the app.
///
/// Mirrors `MCPServerController`'s shape (a single serialised `apply` slot so
/// overlapping restart/stop requests collapse to the newest), but the host it
/// drives is the tiny read-only `StartPageHost`, not the MCP server.
public actor StartPageController {
    public struct Config: Sendable {
        public let port: Int
        /// Called once per HTTP request to get the current status. Hops to the
        /// main actor in the caller (AppDelegate) to read the live queue.
        public let snapshotProvider: @Sendable () async -> StartPageSnapshot
        /// Resolves a poster URL to image bytes. The caller (AppDelegate) MUST
        /// validate the URL against what's actually on the page and fetch it
        /// with the right arr credentials — this route otherwise reaches the
        /// arrs, so an unvalidated fetch would be an SSRF. Return nil to 404.
        public let posterProvider: @Sendable (URL) async -> Data?
        public init(port: Int,
                    snapshotProvider: @escaping @Sendable () async -> StartPageSnapshot,
                    posterProvider: @escaping @Sendable (URL) async -> Data?) {
            self.port = port; self.snapshotProvider = snapshotProvider
            self.posterProvider = posterProvider
        }
    }

    public enum Status: Sendable, Equatable {
        case stopped, running(url: String), failed(message: String)
    }

    private enum DesiredState: Sendable {
        case stopped
        case running(Config)
    }

    private let logger = Logger(label: "arrbarr.startpage")
    /// Always loopback — the start page is never exposed off the machine.
    private static let bindHost = "127.0.0.1"
    private var host: StartPageHost?
    private var onStatus: (@Sendable (Status) -> Void)?
    private var pendingState: DesiredState?
    private var isApplying = false

    public init() {}

    public func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) { onStatus = handler }

    public func restart(with config: Config) async { await apply(.running(config)) }
    public func stop() async { await apply(.stopped) }

    /// Serialises every state change — see `MCPServerController.apply` for why
    /// actor isolation alone isn't enough (each restart suspends at the bind).
    private func apply(_ desired: DesiredState) async {
        pendingState = desired
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        while let next = pendingState {
            pendingState = nil
            switch next {
            case .stopped: await performStop()
            case .running(let config): await performRestart(with: config)
            }
        }
    }

    private func performRestart(with config: Config) async {
        await performStop()

        guard config.port > 0 && config.port <= 65535 else {
            emit(.failed(message: "Invalid start-page port: \(config.port)")); return
        }

        let snapshotProvider = config.snapshotProvider
        let posterProvider = config.posterProvider
        let router: StartPageHost.Router = { request in
            guard request.method == "GET" else {
                return .html("<h1>405 — GET only</h1>", status: 405)
            }
            switch request.path {
            case "/", "/index.html":
                return .html(StartPageRenderer.html(await snapshotProvider()))
            case "/status.json":
                return .json(StartPageRenderer.json(await snapshotProvider()))
            case "/poster":
                guard let token = request.query["u"],
                      let url = StartPagePosterToken.decode(token),
                      let data = await posterProvider(url) else { return .notFound() }
                return .image(data, contentType: Self.imageContentType(data))
            default:
                return .notFound()
            }
        }

        let host = StartPageHost(host: Self.bindHost, port: config.port, logger: logger, router: router)
        self.host = host
        do {
            try await host.start()
            let url = "http://\(Self.bindHost):\(config.port)/"
            emit(.running(url: url))
            logger.notice("start page started", metadata: ["url": .string(url)])
        } catch {
            await host.stop()
            self.host = nil
            emit(.failed(message: "\(error)"))
            logger.error("start page failed to start", metadata: ["error": .string("\(error)")])
        }
    }

    private func performStop() async {
        await host?.stop()
        host = nil
        emit(.stopped)
    }

    private func emit(_ s: Status) { onStatus?(s) }

    /// Sniff the image type from magic bytes so the browser gets an honest
    /// Content-Type (PosterStore may hand back JPEG or PNG depending on source).
    private static func imageContentType(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.count >= 12, data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "application/octet-stream"
    }
}

/// Encodes a poster URL into a URL-safe token for the `/poster?u=` route, and
/// back. Base64url (no padding) so it needs no further percent-encoding.
enum StartPagePosterToken {
    static func encode(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ token: String) -> URL? {
        var s = token.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }
}
