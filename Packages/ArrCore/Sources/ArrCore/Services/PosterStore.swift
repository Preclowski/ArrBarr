import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import MediaKit
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a poster is used for, which decides how big a copy is kept.
nonisolated public enum PosterTier: String, Sendable, CaseIterable {
    /// Spotlight and small UI slots (up to ~85 pt, 256 px at @3x).
    case icon
    case card
    /// The 5× pinch-zoom lightbox: source size, held in memory only, never on disk.
    case full

    /// Each cap sits just above the CDN variant the tier asks for (TMDB `w185` is
    /// 185×278, `w780` 780×1170), so the requested file is stored without re-encoding.
    var maxPixelSize: Int? {
        switch self {
        case .icon: return 288
        case .card: return 1200
        case .full: return nil
        }
    }

    /// The icon store backs the Spotlight index, whose re-index must never need
    /// the network, so it outlives the card store.
    var retention: TimeInterval? {
        switch self {
        case .icon: return 90 * 24 * 3600
        case .card: return 30 * 24 * 3600
        case .full: return nil
        }
    }

    var rank: Int {
        switch self {
        case .icon: return 0
        case .card: return 1
        case .full: return 2
        }
    }

    /// nil for tiers never written to disk.
    var directoryName: String? {
        switch self {
        case .icon: return "posters-icon"
        case .card: return "posters-card"
        case .full: return nil
        }
    }

    /// `.icon` stays out of `~/Library/Caches`: `cache_delete` kills the app to
    /// reclaim Caches, and losing the icon store forces a full re-download.
    var isDisposable: Bool {
        switch self {
        case .icon: return false
        case .card, .full: return true
        }
    }

    /// The server-side resize a media server is asked for; `.full` keeps the original.
    fileprivate var artworkTier: ArtworkTier {
        switch self {
        case .icon: .icon
        case .card: .card
        case .full: .full
        }
    }
}

/// Byte count is per fetch, not a store counter: UI and Spotlight share one store.
public struct PosterFetch: Sendable {
    public let data: Data
    /// 0 when the copy was derived from a larger one already on disk.
    public let downloadedBytes: Int
}

/// One cache for every poster in the app, sized and retained per tier.
public actor PosterStore {
    nonisolated public static let shared = PosterStore()

    private let memory = NSCache<NSString, PlatformImage>()
    private let session: URLSession
    private static let logger = Logger(category: "PosterStore")
    nonisolated private static let memoryCostCap = 50 * 1024 * 1024

    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    private var negativeCache: [String: Date] = [:]
    nonisolated private static let negativeTTL: TimeInterval = 60 * 60
    /// On disk so the library prefetch doesn't re-spend its budget on dead artwork after a relaunch.
    nonisolated private static let missTTL: TimeInterval = 7 * 24 * 3600
    /// Limits the touch-on-use write to once a week per file.
    nonisolated private static let touchThreshold: TimeInterval = 7 * 24 * 3600

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
            // Not reclaimable, but still re-downloadable: keep it out of backups and iCloud.
            guard !tier.isDisposable else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
    }

    // MARK: - Reading

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
        // A concurrent caller may have installed its own task for this key meanwhile.
        if inflight[key] == task { inflight[key] = nil }
        return result
    }

    /// The best smaller copy already held, painted while the real one loads. Never
    /// touches the network.
    public func cachedPreview(for url: URL, below tier: PosterTier) -> PlatformImage? {
        for candidate in PosterTier.allCases.reversed() where candidate.rank < tier.rank {
            let key = Self.memoryKey(url, candidate)
            if let hit = memory.object(forKey: key as NSString) { return hit }
            if let data = Self.storedData(for: url, tier: candidate),
               let image = Self.decoded(data) {
                Self.keepAlive([url], tier: candidate)
                store(image, key: key)
                return image
            }
        }
        return nil
    }

    /// Sync and nonisolated: the indexer calls it for thousands of items.
    public nonisolated static func storedData(for url: URL, tier: PosterTier) -> Data? {
        guard let file = file(url, tier) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Pure: used as a work-list predicate, so it must not refresh retention (that's `keepAlive`).
    public nonisolated static func hasCached(_ url: URL, tier: PosterTier) -> Bool {
        guard let file = file(url, tier) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Refreshes mtimes so `purge()` doesn't reclaim posters the library still uses.
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

    /// Arr posters the media server's artwork replaced, keyed by the media server URL.
    nonisolated private static let superseded = OSAllocatedUnfairLock<[URL: URL]>(initialState: [:])

    public nonisolated static func supersede(_ arr: URL?, with replacement: URL) {
        guard let arr, arr != replacement else { return }
        let isNew = superseded.withLock { map in
            guard map[replacement] != arr else { return false }
            map[replacement] = arr
            return true
        }
        // Covers a replacement stored in an earlier launch; a fresh download drops it in `persist`.
        if isNew { Task(priority: .utility) { await shared.dropSuperseded(by: replacement) } }
    }

    /// Expired markers are deleted here, which re-opens the URL for a retry.
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
        if let image = await Self.loadStored(url, tier) {
            // Reading counts as use: `purge()` goes by mtime and only the icon tier gets a keep-alive sweep.
            Self.keepAlive([url], tier: tier)
            store(image, key: Self.memoryKey(url, tier))
            return image
        }
        guard let fetched = await fetchStoring(url, tier: tier, apiKey: apiKey),
              let image = await Self.decode(fetched.data) else {
            // Only artwork the server says is gone sits out the cool-off; a dropped connection retries next time.
            if Self.isFreshMiss(url, tier: tier) { noteFailure(Self.memoryKey(url, tier)) }
            return nil
        }
        store(image, key: Self.memoryKey(url, tier))
        return image
    }

    /// The file read and the decode run off the actor, so a grid of posters loads in parallel.
    @concurrent
    private static func loadStored(_ url: URL, _ tier: PosterTier) async -> PlatformImage? {
        storedData(for: url, tier: tier).flatMap(decoded)
    }

    @concurrent
    private static func decode(_ data: Data) async -> PlatformImage? { decoded(data) }

    /// Decoded now: `PlatformImage(data:)` defers the JPEG decode to the first draw, on the main thread mid-scroll.
    nonisolated static func decoded(_ data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }

    /// Also sweeps expired markers: reads only check their own key, so stale ones would never go.
    private func noteFailure(_ key: String) {
        let now = Date()
        negativeCache = negativeCache.filter { $0.value > now }
        negativeCache[key] = now.addingTimeInterval(Self.negativeTTL)
    }

    /// Returns the stored bytes so the Spotlight indexer can inline them without a re-read.
    public func fetchStoring(_ url: URL, tier: PosterTier, apiKey: String?) async -> PosterFetch? {
        // Resizing a larger copy already held beats fetching the same artwork again.
        if let larger = PosterTier.allCases.first(where: {
            $0.rank > tier.rank && Self.hasCached(url, tier: $0)
        }), let data = Self.storedData(for: url, tier: larger),
           let sized = Self.resized(data, maxPixelSize: tier.maxPixelSize) {
            return PosterFetch(data: persist(sized, url: url, tier: tier), downloadedBytes: 0)
        }
        let artwork = await MediaServerIndex.shared.artwork(for: url)
        if let variant = Self.sourceURL(for: url, tier: tier, artwork: artwork),
           case .data(let data) = await download(variant, apiKey: apiKey, artwork: artwork),
           let sized = Self.resized(data, maxPixelSize: tier.maxPixelSize) {
            return PosterFetch(data: persist(sized, url: url, tier: tier), downloadedBytes: data.count)
        }
        switch await download(url, apiKey: apiKey, artwork: artwork) {
        case .data(let data):
            guard let sized = Self.resized(data, maxPixelSize: tier.maxPixelSize) else {
                markMiss(url, tier: tier)
                return nil
            }
            return PosterFetch(data: persist(sized, url: url, tier: tier), downloadedBytes: data.count)
        case .gone:
            markMiss(url, tier: tier)
            return nil
        case .failed:
            return nil
        }
    }

    /// `gone` is the server's answer (404/410) and is remembered; `failed` (offline, timeout, 5xx) is not.
    enum Download: Equatable {
        case data(Data), gone, failed
    }

    /// TMDB and TheTVDB serve size variants by path (measured 13 kB `w185` vs 241 kB
    /// original). The cache key stays the original URL, so variants never orphan entries.
    nonisolated static func sourceURL(for url: URL, tier: PosterTier, artwork: ArtworkReference? = nil) -> URL? {
        switch url.host {
        case TMDBService.imageBase.host:
            guard let reference = TMDBService.artwork(cdnURL: url, kind: .poster) else { return nil }
            let sized = reference.sized(tier.artworkTier).url
            return sized == url ? nil : sized
        case "artworks.thetvdb.com":
            // `_t` is a thumbnail, too small for a card.
            guard tier == .icon else { return nil }
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            guard !ext.isEmpty, !base.isEmpty, !base.hasSuffix("_t") else { return nil }
            return url.deletingLastPathComponent()
                .appendingPathComponent(base + "_t")
                .appendingPathExtension(ext)
        default:
            // Only media-server artwork references know how to request a resize.
            guard let artwork else { return nil }
            let sized = artwork.sized(tier.artworkTier).url
            return sized == url ? nil : sized
        }
    }

    /// The arr's key goes only to an arr: the URL has to sit under a registered arr's base URL (scheme, host,
    /// port and path prefix, since a reverse proxy can put Plex and Radarr on one origin), whatever the caller passed.
    nonisolated static func arrKey(_ apiKey: String?, for url: URL, artwork: ArtworkReference?, arrs: [URL]) -> String? {
        guard let apiKey, !apiKey.isEmpty, artwork == nil, arrs.contains(where: { isUnder(url, $0) }) else { return nil }
        return apiKey
    }

    nonisolated private static func isUnder(_ url: URL, _ base: URL) -> Bool {
        func port(_ u: URL) -> Int? {
            u.port ?? ["http": 80, "https": 443][u.scheme?.lowercased() ?? ""]
        }
        guard url.scheme?.lowercased() == base.scheme?.lowercased(), url.host?.lowercased() == base.host?.lowercased(),
              port(url) == port(base) else { return false }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return base.path.isEmpty || base.path == "/" || url.path == base.path || url.path.hasPrefix(prefix)
    }

    private func download(_ url: URL, apiKey: String?, artwork: ArtworkReference?) async -> Download {
        // Signposted so poster fetches can be told apart from queue side-loads sharing the per-host pool.
        let signpost = AppSignpost.posters
        let state = signpost.beginInterval("poster download")
        defer { signpost.endInterval("poster download", state) }

        var request = URLRequest(url: url)
        let gateway = await ServiceGateway.resolve()
        let arrs = gateway.arrBaseURLs
        if let apiKey = Self.arrKey(apiKey, for: url, artwork: artwork, arrs: arrs) {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        // The media server token never goes in the URL: it would be persisted and hashed into the cache key.
        if let artwork {
            for (field, value) in await gateway.artworkHeaders(for: artwork) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Never the query: Plex transcode URLs carry item paths and legacy `apikey=` there.
                Self.logger.debug(
                    "poster \(http.statusCode, privacy: .public) for \(url.loggableDescription, privacy: .private)"
                )
                return [404, 410].contains(http.statusCode) ? .gone : .failed
            }
            return .data(data)
        } catch {
            Self.logger.debug("poster fetch failed: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return .failed
        }
    }

    @discardableResult
    private func persist(_ data: Data, url: URL, tier: PosterTier) -> Data {
        if let file = Self.file(url, tier) {
            try? data.write(to: file, options: .atomic)
        }
        dropSuperseded(by: url)
        return data
    }

    private func dropSuperseded(by replacement: URL) {
        guard let arr = Self.superseded.withLock({ $0[replacement] }),
              PosterTier.allCases.contains(where: { Self.hasCached(replacement, tier: $0) }) else { return }
        for tier in PosterTier.allCases {
            memory.removeObject(forKey: Self.memoryKey(arr, tier) as NSString)
            for file in [Self.file(arr, tier), Self.missMarker(arr, tier)].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func markMiss(_ url: URL, tier: PosterTier) {
        guard let marker = Self.missMarker(url, tier) else { return }
        // Atomic write also refreshes the mtime, so the cool-off restarts.
        try? Data().write(to: marker, options: .atomic)
    }

    private func store(_ image: PlatformImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Self.decodedByteCost(image))
    }

    /// Decoded bitmap size, not compressed: a 420 kB poster is 24 MB in memory.
    nonisolated static func decodedByteCost(_ image: PlatformImage) -> Int {
        #if os(macOS)
        // `NSImage.size` is in points and follows the rep's DPI; the bitmap rep has real pixels.
        if let rep = image.representations.first as? NSBitmapImageRep {
            return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
        #else
        return max(1, Int(image.size.width * image.scale * image.size.height * image.scale) * 4)
        #endif
    }

    // MARK: - Resizing

    /// Returns the source untouched when it fits, so a requested CDN variant is stored as-is.
    /// JPEG unless the source has alpha: some artwork is RGBA PNG.
    nonisolated static func resized(_ data: Data, maxPixelSize: Int?) -> Data? {
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

    /// Disposable tiers; the OS may reclaim any of it.
    nonisolated static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Tiers the OS must not reclaim. See `PosterTier.isDisposable`.
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

    nonisolated static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Housekeeping

    /// No retention argument on purpose: the icon store must live as long as the Spotlight index.
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
                Self.logger.debug("purged \(removed, privacy: .public) \(tier.rawValue, privacy: .public) posters")
            }
        }
    }

    /// Moves the Spotlight thumbnails (a rename, not a re-download) and drops the old full-size cache.
    private func migrateLegacyLayout() {
        guard !didMigrate else { return }
        didMigrate = true
        let fm = FileManager.default
        // Newest legacy home first: Caches, then the flat `spotlight-thumbs` directory.
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
            Self.logger.notice("dropped \(freed, privacy: .public) full-size posters (superseded by the card tier)")
        }
    }

    /// Adopts only into an empty tier, so the newest legacy home wins.
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
        Self.logger.notice(
            "carried \(carried, privacy: .public) icon posters over from \(source, privacy: .public)"
        )
    }

    /// Internal: user-facing clearing goes through `AppCaches.clearArtwork()` and
    /// `SpotlightIndexer.clearIndex()`, which clear related state too.
    func clear(tier: PosterTier) {
        guard let dir = Self.directory(tier) else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// `.full` lives only in the memory cache, so the in-memory sweep is what clears it.
    func clearAllTiers() {
        for tier in PosterTier.allCases { clear(tier: tier) }
        memory.removeAllObjects()
        negativeCache.removeAll()
    }

    /// Walks the directories: the OS can reclaim disposable tiers, so a counter would drift.
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
