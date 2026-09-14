import Foundation
import Combine
import MediaKit

/// The app's composition root for MediaKit: builds the provider list out of
/// whatever is configured right now and hands the views one graph to ask.
///
/// Everything credential-shaped stays on this side of the line — the TMDB key
/// out of `TonightConfig` (a plain file: no Keychain under ad-hoc signing) and
/// the Radarr URL/key out of ArrBarr's defaults. MediaKit is handed values and
/// never goes looking for them.
@MainActor
public final class MediaStack: ObservableObject {
    public static let shared = MediaStack()

    /// Rebuilt whenever the configuration behind it changes, so a pasted TMDB
    /// key or a re-pointed Radarr takes effect without a relaunch.
    @Published public private(set) var graph: MediaGraph

    /// Debug mode, remembered across launches. `MEDIAKIT_DEBUG=1` in the
    /// environment turns it on for a single run without touching the setting.
    @Published public var telemetryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(telemetryEnabled, forKey: Self.telemetryKey)
            Task { await MediaTelemetry.shared.setEnabled(telemetryEnabled) }
        }
    }

    /// The single media-server connection. One instance, because it holds a
    /// library sweep of a few thousand titles and sweeping twice for the same
    /// answers is the waste this layer exists to remove.
    @Published public private(set) var mediaServer: MediaServerProvider?

    private static let telemetryKey = "debug.mediaTelemetry"
    private let cache = FragmentCache(telemetry: MediaTelemetry.shared)
    private var fingerprint = ""
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.bool(forKey: Self.telemetryKey)
        let environment = ProcessInfo.processInfo.environment["MEDIAKIT_DEBUG"] == "1"
        telemetryEnabled = stored || environment
        graph = MediaGraph(providers: [], cache: cache, telemetry: MediaTelemetry.shared)

        let enabled = telemetryEnabled
        Task { await MediaTelemetry.shared.setEnabled(enabled) }
        rebuild()
    }

    /// Follow the config object so the graph tracks the key and region the
    /// user is actually using.
    public func track(_ config: TonightConfig) {
        config.objectWillChange
            .sink { [weak self] _ in
                // objectWillChange fires before the value lands; rebuild on
                // the next turn so the new key is the one we read.
                Task { @MainActor in self?.rebuild(config) }
            }
            .store(in: &cancellables)
        rebuild(config)
    }

    private func rebuild(_ config: TonightConfig? = nil) {
        let config = config ?? TonightConfig.shared
        let radarr = ArrBarrProfile.service(.radarr)
            .map { ProviderCredentials(baseURL: $0.baseURL, apiKey: $0.apiKey) }
        let sonarr = ArrBarrProfile.service(.sonarr)
            .map { ProviderCredentials(baseURL: $0.baseURL, apiKey: $0.apiKey) }

        // Cheap identity of the whole setup: rebuilding on every config
        // notification would throw the cache away on each keystroke in
        // Settings.
        let stamp = """
            \(config.tmdbApiKey.count)|\(config.watchRegion)|\
            \(radarr?.fingerprint ?? "-")|\(sonarr?.fingerprint ?? "-")
            """
        guard stamp != fingerprint else { return }
        fingerprint = stamp

        let telemetry = MediaTelemetry.shared
        var providers: [any MediaProvider] = [
            TMDBProvider(apiKey: config.tmdbApiKey,
                         region: config.watchRegion,
                         telemetry: telemetry),
        ]
        if let radarr {
            providers.append(RadarrProvider(credentials: radarr, telemetry: telemetry))
        }
        if let sonarr {
            // Series live here: Radarr answers for films only, and before
            // this the whole TV half of the app had no library source at all.
            providers.append(SonarrProvider(credentials: sonarr, telemetry: telemetry))
        }
        // Plex / Jellyfin / Emby: the only source of the user's own artwork
        // (poster, backdrop and clear logo) and of what they have watched.
        if let server = Self.mediaServerProvider(telemetry: telemetry) {
            mediaServer = server
            providers.append(server)
        } else {
            mediaServer = nil
        }
        // The arrs' half of "do I have this", read from the app's existing
        // index — no network of its own.
        providers.append(LibraryPresenceProvider())

        graph = MediaGraph(providers: providers,
                           resolvers: [
                               // Sonarr can only be asked in TVDB terms.
                               TMDBIdentityResolver(apiKey: config.tmdbApiKey,
                                                    telemetry: telemetry),
                           ],
                           cache: cache,
                           telemetry: telemetry,
                           fingerprints: [
                               .radarr: radarr?.fingerprint ?? "-",
                               .sonarr: sonarr?.fingerprint ?? "-",
                           ])
    }

    /// Build the media-server provider from ArrBarr's connection, if there
    /// is one. The Jellyfin/Emby user id (play state is per user) comes from
    /// ArrCore's handshake and is filled in asynchronously — artwork does not
    /// wait for it.
    private static func mediaServerProvider(telemetry: MediaTelemetry) -> MediaServerProvider? {
        guard let config = ArrBarrProfile.mediaServerConfig(),
              let baseURL = URL(string: config.baseURL) else { return nil }
        let flavor: MediaServerFlavor = switch config.kind {
        case .plex: .plex
        case .jellyfin: .jellyfin
        case .emby: .emby
        }
        return MediaServerProvider(flavor: flavor,
                                   baseURL: baseURL,
                                   token: config.token,
                                   userID: nil,
                                   telemetry: telemetry)
    }

    /// Ask for fields about one title. The view says what it needs; who
    /// answers is the graph's business.
    public func snapshot(for item: MediaItem,
                         fields: MediaFieldSet,
                         policy: FreshnessPolicy = .default) async -> MediaSnapshot {
        await graph.fetch(item.identity, fields: fields, policy: policy)
    }

    /// A browse, a shelf, a search — one page of titles, already carrying
    /// whatever the source knew and topped up from the local providers.
    ///
    /// Views get `MediaItem`s back: the layer's snapshots stay inside the
    /// layer until the app is ready to bind to them directly.
    public func titles(_ query: MediaCatalogQuery,
                       enrich: MediaFieldSet = .availability,
                       policy: FreshnessPolicy = .default) async throws -> TitlePage {
        do {
            return try await page(query, enrich: enrich, policy: policy)
        } catch MediaError.noSource(let detail) {
            // The graph was built before the configuration was: a key pasted
            // in Settings, an import from ArrBarr, a provider list assembled
            // during launch. Rebuild once and ask again rather than leaving
            // the screen parked on an error the user cannot clear.
            rebuildNow()
            do {
                return try await page(query, enrich: enrich, policy: policy)
            } catch MediaError.noSource {
                throw MediaError.noSource(detail)
            }
        }
    }

    private func page(_ query: MediaCatalogQuery, enrich: MediaFieldSet,
                      policy: FreshnessPolicy) async throws -> TitlePage {
        let page = try await graph.catalog(query, enrich: enrich, policy: policy)
        return TitlePage(items: page.items.compactMap(MediaItem.init),
                         hasMore: page.hasMore,
                         unappliedFilters: page.unappliedFilters)
    }

    /// Rebuild the provider list even if the configuration looks unchanged.
    public func rebuildNow() {
        fingerprint = ""
        rebuild()
    }

    public struct TitlePage: Sendable {
        public let items: [MediaItem]
        public let hasMore: Bool
        /// Filters the source silently ignored — the caller decides whether
        /// that is worth telling the user.
        public let unappliedFilters: [String]
    }

    public func usageReport() async -> MediaUsageReport {
        await MediaTelemetry.shared.report()
    }

    public func resetUsage() async {
        await MediaTelemetry.shared.reset()
    }

    /// Drop everything cached for one title — after marking it watched, or
    /// adding it somewhere, when the next read must not be the old answer.
    public func invalidate(_ item: MediaItem) async {
        await graph.invalidate(item.identity)
    }
}
