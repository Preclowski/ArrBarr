import Combine
import Foundation
import MediaKit
import os

extension ServiceKind {
    public var instanceKind: InstanceKind { InstanceKind(rawValue: rawValue)! }
    public var instanceID: InstanceID { InstanceID(instanceKind) }
}

extension QueueItem.Source {
    public var instanceID: InstanceID { InstanceID(serviceKind.instanceKind) }
}

extension MediaServerKind {
    var instanceID: InstanceID {
        switch self {
        case .plex: InstanceID(.plex)
        case .jellyfin: InstanceID(.jellyfin)
        case .emby: InstanceID(.emby)
        }
    }
}

/// The one place ArrCore reaches MediaKit. Owned by `ConfigStore`; rebuilt for demo mode, reconciled on every config change.
@MainActor
public final class ServiceGateway {
    public private(set) var kit: MediaStack
    public let telemetry = TelemetryRecorder()
    private let configStore: ConfigStore
    private var observers: Set<AnyCancellable> = []
    private var started = false
    private var startTask: Task<Void, Never>?
    private var realtime: [InstanceID: SignalRSource] = [:]

    public init(configStore: ConfigStore) {
        self.configStore = configStore
        kit = Self.makeKit(configStore: configStore, telemetry: telemetry, demo: DemoMode.isActive)
        observe()
        startTask = Task { await self.start() }
    }

    /// Consumers await this before their first read so the registry is populated.
    public func ready() async { await startTask?.value }

    public func start() async {
        started = true
        await kit.start(instances: descriptors())
        await syncRealtime()
    }

    public func reconcile() async {
        guard started else { return }
        _ = await kit.reconcile(descriptors())
        await syncRealtime()
    }

    /// Demo toggles swap the transport and the database; the profile itself is `ConfigStore`'s business.
    public func rebuild(demo: Bool) async {
        await kit.stop()
        realtime = [:]
        kit = Self.makeKit(configStore: configStore, telemetry: telemetry, demo: demo)
        if started {
            await kit.start(instances: descriptors())
            await syncRealtime()
        }
    }

    /// One SignalR source per configured arr; the hub turns its frames into store invalidations.
    private func syncRealtime() async {
        let wanted = Set(kit.registry.configured(.servarr))
        for id in realtime.keys where !wanted.contains(id) {
            await kit.events.detach(id)
            realtime.removeValue(forKey: id)
        }
        for id in wanted where realtime[id] == nil {
            let source = kit.realtime(for: id)
            realtime[id] = source
            await kit.events.attach(source, for: id)
        }
    }

    public func systemDidWake() async {
        await kit.governor.noteWake(at: Date())
        await kit.events.wakeAll()
    }

    public func servarr(_ source: QueueItem.Source) -> ServarrService { kit.servarr(source.instanceID)! }
    public func download(_ kind: ServiceKind) -> (any DownloadService)? { kit.download(kind.instanceID) }
    public var mediaServer: MediaServerService? {
        guard configStore.mediaServer.isConfigured else { return nil }
        return kit.mediaServer(configStore.mediaServer.kind.instanceID)
    }
    public var tmdb: TMDBService { kit.tmdb }
    public var store: ResourceStore { kit.store }
    public var engine: CompositionEngine { kit.engine }
    public var events: EventHub { kit.events }

    public func isConfigured(_ source: QueueItem.Source) -> Bool {
        kit.registry.descriptor(source.instanceID)?.enabled ?? false
    }

    // MARK: - Assembly

    private static func makeKit(configStore: ConfigStore, telemetry: TelemetryRecorder, demo: Bool) -> MediaStack {
        let credentials = ConfigCredentialProvider(configStore: configStore, demo: demo)
        var configuration: MediaStack.Configuration
        if demo {
            configuration = MediaStack.Configuration(transport: FixtureTransport(), sockets: nil, credentials: credentials)
            configuration.database = .memory
        } else {
            let plain = URLSessionTransport(session: URLSessionTransport.makeSession(cookies: false))
            let cookies = URLSessionTransport(session: URLSessionTransport.makeSession(cookies: true))
            let transport = CookieSplittingTransport(plain: plain, cookies: cookies)
            configuration = MediaStack.Configuration(transport: transport, sockets: plain, credentials: credentials)
            configuration.database = databaseLocation()
        }
        configuration.telemetry = telemetry
        configuration.log = OSLogSink(subsystem: "pl.incred.ArrBarr")
        configuration.signposts = OSSignposter(subsystem: "pl.incred.ArrBarr", category: "MediaKit")
        configuration.mediaServerUserID = configStore.mediaServer.userId.isEmpty ? nil : configStore.mediaServer.userId
        do { return try MediaStack(configuration) } catch {
            Logger(category: "Gateway").error("MediaKit database unavailable, running in memory: \(error.localizedDescription, privacy: .public)")
            configuration.database = .memory
            return try! MediaStack(configuration)
        }
    }

    /// Application Support inside the sandbox on macOS; the app group on iOS so the widget shares the file.
    private static func databaseLocation() -> DatabaseLocation {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.pl.incred.ArrBarr") {
            return .file(in: group.appendingPathComponent("Library/Application Support/MediaKit"), protectFiles: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return .file(in: base.appendingPathComponent("MediaKit"))
    }

    private func descriptors() -> [InstanceDescriptor] {
        var out: [InstanceDescriptor] = []
        for kind in ServiceKind.allCases {
            let config = configStore.config(for: kind)
            guard let url = URL(string: config.baseURL), config.isConfigured else { continue }
            let generation = SecretGenerations.generation(for: .apiKey(for: kind), in: configStore.defaultsForGateway)
                + "." + SecretGenerations.generation(for: .password(for: kind), in: configStore.defaultsForGateway)
            out.append(InstanceDescriptor(id: kind.instanceID, baseURL: url, enabled: config.isVisible, generation: generation))
        }
        let server = configStore.mediaServer
        if server.isConfigured, let url = URL(string: server.baseURL) {
            out.append(InstanceDescriptor(id: server.kind.instanceID, baseURL: url, enabled: true,
                                          generation: SecretGenerations.generation(for: .mediaServerToken, in: configStore.defaultsForGateway)))
        }
        if !configStore.tmdbApiKey.isEmpty {
            out.append(InstanceDescriptor(id: InstanceID(.tmdb), baseURL: URL(string: "https://api.themoviedb.org")!, enabled: true,
                                          generation: SecretGenerations.generation(for: .tmdbKey, in: configStore.defaultsForGateway)))
        }
        return out
    }

    private func observe() {
        let services = Publishers.MergeMany(ServiceKind.allCases.map { configStore.publisher(for: $0).map { _ in () } })
        services
            .merge(with: configStore.$mediaServer.map { _ in () }, configStore.$tmdbApiKey.map { _ in () })
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.reconcile() } }
            .store(in: &observers)
    }
}

/// qBittorrent and Deluge hold a cookie session; every other service gets the cookie-free session.
private struct CookieSplittingTransport: Transport {
    let plain: URLSessionTransport
    let cookies: URLSessionTransport
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.operation.kind {
        case .qbittorrent, .deluge: try await cookies.send(request)
        default: try await plain.send(request)
        }
    }
}

/// Reads the secret at request time from the main-actor config; MediaKit never holds it.
private struct ConfigCredentialProvider: CredentialProvider {
    let configStore: ConfigStore
    let demo: Bool

    func credentials(for instance: InstanceID) async -> Credentials? {
        await MainActor.run { resolve(instance) }
    }

    @MainActor
    private func resolve(_ instance: InstanceID) -> Credentials? {
        let defaults = configStore.defaultsForGateway
        switch instance.kind {
        case .plex, .jellyfin, .emby:
            let server = configStore.mediaServer
            guard server.isConfigured, let url = URL(string: server.baseURL) else { return nil }
            return Credentials(baseURL: url, material: .token(server.token), generation: SecretGenerations.generation(for: .mediaServerToken, in: defaults))
        case .tmdb:
            guard !configStore.tmdbApiKey.isEmpty else { return nil }
            return Credentials(baseURL: URL(string: "https://api.themoviedb.org")!, material: .apiKey(configStore.tmdbApiKey),
                               generation: SecretGenerations.generation(for: .tmdbKey, in: defaults))
        default:
            guard let kind = ServiceKind(rawValue: instance.kind.rawValue) else { return nil }
            let config = configStore.config(for: kind)
            guard let url = URL(string: config.baseURL) else { return nil }
            let material: Credentials.Material
            if kind.requiresApiKey || (kind == .qbittorrent && !config.apiKey.isEmpty) {
                material = .apiKey(config.apiKey)
            } else {
                material = .userPassword(user: config.username, password: config.password)
            }
            let generation = SecretGenerations.generation(for: .apiKey(for: kind), in: defaults) + "." + SecretGenerations.generation(for: .password(for: kind), in: defaults)
            return Credentials(baseURL: url, material: demo ? .apiKey("demo") : material, generation: generation)
        }
    }
}
