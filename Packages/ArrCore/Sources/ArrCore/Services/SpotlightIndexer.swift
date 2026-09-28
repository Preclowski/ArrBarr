import Foundation
import CoreSpotlight
import CryptoKit
import UniformTypeIdentifiers
import SwiftUI
import os

// MARK: - CoreSpotlight library indexing
// A pass never blocks on the network: rows get a cached thumbnail or the brand
// icon, and `fillMissingThumbnails` re-indexes the fallbacks later.
public enum SpotlightIndexer {
    private static let log = Logger(category: "Spotlight")
    private static let domainRadarr = "arrbarr.radarr"
    private static let domainSonarr = "arrbarr.sonarr"

    /// Posters fetched per pass (~20 kB each); the rest wait for later passes.
    private static let prefetchBudget = 1000
    private static let prefetchConcurrency = 4
    private static let indexBatch = 500

    /// `apiKey` is nil when the poster is a public CDN URL.
    private struct IndexedRecord {
        let item: CSSearchableItem
        let posterURL: URL?
        let apiKey: String?
    }

    static func identifier(source: QueueItem.Source, id: Int) -> String {
        "arrbarr.\(source.rawValue).\(id)"
    }

    public static func parse(_ identifier: String) -> (source: QueueItem.Source, id: Int)? {
        let parts = identifier.split(separator: ".")
        guard parts.count == 3, parts[0] == "arrbarr",
              let src = QueueItem.Source(rawValue: String(parts[1])),
              let id = Int(parts[2]) else { return nil }
        return (src, id)
    }

    /// A pass refetches the whole library (MBs) before it can tell nothing changed,
    /// and every popover open triggers one; hence hours, not minutes.
    private static let reindexThrottle: TimeInterval = 6 * 3600

    /// Persisted so relaunches don't each refetch the library.
    private static let lastReindexKey = "ArrBarr.spotlightLastReindex"

    @MainActor private static var lastReindex: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: lastReindexKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: lastReindexKey)
                return
            }
            UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastReindexKey)
        }
    }

    /// A pass can outlive the throttle; overlapping passes would fetch the same posters twice.
    @MainActor private static var isReindexing = false
    /// Kept so a pass (whose fill loop can run indefinitely) can be cancelled.
    @MainActor private static var indexingTask: Task<Void, Never>?

    /// Fire-and-forget, throttled by `reindexThrottle`.
    @MainActor
    public static func reindex(configStore: ConfigStore) {
        if isReindexing { return }
        if let last = lastReindex, Date().timeIntervalSince(last) < reindexThrottle { return }
        lastReindex = Date()
        isReindexing = true
        let radarr = configStore.radarr
        let sonarr = configStore.sonarr
        let mediaServer: MediaServerConfig? = StoreManager.shared.isPro ? configStore.mediaServer : nil
        // ImageRenderer requires the main actor.
        var radarrIcon: Data?
        var sonarrIcon: Data?
        if #available(iOS 16.0, macOS 13.0, *) {
            radarrIcon = SourceThumbnail.data(for: .radarr)
            sonarrIcon = SourceThumbnail.data(for: .sonarr)
        }
        indexingTask = Task.detached(priority: .utility) {
            // Unstructured `Task` ignores cancellation, so the flag is reset on every exit.
            defer { Task { @MainActor in isReindexing = false } }
            // The media server's artwork wins in the app, so the index waits for it rather than store the arr's.
            if let mediaServer { await MediaServerIndex.shared.refreshIfStale(config: mediaServer) }
            // Index both libraries first so Radarr's prefetch doesn't hold up Sonarr's index.
            var records = await reindexRadarr(radarr, fallbackIcon: radarrIcon)
            records += await reindexSonarr(sonarr, fallbackIcon: sonarrIcon)
            // Loop while a round spends its whole budget; `.miss` markers drop failed URLs,
            // so this terminates.
            while await fillMissingThumbnails(records) {
                // `try?` would swallow cancellation into another round with no delay.
                do { try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC) }
                catch { return }
            }
        }
    }

    @MainActor
    public static func cancelIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
    }

    /// Deletes only our two domains and resets the throttle. The only way to clear
    /// them: CoreSpotlight is per-app.
    @MainActor
    public static func clearIndex() async {
        // An in-flight fill round would re-index and re-download seconds later.
        cancelIndexing()
        let index = CSSearchableIndex.default()
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withDomainIdentifiers: [domainRadarr, domainSonarr]) { _ in
                cont.resume()
            }
        }
        await PosterStore.shared.clear(tier: .icon)
        // The fingerprints claim the index holds this library; stale ones would skip the next pass.
        for domain in [domainRadarr, domainSonarr] {
            UserDefaults.standard.removeObject(forKey: fingerprintKey(domain))
        }
        lastReindex = nil
        log.notice("cleared Spotlight index + prefetched posters")
    }

    /// The opt-out route when `spotlightOpensInApp = false`; the identifier lacks the title slug.
    @MainActor
    public static func browserURL(forIdentifier id: String, configStore: ConfigStore) async -> URL? {
        guard let ref = parse(id) else { return nil }
        let cfg = configStore.config(for: ref.source)
        guard cfg.isConfigured else { return nil }
        let slug: String?
        do {
            switch configStore.arrClient(for: ref.source) {
            case let movies as any MovieArrClient: slug = try await movies.fetchMovieDetails(id: ref.id).titleSlug
            case let series as SonarrClient: slug = try await series.fetchSeriesDetails(id: ref.id).titleSlug
            default: slug = nil
            }
        } catch {
            // A click must open something: the arr itself beats a dead hit.
            log.error("Spotlight hit \(id, privacy: .private) unresolved: \(error.localizedDescription, privacy: .public)")
            return URL(string: cfg.baseURL)
        }
        guard let slug, !slug.isEmpty else { return nil }
        let path = ref.source == .sonarr ? "/series/\(slug)" : "/movie/\(slug)"
        return URL(string: cfg.baseURL)?.appendingPathComponent(path)
    }

    private static func reindexRadarr(_ config: ServiceConfig, fallbackIcon: Data?) async -> [IndexedRecord] {
        guard config.isConfigured else { return [] }
        // Through the store the Library tab reads, so a pass inside its freshness window costs no request.
        let read = await LibraryIndex.shared.moviesRead(config: config)
        guard !read.failed else { return [] }
        return await syncIndex(read.records, domain: domainRadarr, fallbackIcon: fallbackIcon) { rec -> IndexedRecord? in
            guard let id = rec.id else { return nil }
            let title = rec.title
            let attr = CSSearchableItemAttributeSet(contentType: .movie)
            attr.title = rec.year.map { "\(title) (\($0))" } ?? title
            attr.contentDescription = rec.overview
            if let g = rec.genres, !g.isEmpty { attr.keywords = g }
            let (poster, needsAuth) = (rec.images ?? []).posterURL(baseURL: config.baseURL, mediaServerKeys: rec.mediaServerKeys)
            return IndexedRecord(
                item: CSSearchableItem(
                    uniqueIdentifier: identifier(source: .radarr, id: id),
                    domainIdentifier: domainRadarr,
                    attributeSet: attr
                ),
                posterURL: poster,
                apiKey: needsAuth ? config.apiKey : nil
            )
        }
    }

    private static func reindexSonarr(_ config: ServiceConfig, fallbackIcon: Data?) async -> [IndexedRecord] {
        guard config.isConfigured else { return [] }
        let read = await LibraryIndex.shared.seriesRead(config: config)
        guard !read.failed else { return [] }
        return await syncIndex(read.records, domain: domainSonarr, fallbackIcon: fallbackIcon) { rec -> IndexedRecord? in
            guard let id = rec.id else { return nil }
            let title = rec.title
            let attr = CSSearchableItemAttributeSet(contentType: .audiovisualContent)
            attr.title = rec.year.map { "\(title) (\($0))" } ?? title
            attr.contentDescription = rec.overview
            let (poster, needsAuth) = (rec.images ?? []).posterURL(baseURL: config.baseURL, mediaServerKeys: rec.mediaServerKeys)
            return IndexedRecord(
                item: CSSearchableItem(
                    uniqueIdentifier: identifier(source: .sonarr, id: id),
                    domainIdentifier: domainSonarr,
                    attributeSet: attr
                ),
                posterURL: poster,
                apiKey: needsAuth ? config.apiKey : nil
            )
        }
    }

    /// Inline bytes, never `thumbnailURL`: a sandbox-container URL renders no artwork
    /// in Spotlight. Icon tier only, to keep the system index small.
    private static func attachThumbnail(_ attr: CSSearchableItemAttributeSet, poster: URL?, fallback: Data?) {
        if let poster, let bytes = PosterStore.storedData(for: poster, tier: .icon) {
            attr.thumbnailData = bytes
        } else if let fallback {
            attr.thumbnailData = fallback
        }
    }

    /// Returns true when the round spent its whole budget (more to fetch).
    @discardableResult
    private static func fillMissingThumbnails(_ records: [IndexedRecord]) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }

        let jobs: [(index: Int, url: URL, apiKey: String?)] = records.enumerated().compactMap { idx, rec in
            guard let url = rec.posterURL,
                  !PosterStore.hasCached(url, tier: .icon),
                  !PosterStore.isFreshMiss(url, tier: .icon) else { return nil }
            return (idx, url, rec.apiKey)
        }.prefix(prefetchBudget).map { $0 }
        guard !jobs.isEmpty else { return false }

        var fetched: [Int: Data] = [:]
        var downloadedBytes = 0
        await withTaskGroup(of: (Int, PosterFetch)?.self) { group in
            var next = 0
            func schedule() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    guard let result = await PosterStore.shared.fetchStoring(
                        job.url, tier: .icon, apiKey: job.apiKey
                    ) else { return nil }
                    return (job.index, result)
                }
            }
            for _ in 0 ..< min(prefetchConcurrency, jobs.count) { schedule() }
            while let done = await group.next() {
                if let (index, result) = done {
                    fetched[index] = result.data
                    downloadedBytes += result.downloadedBytes
                }
                schedule()
            }
        }
        guard !fetched.isEmpty else { return false }

        let refreshed = fetched.map { index, bytes -> CSSearchableItem in
            let item = records[index].item
            item.attributeSet.thumbnailData = bytes
            return item
        }
        let index = CSSearchableIndex.default()
        // Delete first: re-indexing an existing id merges and keeps the old brand icon.
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withIdentifiers: refreshed.map(\.uniqueIdentifier)) { _ in cont.resume() }
        }
        for chunk in refreshed.chunked(into: indexBatch) {
            await withCheckedContinuation { cont in
                index.indexSearchableItems(chunk) { _ in cont.resume() }
            }
        }
        // The index has its own copy; don't hold every fetched poster in memory.
        for item in refreshed { item.attributeSet.thumbnailData = nil }
        log.debug(
            "attached \(refreshed.count, privacy: .public) posters, \(downloadedBytes / 1024, privacy: .public) kB fetched (\(jobs.count - refreshed.count, privacy: .public) missing)"
        )
        return jobs.count == prefetchBudget
    }

    /// Re-pushing an unchanged library means reading ~60 MB of inline thumbnails,
    /// so skip it when the fingerprint matches. Bytes are attached per batch.
    private static func syncIndex<Source>(
        _ source: [Source],
        domain: String,
        fallbackIcon: Data?,
        build: (Source) -> IndexedRecord?
    ) async -> [IndexedRecord] {
        let records = source.compactMap(build)
        // Keep live artwork out of the orphan sweep even when nothing is re-indexed.
        PosterStore.keepAlive(records.compactMap(\.posterURL), tier: .icon)
        let pending = records.filter { rec in
            guard let url = rec.posterURL else { return false }
            return !PosterStore.hasCached(url, tier: .icon)
        }

        let stamp = fingerprint(records)
        guard stamp != UserDefaults.standard.string(forKey: fingerprintKey(domain)) else {
            return pending
        }

        let index = CSSearchableIndex.default()
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in cont.resume() }
        }
        for chunk in records.chunked(into: indexBatch) {
            for rec in chunk { attachThumbnail(rec.item.attributeSet, poster: rec.posterURL, fallback: fallbackIcon) }
            await withCheckedContinuation { cont in
                index.indexSearchableItems(chunk.map(\.item)) { _ in cont.resume() }
            }
            for rec in chunk { rec.item.attributeSet.thumbnailData = nil }
        }
        UserDefaults.standard.set(stamp, forKey: fingerprintKey(domain))
        log.notice(
            "reindexed \(records.count, privacy: .public) rows in \(domain, privacy: .public)"
        )
        return pending
    }

    /// Covers everything a result shows, description included.
    private static func fingerprint(_ records: [IndexedRecord]) -> String {
        var hasher = SHA256()
        for rec in records {
            hasher.update(data: Data(rec.item.uniqueIdentifier.utf8))
            hasher.update(data: Data((rec.item.attributeSet.title ?? "").utf8))
            hasher.update(data: Data((rec.item.attributeSet.contentDescription ?? "").utf8))
            hasher.update(data: Data((rec.posterURL?.absoluteString ?? "").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprintKey(_ domain: String) -> String {
        "ArrBarr.spotlightFingerprint.\(domain)"
    }
}

@available(iOS 16.0, macOS 13.0, *)
enum SourceThumbnail {
    @MainActor private static var cache: [QueueItem.Source: Data] = [:]

    @MainActor static func data(for source: QueueItem.Source) -> Data? {
        if let d = cache[source] { return d }
        let view = ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(color(source))
            Image(source.brandIconName, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(30)
        }
        .frame(width: 128, height: 128)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        #if os(macOS)
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        #else
        guard let img = renderer.uiImage, let png = img.pngData() else { return nil }
        #endif
        cache[source] = png
        return png
    }

    private static func color(_ source: QueueItem.Source) -> Color {
        switch source {
        case .radarr:   return .orange
        case .sonarr:   return .blue
        case .lidarr:   return .green
        case .whisparr: return .pink
        }
    }
}
