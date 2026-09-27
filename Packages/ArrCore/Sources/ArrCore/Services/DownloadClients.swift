import Foundation
import MediaKit

/// One download client value per kind, over MediaKit's `DownloadService`; the names the views and tools construct.
protocol DownloadClientFacade: DownloadAddSource {
    var config: ServiceConfig { get }
    var kind: ServiceKind { get }
}

extension DownloadClientFacade {
    func context() async throws -> (gateway: ServiceGateway, service: any DownloadService) {
        let gateway = await ServiceGateway.resolve()
        let instance = await gateway.adopt(config, for: kind)
        await gateway.ready()
        guard gateway.isConfigured(instance), let service = gateway.kit.download(instance) else { throw MediaKitError.notConfigured(instance) }
        return (gateway, service)
    }

    func testConnection() async throws -> String {
        let (gateway, service) = try await context()
        let version = try await gateway.store.read(service.version(), policy: .mustRevalidate).value
        return version.isEmpty ? kind.displayName : "\(kind.displayName) \(version)"
    }

    public func defaultAddPaused() async -> Bool? {
        guard let (gateway, service) = try? await context() else { return nil }
        return try? await gateway.store.read(service.defaultAddPaused()).value
    }

    public func add(_ drop: DownloadDrop, category: String?, paused: Bool) async throws {
        let (gateway, service) = try await context()
        let payload: DownloadPayload = switch drop.content {
        case let .file(data, filename): DownloadPayload(.file(data, filename: filename))
        case let .magnet(link): DownloadPayload(.magnet(link))
        }
        try await gateway.run(service.add(payload, category: category, paused: paused))
    }
}

nonisolated public struct QbittorrentClient: DownloadClientFacade { public let config: ServiceConfig; let kind: ServiceKind = .qbittorrent; init(config: ServiceConfig) { self.config = config } }
nonisolated public struct SabnzbdClient: DownloadClientFacade { public let config: ServiceConfig; let kind: ServiceKind = .sabnzbd; init(config: ServiceConfig) { self.config = config } }
nonisolated public struct TransmissionClient: DownloadClientFacade { public let config: ServiceConfig; let kind: ServiceKind = .transmission; init(config: ServiceConfig) { self.config = config } }
nonisolated public struct DelugeClient: DownloadClientFacade { public let config: ServiceConfig; let kind: ServiceKind = .deluge; init(config: ServiceConfig) { self.config = config } }
nonisolated public struct RtorrentClient: DownloadClientFacade { public let config: ServiceConfig; let kind: ServiceKind = .rtorrent; init(config: ServiceConfig) { self.config = config } }
nonisolated public struct NzbgetClient: DownloadClientFacade { public let config: ServiceConfig; let kind: ServiceKind = .nzbget; init(config: ServiceConfig) { self.config = config } }
