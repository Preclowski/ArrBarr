import Foundation
import Combine

#if canImport(WidgetKit)
import WidgetKit
#endif

public final class ConfigStore: ObservableObject {
    @MainActor public static let shared = ConfigStore()

    @Published public var radarr: ServiceConfig = .empty
    @Published public var sonarr: ServiceConfig = .empty
    @Published public var lidarr: ServiceConfig = .empty
    @Published public var whisparr: ServiceConfig = .empty
    @Published public var sabnzbd: ServiceConfig = .empty
    @Published public var qbittorrent: ServiceConfig = .empty
    @Published public var nzbget: ServiceConfig = .empty
    @Published public var transmission: ServiceConfig = .empty
    @Published public var rtorrent: ServiceConfig = .empty
    @Published public var deluge: ServiceConfig = .empty
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
    @Published public var notifyHealth: Bool = false
    @Published public var notifyRadarr: Bool = true
    @Published public var notifySonarr: Bool = true
    @Published public var notifyLidarr: Bool = true
    /// `""` = system default, `ConfigStore.silentSoundName` = no sound, otherwise
    /// the bare name of a sound in `/System/Library/Sounds`.
    @Published public var notificationSoundName: String = ""
    @Published public var blurWhisparrPosters: Bool = true
    @Published public var showWatchedIndicator: Bool = true
    /// App Store builds gate enabling Whisparr behind an 18+ confirmation.
    @Published public var whisparrAgeConfirmed: Bool = false
    /// Multiplier applied to every `.scaledFont(size:)` site; `1.0` is the native sizing.
    @Published public var fontScale: Double = 1.0
    @Published public var aiKnowsAboutWhisparr: Bool = false
    /// macOS only: run as a regular Dock app with a real window and no menu-bar icon.
    @Published public var detachedWindow: Bool = false
    /// macOS only: a clicked Spotlight result opens the detail in-app instead of the arr's web UI.
    @Published public var spotlightOpensInApp: Bool = true
    @Published public var iCloudSyncEnabled: Bool = true
    @Published public var appLanguage: String = "system"
    /// UI appearance preference: "system" / "light" / "dark".
    @Published public var appearance: String = "system"
    @Published public var arrOrder: [String] = ConfigStore.defaultArrOrder
    @Published public var showTonight: Bool = true
    @Published public var showNeedsYou: Bool = true
    /// Warning-level health checks join the always-shown errors in "Needs you".
    /// Legacy name from an indexer-only toggle; the persisted key is kept.
    @Published public var showWarnings: Bool = true
    /// 0 = all (no Show more/less at all).
    @Published public var tonightVisibleCount: Int = 3
    /// `nil` means the welcome screen was never seen; first launch shows the firstRun variant.
    @Published public var welcomeSeenVersion: String? = nil
    @Published public var aiEnabled: Bool = false
    @Published public var chatProvider: ChatProvider = .foundationModels
    @Published public var openai: OpenAIConfig = .empty
    /// Empty disables the TMDB-backed chat tools.
    @Published public var tmdbApiKey: String = ""

    /// Used only as a name service: the arrs report indexers under the sync
    /// template's name, and only Prowlarr knows what the user called them.
    @Published public var prowlarr: ServiceConfig = ServiceConfig(enabled: false, baseURL: "", apiKey: "", username: "", password: "")

    /// The one media server (Plex / Jellyfin / Emby) for artwork and watch state.
    @Published public var mediaServer: MediaServerConfig = .empty

    // MARK: - MCP server
    // On macOS the AppDelegate restarts `MCPServerController` whenever these change.
    @Published public var mcpEnabled: Bool = false
    /// Defaults to localhost only; `0.0.0.0` is an explicit opt-in.
    @Published public var mcpHostPort: String = "127.0.0.1:8080"
    /// The server also refuses non-loopback binds without auth.
    @Published public var mcpRequireAuth: Bool = true
    /// Mirrors the Keychain; the token never lives in UserDefaults.
    @Published public var mcpAuthToken: String = MCPTokenStore.read() ?? ""
    /// Tool names the user switched off; empty = every catalog tool is exposed.
    @Published public var mcpDisabledTools: Set<String> = []

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
        let lang = resolveDefaults().string(forKey: appLanguageKey) ?? "system"
        if lang == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
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

    var defaults: UserDefaults
    var defaultsForGateway: UserDefaults { defaults }
    /// The MediaKit assembly for this profile; created on first use, rebuilt when demo mode toggles.
    @MainActor public internal(set) lazy var gateway = ServiceGateway(configStore: self)
    /// Follows the backing store (`useStore`) so demo mode never writes the real profile's secrets.
    var secrets: SecretStore
    var cancellables: Set<AnyCancellable> = []

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
        setupSinks()
    }

    public func useDemoStore(_ on: Bool) {
        useStore(on ? (DemoMode.demoDefaults ?? .standard) : (WidgetDataStore.groupDefaults() ?? .standard))
        // The widget extension can't see the app's `.standard`; mirror demo state into the group suite.
        WidgetDataStore.setDemoActive(on)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Test seam. Tears down sinks before reloading so the reload fires no writes or side effects.
    func useStore(_ target: UserDefaults) {
        guard target !== defaults else { return }
        cancellables.removeAll()
        defaults = target
        secrets = Self.makeDefaultSecretStore(defaults: target)
        applyValues(from: target)
        setupSinks()
        QueueUIState.shared.use(target)
    }

    public func reloadFromDefaults() {
        cancellables.removeAll()
        applyValues(from: defaults)
        setupSinks()
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
