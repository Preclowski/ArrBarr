import Foundation
import MediaKit
import os

/// Indexer names for manual-search results.
///
/// A release only carries the *arr's own indexer id and label, and that label
/// is whatever the sync that created it decided to call the indexer —
/// "NZBgeek (Prowlarr)", "Prowlarr - NZBgeek", anything. Prowlarr holds the
/// name the user actually chose, so when it's configured we resolve through it:
/// the *arr's indexer definition carries the Prowlarr id inside its `baseUrl`,
/// and Prowlarr turns that id into a name.
///
/// Without Prowlarr (or when an indexer wasn't synced from it) the *arr's own
/// label stands, minus a trailing "(Prowlarr)" — the one suffix we can strip
/// without guessing.
final class IndexerNames {
    static let shared = IndexerNames()

    /// Resolved names per arr, keyed by the id a release reports. Names change
    /// only when the servers are reconfigured, so one fetch per launch is
    /// plenty; a failure caches nothing and is retried on the next search.
    private var cache: [QueueItem.Source: [Int: String]] = [:]
    private var inFlight: [QueueItem.Source: Task<[Int: String], Never>] = [:]

    private init() {}

    /// Wipe on config changes — a new Prowlarr (or a renamed indexer) must not
    /// be answered from a snapshot of the old one.
    func invalidate() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    func names(for source: QueueItem.Source, configStore: ConfigStore) async -> [Int: String] {
        if let cached = cache[source] { return cached }
        if let running = inFlight[source] { return await running.value }
        let task = Task { @MainActor in await resolve(source: source, configStore: configStore) }
        inFlight[source] = task
        let names = await task.value
        inFlight[source] = nil
        if !names.isEmpty { cache[source] = names }
        return names
    }

    private func resolve(source: QueueItem.Source, configStore: ConfigStore) async -> [Int: String] {
        let client = configStore.arrClient(for: source)
        guard let definitions = try? await client.fetchIndexers() else { return [:] }
        let prowlarrNames = await prowlarrNames(configStore: configStore)
        var out: [Int: String] = [:]
        for definition in definitions {
            if let prowlarrID = definition.prowlarrIndexerID, let name = prowlarrNames[prowlarrID] {
                out[definition.id] = name
            } else if let name = definition.name, !name.isEmpty {
                out[definition.id] = ArrRelease.strippingProwlarrSuffix(name)
            }
        }
        Logger(category: "Indexers").debug("resolved \(out.count, privacy: .public) indexer names for \(source.rawValue, privacy: .public)")
        return out
    }

    private func prowlarrNames(configStore: ConfigStore) async -> [Int: String] {
        do {
            let indexers = try await configStore.prowlarrClient.indexers()
            return indexers.reduce(into: [:]) { out, indexer in
                if let name = indexer.name, !name.isEmpty { out[indexer.id] = name }
            }
        } catch {
            // Prowlarr being down (or unconfigured) only costs us the nicer spelling.
            Logger(category: "Indexers").debug("Prowlarr indexer list unavailable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
