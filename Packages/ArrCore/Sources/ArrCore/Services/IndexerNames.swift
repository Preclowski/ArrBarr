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
/// Both lists are store reads, so a second search reads them from disk; a
/// Prowlarr or arr edit re-registers the instance, which drops its rows.
enum IndexerNames {
    private static let log = Logger(category: "Indexers")

    static func names(for source: QueueItem.Source, configStore: ConfigStore) async -> [Int: String] {
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
        log.debug("resolved \(out.count, privacy: .public) indexer names for \(source.rawValue, privacy: .public)")
        return out
    }

    private static func prowlarrNames(configStore: ConfigStore) async -> [Int: String] {
        do {
            let indexers = try await configStore.prowlarrClient.indexers()
            return indexers.reduce(into: [:]) { out, indexer in
                if let name = indexer.name, !name.isEmpty { out[indexer.id] = name }
            }
        } catch {
            // Prowlarr being down (or unconfigured) only costs us the nicer spelling.
            log.debug("Prowlarr indexer list unavailable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
