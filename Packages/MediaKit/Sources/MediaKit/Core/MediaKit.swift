import Foundation
import os

/// One assembled data layer: kernel, store, services and streams behind a single value the app owns.
public final class MediaKit: Sendable {
    public enum Role: Sendable { case app, widgetRefresher, snapshotReader }

    public struct Configuration: Sendable {
        public var role: Role = .app
        public var database: DatabaseLocation? = .memory
        public var transport: any Transport
        public var sockets: (any SocketTransport)?
        public var credentials: any CredentialProvider
        public var clock: any MediaClock = SystemClock()
        public var telemetry: any TelemetrySink = NoTelemetry()
        public var log: any LogSink = NoLog()
        public var signposts: OSSignposter?
        public var limits: HostGovernor.Limits = HostGovernor.Limits()
        public var overrides: [InstanceKind: HostGovernor.Limits] = [.tmdb: { var l = HostGovernor.Limits(); l.minimumInterval = .milliseconds(250); return l }()]
        public var center: NotificationCenter = .default
        public var mediaServerUserID: String?

        public init(transport: any Transport, sockets: (any SocketTransport)?, credentials: any CredentialProvider) {
            self.transport = transport; self.sockets = sockets; self.credentials = credentials
        }
    }

    public let configuration: Configuration
    public let registry: InstanceRegistry
    public let governor: HostGovernor
    public let sessions: SessionBroker
    public let pipeline: RequestPipeline
    public let database: SQLiteDatabase?
    public let identity: IdentityStore
    public let store: ResourceStore
    public let capabilities = CapabilityIndex()
    public let probe: CapabilityProbe
    public let engine: CompositionEngine
    public let events: EventHub
    public let discovery: Discovery
    public var subject: MessageSubject { store.subject }
    private let started = OSAllocatedUnfairLock(initialState: false)
    private let sweeper = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init(_ configuration: Configuration) throws {
        self.configuration = configuration
        let c = configuration
        registry = InstanceRegistry(center: c.center, telemetry: c.telemetry, log: c.log)
        governor = HostGovernor(defaults: c.limits, overrides: c.overrides, clock: c.clock, telemetry: c.telemetry, log: c.log)
        sessions = SessionBroker(strategies: SessionStrategies.standard, telemetry: c.telemetry, log: c.log)
        pipeline = RequestPipeline(transport: c.transport, sockets: c.sockets, governor: governor, sessions: sessions, credentials: c.credentials,
                                   registry: registry, telemetry: c.telemetry, log: c.log, signposts: c.signposts, clock: c.clock)
        database = try c.database.map { try SQLiteDatabase(location: $0, log: c.log) }
        identity = IdentityStore(database: database, clock: c.clock)
        store = ResourceStore(database: database, pipeline: pipeline, identity: identity, clock: c.clock, telemetry: c.telemetry, log: c.log,
                              center: c.center, memoryBudget: c.role == .app ? 8 << 20 : 2 << 20)
        probe = CapabilityProbe(store: store, index: capabilities, database: database, clock: c.clock, log: c.log)
        engine = CompositionEngine(store: store, identity: identity, capabilities: capabilities, clock: c.clock, telemetry: c.telemetry)
        events = EventHub(store: store, clock: c.clock, telemetry: c.telemetry, log: c.log)
        discovery = Discovery(log: c.log)
    }

    /// Wires the actors, restores persisted capabilities, applies the descriptors and probes every host in the background.
    public func start(instances: [InstanceDescriptor]) async {
        if !started.withLock({ let was = $0; $0 = true; return was }) {
            await store.attach(probe: probe, capabilities: capabilities)
            await registry.attach(.init(store: store, capabilities: probe, sessions: sessions, identity: identity, subject: subject))
            await probe.restore()
        }
        await registry.apply(instances)
        if configuration.role == .app {
            Task { [probe, registry] in
                for id in registry.all.filter(\.enabled).map(\.id) { await probe.ensure(id) }
            }
            sweeper.withLock { task in
                task?.cancel()
                task = Task { [store, clock = configuration.clock] in
                    while !Task.isCancelled {
                        await store.sweep()
                        try? await clock.sleep(for: .seconds(6 * 3600))
                    }
                }
            }
        }
    }

    public func reconcile(_ instances: [InstanceDescriptor]) async -> Set<InstanceID> { await registry.apply(instances) }

    public func stop() async {
        sweeper.withLock { $0?.cancel(); $0 = nil }
        for id in registry.all.map(\.id) { await events.detach(id) }
    }

    public func health(of instance: InstanceID) -> HostHealth {
        registry.host(instance).map { governor.health(of: $0) } ?? .unknown
    }

    // MARK: - Services

    public func servarr(_ instance: InstanceID) -> ServarrService? {
        ServarrProfile.profile(for: instance.kind).map { ServarrService(instance: instance, profile: $0, capabilities: capabilities) }
    }

    public func download(_ instance: InstanceID) -> (any DownloadService)? {
        switch instance.kind {
        case .qbittorrent: QBittorrentService(instance: instance, capabilities: capabilities)
        case .transmission: TransmissionService(instance: instance)
        case .deluge: DelugeService(instance: instance)
        case .rtorrent: RTorrentService(instance: instance)
        case .sabnzbd: SABnzbdService(instance: instance)
        case .nzbget: NZBGetService(instance: instance)
        default: nil
        }
    }

    public func mediaServer(_ instance: InstanceID) -> MediaServerService? {
        instance.kind.family == .mediaServer ? MediaServerService(instance: instance, capabilities: capabilities, userID: configuration.mediaServerUserID) : nil
    }

    public var tmdb: TMDBService { TMDBService(capabilities: capabilities) }

    // MARK: - Live streams

    public func liveQueue(instances: [InstanceID]) -> LiveStream<ArrQueueRecord> {
        let kit = self
        return LiveStream(id: .queue, instances: instances, policy: .queue, pipeline: pipeline, database: database, clock: configuration.clock,
                          telemetry: configuration.telemetry, log: configuration.log, elementID: { "\($0.id)" }, fetch: { instance, _, pipeline in
            guard let service = kit.servarr(instance) else { return [] }
            let response = try await pipeline.send(service.queuePlan())
            return try await pipeline.decode(ArrPage<ArrQueueRecord>.self, from: response, operation: service.queuePlan().operation).records
        }, isActive: { records in records.contains { ($0.status ?? "").lowercased() == "downloading" } })
    }

    public func liveProgress(instances: [InstanceID]) -> LiveStream<DownloadTask> {
        let kit = self
        return LiveStream(id: .progress, instances: instances, policy: .progress, pipeline: pipeline, database: database, clock: configuration.clock,
                          telemetry: configuration.telemetry, log: configuration.log, elementID: \.id, fetch: { instance, scope, pipeline in
            guard let service = kit.download(instance) else { return [] }
            let ids: Set<String> = if case let .ids(set) = scope { set } else { [] }
            return try await service.fetchTasks(ids: ids, pipeline: pipeline)
        }, isActive: { tasks in tasks.contains { $0.state == .downloading } })
    }

    public func liveSessions(instance: InstanceID) -> LiveStream<MediaServerSession> {
        let kit = self
        return LiveStream(id: .sessions, instances: [instance], policy: .sessions, pipeline: pipeline, database: database, clock: configuration.clock,
                          telemetry: configuration.telemetry, log: configuration.log, elementID: \.itemID, fetch: { instance, _, pipeline in
            guard let service = kit.mediaServer(instance) else { return [] }
            return try service.decodeSessions(try await pipeline.send(service.sessionsPlan()))
        })
    }

    public func realtime(for instance: InstanceID) -> SignalRSource {
        SignalRSource(instance: instance, pipeline: pipeline, clock: configuration.clock, telemetry: configuration.telemetry, log: configuration.log)
    }

    // MARK: - Artwork

    /// Resolves `.credential` header refs through the provider and the instance's session strategy; `.literal` copies.
    public func artworkHeaders(for reference: ArtworkReference) async -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (name, ref) in reference.headers {
            switch ref {
            case let .literal(value): headers[name] = value
            case let .credential(instance):
                guard let credentials = await configuration.credentials.credentials(for: instance) else { continue }
                let placement: RequestPlan.AuthPlacement = switch instance.kind {
                case .plex: .header("X-Plex-Token")
                case .jellyfin: .jellyfinMediaBrowser
                case .emby: .header("X-Emby-Token")
                default: .header(name)
                }
                let plan = RequestPlan(instance: instance, operation: "artwork", pathTemplate: "/", auth: placement)
                if let request = try? await sessions.authorize(plan, credentials: credentials) { headers.merge(request.headers) }
            }
        }
        return headers
    }
}
