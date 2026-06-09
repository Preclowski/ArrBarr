import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import SwiftUI

// MARK: - CoreSpotlight library indexing
//
// Indexes the Radarr/Sonarr library into Spotlight so the user can search
// "american pie" in system Spotlight and tap a result to open it in ArrBarr.
//
// Scale: CoreSpotlight comfortably handles thousands of items (Mail/Notes
// index far more). The cost to avoid is downloading posters — so thumbnails
// are attached ONLY when the poster is already in our ImageCache (zero extra
// network). Indexing is batched and a full reindex deletes-by-domain first so
// removed library items disappear.
public enum SpotlightIndexer {
    private static let domainRadarr = "arrbarr.radarr"
    private static let domainSonarr = "arrbarr.sonarr"

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

    /// Re-index the configured libraries. Fire-and-forget; runs detached so it
    /// never blocks launch. Throttled to once / 2 min so launch + foreground
    /// triggers don't double-fetch the whole library. Re-running picks up
    /// posters that got cached since (cached-only thumbnails).
    @MainActor
    public static func reindex(configStore: ConfigStore = .shared) {
        if let last = lastReindex, Date().timeIntervalSince(last) < 120 { return }
        lastReindex = Date()
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
        Task.detached(priority: .utility) {
            await reindexRadarr(radarr, fallbackIcon: radarrIcon)
            await reindexSonarr(sonarr, fallbackIcon: sonarrIcon)
        }
    }

    /// macOS opens Spotlight hits in the arr's web UI (the menu-bar app has no
    /// window to host a detail view). Fetches the title slug — the synthetic
    /// item from the identifier doesn't carry it.

    /// Remove ArrBarr's own Spotlight entries (the Radarr/Sonarr library items
    /// we indexed) without re-adding them. Surgical: deletes only our two
    /// domains, so nothing else in the system index is touched. Resets the
    /// reindex throttle so a later `reindex()` can repopulate on demand.
    /// This is the only way to clear these — CoreSpotlight is per-app, so an
    /// external tool can't reach ArrBarr's index.
    @MainActor
    public static func clearIndex() async {
        let index = CSSearchableIndex.default()
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withDomainIdentifiers: [domainRadarr, domainSonarr]) { _ in
                cont.resume()
            }
        }
        lastReindex = nil
    }

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

    private static func reindexRadarr(_ config: ServiceConfig, fallbackIcon: Data?) async {
        guard config.isConfigured else { return }
        guard let movies = try? await RadarrClient(config: config).fetchAllMovies() else { return }
        let items = movies.compactMap { rec -> CSSearchableItem? in
            guard let id = rec.id, let title = rec.title else { return nil }
            let attr = CSSearchableItemAttributeSet(contentType: .movie)
            attr.title = rec.year.map { "\(title) (\($0))" } ?? title
            attr.contentDescription = rec.overview
            if let g = rec.genres, !g.isEmpty { attr.keywords = g }
            attachThumbnail(attr, images: rec.images, baseURL: config.baseURL, fallback: fallbackIcon)
            return CSSearchableItem(
                uniqueIdentifier: identifier(source: .radarr, id: id),
                domainIdentifier: domainRadarr,
                attributeSet: attr
            )
        }
        await pushFullIndex(items, domain: domainRadarr)
    }

    private static func reindexSonarr(_ config: ServiceConfig, fallbackIcon: Data?) async {
        guard config.isConfigured else { return }
        guard let series = try? await SonarrClient(config: config).fetchAllSeries() else { return }
        let items = series.compactMap { rec -> CSSearchableItem? in
            guard let id = rec.id, let title = rec.title else { return nil }
            let attr = CSSearchableItemAttributeSet(contentType: .audiovisualContent)
            attr.title = rec.year.map { "\(title) (\($0))" } ?? title
            attr.contentDescription = rec.overview
            attachThumbnail(attr, images: rec.images, baseURL: config.baseURL, fallback: fallbackIcon)
            return CSSearchableItem(
                uniqueIdentifier: identifier(source: .sonarr, id: id),
                domainIdentifier: domainSonarr,
                attributeSet: attr
            )
        }
        await pushFullIndex(items, domain: domainSonarr)
    }

    /// Cached poster if we already have it (no network); otherwise the
    /// per-source fallback icon so the result is never blank.
    private static func attachThumbnail(_ attr: CSSearchableItemAttributeSet, images: [ArrImage]?, baseURL: String, fallback: Data?) {
        if let url = (images ?? []).posterURL(baseURL: baseURL).0,
           let file = ImageCache.posterCacheFileURL(for: url) {
            attr.thumbnailURL = file
        } else if let fallback {
            attr.thumbnailData = fallback
        }
    }

    /// Delete the domain (handles removed items) then add the current set in
    /// batches so a 5000-item library doesn't spike memory.
    private static func pushFullIndex(_ items: [CSSearchableItem], domain: String) async {
        let index = CSSearchableIndex.default()
        await withCheckedContinuation { cont in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in cont.resume() }
        }
        for chunk in items.chunked(into: 500) {
            await withCheckedContinuation { cont in
                index.indexSearchableItems(chunk) { _ in cont.resume() }
            }
        }
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
