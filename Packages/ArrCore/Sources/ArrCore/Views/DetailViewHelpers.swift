import Foundation
import SwiftUI

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

// MARK: - Header search menu

/// Toolbar/header search control: a bare magnifier glyph (sized to sit in
/// the `[search] [bookmark] [safari] [trash]` cluster) whose tap opens the
/// native Automatic / Manual menu — the same choice the bottom "Search" CTA
/// used to offer before it moved up here. Carries the sweep states inline:
/// spinner while a search runs, a brief checkmark right after queueing one.
struct HeaderSearchMenu: View {
    let inFlight: Bool
    let didQueue: Bool
    let onAutomatic: () -> Void
    let onManual: () -> Void

    var body: some View {
        Menu {
            Button(action: onAutomatic) {
                Label { Text("Automatic search", bundle: .module) } icon: { Image(systemName: "bolt.fill") }
            }
            Button(action: onManual) {
                Label { Text("Manual search", bundle: .module) } icon: { Image(systemName: "list.bullet") }
            }
        } label: {
            Group {
                if inFlight {
                    ProgressView().controlSize(.small)
                } else if didQueue {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(inFlight)
        .help(Text("Search", bundle: .module))
        .accessibilityLabel(inFlight
                            ? Text("detail.searchingForRelease.label", bundle: .module)
                            : Text("Search", bundle: .module))
    }
}
