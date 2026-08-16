import Foundation
import CryptoKit
import os

/// The cold half of the queue's two-speed model.
///
/// A queue row is two kinds of data glued together. The volatile half — status,
/// progress, size left, time left — genuinely changes between polls and is why
/// the app polls at all. The stable half — what the title is called, its year,
/// its artwork, its deep-link slug — changes when a user renames something or
/// refreshes metadata in the arr, which is to say almost never, and never while
/// a download is in flight.
///
/// Servarr ships both together: `includeSeries` / `includeMovie` /
/// `includeArtist` / `includeAlbum` embed the whole entity in every row, on
/// every poll, and the decoders throw away most of it. On a 77-row Lidarr queue
/// that was 1 MB of artist and album objects per poll for four fields.
///
/// This is where the stable half lives instead: resolved once, kept, and joined
/// back onto the volatile rows at unify time. It mirrors `PosterStore` — the
/// same split between what the OS may reclaim and what it may not, the same
/// touch-on-use retention so anything in active use never ages out.
///
/// Deliberately does **no networking**. It is a cache, not a client: the arr
/// client owns fetching its own misses, because it already holds the config and
/// the auth headers. That keeps this type free of `ServiceConfig`, free of a
/// store↔client cycle, and testable against a temp directory.
public actor TitleMetadataStore {
    public static let shared = TitleMetadataStore()

    /// Which kind of entity an id refers to. Part of the key because ids are
    /// only unique per kind — Lidarr album 15 and artist 15 are different rows.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case movie, series, album
    }

    /// Everything a queue row needs that the volatile poll doesn't carry.
    /// Deliberately narrow: fields are here because `unify` reads them, not
    /// because the wire offers them. `runtime` and `ratings` are on the wire and
    /// stay off this record — only the calendar path reads those.
    public struct Metadata: Codable, Sendable, Equatable {
        public var title: String
        /// Artist name for a Lidarr album. Unused by the movie/series kinds.
        public var secondary: String?
        public var year: Int?
        /// Deep-link slug: `titleSlug` for Sonarr/Radarr, `foreignAlbumId` for
        /// Lidarr. The one field with a visible failure mode when stale — it
        /// 404s in the arr's web UI rather than redirecting — which is why the
        /// library sweep re-seeds every entry it finds.
        public var slug: String?
        /// The *arr's own* resolved poster URL, not the `[ArrImage]` array it
        /// came from. `posterURL(baseURL:coverTypes:)` is pure over (images,
        /// baseURL) and the base URL is already baked into the key, so
        /// resolving on write halves the record and removes a decode step from
        /// every row.
        ///
        /// Deliberately NOT the media server's artwork, even when one is
        /// connected — see `mediaServerKeys`.
        public var posterURL: URL?
        public var posterRequiresAuth: Bool
        /// Provider ids (`"tmdb:157336"`) this title can be matched by on a
        /// media server, in `MediaServerExternalKey.rawKey` form.
        ///
        /// Stored so the media-server poster can be resolved at READ time. It
        /// used to be baked in on write, which quietly meant "whatever server
        /// was connected the first time this title was seen": entries cached
        /// before Plex was set up kept the arr's artwork for the store's whole
        /// 30-day retention, while detail views — which resolve live — showed
        /// the Plex one. Connecting, switching or disabling a server is now
        /// visible on the next poll, and there is no cache to clear for it.
        ///
        /// Optional so records written before this field decode unchanged.
        public var mediaServerKeys: [String]?

        public init(
            title: String,
            secondary: String? = nil,
            year: Int? = nil,
            slug: String? = nil,
            posterURL: URL? = nil,
            posterRequiresAuth: Bool = false,
            mediaServerKeys: [String]? = nil,
        ) {
            self.title = title
            self.secondary = secondary
            self.year = year
            self.slug = slug
            self.posterURL = posterURL
            self.posterRequiresAuth = posterRequiresAuth
            self.mediaServerKeys = mediaServerKeys
        }

        /// This record with the connected media server's artwork substituted,
        /// when the server holds the title. Unchanged when no server is
        /// connected, the index hasn't loaded, or the title isn't on it —
        /// which is what makes it safe to apply on every read.
        ///
        /// A media-server poster carries its token in a header rather than in
        /// the URL, so it never "requires auth" in the arr sense.
        public func applyingMediaServerArtwork() -> Metadata {
            guard let raw = mediaServerKeys, !raw.isEmpty else { return self }
            let keys = raw.compactMap(MediaServerExternalKey.init(rawKey:))
            guard let override = MediaServerIndex.shared.posterURL(for: keys) else { return self }
            var copy = self
            copy.posterURL = override
            copy.posterRequiresAuth = false
            return copy
        }
    }

    /// Identity of one cached entity.
    ///
    /// `instance` is a hash of the service's base URL, not the source alone: the
    /// same `source` repointed at a different server is a different library, and
    /// without it entry 42 from the old server would answer for entry 42 on the
    /// new one. Same reasoning as `PosterStore.key(for:)`.
    public struct Key: Hashable, Sendable {
        let source: QueueItem.Source
        let instance: String
        let kind: Kind
        let id: Int

        public init(source: QueueItem.Source, baseURL: String, kind: Kind, id: Int) {
            self.source = source
            self.instance = Self.instanceHash(baseURL)
            self.kind = kind
            self.id = id
        }

        static func instanceHash(_ baseURL: String) -> String {
            let digest = SHA256.hash(data: Data(baseURL.utf8))
            return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        /// Flat string form, so the on-disk map is a plain JSON dictionary
        /// rather than an array of key/value pairs.
        var storageKey: String { "\(source.rawValue)/\(instance)/\(kind.rawValue)/\(id)" }
    }

    private struct Entry: Codable {
        var metadata: Metadata
        /// Touch-on-use, the way `PosterStore` tracks live artwork. Retention
        /// reclaims by this, never by write time, so a download that sits in the
        /// queue for three weeks cannot lose its title on day eight.
        var lastSeen: Date
    }

    /// How long an *untouched* entry survives. Anything still being resolved
    /// keeps having its `lastSeen` refreshed, so this only reaps entities that
    /// have left the queue and the library both.
    private static let retention: TimeInterval = 30 * 24 * 3600

    /// Writes are coalesced: a queue refresh resolves dozens of rows at once and
    /// each would otherwise rewrite the whole map.
    private static let flushDelay: TimeInterval = 2

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private var flushTask: Task<Void, Never>?
    private let logger = Logger(category: "TitleMetadata")

    // MARK: - Reading

    /// Cached metadata for these keys, touching each hit so retention treats it
    /// as live. Missing keys are simply absent from the result — resolving them
    /// is the caller's job.
    public func metadata(for keys: [Key]) -> [Key: Metadata] {
        load()
        guard !keys.isEmpty else { return [:] }
        let now = Date()
        var result: [Key: Metadata] = [:]
        for key in keys {
            guard var entry = entries[key.storageKey] else { continue }
            result[key] = entry.metadata
            // Only rewrite the timestamp when it has actually aged, so a 5-second
            // foreground poll doesn't mark the map dirty on every tick.
            if now.timeIntervalSince(entry.lastSeen) > 3600 {
                entry.lastSeen = now
                entries[key.storageKey] = entry
                dirty = true
            }
        }
        scheduleFlushIfNeeded()
        return result
    }

    // MARK: - Writing

    public func store(_ values: [Key: Metadata]) {
        guard !values.isEmpty else { return }
        load()
        let now = Date()
        for (key, metadata) in values {
            if let existing = entries[key.storageKey], existing.metadata == metadata {
                // Unchanged value, but still evidence the entity exists — so
                // refresh `lastSeen` on the same "has it aged" rule `metadata`
                // uses. Skipping the touch entirely (the first version of this)
                // meant a title that is in the library but not currently queued
                // aged out of a store the library sweep would then re-add, which
                // is churn dressed up as retention.
                guard now.timeIntervalSince(existing.lastSeen) > 3600 else { continue }
                entries[key.storageKey] = Entry(metadata: metadata, lastSeen: now)
                dirty = true
                continue
            }
            entries[key.storageKey] = Entry(metadata: metadata, lastSeen: now)
            dirty = true
        }
        scheduleFlushIfNeeded()
    }

    /// Drop entries nothing has looked at for `retention`. Cheap enough to call
    /// at launch alongside `PosterStore.purge()`.
    public func purge() {
        load()
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let before = entries.count
        entries = entries.filter { $0.value.lastSeen >= cutoff }
        let reclaimed = before - entries.count
        guard reclaimed > 0 else { return }
        dirty = true
        // Launch-time housekeeping, same as `PosterStore.purge()` — `.debug`.
        logger.debug("purged \(reclaimed, privacy: .public) title metadata entries")
        scheduleFlushIfNeeded()
    }


    // MARK: - Persistence

    private func scheduleFlushIfNeeded() {
        guard dirty, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushDelay * 1_000_000_000))
            await self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard dirty, let url = Self.storeURL() else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            dirty = false
        } catch {
            logger.error("title metadata flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.storeURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    /// Application Support, never Caches.
    ///
    /// The same rule `PosterTier.isDisposable` encodes: everything under an
    /// app's Caches directory is reclaimable by macOS `cache_delete`, and
    /// reclaiming it kills the app to do so. A store whose whole purpose is to
    /// avoid re-downloading metadata must not live somewhere the OS empties.
    ///
    /// One file, not one per entity: these records are a couple of hundred bytes
    /// each, and thousands of tiny files would cost more in directory churn than
    /// the data is worth. That is the opposite of `PosterStore`'s choice, and
    /// deliberately so — 15 kB images and 200-byte records want different shapes.
    nonisolated static func storeURL() -> URL? {
        let fm = FileManager.default
        guard var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        dir.appendPathComponent(Bundle.main.bundleIdentifier ?? "pl.incred.ArrBarr", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Re-downloadable, so keep it out of backups and iCloud — same call
        // `PosterStore` makes for the icon tier.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir.appendingPathComponent("title-metadata.json")
    }
}
