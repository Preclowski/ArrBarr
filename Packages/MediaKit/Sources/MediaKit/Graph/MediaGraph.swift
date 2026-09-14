import Foundation

/// How fresh an answer has to be.
public enum FreshnessPolicy: Sendable {
    /// Cache if it is within the field's own TTL.
    case `default`
    /// Cache at any age — for a first paint that will be refreshed anyway.
    case cacheFirst
    /// Skip the cache entirely (a pull-to-refresh, a write that just landed).
    case reload
}

public struct MediaQuery: Sendable {
    public let identity: MediaIdentity
    public let fields: MediaFieldSet
    public let policy: FreshnessPolicy

    public init(_ identity: MediaIdentity, fields: MediaFieldSet,
                policy: FreshnessPolicy = .default) {
        self.identity = identity
        self.fields = fields
        self.policy = policy
    }
}

/// The query layer: ask for fields, get a snapshot.
///
/// This is the only type that knows which provider answers which field. It
/// plans (who can answer what, cheapest first), runs the chosen providers
/// concurrently, and merges their fragments in per-field precedence order. One
/// dead source costs one field; nothing else on screen notices.
public actor MediaGraph {
    private let providers: [any MediaProvider]
    /// Id cross-walks, tried when a provider needs a namespace the caller
    /// doesn't have (Sonarr wants TVDB; the app speaks TMDB).
    private let resolvers: [any IdentityResolving]
    private let cache: FragmentCache
    private let telemetry: MediaTelemetry?
    /// Per-provider "is this still the same server" stamp, so a re-pointed
    /// service can't be served another server's answers.
    private let fingerprints: [ProviderID: String]
    /// Catalog pages, kept briefly: paging back and forth through a browse
    /// must not re-ask, but "what is trending" is a different answer tomorrow.
    private struct CatalogKey: Hashable {
        let query: MediaCatalogQuery
        let enrich: MediaFieldSet
    }
    private var catalogCache: [CatalogKey: (page: MediaCatalogPage, storedAt: Date)] = [:]
    private let catalogTTL: TimeInterval = 60 * 10
    private let catalogCacheLimit = 60

    public init(providers: [any MediaProvider],
                resolvers: [any IdentityResolving] = [],
                cache: FragmentCache = FragmentCache(),
                telemetry: MediaTelemetry? = nil,
                fingerprints: [ProviderID: String] = [:]) {
        self.providers = providers
        self.resolvers = resolvers
        self.cache = cache
        self.telemetry = telemetry
        self.fingerprints = fingerprints
    }

    public func fetch(_ query: MediaQuery) async -> MediaSnapshot {
        // 0. Make the identity answerable. A provider keyed on an id space
        //    the caller doesn't carry (Sonarr on TVDB) is not "incapable" —
        //    it is one cross-walk away, and resolving is cheap and cached.
        let identity = await resolvingIDs(for: query)
        let query = MediaQuery(identity, fields: query.fields, policy: query.policy)
        var snapshot = MediaSnapshot(identity: identity)

        // 1. Plan. A provider is asked only for the fields it claims, is
        //    configured for, and is not known to be down for. Cheapest first,
        //    so a LAN box answers before a rate-limited API when both can.
        let plan = providers
            .map { (provider: $0, fields: $0.answerable(query.fields)) }
            .filter {
                !$0.fields.isEmpty && $0.provider.health != .down
                    && $0.provider.canAnswer(query.identity)
            }
            .sorted { $0.provider.cost < $1.provider.cost }

        // Everything the plan left out is worth a line in the debug trace:
        // "why did nobody answer .ratings" is the question this layer will be
        // asked most often.
        for provider in providers
        where provider.answerable(query.fields).isEmpty || !provider.canAnswer(query.identity) {
            let note: String
            if !provider.isConfigured { note = "not configured" }
            else if provider.answerable(query.fields).isEmpty { note = "cannot supply" }
            else { note = "no usable id" }
            await telemetry?.record(.init(kind: .skipped, provider: provider.id,
                                          identity: query.identity.cacheKey,
                                          fields: query.fields, note: note))
        }

        guard !plan.isEmpty else {
            snapshot.fail(query.fields, with: .unsupported(query.fields.fields.first ?? .title))
            return snapshot
        }

        // 2. Fetch, concurrently, each provider isolated from the others'
        //    failures.
        var results: [(provider: any MediaProvider, fragment: MediaFragment)] = []
        var failures: [(MediaFieldSet, MediaError)] = []

        await withTaskGroup(of: (ProviderID, Result<MediaFragment, Error>, MediaFieldSet).self) { group in
            for (provider, fields) in plan {
                group.addTask { [weak self] in
                    guard let self else { return (provider.id, .failure(MediaError.cancelled), fields) }
                    do {
                        let fragment = try await self.fragment(from: provider, query: query, fields: fields)
                        return (provider.id, .success(fragment), fields)
                    } catch {
                        return (provider.id, .failure(error), fields)
                    }
                }
            }
            for await (providerID, result, fields) in group {
                guard let provider = plan.first(where: { $0.provider.id == providerID })?.provider else { continue }
                switch result {
                case .success(let fragment): results.append((provider, fragment))
                case .failure(let error):
                    failures.append((fields, (error as? MediaError) ?? .unreachable(providerID)))
                }
            }
        }

        // 3. Merge, one field at a time, best source first. `apply` keeps the
        //    first answer for single-valued fields, so ordering here IS the
        //    precedence table.
        for field in query.fields.fields {
            let ranked = results
                .filter { $0.fragment.populated.contains(field.set) }
                .sorted { lhs, rhs in
                    let left = lhs.provider.precedence(for: field)
                    let right = rhs.provider.precedence(for: field)
                    return left == right ? lhs.provider.cost < rhs.provider.cost : left > right
                }
            for (provider, fragment) in ranked {
                let before = snapshot.provenance[field]?.provider
                snapshot.apply(fragment.slice(field),
                               from: Provenance(provider: provider.id,
                                                fetchedAt: Date(),
                                                fromCache: false))
                // Record who actually won the field, not merely who replied —
                // that is the question the debug report exists to answer.
                // Ratings and availability MERGE, so every contributor served
                // it; the single-valued fields have exactly one winner.
                let merges = field == .ratings || field == .availability
                if merges || (before == nil && snapshot.provenance[field]?.provider == provider.id) {
                    await telemetry?.record(.init(kind: .served, provider: provider.id,
                                                  identity: query.identity.cacheKey,
                                                  fields: field.set))
                }
            }
        }
        // Ids learned by any provider belong to the snapshot even when that
        // provider answered no requested field.
        for (_, fragment) in results {
            snapshot.apply(fragment.identityOnly,
                           from: Provenance(provider: .cache, fetchedAt: Date(), fromCache: true))
        }
        for (fields, error) in failures {
            snapshot.fail(fields, with: error)
        }
        return snapshot
    }

    /// Convenience for the common "one title, the card fields" call.
    public func fetch(_ identity: MediaIdentity,
                      fields: MediaFieldSet = .card,
                      policy: FreshnessPolicy = .default) async -> MediaSnapshot {
        await fetch(MediaQuery(identity, fields: fields, policy: policy))
    }

    // MARK: - Identity

    /// Ask the resolvers for every id namespace some capable provider needs
    /// and this identity lacks. Failures are silent: the provider is then
    /// skipped with "no usable id" in the trace, which is exactly what
    /// happened.
    private func resolvingIDs(for query: MediaQuery) async -> MediaIdentity {
        var identity = query.identity
        guard !resolvers.isEmpty else { return identity }

        let needed = providers
            .filter { $0.isConfigured && !$0.answerable(query.fields).isEmpty }
            .filter { !$0.canAnswer(identity) }
            .flatMap(\.requiredIDs)
        for namespace in Set(needed) {
            for resolver in resolvers {
                if let id = try? await resolver.resolve(identity, into: namespace) {
                    identity.insert(id)
                    break
                }
            }
        }
        return identity
    }

    // MARK: - One provider

    private func fragment(from provider: any MediaProvider, query: MediaQuery,
                          fields: MediaFieldSet) async throws -> MediaFragment {
        let fingerprint = fingerprints[provider.id] ?? "-"
        if query.policy != .reload,
           let hit = await cache.cached(provider.id, query.identity, fields: fields,
                                        fingerprint: fingerprint,
                                        allowStale: query.policy == .cacheFirst) {
            await telemetry?.record(.init(kind: .cacheHit, provider: provider.id,
                                          identity: query.identity.cacheKey, fields: fields))
            return hit
        }
        await telemetry?.record(.init(kind: .cacheMiss, provider: provider.id,
                                      identity: query.identity.cacheKey, fields: fields))
        await telemetry?.record(.init(kind: .request, provider: provider.id,
                                      identity: query.identity.cacheKey, fields: fields))

        let identity = query.identity
        let fragment = try await cache.coalesced(provider.id, identity, fields: fields) {
            try await provider.fetch(identity, fields: fields)
        }
        await cache.store(fragment, from: provider.id, for: identity, fingerprint: fingerprint)
        return fragment
    }

    // MARK: - Catalogs

    /// "Which titles?" — routed to the cheapest provider that can serve this
    /// intent, and optionally topped up with fields the list endpoint didn't
    /// carry.
    ///
    /// Unlike `fetch`, this one throws: a catalog has exactly one source per
    /// query, so there is no partial answer to hand back — either the browse
    /// loaded or the screen has nothing to show.
    public func catalog(_ query: MediaCatalogQuery,
                        enrich: MediaFieldSet = [],
                        policy: FreshnessPolicy = .default) async throws -> MediaCatalogPage {
        let candidates = providers
            .compactMap { $0 as? any MediaCatalogProviding }
            .filter { $0.canServe(query) }
            .sorted { $0.cost < $1.cost }
        guard let provider = candidates.first else {
            let configured = providers.filter(\.isConfigured).map(\.id.rawValue)
            throw MediaError.noSource(
                "\(query.intent) (\(query.kind?.rawValue ?? "any")) — configured: "
                + (configured.isEmpty ? "none" : configured.joined(separator: ", ")))
        }

        // Keyed WITHOUT the presence filter: the source never sees it, so
        // "sci-fi I own" and "sci-fi I don't" are the same request to TMDB
        // and differ only in what the graph keeps afterwards. Keying on the
        // whole query made switching that control re-fetch identical pages.
        let key = CatalogKey(query: query.ignoringPresence, enrich: enrich)
        if policy != .reload, let hit = catalogCache[key],
           Date().timeIntervalSince(hit.storedAt) < catalogTTL {
            await telemetry?.record(.init(kind: .cacheHit, provider: provider.id,
                                          identity: "catalog", fields: [.title]))
            var cached = hit.page
            cached.items = filtered(cached.items, by: query.filter.presence)
            return cached
        }
        await telemetry?.record(.init(kind: .cacheMiss, provider: provider.id,
                                      identity: "catalog", fields: [.title]))

        var page = try await provider.catalog(query)
        // Who answered a browse is as worth recording as who answered a
        // field: without it the debug report's Fields section reads
        // "unanswered" for every list the app draws.
        if let fields = page.items.first?.fields, !page.items.isEmpty {
            await telemetry?.record(.init(kind: .served, provider: provider.id,
                                          identity: "catalog", fields: fields))
        }
        if !enrich.isEmpty {
            page.items = await enriched(page.items, fields: enrich)
        }
        catalogCache[key] = (page, Date())
        trimCatalogCache()
        // The one filter no metadata service can apply: whether the user has
        // it. Applied here, after the local providers have spoken.
        page.items = filtered(page.items, by: query.filter.presence)
        return page
    }

    /// Top up a page from providers that answer from an index — the media
    /// server's sweep, the app's own library. Never from one that makes a
    /// request per title: a 20-card grid became 20 concurrent Radarr lookups,
    /// which timed out and logged twenty failures per browse.
    private func enriched(_ items: [MediaSnapshot], fields: MediaFieldSet) async -> [MediaSnapshot] {
        // Both conditions, and for different reasons: `answersFromIndex`
        // rules out a request per title, `cost` rules out spending somebody's
        // quota twenty times for one screen.
        let local = providers.filter {
            $0.answersFromIndex && $0.cost <= .local
                && $0.isConfigured && !$0.answerable(fields).isEmpty
        }
        guard !local.isEmpty else { return items }

        return await withTaskGroup(of: (Int, MediaSnapshot).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    var snapshot = item
                    for provider in local where provider.canAnswer(item.identity) {
                        guard let fragment = try? await provider.fetch(item.identity, fields: fields)
                        else { continue }
                        snapshot.apply(fragment, from: Provenance(provider: provider.id,
                                                                  fetchedAt: Date(),
                                                                  fromCache: false))
                    }
                    return (index, snapshot)
                }
            }
            var result = items
            for await (index, snapshot) in group { result[index] = snapshot }
            return result
        }
    }

    private func filtered(_ items: [MediaSnapshot],
                          by presence: MediaFilter.LibraryPresence) -> [MediaSnapshot] {
        switch presence {
        case .any: items
        case .owned: items.filter { $0.availability?.owned == true }
        case .notOwned: items.filter { $0.availability?.owned != true }
        case .watched: items.filter { $0.availability?.watched == true }
        case .unwatched: items.filter { $0.availability?.watched != true }
        }
    }

    private func trimCatalogCache() {
        guard catalogCache.count > catalogCacheLimit else { return }
        let oldest = catalogCache.sorted { $0.value.storedAt < $1.value.storedAt }
            .prefix(catalogCache.count - catalogCacheLimit)
        for (key, _) in oldest { catalogCache[key] = nil }
    }

    // MARK: - Maintenance

    /// Call after a write the layer can't see (marked watched, added to
    /// Radarr): the next read re-asks instead of serving the old answer.
    public func invalidate(_ identity: MediaIdentity) async {
        await cache.invalidate(identity)
    }

    public func invalidate(provider: ProviderID) async {
        await cache.invalidate(provider: provider)
    }
}

extension MediaFragment {
    /// This fragment with only one field kept — how the graph applies answers
    /// in per-field precedence order without letting a provider that won
    /// `.ratings` also win `.title`.
    func slice(_ field: MediaField) -> MediaFragment {
        var sliced = MediaFragment(identity: identity)
        switch field {
        case .title: sliced.title = title
        case .artwork: sliced.artwork = artwork
        case .ratings: sliced.ratings = ratings
        case .availability: sliced.availability = availability
        case .credits: sliced.credits = credits
        case .streaming: sliced.streaming = streaming
        }
        return sliced
    }

    /// The ids only — no facts. Lets a snapshot learn what a provider knew
    /// about identity even if its facts lost every precedence contest.
    var identityOnly: MediaFragment { MediaFragment(identity: identity) }
}
