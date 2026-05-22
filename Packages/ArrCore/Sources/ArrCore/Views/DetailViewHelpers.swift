import Foundation

/// Pure helpers used by `DetailView`'s per-arr sections. Lifted out as free
/// functions so the per-arr `*Content` view-builders don't have to be members
/// of `DetailView` just to reach `configStore`. Each takes `(item, configStore)`
/// (plus per-call extras like an images array) and computes a stateless answer.

/// Poster auth key for the source's configured arr. Returns the api key for
/// whichever arr `item.source` points at, regardless of whether the poster
/// actually requires auth — callers gate on `item.posterRequiresAuth`.
@MainActor
func arrAPIKey(for item: QueueItem, in configStore: ConfigStore) -> String? {
    configStore.serviceConfig(for: item.source).apiKey
}

/// Deep-link to the arr's web UI for this item, if we know a slug. Path
/// differs per arr — Sonarr uses `/series/`, Lidarr `/album/`, Radarr +
/// Whisparr both use `/movie/` (Whisparr is a Radarr fork).
@MainActor
func arrWebURL(for item: QueueItem, in configStore: ConfigStore) -> URL? {
    guard let slug = item.contentSlug else { return nil }
    let cfg = configStore.serviceConfig(for: item.source)
    let path: String = switch item.source {
    case .radarr, .whisparr: "/movie/\(slug)"
    case .sonarr:            "/series/\(slug)"
    case .lidarr:            "/album/\(slug)"
    }
    return URL(string: cfg.baseURL)?.appendingPathComponent(path)
}

/// Resolve a poster URL from an arr's `images` array against its base URL.
/// Falls back to `item.posterURL` (set when the source had no images list)
/// is the caller's job — this only resolves the images side.
@MainActor
func arrPosterURL(images: [ArrImage]?, for item: QueueItem,
                  in configStore: ConfigStore) -> URL? {
    let baseURL = configStore.serviceConfig(for: item.source).baseURL
    return images?.posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]).0
}
