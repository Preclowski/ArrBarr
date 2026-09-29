import Foundation
import MediaKit
import os

nonisolated extension ServiceKind {
    public var instanceKind: InstanceKind { InstanceKind(rawValue: rawValue)! }
    public var instanceID: InstanceID { InstanceID(instanceKind) }
}

nonisolated extension QueueItem.Source {
    public var instanceID: InstanceID { InstanceID(serviceKind.instanceKind) }
}

nonisolated extension MediaServerKind {
    var instanceID: InstanceID {
        switch self {
        case .plex: InstanceID(.plex)
        case .jellyfin: InstanceID(.jellyfin)
        case .emby: InstanceID(.emby)
        }
    }
}

/// The one place ArrCore reaches MediaKit. Owned by `ConfigStore`; rebuilt for demo mode, reconciled on every config change.
public final class ServiceGateway {
    /// The process-wide gateway, for the arr client values that are built anywhere and hold no reference.
    public nonisolated(unsafe) static var current: ServiceGateway?
    private let kitLock: OSAllocatedUnfairLock<MediaStack>
    public nonisolated var kit: MediaStack { kitLock.withLock { $0 } }
    public let telemetry = TelemetryRecorder()
    let configStore: ConfigStore
    private var observer: Task<Void, Never>?
    private var started = false
    private var startTask: Task<Void, Never>?
    private var realtime: [InstanceID: SignalRSource] = [:]
    private var breakerRelay: Task<Void, Never>?
    private var breakerContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Demo answers from bundled fixtures; held here so a gateway built for a test can be a demo one without the global flag.
    private var demo: Bool
    private let transport: (any Transport)?
    /// Configs handed to a client that differ from the saved profile (Settings drafts, tests). Each distinct config
    /// is its own instance (ordinal 1...), so a draft never displaces the saved instance's cache or credentials.
    private let adHoc = OSAllocatedUnfairLock<[ServiceKind: [ServiceConfig]]>(initialState: [:])
    private let adHocServers = OSAllocatedUnfairLock<[MediaServerConfig]>(initialState: [])
    private let adHocTMDBKeys = OSAllocatedUnfairLock<[String]>(initialState: [])
    private nonisolated(unsafe) static var testGateway: ServiceGateway?
    /// Live streams belong to the stack that made them: a demo rebuild swaps the stack and so starts fresh ones.
    private let streams = OSAllocatedUnfairLock<LiveStreams>(initialState: LiveStreams())
    private var queueUpdateContinuations: [UUID: AsyncStream<QueueItem.Source>.Continuation] = [:]
    /// Streams already pumping and registered, by identity, each with the task forwarding its values.
    private var pumping: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let log = Logger(category: "Gateway")

    public init(configStore: ConfigStore, demo: Bool = DemoMode.isActive, transport: (any Transport)? = nil) {
        self.configStore = configStore
        self.demo = demo
        self.transport = transport
        kitLock = OSAllocatedUnfairLock(initialState: Self.makeKit(configStore: configStore, telemetry: telemetry, demo: demo, transport: transport))
        if Self.current == nil { Self.current = self }
        observe()
        startTask = Task { await self.start() }
    }

    public func ready() async { await startTask?.value }

    /// What the crosswalk already knows about `id` in another id space — no request.
    nonisolated func known(_ id: MediaID, in namespace: IDNamespace) async -> MediaID? {
        await kit.identity.known(id, in: namespace)
    }

    /// The registered arrs' base URLs: the only places an arr key may be sent.
    nonisolated var arrBaseURLs: [URL] { kit.registry.all.filter { $0.id.kind.family == .servarr }.map(\.baseURL) }

    /// The headers a media-server artwork reference resolves to, per request.
    nonisolated func artworkHeaders(for reference: ArtworkReference) async -> [String: String] {
        await kit.artworkHeaders(for: reference).dictionary
    }

    /// The gateway for values built without one: the shared profile's, created on first use. A test process
    /// gets an empty profile instead, so nothing reaches the owner's services from a test.
    public static func resolve() async -> ServiceGateway {
        if let override { return override }
        if TestProcess.isActive {
            if let testGateway { return testGateway }
            return await MainActor.run {
                if let testGateway { return testGateway }
                let gateway = ConfigStore(defaults: UserDefaults(suiteName: "ArrCoreTests.gateway")!).gateway
                testGateway = gateway
                return gateway
            }
        }
        if let current { return current }
        return await MainActor.run { current ?? ConfigStore.shared.gateway }
    }

    /// The gateway every facade resolves inside `withValue`: a fixture-backed run of the tools under test.
    @TaskLocal public static var override: ServiceGateway?

    /// A gateway on the bundled fixtures for `kinds`, independent of the global demo flag: the widget's demo and tests.
    /// It never becomes the process-wide gateway.
    public static func demo(kinds: Set<ServiceKind>) -> ServiceGateway {
        let store = ConfigStore(defaults: UserDefaults(suiteName: "pl.incred.ArrBarr.demo.fixtures")!, secrets: InMemorySecretStore())
        for kind in ServiceKind.allCases where kinds.contains(kind) {
            // A placeholder origin and key, so the profile counts as configured without the global demo flag.
            store.update(kind, with: ServiceConfig(enabled: true, baseURL: demoURL(kind.instanceKind).absoluteString, apiKey: "demo", username: "", password: ""))
        }
        for kind in ServiceKind.allCases where !kinds.contains(kind) { store.update(kind, with: .empty) }
        let hadCurrent = current != nil
        let gateway = ServiceGateway(configStore: store, demo: true)
        if !hadCurrent { current = nil }
        return gateway
    }

    /// A client built with a config that is not the saved one (a Settings draft, a test) gets its own instance.
    public func adopt(_ config: ServiceConfig, for kind: ServiceKind) async -> InstanceID {
        if config == configStore.config(for: kind) { return await saved(kind.instanceID) }
        let (ordinal, added): (Int, Bool) = adHoc.withLock { table in
            var list = table[kind] ?? []
            if let index = list.firstIndex(of: config) { return (index + 1, false) }
            list.append(config)
            table[kind] = list
            return (list.count, true)
        }
        let instance = InstanceID(kind.instanceKind, ordinal: ordinal)
        await ready()
        // A concurrent adopter may have appended the same draft; whoever finds it unregistered reconciles.
        if added || kit.registry.descriptor(instance) == nil { await reconcileRegistry() }
        return instance
    }

    /// A media server config that is not the saved one gets its own instance; the saved one stays ordinal 0.
    public func adopt(mediaServer config: MediaServerConfig) async -> InstanceID {
        if config == configStore.mediaServer { return await saved(config.kind.instanceID) }
        let (ordinal, added): (Int, Bool) = adHocServers.withLock { list in
            if let index = list.firstIndex(of: config) { return (index + 1, false) }
            list.append(config)
            return (list.count, true)
        }
        let instance = InstanceID(config.kind.instanceID.kind, ordinal: ordinal)
        await ready()
        if added || kit.registry.descriptor(instance) == nil { await reconcileRegistry() }
        return instance
    }

    /// A TMDB key that is not the saved one (Settings draft) gets its own instance.
    public func adopt(tmdbKey key: String) async -> InstanceID {
        if key == configStore.tmdbApiKey { return await saved(InstanceID(.tmdb)) }
        let (ordinal, added): (Int, Bool) = adHocTMDBKeys.withLock { list in
            if let index = list.firstIndex(of: key) { return (index + 1, false) }
            list.append(key)
            return (list.count, true)
        }
        let instance = InstanceID(.tmdb, ordinal: ordinal)
        await ready()
        if added || kit.registry.descriptor(instance) == nil { await reconcileRegistry() }
        return instance
    }

    /// Settings binds straight to the saved profile, so a Test can outrun the debounced reconcile.
    private func saved(_ instance: InstanceID) async -> InstanceID {
        await ready()
        if descriptors().first(where: { $0.id == instance }) != kit.registry.descriptor(instance) { await reconcileRegistry() }
        return instance
    }

    nonisolated func adHocServer(for instance: InstanceID) -> MediaServerConfig? {
        guard instance.ordinal > 0 else { return nil }
        return adHocServers.withLock { $0.indices.contains(instance.ordinal - 1) ? $0[instance.ordinal - 1] : nil }
    }

    nonisolated func adHocTMDBKey(for instance: InstanceID) -> String? {
        guard instance.ordinal > 0 else { return nil }
        return adHocTMDBKeys.withLock { $0.indices.contains(instance.ordinal - 1) ? $0[instance.ordinal - 1] : nil }
    }

    nonisolated func adHocConfig(for instance: InstanceID) -> ServiceConfig? {
        guard instance.ordinal > 0, let kind = ServiceKind(rawValue: instance.kind.rawValue) else { return nil }
        return adHoc.withLock { $0[kind].flatMap { $0.indices.contains(instance.ordinal - 1) ? $0[instance.ordinal - 1] : nil } }
    }

    public func start() async {
        started = true
        // Under tests the saved profile is registered only on an injected transport (see `descriptors`).
        let instances = descriptors()
        await kit.start(instances: instances)
        relayBreakers()
        if !TestProcess.isActive {
            await syncRealtime()
            #if DEBUG
            logTelemetryAfterLaunch()
            #endif
        }
        Self.log.notice("MediaKit started with \(instances.count, privacy: .public) instance(s), demo \(self.demo, privacy: .public)")
    }

    public func reconcile() async {
        guard started else { return }
        let changed = await reconcileRegistry()
        let connected = Set(realtime.keys)
        await syncRealtime()
        // An open socket keeps talking to the old host or key until it drops; a changed instance reconnects now.
        for id in changed.intersection(connected) { await realtime[id]?.forceReconnect() }
    }

    private var reconcileTask: Task<Set<InstanceID>, Never>?
    private var reconcileAgain = false

    /// One reconcile at a time; adopters arriving mid-run get a second pass instead of a concurrent one.
    /// Returns the instances whose origin or credentials changed.
    @discardableResult
    private func reconcileRegistry() async -> Set<InstanceID> {
        if let running = reconcileTask {
            reconcileAgain = true
            return await running.value
        }
        let task = Task { @MainActor in
            var changed: Set<InstanceID> = []
            repeat {
                reconcileAgain = false
                changed.formUnion(await kit.reconcile(descriptors()))
            } while reconcileAgain
            // Cleared in the same main-actor turn as the last check, so no caller can join a finished run.
            reconcileTask = nil
            return changed
        }
        reconcileTask = task
        return await task.value
    }

    /// iOS switches demo live (macOS relaunches). Transport and database belong to the stack, so it is replaced;
    /// whoever subscribed to the old one's hub re-subscribes (`QueueViewModel.demoModeChanged`).
    func rebuild(demo: Bool) async {
        guard demo != self.demo else { return }
        self.demo = demo
        for forward in pumping.values { forward.cancel() }
        pumping = [:]
        let (queues, progress) = streams.withLock { (Array($0.queue.values), $0.progress?.stream) }
        for stream in queues { await stream.stop() }
        await progress?.stop()
        await kit.stop()
        realtime = [:]
        let fresh = Self.makeKit(configStore: configStore, telemetry: telemetry, demo: demo, transport: transport)
        kitLock.withLock { $0 = fresh }
        guard started else { return }
        await kit.start(instances: descriptors())
        relayBreakers()
        await syncRealtime()
    }

    private var liveQueuesTask: Task<Void, Never>?
    private var wantedLiveQueues: (sources: [QueueItem.Source], activity: LiveActivity, policy: LivePolicy)?

    /// Run these arrs' queue streams on their own clock and pushes. Idempotent: called on every panel open and close.
    /// Calls overlap (panel, scene phase, config), and applying one awaits per stream, so the last request wins whole.
    public func setLiveQueues(sources: [QueueItem.Source], activity: LiveActivity, policy: LivePolicy) async {
        wantedLiveQueues = (sources, activity, policy)
        if liveQueuesTask == nil {
            liveQueuesTask = Task { @MainActor in
                while let wanted = wantedLiveQueues {
                    wantedLiveQueues = nil
                    await applyLiveQueues(sources: wanted.sources, activity: wanted.activity, policy: wanted.policy)
                }
                liveQueuesTask = nil
            }
        }
        await liveQueuesTask?.value
    }

    private func applyLiveQueues(sources: [QueueItem.Source], activity: LiveActivity, policy: LivePolicy) async {
        let events = kit.events
        await events.setForeground(activity == .foreground)
        let dropped = streams.withLock { streams in streams.queue.filter { !sources.contains($0.key) }.map(\.value) }
        for stream in dropped {
            guard let forward = pumping.removeValue(forKey: ObjectIdentifier(stream)) else { continue }
            forward.cancel()
            await stream.stop()
        }
        // A just-configured arr reaches here before the debounced reconcile registers it; its first fetch needs it.
        let starting = sources.filter { source in streams.withLock { $0.queue[source] }.map { pumping[ObjectIdentifier($0)] == nil } ?? true }
        if !starting.isEmpty, started { await reconcileRegistry() }
        for source in sources {
            let stream = queueStream(source)
            await stream.setPolicy(policy)
            await stream.setActivity(activity)
            let key = ObjectIdentifier(stream)
            guard pumping[key] == nil else { continue }
            pumping[key] = Task { @MainActor [weak self] in
                for await _ in await stream.values() { self?.yieldQueueUpdate(source) }
            }
            await events.register(stream)
            await stream.start()
        }
    }

    /// Yields an arr whenever its queue stream publishes, across demo rebuilds; read the rows from `queueStream`.
    public func queueUpdates() -> AsyncStream<QueueItem.Source> {
        let (stream, continuation) = AsyncStream<QueueItem.Source>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        queueUpdateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.queueUpdateContinuations[id] = nil } }
        return stream
    }

    private func yieldQueueUpdate(_ source: QueueItem.Source) {
        for continuation in queueUpdateContinuations.values { continuation.yield(source) }
    }

    /// Yields whenever some host's breaker opens or closes, across demo rebuilds; read `hostHealth(of:)` on each tick.
    public func breakerChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        breakerContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.breakerContinuations[id] = nil } }
        return stream
    }

    /// The governor publishes on every request; only a breaker transition reaches the main actor.
    private func relayBreakers() {
        breakerRelay?.cancel()
        let governor = kit.governor
        breakerRelay = Task { [weak self] in
            var open: Set<MediaKit.Host> = []
            for await (host, health) in await governor.healthUpdates() {
                let isDown = if case .down = health { true } else { false }
                guard isDown != open.contains(host) else { continue }
                if isDown { open.insert(host) } else { open.remove(host) }
                guard let self else { return }
                for continuation in self.breakerContinuations.values { continuation.yield() }
            }
        }
    }

    /// The governor's passive view of the host behind a monitored service; OpenAI never goes through MediaKit.
    public func hostHealth(of service: MonitoredService) -> HostHealth {
        switch service {
        case .arr(let kind): kit.health(of: kind.instanceID)
        case .tmdb: kit.health(of: InstanceID(.tmdb))
        case .mediaServer: kit.health(of: configStore.mediaServer.kind.instanceID)
        case .prowlarr: kit.health(of: InstanceID(.prowlarr))
        case .openai: .unknown
        }
    }

    /// The widget reads the app's stored rows and refetches what is stale; it runs no hubs, probes or sweeps.
    nonisolated static let isAppExtension = Bundle.main.bundlePath.hasSuffix(".appex")

    private func syncRealtime() async {
        guard !Self.isAppExtension else { return }
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

    #if DEBUG
    /// Request volume of the first minute, counts only.
    private func logTelemetryAfterLaunch() {
        Task { [telemetry] in
            try? await Task.sleep(for: .seconds(60))
            let (hosts, caches, operations) = telemetry.totals()
            let top = operations.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                .prefix(12).map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
            Self.log.notice("telemetry 60 s after launch: requests \(hosts.requests, privacy: .public) failures \(hosts.failures, privacy: .public) skipped \(hosts.skipped, privacy: .public) bytes \(hosts.bytes, privacy: .public) cache hits \(caches.hits, privacy: .public) misses \(caches.misses, privacy: .public) stale \(caches.staleServed, privacy: .public) coalesced \(caches.coalesced, privacy: .public) top \(top, privacy: .public)")
        }
    }
    #endif

    /// Retention sweep of the SQLite resource store, beside the poster sweep.
    public nonisolated func sweepDataCache() async { await kit.store.sweep() }

    public nonisolated func purgeDataCache() async { await kit.store.purgeAll() }

    public nonisolated func dataCacheBytes() async -> Int64 {
        let stats = await kit.store.statistics()
        return Int64(stats.bytes + stats.memoryBytes)
    }

    public func systemDidWake() async {
        await kit.governor.noteWake(at: Date())
        await kit.events.wakeAll()
    }

    public nonisolated func servarr(_ source: QueueItem.Source) -> ServarrService { kit.servarr(source.instanceID)! }

    /// Runs a write and lays the row changes it promises over the live streams, which drop them once the source agrees.
    @discardableResult
    nonisolated func run(_ command: Command) async throws -> CommandReceipt {
        let receipt = try await store.run(command)
        guard !command.effects.isEmpty else { return receipt }
        let (queues, progress) = streams.withLock { (Array($0.queue.values), $0.progress?.stream) }
        for effect in command.effects {
            for stream in queues { await stream.apply(effect) }
            await progress?.apply(effect)
        }
        return receipt
    }

    public nonisolated func queueStream(_ source: QueueItem.Source) -> LiveStream<ArrQueueRecord> {
        let kit = self.kit
        return streams.withLock { streams in
            streams.adopt(kit)
            if let stream = streams.queue[source] { return stream }
            let stream = kit.liveQueue(instances: [source.instanceID])
            streams.queue[source] = stream
            return stream
        }
    }

    public nonisolated func progressStream(instances: [InstanceID]) -> LiveStream<DownloadTask> {
        let kit = self.kit
        return streams.withLock { streams in
            streams.adopt(kit)
            if let progress = streams.progress, progress.instances == instances { return progress.stream }
            let stream = kit.liveProgress(instances: instances)
            streams.progress = (instances, stream)
            return stream
        }
    }
    public nonisolated func download(_ kind: ServiceKind) -> (any DownloadService)? { kit.download(kind.instanceID) }
    /// Internal: `ProwlarrClient` is the door, the way `servarr` is for the arrs.
    var prowlarr: ProwlarrService? {
        configStore.prowlarr.isConfigured ? kit.prowlarr : nil
    }
    public nonisolated var store: ResourceStore { kit.store }
    public nonisolated var events: EventHub { kit.events }

    public nonisolated func isConfigured(_ source: QueueItem.Source) -> Bool {
        kit.registry.descriptor(source.instanceID)?.enabled ?? false
    }

    public nonisolated func isConfigured(_ instance: InstanceID) -> Bool {
        kit.registry.descriptor(instance)?.enabled ?? false
    }

    // MARK: - Assembly

    private static func makeKit(configStore: ConfigStore, telemetry: TelemetryRecorder, demo: Bool, transport: (any Transport)?) -> MediaStack {
        let credentials = ConfigCredentialProvider(configStore: configStore, demo: demo)
        var configuration: MediaStack.Configuration
        if demo {
            configuration = MediaStack.Configuration(transport: FixtureTransport(), sockets: nil, credentials: credentials)
            configuration.database = .memory
        } else if let transport {
            configuration = MediaStack.Configuration(transport: transport, sockets: nil, credentials: credentials)
            configuration.database = .memory
            configuration.readPolicyOverride = .mustRevalidate
        } else {
            // Tests reach a service only through an injected transport; `.shared` keeps the rest off the app's cookie jar.
            let plain = URLSessionTransport(session: TestProcess.isActive ? .shared : URLSessionTransport.makeSession(cookies: false))
            let cookies = URLSessionTransport(session: TestProcess.isActive ? .shared : URLSessionTransport.makeSession(cookies: true))
            let transport = CookieSplittingTransport(plain: plain, cookies: cookies)
            configuration = MediaStack.Configuration(transport: transport, sockets: plain, credentials: credentials)
            configuration.database = TestProcess.isActive ? .memory : databaseLocation()
            if TestProcess.isActive { configuration.readPolicyOverride = .mustRevalidate }
        }
        configuration.role = isAppExtension ? .snapshotReader : .app
        configuration.telemetry = telemetry
        configuration.log = OSLogSink(subsystem: AppLog.subsystem)
        configuration.signposts = OSSignposter(subsystem: AppLog.subsystem, category: "MediaKit")
        configuration.mediaServerUserID = configStore.mediaServer.userId.isEmpty ? nil : configStore.mediaServer.userId
        do { return try MediaStack(configuration) } catch {
            log.error("MediaKit database unavailable, running in memory: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
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

    /// The demo profile has no hosts; every enabled kind gets a placeholder origin that only the fixture transport sees.
    nonisolated static func demoURL(_ kind: InstanceKind) -> URL { URL(string: "http://\(kind.rawValue).demo.invalid")! }

    private func descriptors() -> [InstanceDescriptor] {
        var out: [InstanceDescriptor] = []
        for kind in ServiceKind.allCases {
            let config = configStore.config(for: kind)
            if demo {
                if config.enabled { out.append(InstanceDescriptor(id: kind.instanceID, baseURL: Self.demoURL(kind.instanceKind), enabled: true, generation: "demo")) }
                continue
            }
            // A test registers the saved profile only on its own transport, so nothing reaches a real server.
            if !TestProcess.isActive || transport != nil, let url = URL(string: config.baseURL), config.isConfigured {
                let generation = SecretGenerations.generation(for: .apiKey(for: kind), in: configStore.defaultsForGateway)
                    + "." + SecretGenerations.generation(for: .password(for: kind), in: configStore.defaultsForGateway)
                out.append(InstanceDescriptor(id: kind.instanceID, baseURL: url, enabled: config.isUsable(as: kind), generation: generation))
            }
            for (index, draft) in (adHoc.withLock { $0[kind] } ?? []).enumerated() {
                guard let url = URL(string: draft.baseURL), draft.isConfigured else { continue }
                out.append(InstanceDescriptor(id: InstanceID(kind.instanceKind, ordinal: index + 1), baseURL: url, enabled: draft.isUsable(as: kind), generation: "draft"))
            }
        }
        let server = configStore.mediaServer
        if demo {
            if server.enabled { out.append(InstanceDescriptor(id: server.kind.instanceID, baseURL: Self.demoURL(server.kind.instanceID.kind), enabled: true, generation: "demo")) }
            out.append(InstanceDescriptor(id: InstanceID(.tmdb), baseURL: Self.demoURL(.tmdb), enabled: true, generation: "demo"))
            return out
        }
        if !TestProcess.isActive, server.isConfigured, let url = URL(string: server.baseURL) {
            out.append(InstanceDescriptor(id: server.kind.instanceID, baseURL: url, enabled: true,
                                          generation: SecretGenerations.generation(for: .mediaServerToken, in: configStore.defaultsForGateway)))
        }
        for (index, draft) in adHocServers.withLock({ $0 }).enumerated() where draft.isConfigured {
            guard let url = URL(string: draft.baseURL) else { continue }
            out.append(InstanceDescriptor(id: InstanceID(draft.kind.instanceID.kind, ordinal: index + 1), baseURL: url, enabled: true, generation: "draft"))
        }
        let prowlarr = configStore.prowlarr
        if !TestProcess.isActive, prowlarr.isConfigured, let url = URL(string: prowlarr.baseURL) {
            out.append(InstanceDescriptor(id: InstanceID(.prowlarr), baseURL: url, enabled: true,
                                          generation: SecretGenerations.generation(for: .prowlarrKey, in: configStore.defaultsForGateway)))
        }
        let tmdbURL = URL(string: "https://api.themoviedb.org")!
        if !TestProcess.isActive, !configStore.tmdbApiKey.isEmpty {
            out.append(InstanceDescriptor(id: InstanceID(.tmdb), baseURL: tmdbURL, enabled: true,
                                          generation: SecretGenerations.generation(for: .tmdbKey, in: configStore.defaultsForGateway)))
        }
        for index in adHocTMDBKeys.withLock({ $0 }).indices {
            out.append(InstanceDescriptor(id: InstanceID(.tmdb, ordinal: index + 1), baseURL: tmdbURL, enabled: true, generation: "draft"))
        }
        return out
    }

    /// Everything `descriptors()` reads from the profile.
    nonisolated private struct Registered: Equatable, Sendable {
        let services: [ServiceConfig]
        let mediaServer: MediaServerConfig
        let tmdbKey: String
        let prowlarr: ServiceConfig
    }

    private func observe() {
        let store = configStore
        observer = observeChanges(of: {
            Registered(services: ServiceKind.allCases.map(store.config(for:)), mediaServer: store.mediaServer,
                       tmdbKey: store.tmdbApiKey, prowlarr: store.prowlarr)
        }, debounce: .seconds(1.5)) { [weak self] _ in Task { await self?.reconcile() } }
    }
}

/// qBittorrent and Deluge hold a cookie session; every other service gets the cookie-free session.
private struct CookieSplittingTransport: Transport {
    let plain: URLSessionTransport
    let cookies: URLSessionTransport
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.operation.kind {
        case .qbittorrent, .deluge: return try await cookies.send(request)
        default: return try await plain.send(request)
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
        if demo { return Credentials(baseURL: ServiceGateway.demoURL(instance.kind), material: .apiKey("demo"), generation: "demo") }
        let defaults = configStore.defaultsForGateway
        switch instance.kind {
        case .plex, .jellyfin, .emby:
            let draft = configStore.gateway.adHocServer(for: instance)
            let server = draft ?? configStore.mediaServer
            guard server.isConfigured, let url = URL(string: server.baseURL) else { return nil }
            return Credentials(baseURL: url, material: .token(server.token),
                               generation: draft == nil ? SecretGenerations.generation(for: .mediaServerToken, in: defaults) : "draft")
        case .prowlarr:
            let config = configStore.prowlarr
            guard config.isConfigured, let url = URL(string: config.baseURL) else { return nil }
            return Credentials(baseURL: url, material: .apiKey(config.apiKey),
                               generation: SecretGenerations.generation(for: .prowlarrKey, in: defaults))
        case .tmdb:
            let draft = configStore.gateway.adHocTMDBKey(for: instance)
            let key = draft ?? configStore.tmdbApiKey
            guard !key.isEmpty else { return nil }
            return Credentials(baseURL: URL(string: "https://api.themoviedb.org")!, material: .apiKey(key),
                               generation: draft == nil ? SecretGenerations.generation(for: .tmdbKey, in: defaults) : "draft")
        default:
            guard let kind = ServiceKind(rawValue: instance.kind.rawValue) else { return nil }
            let draft = configStore.gateway.adHocConfig(for: instance)
            let config = draft ?? configStore.config(for: kind)
            guard let url = URL(string: config.baseURL) else { return nil }
            let material: Credentials.Material
            if kind.requiresApiKey || (kind == .qbittorrent && !config.apiKey.isEmpty) {
                material = .apiKey(config.apiKey)
            } else {
                material = .userPassword(user: config.username, password: config.password)
            }
            let generation = draft == nil
                ? SecretGenerations.generation(for: .apiKey(for: kind), in: defaults) + "." + SecretGenerations.generation(for: .password(for: kind), in: defaults)
                : "draft"
            return Credentials(baseURL: url, material: demo ? .apiKey("demo") : material, generation: generation)
        }
    }
}

nonisolated private struct LiveStreams {
    var kit: ObjectIdentifier?
    var queue: [QueueItem.Source: LiveStream<ArrQueueRecord>] = [:]
    var progress: (instances: [InstanceID], stream: LiveStream<DownloadTask>)?

    mutating func adopt(_ stack: MediaStack) {
        guard kit != ObjectIdentifier(stack) else { return }
        self = LiveStreams(kit: ObjectIdentifier(stack))
    }
}
