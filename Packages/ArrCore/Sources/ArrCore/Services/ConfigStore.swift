import Foundation
import Observation

#if canImport(WidgetKit)
import WidgetKit
#endif

@Observable
public final class ConfigStore {
    @MainActor public static let shared = ConfigStore()

    public var radarr: ServiceConfig = .empty { didSet { persist(.radarr, radarr, oldValue) } }
    public var sonarr: ServiceConfig = .empty { didSet { persist(.sonarr, sonarr, oldValue) } }
    public var lidarr: ServiceConfig = .empty { didSet { persist(.lidarr, lidarr, oldValue) } }
    public var whisparr: ServiceConfig = .empty { didSet { persist(.whisparr, whisparr, oldValue) } }
    public var sabnzbd: ServiceConfig = .empty { didSet { persist(.sabnzbd, sabnzbd, oldValue) } }
    public var qbittorrent: ServiceConfig = .empty { didSet { persist(.qbittorrent, qbittorrent, oldValue) } }
    public var nzbget: ServiceConfig = .empty { didSet { persist(.nzbget, nzbget, oldValue) } }
    public var transmission: ServiceConfig = .empty { didSet { persist(.transmission, transmission, oldValue) } }
    public var rtorrent: ServiceConfig = .empty { didSet { persist(.rtorrent, rtorrent, oldValue) } }
    public var deluge: ServiceConfig = .empty { didSet { persist(.deluge, deluge, oldValue) } }
    /// Hard-locked and slow on purpose: progress bars interpolate between readings
    /// and real changes arrive by SignalR push, so the fetch only keeps facts current.
    public let foregroundInterval: TimeInterval = 30
    /// Fallback poll while the panel is closed, used only when realtime has gone
    /// quiet for every source.
    public let backgroundInterval: TimeInterval = 30
    /// Silence before realtime is distrusted. Servarr's `RefreshMonitoredDownloads`
    /// broadcasts the queue every minute by default, so a healthy hub is never quiet this long.
    public let realtimeSilenceTimeout: TimeInterval = 300
    /// Off by default: unlike every other notification, the user never asked for this one.
    public var notifyHealth: Bool = false { didSet { persist(notifyHealth, oldValue, Keys.notifyHealth) } }
    public var notifyRadarr: Bool = true { didSet { persist(notifyRadarr, oldValue, Keys.notifyRadarr) } }
    public var notifySonarr: Bool = true { didSet { persist(notifySonarr, oldValue, Keys.notifySonarr) } }
    public var notifyLidarr: Bool = true { didSet { persist(notifyLidarr, oldValue, Keys.notifyLidarr) } }
    /// `""` = system default, `ConfigStore.silentSoundName` = no sound, otherwise
    /// the bare name of a sound in `/System/Library/Sounds`.
    public var notificationSoundName: String = "" { didSet { persist(notificationSoundName, oldValue, Keys.notificationSoundName) } }
    public var blurWhisparrPosters: Bool = true { didSet { persist(blurWhisparrPosters, oldValue, Keys.blurWhisparrPosters) } }
    public var showWatchedIndicator: Bool = true { didSet { persist(showWatchedIndicator, oldValue, Keys.showWatchedIndicator) } }
    /// App Store builds gate enabling Whisparr behind an 18+ confirmation.
    public var whisparrAgeConfirmed: Bool = false { didSet { persist(whisparrAgeConfirmed, oldValue, Keys.whisparrAgeConfirmed) } }
    /// Multiplier applied to every `.scaledFont(size:)` site; `1.0` is the native sizing.
    public var fontScale: Double = 1.0 { didSet { persist(fontScale, oldValue, Keys.fontScale) } }
    public var aiKnowsAboutWhisparr: Bool = false { didSet { persist(aiKnowsAboutWhisparr, oldValue, Keys.aiKnowsAboutWhisparr) } }
    /// macOS only: run as a regular Dock app with a real window and no menu-bar icon.
    public var detachedWindow: Bool = false { didSet { persist(detachedWindow, oldValue, Keys.detachedWindow) } }
    /// Raw value of the popover tab selected when the panel is built.
    public var launchTab: String = "Queue" { didSet { persist(launchTab, oldValue, Keys.launchTab) } }
    /// macOS only: a clicked Spotlight result opens the detail in-app instead of the arr's web UI.
    public var spotlightOpensInApp: Bool = true { didSet { persist(spotlightOpensInApp, oldValue, Keys.spotlightOpensInApp) } }
    public var iCloudSyncEnabled: Bool = true {
        didSet {
            guard !isLoading, iCloudSyncEnabled != oldValue else { return }
            defaults.set(iCloudSyncEnabled, forKey: Self.iCloudSyncEnabledKey)
            guard AppCapabilities.isAppStore else { return }
            KVSyncCoordinator.shared?.setEnabled(iCloudSyncEnabled)
            secrets.reapplySyncAttribute(for: SecretKey.syncable)
        }
    }
    public var appLanguage: String = "system" {
        didSet {
            guard !isLoading, appLanguage != oldValue else { return }
            defaults.set(appLanguage, forKey: Self.appLanguageKey)
            Self.applyAppLanguage(appLanguage)
        }
    }
    /// UI appearance preference: "system" / "light" / "dark".
    public var appearance: String = "system" { didSet { persist(appearance, oldValue, Keys.appearance) } }
    public var arrOrder: [String] = ConfigStore.defaultArrOrder { didSet { persist(arrOrder, oldValue, Keys.arrOrder) } }
    public var showTonight: Bool = true { didSet { persist(showTonight, oldValue, Keys.showTonight) } }
    public var showNeedsYou: Bool = true { didSet { persist(showNeedsYou, oldValue, Keys.showNeedsYou) } }
    /// Warning-level health checks join the always-shown errors in "Needs you".
    /// Legacy name from an indexer-only toggle; the persisted key is kept.
    public var showWarnings: Bool = true { didSet { persist(showWarnings, oldValue, Keys.showIndexerIssues) } }
    /// 0 = all (no Show more/less at all).
    public var tonightVisibleCount: Int = 3 { didSet { persist(tonightVisibleCount, oldValue, Keys.tonightVisibleCount) } }
    /// `nil` means the welcome screen was never seen; first launch shows the firstRun variant.
    public var welcomeSeenVersion: String? = nil {
        didSet {
            guard !isLoading, welcomeSeenVersion != oldValue else { return }
            defaults.set(welcomeSeenVersion, forKey: Keys.welcomeSeenVersion)
        }
    }
    public var aiEnabled: Bool = false { didSet { persist(aiEnabled, oldValue, Keys.aiEnabled) } }
    public var chatProvider: ChatProvider = .foundationModels { didSet { persist(chatProvider.rawValue, oldValue.rawValue, Keys.chatProvider) } }
    public var openai: OpenAIConfig = .empty {
        didSet {
            guard !isLoading, openai != oldValue else { return }
            setOrDelete(openai.apiKey, for: .openAIKey)
            var stripped = openai
            stripped.apiKey = ""
            store(stripped, forKey: Self.openaiConfigKey)
        }
    }
    /// Empty disables the TMDB-backed chat tools.
    public var tmdbApiKey: String = "" {
        didSet {
            guard !isLoading, tmdbApiKey != oldValue else { return }
            setOrDelete(tmdbApiKey, for: .tmdbKey)
            defaults.removeObject(forKey: Self.tmdbApiKeyKey)
        }
    }

    /// Used only as a name service: the arrs report indexers under the sync
    /// template's name, and only Prowlarr knows what the user called them.
    public var prowlarr: ServiceConfig = ServiceConfig(enabled: false, baseURL: "", apiKey: "", username: "", password: "") {
        didSet {
            guard !isLoading, prowlarr != oldValue else { return }
            setOrDelete(prowlarr.apiKey, for: .prowlarrKey)
            var stripped = prowlarr
            stripped.apiKey = ""
            store(stripped, forKey: Self.prowlarrKey)
        }
    }

    /// The one media server (Plex / Jellyfin / Emby) for artwork and watch state.
    public var mediaServer: MediaServerConfig = .empty {
        didSet {
            guard !isLoading, mediaServer != oldValue else { return }
            setOrDelete(mediaServer.token, for: .mediaServerToken)
            var stripped = mediaServer
            stripped.token = ""
            store(stripped, forKey: Self.mediaServerKey)
        }
    }

    // MARK: - MCP server
    // On macOS the AppDelegate restarts `MCPServerController` whenever these change.
    public var mcpEnabled: Bool = false { didSet { persist(mcpEnabled, oldValue, Keys.mcpEnabled) } }
    /// Defaults to localhost only; `0.0.0.0` is an explicit opt-in.
    public var mcpHostPort: String = "127.0.0.1:8080" { didSet { persist(mcpHostPort, oldValue, Keys.mcpHostPort) } }
    /// The server also refuses non-loopback binds without auth.
    public var mcpRequireAuth: Bool = true { didSet { persist(mcpRequireAuth, oldValue, Keys.mcpRequireAuth) } }
    /// Mirrors the Keychain; the token never lives in UserDefaults.
    public var mcpAuthToken: String = MCPTokenStore.read() ?? "" {
        didSet {
            guard !isLoading, mcpAuthToken != oldValue else { return }
            if mcpAuthToken.isEmpty { MCPTokenStore.delete() } else { MCPTokenStore.set(mcpAuthToken) }
        }
    }
    /// Tool names the user switched off; empty = every catalog tool is exposed.
    public var mcpDisabledTools: Set<String> = [] { didSet { persist(Array(mcpDisabledTools).sorted(), Array(oldValue).sorted(), Keys.mcpDisabledTools) } }

    public static let needsYouOrderKey = "needsyou"
    public static let tonightOrderKey = "tonight"
    public static let defaultArrOrder = ["tonight", "needsyou", "radarr", "sonarr", "lidarr", "whisparr"]
    /// Picker options for `tonightVisibleCount` — 0 renders as "All".
    public static let tonightVisibleOptions = [3, 5, 0]

    public static let appLanguageOptions: [(code: String, label: String)] = [
        ("system", "System"),
        ("en", "English"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
    ]

    public var currentLocale: Locale {
        if appLanguage == "system" { return .autoupdatingCurrent }
        return Locale(identifier: appLanguage)
    }

    /// Apply the in-app language to the process so model-layer `String(localized:)`
    /// follows it too; Foundation only reads `.standard`, never the group suite. Call before the first lookup.
    nonisolated public static func applyAppLanguageToProcess() {
        applyAppLanguage(resolveDefaults().string(forKey: appLanguageKey) ?? "system")
    }

    /// Foundation Models is keyless; an enabled-but-keyless OpenAI config counts as AI off.
    public var aiConfigured: Bool {
        guard aiEnabled else { return false }
        // Demo chat runs on DemoChatProvider, which needs no key and no Apple Intelligence.
        if DemoMode.isActive { return true }
        switch chatProvider {
        case .foundationModels: return FoundationModelsAvailability.isSupported
        case .openai:           return openai.isConfigured
        }
    }

    /// iOS has no text-size picker and the shared sizes read small on phone, so a fixed bump.
    public var effectiveFontScale: Double {
        #if os(iOS)
        return 1.1
        #else
        return fontScale
        #endif
    }

    @ObservationIgnored var defaults: UserDefaults
    var defaultsForGateway: UserDefaults { defaults }
    /// The MediaKit assembly for this profile; created on first use, rebuilt when demo mode toggles.
    @ObservationIgnored @MainActor public internal(set) lazy var gateway = ServiceGateway(configStore: self)
    /// Follows the backing store (`useStore`) so demo mode never writes the real profile's secrets.
    @ObservationIgnored var secrets: SecretStore
    /// Stops a load writing back what it just read (and echoing an iCloud change back to iCloud).
    /// `true` because the first load runs in `init`.
    @ObservationIgnored var isLoading = true

    /// Demo suite while demo is active, otherwise the App Group suite (`.standard` in tests).
    /// Only the host app migrates: an extension's `.standard` is a different, empty container.
    nonisolated public static func resolveDefaults() -> UserDefaults {
        if DemoMode.isActive, let demo = DemoMode.demoDefaults { return demo }
        guard let group = WidgetDataStore.groupDefaults() else { return .standard }
        if !isAppExtension { migrateToGroupSuite(from: .standard, to: group) }
        return group
    }

    nonisolated static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// Idempotent, `ArrBarr.*`-scoped copy into the group suite; never touches the demo suite.
    public nonisolated static func migrateToGroupSuite(from source: UserDefaults, to group: UserDefaults) {
        guard !group.bool(forKey: groupMigrationDoneKey) else { return }
        for (key, value) in source.dictionaryRepresentation() where key.hasPrefix("ArrBarr.") {
            group.set(value, forKey: key)
        }
        group.set(true, forKey: groupMigrationDoneKey)
    }

    // nonisolated: read by the migration helpers and the widget extension.
    nonisolated private static let groupMigrationDoneKey = "ArrBarr.groupMigrationDone"
    nonisolated static let secretsMigratedKey = "ArrBarr.secretsMigratedToKeychain"
    // periphery:ignore
    nonisolated static var groupMigrationDoneKeyForTesting: String { groupMigrationDoneKey }
    // periphery:ignore
    nonisolated static var secretsMigratedKeyForTesting: String { secretsMigratedKey }
    // periphery:ignore
    nonisolated static func serviceKeyForTesting(_ kind: ServiceKind) -> String { key(kind) }

    public init(defaults: UserDefaults = ConfigStore.resolveDefaults(),
                secrets: SecretStore? = nil) {
        self.defaults = defaults
        let store = secrets ?? Self.makeDefaultSecretStore(defaults: defaults)
        self.secrets = store
        // Branch on the store we got, not capability flags: an injected store must never
        // be mistaken for the Keychain, or the plaintext sweep would alias onto itself.
        if store is KeychainSecretStore {
            Self.migrateSecretsToKeychain(defaults: defaults, secrets: store)
            Self.migratePlaintextSecretsIntoKeychain(defaults: defaults, keychain: store)
        } else {
        // Ad-hoc builds can't reach the Keychain; pull back secrets an earlier build moved there.
            Self.recoverSecretsFromKeychainIfNeeded(defaults: defaults, secrets: store)
        }
        applyValues(from: defaults)
    }

    public func useDemoStore(_ on: Bool) {
        useStore(on ? (DemoMode.demoDefaults ?? .standard) : (WidgetDataStore.groupDefaults() ?? .standard))
        // The widget extension can't see the app's `.standard`; mirror demo state into the group suite.
        WidgetDataStore.setDemoActive(on)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Test seam.
    func useStore(_ target: UserDefaults) {
        guard target !== defaults else { return }
        defaults = target
        secrets = Self.makeDefaultSecretStore(defaults: target)
        applyValues(from: target)
        QueueUIState.shared.use(target)
    }

    public func reloadFromDefaults() {
        applyValues(from: defaults)
    }

    /// Demo instances get a demo URL and key so every gate reads them like a real profile.
    /// The seed-done flag lives in the demo suite, so wiping it re-arms the seed.
    func seedDemoConfigsIfNeeded() {
        guard !defaults.bool(forKey: DemoMode.seedDoneKey) else { return }
        for kind in [ServiceKind.radarr, .sonarr, .lidarr, .whisparr, .qbittorrent, .sabnzbd] where config(for: kind).baseURL.isEmpty {
            update(kind, with: ServiceConfig(enabled: kind != .whisparr, baseURL: ServiceGateway.demoURL(kind.instanceKind).absoluteString,
                                             apiKey: "demo", username: "demo", password: "demo"))
        }
        if tmdbApiKey.isEmpty { tmdbApiKey = "demo" }
        if !aiEnabled { aiEnabled = true }
        defaults.set(true, forKey: DemoMode.seedDoneKey)
    }

}
