import Foundation
import os
import MediaKit

/// The only way to tell apart an arr that was unconfigured, unreachable or had no matching client.
nonisolated private let dropLog = Logger(category: "DownloadDrop")

/// Goes through the arr: pushing to a client of our choosing would leave the download unimported,
/// because no arr watches that category.
public actor DownloadDropService {
    nonisolated public static let shared = DownloadDropService()

    public init() {}

    /// Pairs that speak the payload's protocol and that ArrBarr has credentials for. An unreachable arr
    /// contributes nothing rather than failing the whole resolve.
    public func destinations(for kind: DownloadKind, configs: [ServiceKind: ServiceConfig]) async -> [DownloadDestination] {
        var result: [DownloadDestination] = []
        for arr in ServiceKind.arrKinds {
            guard let config = configs[arr], config.isVisible else {
                dropLog.debug("\(arr.rawValue, privacy: .public): not configured")
                continue
            }
            let clients: [ArrDropClient]
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
                // Without an ArrBarr login the client can't be reached, and the drop would fail at add time.
                guard let local = client.serviceKind,
                      configs[local]?.isConfigured == true else { continue }
                result.append(DownloadDestination(arr: arr, client: client, serviceKind: local))
            }
        }
        return result
    }

    /// The category comes from the destination (the arr), never from the caller.
    public func add(
        _ drop: DownloadDrop,
        to destination: DownloadDestination,
        paused: Bool,
        configs: [ServiceKind: ServiceConfig]
    ) async throws {
        guard let config = configs[destination.serviceKind],
              let client = Self.addSource(destination.serviceKind, config) else {
            throw MediaKitError.notConfigured(InstanceID(destination.serviceKind.instanceKind))
        }
        try await client.add(drop, category: destination.client.category, paused: paused)
    }

    /// The client's own preference, or off for clients without one.
    public func defaultPaused(for destination: DownloadDestination, configs: [ServiceKind: ServiceConfig]) async -> Bool {
        guard let config = configs[destination.serviceKind],
              let client = Self.addSource(destination.serviceKind, config) else { return false }
        return await client.defaultAddPaused() ?? false
    }

    /// Separate from `DownloadProgressService.makeSource`: an arr kind can report progress but never add.
    nonisolated private static func addSource(_ kind: ServiceKind, _ config: ServiceConfig) -> (any DownloadAddSource)? {
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

    nonisolated private static func downloadClients(arr: ServiceKind, config: ServiceConfig) async throws -> [ArrDropClient] {
        try await ServiceHandles.arr(QueueItem.Source(rawValue: arr.rawValue)!, config: config).fetchDownloadClients()
    }

}

nonisolated public extension ServiceKind {
    nonisolated static var arrKinds: [ServiceKind] { [.sonarr, .radarr, .lidarr, .whisparr] }

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
