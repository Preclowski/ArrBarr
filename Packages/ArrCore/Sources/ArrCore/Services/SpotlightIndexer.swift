import Foundation
import CoreSpotlight
import CryptoKit
import UniformTypeIdentifiers
import SwiftUI
import os

// MARK: - CoreSpotlight library indexing
//
// Indexes the Radarr/Sonarr library into Spotlight so the user can search
// "american pie" in system Spotlight and tap a result to open it in ArrBarr.
//
// Scale: CoreSpotlight comfortably handles thousands of items (Mail/Notes
// index far more). Indexing is batched and a full reindex deletes-by-domain
// first so removed library items disappear.
//
// Artwork: an indexing pass never blocks on the network — a row gets whatever
// thumbnail is already on disk, else the brand fallback icon. The rows that
// fell back are then filled in by `fillMissingThumbnails` and re-indexed (see
// `PosterStore` for why that round trip is the only option).
public enum SpotlightIndexer {
    private static let domainRadarr = "arrbarr.radarr"
    private static let domainSonarr = "arrbarr.sonarr"

    /// Posters fetched per indexing pass (~20 kB each). The remainder is picked
    /// up by the next one, so even a huge library fills in over a couple of
    /// launches instead of hammering the arr (and TMDB, which serves `remoteUrl`
    /// artwork) in one burst.
    private static let prefetchBudget = 1000
    private static let prefetchConcurrency = 4
    private static let indexBatch = 500

    /// One library row: its Spotlight item plus what filling the thumbnail in
    /// later needs. `apiKey` is nil when the poster is a public CDN URL.
    private struct IndexedRecord {
        let item: CSSearchableItem
        let posterURL: URL?
        let apiKey: String?
    }

    static func identifier(source: QueueItem.Source, id: Int) -> String {
        "arrbarr.\(source.rawValue).\(id)"
    }

    /// Parse a Spotlight item identifier back to (source, arr entity id).
    public static func parse(_ identifier: String) -> (source: QueueItem.Source, id: Int)? {
        let parts = identifier.split(separator: ".")
        guard parts.count == 3, parts[0] == "arrbarr",
              let src = QueueItem.Source(rawValue: String(parts[1])),
              let id = Int(parts[2]) else { return nil }
        return (src, id)
    }

    @MainActor private static var lastReindex: Date?
    /// A pass that spends its poster budget outlives the 2-minute throttle, so
    /// the throttle alone can't stop two passes overlapping — which would fetch
    /// the same posters twice (neither has written its files yet).
    @MainActor private static var isReindexing = false
    /// The in-flight pass, so it can be stopped. A fill round sleeps 30s between
    /// attempts and keeps going while there is artwork left, so without a handle
    /// there is nothing anyone can do about a pass that has outlived its
    /// usefulness — and it holds the whole record array the entire time.
    @MainActor private static var indexingTask: Task<Void, Never>?

    /// Re-index the configured libraries. Fire-and-forget; runs detached so it
    /// never blocks launch. Throttled to once / 2 min so launch + foreground
    /// triggers don't double-fetch the whole library. Each run also fetches a
    /// slice of the still-missing posters (see `prefetchBudget`), so artwork
    /// converges across launches.
    @MainActor
    public static func reindex(configStore: ConfigStore = .shared) {
        if isReindexing { return }
        if let last = lastReindex, Date().timeIntervalSince(last) < 120 { return }
        lastReindex = Date()
        isReindexing = true
        let radarr = configStore.radarr
        let sonarr = configStore.sonarr
        // Per-source fallback icons (movie→Radarr, series→Sonarr) so every
        // result has a recognisable thumbnail even without a cached poster.
        // Rendered on the main actor (ImageRenderer requirement), cached.
        var radarrIcon: Data?
        var sonarrIcon: Data?
        if #available(iOS 16.0, macOS 13.0, *) {
            radarrIcon = SourceThumbnail.data(for: .radarr)
            sonarrIcon = SourceThumbnail.data(for: .sonarr)
        }
        indexingTask = Task.detached(priority: .utility) {
            // EVERY exit path has to put the flag back down — a pass that ends
            // early or gets cancelled would otherwise leave `isReindexing` true
            // and disable re-indexing for the rest of the process lifetime. An
            // unstructured `Task` doesn't inherit cancellation, so this still
            // runs when the pass above it was cancelled.
            defer { Task { @MainActor in isReindexing = false } }
            // Both libraries are indexed first, then artwork is filled in for
            // whatever fell back — otherwise Radarr's prefetch would hold up
            // Sonarr's index for the length of a download pass.
            var records = await reindexRadarr(radarr, fallbackIcon: radarrIcon)
            records += await reindexSonarr(sonarr, fallbackIcon: sonarrIcon)
            // Keep going as long as a round spends its whole budget — a fresh
            // library of several thousand posters would otherwise need one app
            // activation per `prefetchBudget`, which for a menu-bar app that
            // just sits there could be days. `records` is already in hand, so a
            // follow-up round costs no library refetch. Ends by itself: rounds
            // stop when nothing is missing, and failures leave `.miss` markers
            // that take the URL out of the work list.
            while await fillMissingThumbnails(records) {
                // Cancellation makes the sleep throw straight away, and `try?`
                // would swallow it into another full round — so leave here
                // rather than spinning the fill loop with no delay.
                do { try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC) }
                catch { return }
            }
        }
    }

    /// Stop the in-flight pass. The flag it holds is cleared by the task's own
    /// `defer`, so a later `reindex()` is free to start over.
    @MainActor
    public static func cancelIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
    }

    /// Remove ArrBarr's own Spotlight entries (the Radarr/Sonarr library items
    /// we indexed) without re-adding them. Surgical: deletes only our two
    /// domains, so nothing else in the system index is touched. Resets the
    /// reindex throttle so a later `reindex()` can repopulate on demand.
    /// This is the only way to clear these — CoreSpotlight is per-app, so an
    /// external tool can't reach ArrBarr's index.
    @MainActor
    public static func clearIndex() async {
        // Stop any pass first, or a fill round already in flight re-indexes its
        // rows and re-downloads their posters seconds after the user asked for
        // all of it to go away.
        cancelIndexing()
        let index = CSSearchableIndex.default()
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withDomainIdentifiers: [domainRadarr, domainSonarr]) { _ in
                cont.resume()
            }
        }
        // Drop the prefetched artwork too, so "clear" really means clear (and a
        // later reindex re-fetches rather than resurrecting stale posters).
        await PosterStore.shared.clear(tier: .icon)
        // MUST forget the fingerprints as well: they say "the index already
        // holds this library", which stops being true the moment we delete it.
        // Leave them and the next pass would skip re-indexing entirely.
        for domain in [domainRadarr, domainSonarr] {
            UserDefaults.standard.removeObject(forKey: fingerprintKey(domain))
        }
        lastReindex = nil
        // Destructive and user-triggered — leave a trace, otherwise "my posters
        // vanished" is impossible to tell apart from a failed prefetch.
        Logger(category: "Spotlight").notice("cleared Spotlight index + prefetched posters")
    }

    /// The item's page in the arr's web UI — the opt-out route for a Spotlight
    /// hit on macOS (`spotlightOpensInApp = false`). Fetches the title slug,
    /// which the identifier alone doesn't carry.
    @MainActor
    public static func browserURL(forIdentifier id: String, configStore: ConfigStore = .shared) async -> URL? {
        guard let ref = parse(id) else { return nil }
        let cfg = configStore.serviceConfig(for: ref.source)
        guard cfg.isConfigured else { return nil }
        let slug: String?
        switch ref.source {
        case .radarr:   slug = try? await RadarrClient(config: cfg).fetchMovieDetails(id: ref.id).titleSlug
        case .whisparr: slug = try? await WhisparrClient(config: cfg).fetchMovieDetails(id: ref.id).titleSlug
        case .sonarr:   slug = try? await SonarrClient(config: cfg).fetchSeriesDetails(id: ref.id).titleSlug
        case .lidarr:   slug = nil
        }
        guard let slug, !slug.isEmpty else { return nil }
        let path = ref.source == .sonarr ? "/series/\(slug)" : "/movie/\(slug)"
        return URL(string: cfg.baseURL)?.appendingPathComponent(path)
    }

    private static func reindexRadarr(_ config: ServiceConfig, fallbackIcon: Data?) async -> [IndexedRecord] {
        guard config.isConfigured else { return [] }
        guard let movies = try? await RadarrClient(config: config).fetchAllMovies() else { return [] }
        return await syncIndex(movies, domain: domainRadarr, fallbackIcon: fallbackIcon) { rec -> IndexedRecord? in
            guard let id = rec.id, let title = rec.title else { return nil }
            let attr = CSSearchableItemAttributeSet(contentType: .movie)
            attr.title = rec.year.map { "\(title) (\($0))" } ?? title
            attr.contentDescription = rec.overview
            if let g = rec.genres, !g.isEmpty { attr.keywords = g }
            let (poster, needsAuth) = (rec.images ?? []).posterURL(baseURL: config.baseURL)
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
        guard let series = try? await SonarrClient(config: config).fetchAllSeries() else { return [] }
        return await syncIndex(series, domain: domainSonarr, fallbackIcon: fallbackIcon) { rec -> IndexedRecord? in
            guard let id = rec.id, let title = rec.title else { return nil }
            let attr = CSSearchableItemAttributeSet(contentType: .audiovisualContent)
            attr.title = rec.year.map { "\(title) (\($0))" } ?? title
            attr.contentDescription = rec.overview
            let (poster, needsAuth) = (rec.images ?? []).posterURL(baseURL: config.baseURL)
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

    /// Best thumbnail available *without touching the network*: our prefetched
    /// poster, else the per-source brand icon so the result is never blank.
    /// Rows that land on the fallback are `fillMissingThumbnails`' work list.
    ///
    /// Always inline bytes, never `thumbnailURL`: a URL pointing into our
    /// sandbox container produced no artwork in Spotlight at all, while
    /// `thumbnailData` — what the brand icon has always used — renders. That
    /// is also why the index is fed from the icon tier and nothing larger: a
    /// card is ~160 kB, and 3000 of those inlined is not a cache, it is a
    /// second copy of the library inside the system index.
    private static func attachThumbnail(_ attr: CSSearchableItemAttributeSet, poster: URL?, fallback: Data?) {
        if let poster, let bytes = PosterStore.storedData(for: poster, tier: .icon) {
            attr.thumbnailData = bytes
        } else if let fallback {
            attr.thumbnailData = fallback
        }
    }

    /// Fetch posters for the rows that fell back to the brand icon and re-index
    /// just those rows. Returns true when the round spent its whole budget,
    /// i.e. there is probably more to fetch.
    @discardableResult
    private static func fillMissingThumbnails(_ records: [IndexedRecord]) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }

        // Index into `records` + the poster to fetch, capped at the per-run
        // budget. Already-stored and recently-failed posters are skipped.
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
        // Delete before re-indexing. Indexing an existing `uniqueIdentifier`
        // merges into what is already stored, and a merge kept showing the
        // brand icon we attached on the first pass. Deleting first makes the
        // poster the only thumbnail the row has ever had.
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withIdentifiers: refreshed.map(\.uniqueIdentifier)) { _ in cont.resume() }
        }
        for chunk in refreshed.chunked(into: indexBatch) {
            await withCheckedContinuation { cont in
                index.indexSearchableItems(chunk) { _ in cont.resume() }
            }
        }
        // The index has its own copy now — drop ours so a long fill doesn't
        // accumulate every poster it has ever fetched in memory.
        for item in refreshed { item.attributeSet.thumbnailData = nil }
        Logger(category: "Spotlight").notice(
            "attached \(refreshed.count, privacy: .public) posters, \(downloadedBytes / 1024, privacy: .public) kB fetched (\(jobs.count - refreshed.count, privacy: .public) missing)"
        )
        return jobs.count == prefetchBudget
    }

    /// Re-index `domain` if the library changed since the last pass, and either
    /// way return the rows still missing artwork — the fill pass's work list.
    ///
    /// The fingerprint matters because a pass is not cheap any more: posters go
    /// into the index as bytes, so re-pushing an unchanged 3000-title library
    /// means reading ~60 MB off disk and handing it to CoreSpotlight — on every
    /// activation of a menu-bar app. Rows are built without artwork; the bytes
    /// are attached per batch and dropped again right after the batch is
    /// indexed, so peak memory is one batch rather than the whole library.
    private static func syncIndex<Source>(
        _ source: [Source],
        domain: String,
        fallbackIcon: Data?,
        build: (Source) -> IndexedRecord?
    ) async -> [IndexedRecord] {
        let records = source.compactMap(build)
        // Anything the library still points at counts as live artwork, whether
        // or not we re-index this time — otherwise a stable library would let
        // its own thumbnails age into the orphan sweep.
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
        // Rare by design — its absence on a later pass is the fingerprint
        // doing its job.
        Logger(category: "Spotlight").notice(
            "reindexed \(records.count, privacy: .public) rows in \(domain, privacy: .public)"
        )
        return pending
    }

    /// Identity of everything a Spotlight result actually shows — id, title,
    /// description and artwork. Anything that would change a result changes the
    /// hash; a poll that returns the same library doesn't. Deliberately covers
    /// the description too: it is rendered in the result, so leaving it out
    /// would let an updated overview sit stale forever.
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

/// Generates (once, cached) a branded fallback thumbnail per arr — brand
/// colour rounded square + a glyph (film for movies, tv for series) — so
/// Spotlight results without a cached poster still show a recognisable icon.
@available(iOS 16.0, macOS 13.0, *)
enum SourceThumbnail {
    @MainActor private static var cache: [QueueItem.Source: Data] = [:]

    @MainActor static func data(for source: QueueItem.Source) -> Data? {
        if let d = cache[source] { return d }
        let view = ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(color(source))
            // The provided brand SVG (ServiceIcons.xcassets), tinted white —
            // same asset ServiceIcon uses — not an SF Symbol.
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
