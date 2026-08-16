import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a poster is being used for — which is what decides how big a copy we
/// keep. Sizing by purpose rather than by source is the whole point: the arr's
/// artwork is 421 kB on average, and a 40×60 pt list row was pulling all of it.
public enum PosterTier: String, Sendable, CaseIterable {
    /// Spotlight results and every small UI slot (up to ~85 pt on the long
    /// edge, which is 256 px even at @3x).
    case icon
    /// Detail heroes, the Quiz deck, chat result cards — anything bigger.
    case card
    /// The pinch-zoom lightbox, which goes to 5×. Fetched at whatever the
    /// source serves and held in memory for the sheet's lifetime only: it is
    /// one deliberate action on one poster, and it was persisting originals
    /// that made the old cache 306 MB.
    case full

    /// Longest edge we store, or nil to keep the source as served.
    ///
    /// Each cap sits just *above* the CDN variant this tier asks for — TMDB's
    /// `w185` poster is 185×278 and `w780` is 780×1170 — so the file we
    /// requested lands on disk byte-for-byte instead of being decoded and
    /// recompressed for nothing. The cap still bites for sources with no
    /// variant convention, which is exactly where it is needed.
    var maxPixelSize: Int? {
        switch self {
        case .icon: return 288
        case .card: return 1200
        case .full: return nil
        }
    }

    /// How long an untouched file survives. The icon store backs the Spotlight
    /// index — a re-index must never need the network — so it outlives the card
    /// store by a wide margin. Retention is a property of the tier precisely so
    /// that no caller can pass a day count and quietly break that invariant.
    var retention: TimeInterval? {
        switch self {
        case .icon: return 90 * 24 * 3600
        case .card: return 30 * 24 * 3600
        case .full: return nil
        }
    }

    /// Ordering by pixel size: `.icon` < `.card` < `.full`. Lets the store find
    /// a smaller copy to paint immediately, and a larger one to derive from
    /// instead of downloading.
    var rank: Int {
        switch self {
        case .icon: return 0
        case .card: return 1
        case .full: return 2
        }
    }

    /// nil for tiers that are never written to disk.
    var directoryName: String? {
        switch self {
        case .icon: return "posters-icon"
        case .card: return "posters-card"
        case .full: return nil
        }
    }

    /// Whether this tier may live in `~/Library/Caches`.
    ///
    /// `.icon` may not. Everything under an app's Caches directory is
    /// reclaimable by macOS `cache_delete` — and reclaiming it is not passive:
    /// the daemon takes a termination assertion and *kills the app* to do it
    /// (`CacheDeleteAppContainerCaches`), which is what made ArrBarr look like
    /// it was quitting on its own every few minutes with no crash report. Each
    /// sweep also deleted the whole icon store, so the next launch re-downloaded
    /// every poster in the library — 54 MB here — feeding the disk pressure that
    /// triggered the next sweep.
    ///
    /// That directly contradicts the invariant `retention` is written around: a
    /// re-index must never need the network. So the tier that backs the
    /// Spotlight index lives in Application Support, which the OS does not
    /// reclaim. `.card` and `.full` are genuinely disposable — a cleared card is
    /// one poster re-fetched when a detail view opens — and stay in Caches.
    var isDisposable: Bool {
        switch self {
        case .icon: return false
        case .card, .full: return true
        }
    }

    /// The CDN's own size variant for this tier, if the host has one.
    ///
    /// `.full` asks for `original` rather than "leave the URL alone", because
    /// the URL it is handed is usually already a *small* variant: TMDB person
    /// portraits are built at `w185` (`TMDBClient.profileURL`), and the
    /// lightbox zooms to 5×. Without the upgrade, tapping a portrait enlarged
    /// a 185-pixel image. Swapping to a size the URL already has is a no-op,
    /// so an `original` URL stays untouched.
    fileprivate var tmdbSize: String? {
        switch self {
        case .icon: return "w185"
        case .card: return "w780"
        case .full: return "original"
        }
    }
}

/// A freshly stored poster, plus what it actually cost to get. The byte count
/// is per-fetch rather than a counter on the store: one store now serves both
/// the UI and the Spotlight prefetch, so a shared counter would attribute the
/// interface's downloads to whoever logged last.
public struct PosterFetch: Sendable {
    public let data: Data
    /// 0 when the copy was derived from a larger one already on disk.
    public let downloadedBytes: Int
}

/// One cache for every poster in the app, sized per use.
///
/// Replaces the old split between a full-size `ImageCache` for the UI and a
/// thumbnail store for Spotlight, which downloaded the same artwork twice and
/// kept 421 kB originals to draw 40×60 pt rows. One downloader, one key, one
/// in-flight dedup, one negative cache — with retention and size decided by the
/// tier rather than by the call site.
public actor PosterStore {
    public static let shared = PosterStore()

    private let memory = NSCache<NSString, PlatformImage>()
    private let session: URLSession
    private let logger = Logger(category: "PosterStore")
    private static let memoryCostCap = 50 * 1024 * 1024

    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    private var negativeCache: [String: Date] = [:]
    private static let negativeTTL: TimeInterval = 60 * 60
    /// A poster that failed is not retried for a week. Kept on disk (unlike the
    /// in-memory negative cache) so the library prefetch doesn't spend its
    /// whole budget re-trying the same dead artwork after every relaunch.
    private static let missTTL: TimeInterval = 7 * 24 * 3600
    /// How stale a file's mtime may get before `keepAlive` refreshes it. Keeps
    /// the touch-on-use write down to once a week per file while still keeping
    /// live entries far away from their retention limit.
    private static let touchThreshold: TimeInterval = 7 * 24 * 3600

    private var didMigrate = false

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
        memory.totalCostLimit = Self.memoryCostCap
        for tier in PosterTier.allCases {
            guard var dir = Self.directory(tier) else { continue }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Out of Caches so the OS can't reclaim it (see `isDisposable`) —
            // but it is still re-downloadable artwork, so keep it out of backups
            // and iCloud rather than shipping ~50 MB of posters to both.
            guard !tier.isDisposable else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
    }

    // MARK: - Reading

    /// The poster at `tier`, from memory, then disk, then the network.
    public func image(for url: URL, tier: PosterTier, apiKey: String? = nil) async -> PlatformImage? {
        let key = Self.memoryKey(url, tier)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let until = negativeCache[key], until > Date() { return nil }
        if let task = inflight[key] { return await task.value }

        let task = Task<PlatformImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadOrFetch(url: url, tier: tier, apiKey: apiKey)
        }
        inflight[key] = task
        let result = await task.value
        // Only clear the slot if it still holds THIS task — while we were
        // awaiting, a concurrent caller may have installed its own task for the
        // same key, and clearing unconditionally would orphan it.
        if inflight[key] == task { inflight[key] = nil }
        return result
    }

    /// The best copy *smaller* than `tier` that we already hold, for painting
    /// something the instant a view appears while the real one loads. Never
    /// touches the network — it is a look in the cupboard, not a request.
    ///
    /// This is what makes the library-wide icon store pay off twice: every
    /// title has an 18 kB copy on disk, so a detail view that used to sit empty
    /// through a download now opens with its poster and merely sharpens.
    public func cachedPreview(for url: URL, below tier: PosterTier) -> PlatformImage? {
        // Largest first — a card is a better stand-in for the lightbox than an
        // icon is.
        for candidate in PosterTier.allCases.reversed() where candidate.rank < tier.rank {
            let key = Self.memoryKey(url, candidate)
            if let hit = memory.object(forKey: key as NSString) { return hit }
            if let data = Self.storedData(for: url, tier: candidate),
               let image = PlatformImage(data: data) {
                Self.keepAlive([url], tier: candidate)
                store(image, key: key)
                return image
            }
        }
        return nil
    }

    /// Stored bytes for `tier`, ready to inline into a Spotlight item. Sync and
    /// nonisolated: the indexer calls it while building thousands of items and
    /// an actor hop per row would dominate the pass.
    public nonisolated static func storedData(for url: URL, tier: PosterTier) -> Data? {
        guard let file = file(url, tier) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Do we already have this poster at this tier? **Pure** — it is used as a
    /// predicate while building work lists, and a probe that quietly refreshed
    /// retention state would make a dry run indistinguishable from a real pass.
    /// Ageing is `keepAlive`'s job.
    public nonisolated static func hasCached(_ url: URL, tier: PosterTier) -> Bool {
        guard let file = file(url, tier) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Mark these posters as still referenced, so `purge()` (which goes by
    /// mtime) doesn't reclaim artwork the library is actively using. Every
    /// indexing pass calls it — including one that skips re-indexing, which
    /// would otherwise let live entries look abandoned.
    public nonisolated static func keepAlive(_ urls: [URL], tier: PosterTier) {
        let now = Date()
        for url in urls {
            guard let file = file(url, tier),
                  let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate,
                  now.timeIntervalSince(mtime) > touchThreshold else { continue }
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
    }

    /// True while a recent failure is still cooling off. Expired markers are
    /// deleted here, which re-opens the URL for a retry.
    public nonisolated static func isFreshMiss(_ url: URL, tier: PosterTier) -> Bool {
        guard let marker = missMarker(url, tier) else { return false }
        guard let mtime = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return false }
        if Date().timeIntervalSince(mtime) < missTTL { return true }
        try? FileManager.default.removeItem(at: marker)
        return false
    }

    // MARK: - Fetching

    private func loadOrFetch(url: URL, tier: PosterTier, apiKey: String?) async -> PlatformImage? {
        if let file = Self.file(url, tier), let data = try? Data(contentsOf: file),
           let image = PlatformImage(data: data) {
            // Reading counts as use. `purge()` goes by mtime, and only the icon
            // tier gets a keep-alive sweep from the indexer — without this, a
            // card you open every day would still be reclaimed on its 30th.
            Self.keepAlive([url], tier: tier)
            store(image, key: Self.memoryKey(url, tier))
            return image
        }
        guard let fetched = await fetchStoring(url, tier: tier, apiKey: apiKey),
              let image = PlatformImage(data: fetched.data) else {
            noteFailure(Self.memoryKey(url, tier))
            return nil
        }
        store(image, key: Self.memoryKey(url, tier))
        return image
    }

    /// Start this poster's cool-off, sweeping out every marker that has already
    /// expired. The sweep is the point: reads only ever look up the one key they
    /// are about to fetch, so an expired entry for a poster nothing asks for
    /// again is never touched — and a library prefetch that misses on a few
    /// hundred URLs would hold all of them for the life of the process.
    private func noteFailure(_ key: String) {
        let now = Date()
        negativeCache = negativeCache.filter { $0.value > now }
        negativeCache[key] = now.addingTimeInterval(Self.negativeTTL)
    }

    /// Download, resize to the tier and store it. Returns the stored bytes —
    /// the Spotlight indexer inlines them directly, so handing them back saves
    /// reading the file we just wrote — along with what it actually cost.
    ///
    /// Asks the CDN for its own size variant first and only falls back to the
    /// full-size URL if that isn't served, so the common case moves 13 kB
    /// instead of 241 kB over the wire.
    public func fetchStoring(_ url: URL, tier: PosterTier, apiKey: String?) async -> PosterFetch? {
        // Nothing to download if we already hold a bigger copy: resizing it is
        // local, exact, and beats fetching the same artwork twice when a title
        // gets opened before the library prefetch reaches it.
        if let larger = PosterTier.allCases.first(where: {
            $0.rank > tier.rank && Self.hasCached(url, tier: $0)
        }), let data = Self.storedData(for: url, tier: larger),
           let sized = Self.resized(data, maxPixelSize: tier.maxPixelSize) {
            return PosterFetch(data: persist(sized, url: url, tier: tier), downloadedBytes: 0)
        }
        if let variant = Self.sourceURL(for: url, tier: tier),
           let data = await download(variant, apiKey: apiKey),
           let sized = Self.resized(data, maxPixelSize: tier.maxPixelSize) {
            return PosterFetch(data: persist(sized, url: url, tier: tier), downloadedBytes: data.count)
        }
        guard let data = await download(url, apiKey: apiKey),
              let sized = Self.resized(data, maxPixelSize: tier.maxPixelSize) else {
            markMiss(url, tier: tier)
            return nil
        }
        return PosterFetch(data: persist(sized, url: url, tier: tier), downloadedBytes: data.count)
    }

    /// The CDN's own size variant of `url` for this tier, when there is one.
    ///
    /// Radarr hands us `image.tmdb.org/t/p/original/…` and Sonarr
    /// `artworks.thetvdb.com/banners/…`; both serve variants by path alone, and
    /// the difference is not marginal — measured, 13 kB (`w185`) / 74 kB
    /// (`w500`) / 161 kB (`w780`) against 241 kB for the original, and 53 vs
    /// 193 kB for TheTVDB's `_t`. Anything else, including an arr's own
    /// `/MediaCover` path, has no variant convention we can rely on and is
    /// fetched as-is.
    ///
    /// Purely a transport detail: the cache key stays the ORIGINAL url, so
    /// changing variants never orphans what we already stored.
    static func sourceURL(for url: URL, tier: PosterTier) -> URL? {
        switch url.host {
        case "image.tmdb.org":
            // /t/p/<size>/<file> — the size segment is the only part to swap.
            guard let size = tier.tmdbSize,
                  var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            var parts = comps.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5, parts[1] == "t", parts[2] == "p", parts[3] != size else { return nil }
            parts[3] = size
            comps.path = parts.joined(separator: "/")
            return comps.url
        case "artworks.thetvdb.com":
            // …/<name>.jpg → …/<name>_t.jpg. Only the icon tier: `_t` is a
            // thumbnail, too small to stand in for a card.
            guard tier == .icon else { return nil }
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            guard !ext.isEmpty, !base.isEmpty, !base.hasSuffix("_t") else { return nil }
            return url.deletingLastPathComponent()
                .appendingPathComponent(base + "_t")
                .appendingPathExtension(ext)
        default:
            // Plex / Jellyfin / Emby resize on request, but only for the host
            // the user actually connected — hence the config lookup rather
            // than a host literal like the two CDNs above.
            return MediaServerPosterAccess.shared.sizedURL(for: url, tier: tier)
        }
    }

    private func download(_ url: URL, apiKey: String?) async -> Data? {
        // Poster fetches are the app's other fan-out, and they share the same
        // six-connections-per-host pool as the queue's side-loads. Whether a
        // slow refresh is the arr being slow or the poster loader hogging the
        // pool is visible in Instruments when both are signposted, and not
        // otherwise. The tier names the interval so over-fetching a large tier
        // for a small row shows up as a wide band.
        let signpost = AppSignpost.posters
        let state = signpost.beginInterval("poster download")
        defer { signpost.endInterval("poster download", state) }

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        // The media server's token never appears in the URL — it would be
        // persisted with the poster URL and hashed into the cache key. It is
        // resolved per request instead; see `MediaServerPosterAccess`.
        for (field, value) in MediaServerPosterAccess.shared.headers(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Scheme/host/path, never the query — the same redaction the
                // realtime and queue paths apply. A poster URL reaches a host
                // the user runs, and a Plex transcode URL carries the original
                // item path (and any legacy `apikey=`) in its query string.
                logger.debug(
                    "poster \(http.statusCode, privacy: .public) for \(url.loggableDescription, privacy: .private)"
                )
                return nil
            }
            return data
        } catch {
            logger.debug("poster fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    private func persist(_ data: Data, url: URL, tier: PosterTier) -> Data {
        if let file = Self.file(url, tier) {
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    private func markMiss(_ url: URL, tier: PosterTier) {
        guard let marker = Self.missMarker(url, tier) else { return }
        // Atomic write also refreshes the mtime, so the cool-off restarts from
        // the latest failure.
        try? Data().write(to: marker, options: .atomic)
    }

    private func store(_ image: PlatformImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Self.decodedByteCost(image))
    }

    /// What the cached object actually costs in RAM. Charging the *compressed*
    /// size (as this cache used to) under-counts by 20-50×: a 2000×3000 poster
    /// is ~420 kB on disk but 24 MB as a bitmap, so a 50 MB limit measured in
    /// compressed bytes let NSCache hold roughly a gigabyte of decoded images.
    nonisolated static func decodedByteCost(_ image: PlatformImage) -> Int {
        #if os(macOS)
        // `NSImage.size` is in points and follows the rep's DPI, so it can be
        // far off the pixel count. The bitmap rep knows the real dimensions.
        if let rep = image.representations.first as? NSBitmapImageRep {
            return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
        #else
        // `UIImage.size` is in points; `scale` converts back to pixels.
        return max(1, Int(image.size.width * image.scale * image.size.height * image.scale) * 4)
        #endif
    }

    // MARK: - Resizing

    /// Cap the long edge, or return the source untouched when it already fits
    /// (or the tier keeps originals). Skipping the re-encode matters: it is
    /// what lets a CDN variant we asked for land on disk byte-for-byte instead
    /// of being decoded and recompressed for nothing.
    ///
    /// Capping the *long* edge rather than fitting a CGSize is what makes this
    /// aspect-agnostic: 2:3 posters, Lidarr's square album art and square cast
    /// headshots all come out right without a special case.
    ///
    /// Encodes JPEG unless the source actually has an alpha channel — some
    /// artwork ships as RGBA PNG, and JPEG would flatten transparency to black.
    static func resized(_ data: Data, maxPixelSize: Int?) -> Data? {
        guard let cap = maxPixelSize else { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           max(w, h) <= cap {
            return data
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: cap,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(thumb.alphaInfo)
        let format = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Paths

    /// Where the disposable tiers live — the OS may reclaim any of it.
    nonisolated static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Where tiers the OS must not reclaim live. See `PosterTier.isDisposable`.
    nonisolated static var durableRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? root
        return support.appendingPathComponent(bundleId, isDirectory: true)
    }

    private nonisolated static var bundleId: String {
        Bundle.main.bundleIdentifier ?? "pl.incred.ArrBarr"
    }

    nonisolated static func directory(_ tier: PosterTier) -> URL? {
        guard let name = tier.directoryName else { return nil }
        let base = tier.isDisposable ? root : durableRoot
        return base.appendingPathComponent(name, isDirectory: true)
    }

    private nonisolated static func file(_ url: URL, _ tier: PosterTier) -> URL? {
        directory(tier)?.appendingPathComponent(key(for: url) + ".jpg")
    }

    private nonisolated static func missMarker(_ url: URL, _ tier: PosterTier) -> URL? {
        directory(tier)?.appendingPathComponent(key(for: url) + ".miss")
    }

    private nonisolated static func memoryKey(_ url: URL, _ tier: PosterTier) -> String {
        "\(key(for: url)).\(tier.rawValue)"
    }

    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Housekeeping

    /// Drop entries nothing has referenced within their tier's retention, and
    /// clear out the pre-tiering layout on first run. Takes no argument on
    /// purpose: the icon store's lifetime is the Spotlight index's lifetime,
    /// and a caller-supplied day count is exactly how that gets broken.
    public func purge() {
        migrateLegacyLayout()
        let fm = FileManager.default
        for tier in PosterTier.allCases {
            guard let dir = Self.directory(tier), let retention = tier.retention,
                  let entries = try? fm.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
                  ) else { continue }
            let cutoff = Date().addingTimeInterval(-retention)
            var removed = 0
            for entry in entries {
                let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if mtime < cutoff {
                    try? fm.removeItem(at: entry)
                    removed += 1
                }
            }
            if removed > 0 {
                // Housekeeping that runs on every launch. `.debug` so it stays
                // out of the persistent store, where the migrations below and
                // the queue/tool trail have to survive.
                logger.debug("purged \(removed, privacy: .public) \(tier.rawValue, privacy: .public) posters")
            }
        }
    }

    /// Carry the Spotlight thumbnails over to the tiered layout (a directory
    /// rename — re-downloading them would be tens of MB), and drop the old
    /// full-size poster cache outright. Those originals averaged 421 kB to draw
    /// list rows that now read a 15 kB icon; anything still wanted comes back
    /// on demand at card size.
    private func migrateLegacyLayout() {
        guard !didMigrate else { return }
        didMigrate = true
        let fm = FileManager.default
        // Two former homes for the same artwork, newest first. The icon tier
        // most recently lived in Caches, where the OS could delete it out from
        // under us (see `PosterTier.isDisposable`); before that it was the flat
        // `spotlight-thumbs` directory. Whichever is found is carried over.
        if let name = PosterTier.icon.directoryName {
            adoptAsIconTier(Self.root.appendingPathComponent(name, isDirectory: true), from: "Caches")
        }
        adoptAsIconTier(
            Self.root.appendingPathComponent("spotlight-thumbs", isDirectory: true),
            from: "spotlight-thumbs"
        )
        let legacyOriginals = Self.root.appendingPathComponent("posters", isDirectory: true)
        if fm.fileExists(atPath: legacyOriginals.path) {
            let freed = (try? fm.contentsOfDirectory(atPath: legacyOriginals.path))?.count ?? 0
            try? fm.removeItem(at: legacyOriginals)
            logger.notice("dropped \(freed, privacy: .public) full-size posters (superseded by the card tier)")
        }
    }

    /// Take over `legacy` as the icon tier, or drop it if the tier already holds
    /// artwork. A directory rename either way — the icon store is tens of MB of
    /// downloads, and the whole point of moving it is not to fetch it again.
    /// Adopting only into an *empty* tier keeps the newest home winning when
    /// more than one legacy directory is still lying around.
    private func adoptAsIconTier(_ legacy: URL, from source: String) {
        let fm = FileManager.default
        guard let iconDir = Self.directory(.icon),
              legacy != iconDir,
              fm.fileExists(atPath: legacy.path) else { return }
        guard (try? fm.contentsOfDirectory(atPath: iconDir.path))?.isEmpty ?? true else {
            try? fm.removeItem(at: legacy)
            return
        }
        let carried = (try? fm.contentsOfDirectory(atPath: legacy.path))?.count ?? 0
        try? fm.removeItem(at: iconDir)
        try? fm.createDirectory(at: iconDir.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: iconDir)
        logger.notice(
            "carried \(carried, privacy: .public) icon posters over from \(source, privacy: .public)"
        )
    }

    /// Wipe one tier. Internal on purpose — user-facing clearing goes through
    /// `AppCaches.clearArtwork()`, which also drops the derived tints, and
    /// `SpotlightIndexer.clearIndex()`, which knows the icon store and the
    /// Spotlight index have to be cleared together.
    func clear(tier: PosterTier) {
        guard let dir = Self.directory(tier) else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Wipe every tier, on disk and in memory. `.full` has no directory — it
    /// lives in the memory cache alone — so the in-memory sweep is not an
    /// optimisation here, it is the only thing that clears it.
    func clearAllTiers() {
        for tier in PosterTier.allCases { clear(tier: tier) }
        memory.removeAllObjects()
        negativeCache.removeAll()
    }

    /// Bytes the on-disk tiers occupy. Walks the directories rather than
    /// tracking a running total: the OS can reclaim the disposable tiers behind
    /// our back (see `PosterTier.isDisposable`), so a counter would drift.
    func diskUsage() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for tier in PosterTier.allCases {
            guard let dir = Self.directory(tier),
                  let entries = try? fm.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: [.fileSizeKey]
                  ) else { continue }
            for entry in entries {
                total += Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}
