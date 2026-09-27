import Foundation
import Combine
import os

#if os(macOS)
import ServiceManagement
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

enum LaunchAtLogin {
    private static let logger = Logger(category: "LaunchAtLogin")

    static func set(enabled: Bool) {
        #if os(macOS)
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            logger.error("LaunchAtLogin toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        #else
        // No equivalent on iOS — apps don't have a "launch at login" model.
        _ = enabled
        #endif
    }
}

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
    @Published public var launchAtLogin: Bool = false
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
    @Published public var tonightHours: Int = 168
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

    private var defaults: UserDefaults
    var defaultsForGateway: UserDefaults { defaults }
    /// The MediaKit assembly for this profile; created on first use, rebuilt when demo mode toggles.
    @MainActor public internal(set) lazy var gateway = ServiceGateway(configStore: self)
    /// Follows the backing store (`useStore`) so demo mode never writes the real profile's secrets.
    private var secrets: SecretStore
    private var cancellables: Set<AnyCancellable> = []

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

    private static let notifyHealthKey = "ArrBarr.notifyHealth"
    private static let notifyRadarrKey = "ArrBarr.notifyRadarr"
    private static let notifySonarrKey = "ArrBarr.notifySonarr"
    private static let notifyLidarrKey = "ArrBarr.notifyLidarr"
    private static let notificationSoundNameKey = "ArrBarr.notificationSoundName"
    /// Sentinel value stored in `notificationSoundName` to mean "play no sound".
    public static let silentSoundName = "__none__"
    private static let blurWhisparrPostersKey = "ArrBarr.blurWhisparrPosters"
    private static let showWatchedIndicatorKey = "ArrBarr.showWatchedIndicator"
    private static let whisparrAgeConfirmedKey = "ArrBarr.whisparrAgeConfirmed"
    private static let fontScaleKey = "ArrBarr.fontScale"
    private static let aiKnowsAboutWhisparrKey = "ArrBarr.aiKnowsAboutWhisparr"
    private static let launchAtLoginKey = "ArrBarr.launchAtLogin"
    private static let detachedWindowKey = "ArrBarr.detachedWindow"
    private static let spotlightOpensInAppKey = "ArrBarr.spotlightOpensInApp"
    nonisolated static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"
    nonisolated private static let appLanguageKey = "ArrBarr.appLanguage"
    private static let appearanceKey = "ArrBarr.appearance"
    private static let arrOrderKey = "ArrBarr.arrOrder"
    private static let showTonightKey = "ArrBarr.showTonight"
    private static let showNeedsYouKey = "ArrBarr.showNeedsYou"
    private static let tonightHoursKey = "ArrBarr.tonightHours"
    private static let tonightVisibleCountKey = "ArrBarr.tonightVisibleCount"
    private static let showIndexerIssuesKey = "ArrBarr.showIndexerIssues"
    private static let welcomeSeenVersionKey = "ArrBarr.welcomeSeenVersion"
    private static let aiEnabledKey = "ArrBarr.aiEnabled"
    private static let chatProviderKey = "ArrBarr.chatProvider"
    nonisolated static let openaiConfigKey = "ArrBarr.openai"
    nonisolated static let tmdbApiKeyKey = "ArrBarr.tmdbApiKey"
    nonisolated static let mediaServerKey = "ArrBarr.mediaServer"
    nonisolated static let prowlarrKey = "ArrBarr.prowlarr"
    private static let mcpEnabledKey = "ArrBarr.mcpEnabled"
    private static let mcpHostPortKey = "ArrBarr.mcpHostPort"
    private static let mcpRequireAuthKey = "ArrBarr.mcpRequireAuth"
    private static let mcpDisabledToolsKey = "ArrBarr.mcpDisabledTools"
    // nonisolated: read by the migration helpers and the widget extension.
    nonisolated private static let groupMigrationDoneKey = "ArrBarr.groupMigrationDone"
    nonisolated private static let secretsMigratedKey = "ArrBarr.secretsMigratedToKeychain"
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

    /// The data-protection Keychain when the signature provisions the access group
    /// (silent probe); ad-hoc builds fall back to UserDefaults, since the file Keychain would prompt on every rebuild.
    nonisolated static func makeDefaultSecretStore(defaults: UserDefaults) -> SecretStore {
        // The Keychain is process-wide, so demo needs its own suite-backed store
        // or demo edits would overwrite (and blank) the real profile's secrets.
        if DemoMode.isActive { return UserDefaultsSecretStore(defaults: defaults) }
        return AppCapabilities.keychainSharingAvailable
            ? KeychainSecretStore()
            : UserDefaultsSecretStore(defaults: defaults)
    }

    /// Cannot prompt: an unentitled read just fails and leaves the flag for the next launch.
    nonisolated static func recoverSecretsFromKeychainIfNeeded(defaults: UserDefaults, secrets: SecretStore) {
        guard defaults.bool(forKey: secretsMigratedKey) else { return }
        let keychain = KeychainSecretStore()
        var recoveredAny = false
        func move(_ key: SecretKey) {
            if let v = keychain.read(key), !v.isEmpty {
                secrets.set(v, for: key)
                keychain.delete(key)
                recoveredAny = true
            }
        }
        for kind in ServiceKind.allCases {
            move(.apiKey(for: kind))
            move(.password(for: kind))
        }
        move(.openAIKey)
        move(.tmdbKey)
        move(.mediaServerToken)
        if recoveredAny { defaults.set(false, forKey: secretsMigratedKey) }
    }

    /// Called with sinks torn down, so assignments here are never persisted back.
    private func applyValues(from defaults: UserDefaults) {
        self.radarr = loadService(.radarr)
        self.sonarr = loadService(.sonarr)
        self.lidarr = loadService(.lidarr)
        self.whisparr = loadService(.whisparr)
        self.sabnzbd = loadService(.sabnzbd)
        self.qbittorrent = loadService(.qbittorrent)
        self.nzbget = loadService(.nzbget)
        self.transmission = loadService(.transmission)
        self.rtorrent = loadService(.rtorrent)
        self.deluge = loadService(.deluge)
        self.notifyHealth = defaults.bool(forKey: Self.notifyHealthKey)
        self.notifyRadarr = defaults.object(forKey: Self.notifyRadarrKey) != nil ? defaults.bool(forKey: Self.notifyRadarrKey) : true
        self.notifySonarr = defaults.object(forKey: Self.notifySonarrKey) != nil ? defaults.bool(forKey: Self.notifySonarrKey) : true
        self.notifyLidarr = defaults.object(forKey: Self.notifyLidarrKey) != nil ? defaults.bool(forKey: Self.notifyLidarrKey) : true
        self.notificationSoundName = defaults.string(forKey: Self.notificationSoundNameKey) ?? ""
        self.blurWhisparrPosters = defaults.object(forKey: Self.blurWhisparrPostersKey) != nil ? defaults.bool(forKey: Self.blurWhisparrPostersKey) : true
        self.showWatchedIndicator = defaults.object(forKey: Self.showWatchedIndicatorKey) != nil ? defaults.bool(forKey: Self.showWatchedIndicatorKey) : true
        self.whisparrAgeConfirmed = defaults.bool(forKey: Self.whisparrAgeConfirmedKey)
        // Accept any positive value rather than validating against the picker,
        // so changing the option list never resets saved values.
        let storedScale = defaults.double(forKey: Self.fontScaleKey)
        self.fontScale = storedScale > 0 ? storedScale : 1.0
        self.aiKnowsAboutWhisparr = defaults.object(forKey: Self.aiKnowsAboutWhisparrKey) != nil ? defaults.bool(forKey: Self.aiKnowsAboutWhisparrKey) : false
        self.launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) != nil ? defaults.bool(forKey: Self.launchAtLoginKey) : false
        self.detachedWindow = defaults.bool(forKey: Self.detachedWindowKey)
        self.spotlightOpensInApp = defaults.object(forKey: Self.spotlightOpensInAppKey) != nil
            ? defaults.bool(forKey: Self.spotlightOpensInAppKey) : true
        self.iCloudSyncEnabled = defaults.object(forKey: Self.iCloudSyncEnabledKey) != nil
            ? defaults.bool(forKey: Self.iCloudSyncEnabledKey) : true
        self.appLanguage = defaults.string(forKey: Self.appLanguageKey) ?? "system"
        self.appearance = defaults.string(forKey: Self.appearanceKey) ?? "system"
        #if os(iOS)
        // iOS has no language picker; clear any per-app override an older build left behind.
        self.appLanguage = "system"
        defaults.removeObject(forKey: "AppleLanguages")
        #endif
        self.arrOrder = Self.normalizeArrOrder(defaults.stringArray(forKey: Self.arrOrderKey))
        self.showTonight = defaults.object(forKey: Self.showTonightKey) != nil ? defaults.bool(forKey: Self.showTonightKey) : true
        self.showNeedsYou = defaults.object(forKey: Self.showNeedsYouKey) != nil ? defaults.bool(forKey: Self.showNeedsYouKey) : true
        self.showWarnings = defaults.object(forKey: Self.showIndexerIssuesKey) != nil ? defaults.bool(forKey: Self.showIndexerIssuesKey) : true
        #if os(iOS)
        self.showWarnings = false
        self.appearance = "system"
        #endif
        self.tonightHours = 168
        self.tonightVisibleCount = defaults.object(forKey: Self.tonightVisibleCountKey) != nil
            ? defaults.integer(forKey: Self.tonightVisibleCountKey) : 3
        self.welcomeSeenVersion = defaults.string(forKey: Self.welcomeSeenVersionKey)
        self.aiEnabled = defaults.object(forKey: Self.aiEnabledKey) != nil
            ? defaults.bool(forKey: Self.aiEnabledKey) : false
        // Coerce to OpenAI where Foundation Models is unsupported: the picker hides that
        // option, so a stored `.foundationModels` would show OpenAI but resolve to Unavailable.
        let storedProvider = ChatProvider(rawValue: defaults.string(forKey: Self.chatProviderKey) ?? "") ?? .foundationModels
        self.chatProvider = (storedProvider == .foundationModels && !FoundationModelsAvailability.isSupported)
            ? .openai
            : storedProvider
        if let data = defaults.data(forKey: Self.openaiConfigKey),
           let cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data) {
            self.openai = cfg
        } else {
            self.openai = .empty
        }
        self.openai.apiKey = secrets.read(.openAIKey) ?? self.openai.apiKey
        self.tmdbApiKey = secrets.read(.tmdbKey) ?? (defaults.string(forKey: Self.tmdbApiKeyKey) ?? "")
        if let data = defaults.data(forKey: Self.mediaServerKey),
           let cfg = try? JSONDecoder().decode(MediaServerConfig.self, from: data) {
            self.mediaServer = cfg
        } else {
            self.mediaServer = .empty
        }
        self.mediaServer.token = secrets.read(.mediaServerToken) ?? self.mediaServer.token
        if let data = defaults.data(forKey: Self.prowlarrKey),
           let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data) {
            self.prowlarr = cfg
        }
        self.prowlarr.apiKey = secrets.read(.prowlarrKey) ?? self.prowlarr.apiKey
        // Prowlarr configs saved before it had an Enabled switch persisted as `enabled: false`.
        if !self.prowlarr.enabled, !self.prowlarr.baseURL.isEmpty { self.prowlarr.enabled = true }
        self.mcpEnabled = defaults.bool(forKey: Self.mcpEnabledKey)
        self.mcpHostPort = defaults.string(forKey: Self.mcpHostPortKey) ?? "127.0.0.1:8080"
        // An absent key means the toggle was never touched (sinks write only on change).
        self.mcpRequireAuth = (defaults.object(forKey: Self.mcpRequireAuthKey) as? Bool) ?? true
        self.mcpAuthToken = MCPTokenStore.read() ?? ""
        self.mcpDisabledTools = Set(defaults.stringArray(forKey: Self.mcpDisabledToolsKey) ?? [])
        defaults.removeObject(forKey: "ArrBarr.mcpAuthUsername")
        defaults.removeObject(forKey: "ArrBarr.mcpAuthPassword")
    }

    private func setupSinks() {
        cancellables.removeAll()
        for kind in ServiceKind.allCases {
            publisher(for: kind).dropFirst().sink { [weak self] cfg in
                self?.save(kind, cfg)
            }.store(in: &cancellables)
        }
        $notifyHealth.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.notifyHealthKey)
        }.store(in: &cancellables)
        $notifyRadarr.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.notifyRadarrKey)
        }.store(in: &cancellables)
        $notifySonarr.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.notifySonarrKey)
        }.store(in: &cancellables)
        $notifyLidarr.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.notifyLidarrKey)
        }.store(in: &cancellables)
        $notificationSoundName.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.notificationSoundNameKey)
        }.store(in: &cancellables)
        $whisparrAgeConfirmed.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.whisparrAgeConfirmedKey)
        }.store(in: &cancellables)
        $showWatchedIndicator.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showWatchedIndicatorKey)
        }.store(in: &cancellables)
        $blurWhisparrPosters.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.blurWhisparrPostersKey)
        }.store(in: &cancellables)
        $fontScale.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.fontScaleKey)
        }.store(in: &cancellables)
        $aiKnowsAboutWhisparr.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.aiKnowsAboutWhisparrKey)
        }.store(in: &cancellables)
        $launchAtLogin.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.launchAtLoginKey)
            LaunchAtLogin.set(enabled: val)
        }.store(in: &cancellables)
        $detachedWindow.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.detachedWindowKey)
        }.store(in: &cancellables)
        $spotlightOpensInApp.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.spotlightOpensInAppKey)
        }.store(in: &cancellables)
        $iCloudSyncEnabled.dropFirst().sink { [weak self] val in
            guard let self else { return }
            self.defaults.set(val, forKey: Self.iCloudSyncEnabledKey)
            guard AppCapabilities.isAppStore else { return }
            KVSyncCoordinator.shared?.setEnabled(val)
            self.secrets.reapplySyncAttribute(for: SecretKey.syncable)
        }.store(in: &cancellables)
        $arrOrder.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.arrOrderKey)
        }.store(in: &cancellables)
        $showTonight.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showTonightKey)
        }.store(in: &cancellables)
        $showNeedsYou.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showNeedsYouKey)
        }.store(in: &cancellables)
        $showWarnings.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showIndexerIssuesKey)
        }.store(in: &cancellables)
        $tonightHours.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.tonightHoursKey)
        }.store(in: &cancellables)
        $tonightVisibleCount.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.tonightVisibleCountKey)
        }.store(in: &cancellables)
        $appearance.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.appearanceKey)
        }.store(in: &cancellables)
        $welcomeSeenVersion.dropFirst().sink { [weak self] val in
            if let val {
                self?.defaults.set(val, forKey: Self.welcomeSeenVersionKey)
            } else {
                self?.defaults.removeObject(forKey: Self.welcomeSeenVersionKey)
            }
        }.store(in: &cancellables)
        $appLanguage.dropFirst().sink { [weak self] val in
            guard let self else { return }
            self.defaults.set(val, forKey: Self.appLanguageKey)
            // `.standard`, not the suite: Foundation reads process language only from there,
            // snapshotted at launch, so it takes effect after one restart.
            if val == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([val], forKey: "AppleLanguages")
            }
        }.store(in: &cancellables)
        $aiEnabled.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.aiEnabledKey)
        }.store(in: &cancellables)
        $chatProvider.dropFirst().sink { [weak self] val in
            self?.defaults.set(val.rawValue, forKey: Self.chatProviderKey)
        }.store(in: &cancellables)
        $openai.dropFirst().sink { [weak self] cfg in
            guard let self else { return }
            self.setOrDelete(cfg.apiKey, for: .openAIKey)
            var stripped = cfg
            stripped.apiKey = ""
            if let data = try? JSONEncoder().encode(stripped) {
                self.defaults.set(data, forKey: Self.openaiConfigKey)
            }
        }.store(in: &cancellables)
        $tmdbApiKey.dropFirst().sink { [weak self] val in
            self?.setOrDelete(val, for: .tmdbKey)
            self?.defaults.removeObject(forKey: Self.tmdbApiKeyKey)
        }.store(in: &cancellables)
        $prowlarr.dropFirst().sink { [weak self] cfg in
            guard let self else { return }
            self.setOrDelete(cfg.apiKey, for: .prowlarrKey)
            var stripped = cfg
            stripped.apiKey = ""
            if let data = try? JSONEncoder().encode(stripped) {
                self.defaults.set(data, forKey: Self.prowlarrKey)
            }
        }.store(in: &cancellables)
        $mediaServer.dropFirst().sink { [weak self] cfg in
            guard let self else { return }
            self.setOrDelete(cfg.token, for: .mediaServerToken)
            var stripped = cfg
            stripped.token = ""
            if let data = try? JSONEncoder().encode(stripped) {
                self.defaults.set(data, forKey: Self.mediaServerKey)
            }
        }.store(in: &cancellables)
        $mcpEnabled.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.mcpEnabledKey)
        }.store(in: &cancellables)
        $mcpHostPort.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.mcpHostPortKey)
        }.store(in: &cancellables)
        $mcpRequireAuth.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.mcpRequireAuthKey)
        }.store(in: &cancellables)
        $mcpAuthToken.dropFirst().sink { val in
            if val.isEmpty { MCPTokenStore.delete() } else { MCPTokenStore.set(val) }
        }.store(in: &cancellables)
        $mcpDisabledTools.dropFirst().sink { [weak self] val in
            self?.defaults.set(Array(val), forKey: Self.mcpDisabledToolsKey)
        }.store(in: &cancellables)
    }

    public func useDemoStore(_ on: Bool) {
        useStore(on ? (DemoMode.demoDefaults ?? .standard) : (WidgetDataStore.groupDefaults() ?? .standard))
        // The widget extension can't see the app's `.standard`; mirror demo state into the group suite.
        WidgetDataStore.setDemoActive(on)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Test seam. Tears down sinks before reloading so the reload fires no writes or side
    /// effects (the `launchAtLogin` sink would re-register the real login item).
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

    /// Pause/resume go straight to the download client; only a confirmed `.down` gates,
    /// `.unknown` (not yet probed) stays allowed.
    public func canControlDownload(_ proto: QueueItem.DownloadProtocol) -> Bool {
        guard let kind = selectedDownloadClient(for: proto) else { return false }
        if case .down = ConnectionHealth.shared.state(for: .arr(kind)) { return false }
        return true
    }

    public var tmdbEnabled: Bool { !tmdbApiKey.isEmpty }

    public func testProwlarr() async throws {
        _ = try await ProwlarrClient().testConnection()
    }

    public func config(for source: QueueItem.Source) -> ServiceConfig { config(for: source.serviceKind) }

    public func shouldBlurPoster(for source: QueueItem.Source) -> Bool {
        source == .whisparr && blurWhisparrPosters
    }

    func publisher(for kind: ServiceKind) -> Published<ServiceConfig>.Publisher {
        switch kind {
        case .radarr: $radarr
        case .sonarr: $sonarr
        case .lidarr: $lidarr
        case .whisparr: $whisparr
        case .sabnzbd: $sabnzbd
        case .qbittorrent: $qbittorrent
        case .nzbget: $nzbget
        case .transmission: $transmission
        case .rtorrent: $rtorrent
        case .deluge: $deluge
        }
    }

    public func config(for kind: ServiceKind) -> ServiceConfig {
        switch kind {
        case .radarr: return radarr
        case .sonarr: return sonarr
        case .lidarr: return lidarr
        case .whisparr: return whisparr
        case .sabnzbd: return sabnzbd
        case .qbittorrent: return qbittorrent
        case .nzbget: return nzbget
        case .transmission: return transmission
        case .rtorrent: return rtorrent
        case .deluge: return deluge
        }
    }

    /// The drop flow needs arrs and download clients together: the arr names the client,
    /// the client's config carries its credentials.
    public var downloadDropConfigs: [ServiceKind: ServiceConfig] {
        Dictionary(uniqueKeysWithValues: ServiceKind.allCases.map { ($0, config(for: $0)) })
    }

    /// Same priority order as `QueueAggregator.performUsenet` / `performTorrent`; this
    /// client's reachability gates pause/resume, unlike delete, which the arr performs.
    public func selectedDownloadClient(for proto: QueueItem.DownloadProtocol) -> ServiceKind? {
        switch proto {
        case .usenet:
            if sabnzbd.isConfigured, !sabnzbd.apiKey.isEmpty { return .sabnzbd }
            if nzbget.isConfigured { return .nzbget }
            return nil
        case .torrent:
            if qbittorrent.isConfigured { return .qbittorrent }
            if transmission.isConfigured { return .transmission }
            if rtorrent.isConfigured { return .rtorrent }
            if deluge.isConfigured { return .deluge }
            return nil
        case .unknown:
            return nil
        }
    }


    public func update(_ kind: ServiceKind, with config: ServiceConfig) {
        switch kind {
        case .radarr: radarr = config
        case .sonarr: sonarr = config
        case .lidarr: lidarr = config
        case .whisparr: whisparr = config
        case .sabnzbd: sabnzbd = config
        case .qbittorrent: qbittorrent = config
        case .nzbget: nzbget = config
        case .transmission: transmission = config
        case .rtorrent: rtorrent = config
        case .deluge: deluge = config
        }
    }

    public static func normalizeArrOrder(_ stored: [String]?) -> [String] {
        let known = Set(defaultArrOrder)
        var seen = Set<String>()
        var result = (stored ?? []).filter { known.contains($0) && seen.insert($0).inserted }
        // Users from <0.7.x: put "tonight" and "needsyou" on top; other missing keys append.
        if !seen.contains(needsYouOrderKey) {
            result.insert(needsYouOrderKey, at: 0)
            seen.insert(needsYouOrderKey)
        }
        if !seen.contains(tonightOrderKey) {
            result.insert(tonightOrderKey, at: 0)
            seen.insert(tonightOrderKey)
        }
        for k in defaultArrOrder where !seen.contains(k) { result.append(k) }
        return result
    }

    // MARK: - Persistence

    nonisolated static func key(_ kind: ServiceKind) -> String { "ArrBarr.config.\(kind.rawValue)" }

    private nonisolated static func load(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        guard let data = defaults.data(forKey: key(kind)),
              let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
        else { return .empty }
        return cfg
    }

    /// Extension-safe: the widget must not construct `ConfigStore.shared` (MainActor,
    /// Combine sinks, Keychain migration, LaunchAtLogin).
    public nonisolated static func decodeServiceConfig(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        load(kind, from: defaults)
    }

    private func setOrDelete(_ value: String, for key: SecretKey) {
        if value.isEmpty { secrets.delete(key) } else { secrets.set(value, for: key) }
        SecretGenerations.bump(key, in: defaults)
    }

    private func save(_ kind: ServiceKind, _ config: ServiceConfig) {
        setOrDelete(config.apiKey, for: .apiKey(for: kind))
        setOrDelete(config.password, for: .password(for: kind))
        var stripped = config
        stripped.apiKey = ""
        stripped.password = ""
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: Self.key(kind))
        }
    }

    private func loadService(_ kind: ServiceKind) -> ServiceConfig {
        var cfg = Self.load(kind, from: defaults)
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }

    // MARK: - One-shot migration of plaintext secrets into the SecretStore

    nonisolated static func migrateSecretsToKeychain(defaults: UserDefaults, secrets: SecretStore) {
        guard !defaults.bool(forKey: secretsMigratedKey) else { return }
        var allVerified = true

        /// A failed read-back keeps the plaintext copy and marks the migration incomplete.
        func store(_ value: String, _ key: SecretKey) -> Bool {
            guard !value.isEmpty else { return true }
            secrets.set(value, for: key)
            if secrets.read(key) == value { return true }
            allVerified = false
            return false
        }

        for kind in ServiceKind.allCases {
            guard let data = defaults.data(forKey: key(kind)),
                  var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
            else { continue }
            var changed = false
            if !cfg.apiKey.isEmpty, store(cfg.apiKey, .apiKey(for: kind)) {
                cfg.apiKey = ""; changed = true
            }
            if !cfg.password.isEmpty, store(cfg.password, .password(for: kind)) {
                cfg.password = ""; changed = true
            }
            if changed, let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: key(kind))
            }
        }

        if let data = defaults.data(forKey: openaiConfigKey),
           var cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data),
           !cfg.apiKey.isEmpty, store(cfg.apiKey, .openAIKey) {
            cfg.apiKey = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: openaiConfigKey)
            }
        }

        if let tmdb = defaults.string(forKey: tmdbApiKeyKey), !tmdb.isEmpty,
           store(tmdb, .tmdbKey) {
            defaults.removeObject(forKey: tmdbApiKeyKey)
        }

        if let data = defaults.data(forKey: mediaServerKey),
           var cfg = try? JSONDecoder().decode(MediaServerConfig.self, from: data),
           !cfg.token.isEmpty, store(cfg.token, .mediaServerToken) {
            cfg.token = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: mediaServerKey)
            }
        }

        if allVerified { defaults.set(true, forKey: secretsMigratedKey) }
    }

    /// Not flag-guarded: idempotent and free in steady state, so it self-heals a failed write.
    /// Also sweeps `.standard`, where `MCPTokenStore` keeps its token, except in demo mode.
    nonisolated static func migratePlaintextSecretsIntoKeychain(defaults: UserDefaults,
                                                               keychain: SecretStore) {
        var suites: [UserDefaults] = [defaults]
        if !DemoMode.isActive, defaults !== UserDefaults.standard { suites.append(.standard) }

        func lift(_ key: SecretKey, from plaintext: UserDefaultsSecretStore) {
            guard let value = plaintext.read(key) else { return }
        // Keychain already authoritative: the plaintext copy is a stale duplicate.
            if let existing = keychain.read(key), !existing.isEmpty {
                plaintext.delete(key)
                return
            }
            keychain.set(value, for: key)
            guard keychain.read(key) == value else { return }
            plaintext.delete(key)
        }

        for suite in suites {
            let plaintext = UserDefaultsSecretStore(defaults: suite)
            for kind in ServiceKind.allCases {
                lift(.apiKey(for: kind), from: plaintext)
                lift(.password(for: kind), from: plaintext)
            }
            lift(.openAIKey, from: plaintext)
            lift(.tmdbKey, from: plaintext)
            lift(.mediaServerToken, from: plaintext)
            lift(.mcpBearer, from: plaintext)
        }
    }

}


/// Thrown by `ConfigStore.testProwlarr()` when there's nothing to test yet.
nonisolated struct ProwlarrNotConfigured: LocalizedError {
    var errorDescription: String? { String(localized: "Service not configured", bundle: .module) }
}
