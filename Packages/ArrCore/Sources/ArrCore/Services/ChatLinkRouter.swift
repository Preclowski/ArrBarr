import Foundation
import os

/// Opens the surface behind a `ChatLink`.
///
/// People are direct — `PersonView` takes a TMDB id and fetches the rest. Titles
/// are not: the link carries an EXTERNAL id (tmdb/tvdb/imdb) while the detail
/// panel needs the arr-internal record id, so the ref is resolved through the
/// same `/lookup?term=tmdb:N` path a typed `tmdb:123` query uses, tagged against
/// the library map, and then handed to `DetailRequest.tap` — which owns the
/// "owned → detail, missing → add panel" decision for every other surface too.
@MainActor
public enum ChatLinkRouter {
    private static let log = Logger(subsystem: AppLog.subsystem, category: "ChatLink")

    public static func open(_ link: ChatLink) {
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
        // A TMDB *series* id addresses nothing any arr can look up, so it is
        // translated to a tvdbId first — by id, through the resolver, never by
        // matching the title. If that can't be proven the link simply doesn't
        // navigate: opening the wrong show is worse than opening nothing, and
        // the generic search fallback below would type a `tmdb:` term that
        // Radarr, not Sonarr, would answer.
        var ref = incoming
        if case .tmdbTV(let tmdbTVId) = ref {
            guard let tvdbId = await SeriesIdentityResolver.tvdbId(
                tmdbTVId: tmdbTVId, sonarrConfig: sonarr, tmdbKey: tmdbKey)
            else {
                log.error("chat link: no tvdb id for tmdb tv \(tmdbTVId, privacy: .public)")
                return
            }
            ref = .tvdb(tvdbId)
        }
        // `imdb:` resolves against Radarr first and Sonarr second — the ref
        // itself doesn't say which kind of title it is, and both accept it on
        // /lookup. Whichever answers first wins; a series' imdb id simply
        // returns nothing from Radarr.
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
            guard let result = try? await client.lookup(input: .ref(ref)).first else { continue }
            let owned = await libraryId(for: ref, source: source, config: config)
            DetailRequest.tap(result.withInLibraryArrId(owned ?? result.inLibraryArrId))
            return
        }
        // Nothing resolved: the id was wrong, or the arr that owns this kind of
        // title isn't configured. Fall back to the search bar with the ref
        // pre-typed — the user sees what was asked for rather than a dead tap.
        NotificationCenter.default.post(
            name: .arrBarrSearchQuery, object: nil, userInfo: ["query": ref.lookupTerm]
        )
    }

    /// arr-internal id for a ref the user already owns, or nil. Sonarr's map is
    /// keyed by TVDB id and Radarr's by TMDB id — the same maps the chat's TMDB
    /// tools use to tag results as OWNED.
    private static func libraryId(for ref: MediaRef, source: QueueItem.Source,
                                  config: ServiceConfig) async -> Int? {
        switch (ref, source) {
        case (.tmdb(let id), .radarr):
            return await ArrLibraryMaps.radarrByTMDBId(config: config)[id]
        case (.tvdb(let id), .sonarr):
            return await ArrLibraryMaps.sonarrByTVDBId(config: config)[id]
        default:
            // imdb / musicBrainz: no id map. The lookup record's own
            // `inLibraryArrId` (when the client filled it in) is all we have.
            return nil
        }
    }
}
