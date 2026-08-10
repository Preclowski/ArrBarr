import Foundation
import os

/// Why an arr didn't show up in the add window is invisible from the UI — the
/// arr is simply absent, whether it wasn't configured, wasn't reachable, or had
/// no matching client. This log is the only way to tell those apart.
private let dropLog = Logger(subsystem: "pl.incred.ArrBarr", category: "DownloadDrop")

/// Turns a dropped file or magnet link into an actual download.
///
/// The flow deliberately goes *through the arr*: the user picks which arr the
/// media belongs to, that arr names its own download client and category, and
/// we push the payload into the locally-configured client of the same kind
/// using the credentials the user gave ArrBarr. Uploading straight to a client
/// of our own choosing would work exactly once — the download would land and
/// then sit there, never imported, because no arr is watching that category.
public actor DownloadDropService {
    public static let shared = DownloadDropService()

    /// Resolved destinations keyed by the config signature they were built
    /// from, so re-opening the sheet doesn't re-interrogate every arr — but a
    /// changed config does.
    private var cache: [String: [DownloadDestination]] = [:]

    public init() {}

    /// Every place this payload could go: one entry per (arr, download client)
    /// pair that can speak the payload's protocol AND that ArrBarr itself has
    /// credentials for.
    ///
    /// An arr we can't reach contributes nothing rather than failing the whole
    /// resolve — with three arrs configured and one down, the user should still
    /// be able to file a drop with the other two.
    public func destinations(for kind: DownloadKind, configs: [ServiceKind: ServiceConfig]) async -> [DownloadDestination] {
        let signature = Self.signature(configs) + "|" + kind.rawValue
        if let cached = cache[signature] { return cached }

        var result: [DownloadDestination] = []
        for arr in ServiceKind.arrKinds {
            guard let config = configs[arr], config.isVisible else {
                dropLog.debug("\(arr.rawValue, privacy: .public): not configured")
                continue
            }
            let clients: [ArrDownloadClient]
            do {
                clients = try await Self.downloadClients(arr: arr, config: config)
            } catch {
                // Swallowed on purpose — one unreachable arr must not cost the
                // user the other two — but never silently.
                dropLog.notice("\(arr.rawValue, privacy: .public): download clients unavailable — \(error.localizedDescription, privacy: .public)")
                continue
            }
            if !clients.contains(where: { $0.kind == kind }) {
                dropLog.notice(
                    "\(arr.rawValue, privacy: .public): no enabled \(kind.rawValue, privacy: .public) client (has \(clients.map(\.implementation).joined(separator: ", "), privacy: .public))"
                )
            }
            for client in clients where client.kind == kind {
                if client.serviceKind == nil {
                    dropLog.notice("\(arr.rawValue, privacy: .public): \(client.implementation, privacy: .public) is not a client ArrBarr supports")
                } else if configs[client.serviceKind!]?.isConfigured != true {
                    dropLog.notice("\(arr.rawValue, privacy: .public): \(client.implementation, privacy: .public) is not configured in ArrBarr")
                }
                // A client the arr uses but ArrBarr has no login for can't be
                // reached, so offering it would produce a destination that
                // fails at add time.
                guard let local = client.serviceKind,
                      configs[local]?.isConfigured == true else { continue }
                result.append(DownloadDestination(arr: arr, client: client, serviceKind: local))
            }
        }
        cache[signature] = result
        return result
    }

    /// Push one payload to a resolved destination.
    ///
    /// The category comes from the destination (i.e. from the arr), never from
    /// the caller — it's the one value that must not be a UI choice.
    public func add(
        _ drop: DownloadDrop,
        to destination: DownloadDestination,
        paused: Bool,
        configs: [ServiceKind: ServiceConfig]
    ) async throws {
        guard let config = configs[destination.serviceKind],
              let client = Self.addSource(destination.serviceKind, config) else {
            throw HTTPError.notConfigured
        }
        try await client.add(drop, category: destination.client.category, paused: paused)
    }

    /// What the "add paused" checkbox should start on: the client's own
    /// preference, or off for the clients that have no such setting.
    public func defaultPaused(for destination: DownloadDestination, configs: [ServiceKind: ServiceConfig]) async -> Bool {
        guard let config = configs[destination.serviceKind],
              let client = Self.addSource(destination.serviceKind, config) else { return false }
        return await client.defaultAddPaused() ?? false
    }

    /// Drop the memoised destinations — called when the user edits any service
    /// config, since an arr's download client can change under us.
    public func invalidate() {
        cache.removeAll()
    }

    /// The one place mapping a client kind to something that can be handed a
    /// new download. Mirrors `DownloadProgressService.makeSource`; the two stay
    /// separate because progress and adding are genuinely different
    /// capabilities (an arr kind has the first, never the second).
    private static func addSource(_ kind: ServiceKind, _ config: ServiceConfig) -> (any DownloadAddSource)? {
        switch kind {
        case .qbittorrent:  return QbittorrentClient(config: config)
        case .transmission: return TransmissionClient(config: config)
        case .deluge:       return DelugeClient(config: config)
        case .rtorrent:     return RtorrentClient(config: config)
        case .sabnzbd:      return SabnzbdClient(config: config)
        case .nzbget:       return NzbgetClient(config: config)
        default:            return nil
        }
    }

    private static func downloadClients(arr: ServiceKind, config: ServiceConfig) async throws -> [ArrDownloadClient] {
        switch arr {
        case .sonarr:   return try await SonarrClient(config: config).fetchDownloadClients()
        case .radarr:   return try await RadarrClient(config: config).fetchDownloadClients()
        case .lidarr:   return try await LidarrClient(config: config).fetchDownloadClients()
        case .whisparr: return try await WhisparrClient(config: config).fetchDownloadClients()
        default:        return []
        }
    }

    /// Cheap identity for a config set — enough to notice a URL/key edit
    /// without holding the configs themselves.
    private static func signature(_ configs: [ServiceKind: ServiceConfig]) -> String {
        configs.keys.sorted { $0.rawValue < $1.rawValue }.map { kind in
            let c = configs[kind]
            return "\(kind.rawValue):\(c?.enabled == true):\(c?.baseURL ?? "")"
        }.joined(separator: ",")
    }
}

public extension ServiceKind {
    /// The arr kinds, in the order the add sheet lists them.
    static var arrKinds: [ServiceKind] { [.sonarr, .radarr, .lidarr, .whisparr] }

    /// SF Symbol shown on this arr's tile in the add sheet.
    var symbolName: String {
        switch self {
        case .sonarr:   return "tv"
        case .radarr:   return "film"
        case .lidarr:   return "music.note"
        case .whisparr: return "folder"
        default:        return "arrow.down.circle"
        }
    }
}
