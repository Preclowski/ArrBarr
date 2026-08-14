import Foundation

/// How `PosterStore` talks to the media server: which requests carry the
/// token, and how to ask for a smaller copy.
///
/// This exists because a media-server poster URL must be **token-free**. The
/// resolved URL is not a transient thing — it is copied into `QueueItem`,
/// persisted in `title-metadata.json` under Application Support, and hashed
/// into every cache key. A token in the query string would therefore be
/// written to a plaintext file next to the artwork *and* would invalidate
/// every cached poster the moment it was rotated. So the URL stays bare and
/// the credential travels in a header, resolved per request from the config
/// held here.
///
/// Lock-guarded rather than an actor for the same reason as
/// `MediaServerIndex`: `PosterStore`'s hot path is synchronous, and an actor
/// would push `await` into it for a dictionary read.
public final class MediaServerPosterAccess: @unchecked Sendable {
    public static let shared = MediaServerPosterAccess()

    private let lock = NSLock()
    private var config: MediaServerConfig?

    init(config: MediaServerConfig? = nil) {
        self.config = config
    }

    /// Point this at the current connection. Called from `ConfigStore` on load
    /// and on every change, so there is exactly one writer.
    public func update(_ config: MediaServerConfig?) {
        lock.lock()
        self.config = (config?.isConfigured == true) ? config : nil
        lock.unlock()
    }

    private var currentConfig: MediaServerConfig? {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Auth headers for a URL that belongs to the connected media server, or
    /// none for every other host. Empty is the safe answer: a poster from TMDB
    /// or an arr must never carry the media server's token.
    public func headers(for url: URL) -> [String: String] {
        guard let config = currentConfig, Self.owns(url, config: config) else { return [:] }
        return config.kind.authHeaders(token: config.token)
    }

    /// A server-side-resized variant of `url` for `tier`, or nil to fetch the
    /// artwork as stored.
    public func sizedURL(for url: URL, tier: PosterTier) -> URL? {
        guard let config = currentConfig else { return nil }
        return Self.sizedURL(for: url, tier: tier, config: config)
    }

    // MARK: - Pure logic (config passed in, so it is testable without the singleton)

    /// Whether `url` points at the configured server. Compared on scheme, host
    /// and port — the path differs per item, and the user's base URL may carry
    /// a reverse-proxy prefix we must not require a match on.
    static func owns(_ url: URL, config: MediaServerConfig) -> Bool {
        guard let base = URL(string: config.baseURL),
              let baseHost = base.host?.lowercased(),
              let host = url.host?.lowercased(),
              baseHost == host else { return false }
        return base.port == url.port && base.scheme?.lowercased() == url.scheme?.lowercased()
    }

    /// Ask the server to do the downscaling.
    ///
    /// Worth the special-casing: without it a 40×60 pt list row pulls the
    /// full-size poster the server has on disk — often north of a megabyte —
    /// and the library prefetch does that once per title. Both server families
    /// resize on request, so the icon tier moves tens of kilobytes instead.
    ///
    /// `.full` deliberately gets nil: it backs the pinch-zoom lightbox, which
    /// zooms to 5× and is the one place that wants the original.
    ///
    /// The tier's cap is a *longest edge*, but both servers constrain width —
    /// so a 2:3 poster comes back somewhat taller than the cap and is trimmed
    /// locally by `PosterStore.resized`. Asking for the cap as a width rather
    /// than deriving one from an assumed aspect ratio is the safe direction:
    /// the error is a few extra kilobytes, where guessing too small would show
    /// as a blurry poster on any artwork that isn't 2:3.
    static func sizedURL(for url: URL, tier: PosterTier, config: MediaServerConfig) -> URL? {
        guard owns(url, config: config), let width = tier.maxPixelSize else { return nil }
        switch config.kind {
        case .plex:
            // Plex resizes through a transcoder endpoint that takes the
            // original image's own path as a parameter, so the item path moves
            // from the URL into `url=`. `upscale=0` keeps a small source small
            // rather than blowing it up to the requested box.
            var path = url.path
            if let query = url.query, !query.isEmpty { path += "?\(query)" }
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            comps.path = "/photo/:/transcode"
            comps.queryItems = [
                URLQueryItem(name: "width", value: String(width)),
                // Posters are 2:3; the box only has to contain the image, and
                // Plex preserves the aspect ratio inside it.
                URLQueryItem(name: "height", value: String(Int(Double(width) * 1.5))),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "upscale", value: "0"),
                URLQueryItem(name: "url", value: path),
            ]
            return comps.url
        case .jellyfin, .emby:
            // Same endpoint, one extra parameter — no path rewriting needed.
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            var items = comps.queryItems ?? []
            guard !items.contains(where: { $0.name == "maxWidth" }) else { return nil }
            items.append(URLQueryItem(name: "maxWidth", value: String(width)))
            comps.queryItems = items
            return comps.url
        }
    }
}
