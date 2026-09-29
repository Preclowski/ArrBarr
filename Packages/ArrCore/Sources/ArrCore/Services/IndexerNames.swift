import Foundation
import MediaKit
import os

/// A release carries only the arr's indexer label, whatever the sync called it; Prowlarr holds the user's name,
/// keyed by the id inside the arr indexer's `baseUrl`. Without it, strip a trailing "(Prowlarr)".
enum IndexerNames {
    private static let log = Logger(category: "Indexers")

    static func names(for source: QueueItem.Source, configStore: ConfigStore) async -> [Int: String] {
        let client = configStore.arrClient(for: source)
        guard let definitions = await log.attempt("indexer list", { try await client.fetchIndexers() }) else { return [:] }
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
            // Prowlarr being down only costs the nicer spelling.
            log.debug("Prowlarr indexer list unavailable: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return [:]
        }
    }
}
