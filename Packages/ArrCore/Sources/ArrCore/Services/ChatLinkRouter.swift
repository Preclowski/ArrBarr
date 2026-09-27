import Foundation
import os

/// Titles carry an external id while the detail needs the arr record id, so the ref is
/// resolved through `/lookup?term=tmdb:N` and handed to `DetailRequest.tap`.
enum ChatLinkRouter {
    private static let log = Logger(category: "ChatLink")

    static func open(_ link: ChatLink) {
        switch link {
        case .person(let id, let name):
            PersonRequest.post(PersonRef(tmdbId: id, name: name))
        case .media(let ref):
            let radarr = ConfigStore.shared.radarr
            let sonarr = ConfigStore.shared.sonarr
            let lidarr = ConfigStore.shared.lidarr
            let tmdbKey = ConfigStore.shared.tmdbApiKey
            Task {
                await openMedia(ref, radarr: radarr, sonarr: sonarr, lidarr: lidarr,
                                tmdbKey: tmdbKey)
            }
        }
    }

    private static func openMedia(_ incoming: MediaRef, radarr: ServiceConfig,
                                  sonarr: ServiceConfig, lidarr: ServiceConfig,
                                  tmdbKey: String) async {
        // A TMDB series id is translated to a tvdbId by id, never by title; unproven means no
        // navigation, since opening the wrong show is worse and Radarr would answer a `tmdb:` search.
        var ref = incoming
        if case .tmdbTV(let tmdbTVId) = ref {
            guard let tvdbId = await SeriesIdentityResolver.tvdbId(
                tmdbTVId: tmdbTVId, sonarrConfig: sonarr, tmdbKey: tmdbKey)
            else {
                // Not an error: TMDB knows series the TVDB mapping doesn't cover.
                log.notice("chat link: no tvdb id for tmdb tv \(tmdbTVId, privacy: .public) — not navigating")
                return
            }
            ref = .tvdb(tvdbId)
        }
        // The ref doesn't say which kind of title it is; a series' imdb id returns nothing from Radarr.
        let candidates: [(QueueItem.Source, ServiceConfig)]
        switch ref {
        case .tmdb:        candidates = [(.radarr, radarr)]
        case .tvdb:        candidates = [(.sonarr, sonarr)]
        case .musicBrainz: candidates = [(.lidarr, lidarr)]
        case .imdb:        candidates = [(.radarr, radarr), (.sonarr, sonarr)]
        // Resolved to `.tvdb` above; nothing reaches here still holding one.
        case .tmdbTV:      candidates = []
        }

        for (source, config) in candidates where config.isConfigured {
            let client = SearchClient(config: config, source: source)
            guard let result = await log.attempt("chat link lookup", { try await client.lookup(input: .ref(ref)) })?.first else { continue }
            let owned = await libraryOwnership(for: ref, source: source, config: config)
            // Read back after a wrong-link report: ids and arr public, the resolved title private.
            log.notice("""
                chat link \(incoming.urlString, privacy: .public) → \
                \(source.rawValue, privacy: .public) "\(result.title, privacy: .private)" \
                (\(result.year.map(String.init) ?? "—", privacy: .public))
                """)
            DetailRequest.tap(owned.map(result.withLibraryOwnership) ?? result, addOrigin: .chat)
            return
        }
        // Fall back to search with the ref pre-typed rather than a dead tap.
        log.notice("chat link \(incoming.urlString, privacy: .public) resolved to nothing — falling back to search")
        AppMessages.post(AppMessages.SearchQuery(query: ref.lookupTerm))
    }

    /// Sonarr's map is keyed by TVDB id, Radarr's by TMDB id.
    private static func libraryOwnership(for ref: MediaRef, source: QueueItem.Source,
                                         config: ServiceConfig) async -> LibraryOwnership? {
        switch (ref, source) {
        case (.tmdb(let id), .radarr):
            return await ArrLibraryMaps.radarrByTMDBId(config: config)[id]
        case (.tvdb(let id), .sonarr):
            return await ArrLibraryMaps.sonarrByTVDBId(config: config)[id]
        default:
            // imdb / musicBrainz have no id map; only the record's own `inLibraryArrId`.
            return nil
        }
    }
}
