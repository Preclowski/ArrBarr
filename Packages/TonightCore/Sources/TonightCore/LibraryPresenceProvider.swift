import Foundation
import MediaKit

/// The app's own library index, exposed to MediaKit as a provider.
///
/// `ExternalLibraryStore` already holds one pass over the media server and the
/// arrs, keyed by TMDB id, refreshed in the background. Asking it costs
/// nothing and it is the only source in the app that knows what was actually
/// *watched* — Radarr and Sonarr only know what is on disk.
///
/// It lives here rather than in MediaKit on purpose: MediaKit must not depend
/// on ArrCore, and this reads ArrCore's media-server client. When MediaKit
/// grows its own Plex/Jellyfin provider (step 5), this goes away and nothing
/// else has to change — which is the point of providers being pluggable.
struct LibraryPresenceProvider: MediaProvider {
    let id = ProviderID("library")
    let supplies: MediaFieldSet = .availability
    /// Already in memory: nothing beats it, and the planner should know.
    let cost = ProviderCost.free

    var isConfigured: Bool { ExternalLibraryStore.isAvailableNow }

    /// Owned/watched as the app's own index knows it. `MediaServerProvider`
    /// speaks for the server itself and outranks this; here the arrs' half of
    /// the answer survives even when the server is unreachable.
    func precedence(for field: MediaField) -> Int { field == .availability ? 90 : 0 }

    /// Radarr keeps films and Sonarr keeps shows: naming the other one is
    /// how a page ends up saying "not in Sonarr" about a movie, which is
    /// true and useless. The media server holds both.
    private func speaksFor(_ source: String, kind: MediaKind) -> Bool {
        switch source {
        case "Radarr": kind == .movie
        case "Sonarr": kind == .series
        default: true
        }
    }

    /// An in-memory set: a page of cards costs nothing.
    var answersFromIndex: Bool { true }

    /// The index is keyed by TMDB id; without one there is nothing to look up.
    func canAnswer(_ identity: MediaIdentity) -> Bool { identity.tmdbID != nil }

    func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment {
        var fragment = MediaFragment(identity: identity)
        guard fields.contains(.availability), let tmdbID = identity.tmdbID else { return fragment }
        let (watched, present, missing) = await MainActor.run { () -> (Bool, [String], [String]) in
            let store = ExternalLibraryStore.shared
            var present: [String] = []
            var missing: [String] = []
            // Per source, not pooled: "in Plex, not in Radarr" is the answer
            // the detail page shows, and a union can only ever say "somewhere".
            for name in store.sourceNames where speaksFor(name, kind: identity.kind) {
                if store.ownedBySource[name]?.contains(tmdbID) == true {
                    present.append(name)
                } else {
                    missing.append(name)
                }
            }
            return (store.watchedTmdbIds.contains(tmdbID), present, missing)
        }
        // A miss in the index *is* that server saying no — the index is a
        // full pass over the library, not a sample — so it goes on the
        // record as an absent source rather than as silence.
        // A media server only lists what it can actually play, so presence
        // there is the file being on disk. The arrs in this index are a
        // different claim — "it is in Radarr" — and Radarr's own provider is
        // the one that knows whether the file arrived.
        let server = ArrBarrProfile.mediaServerConfig()?.kind.displayName
        fragment.availability = Availability(owned: !present.isEmpty, watched: watched,
                                             sources: present, absent: missing,
                                             downloaded: present.filter { $0 == server })
        return fragment
    }
}
