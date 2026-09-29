import Foundation
import os

extension ConfigStore {
    /// Plain settings, one `UserDefaults` value each. `SyncedKeys` picks from these, so a rename can't unsync one.
    nonisolated enum Keys {
        static let notifyHealth = "ArrBarr.notifyHealth"
        static let notifyRadarr = "ArrBarr.notifyRadarr"
        static let notifySonarr = "ArrBarr.notifySonarr"
        static let notifyLidarr = "ArrBarr.notifyLidarr"
        static let notificationSoundName = "ArrBarr.notificationSoundName"
        static let blurWhisparrPosters = "ArrBarr.blurWhisparrPosters"
        static let showWatchedIndicator = "ArrBarr.showWatchedIndicator"
        static let whisparrAgeConfirmed = "ArrBarr.whisparrAgeConfirmed"
        static let fontScale = "ArrBarr.fontScale"
        static let aiKnowsAboutWhisparr = "ArrBarr.aiKnowsAboutWhisparr"
        static let detachedWindow = "ArrBarr.detachedWindow"
        static let spotlightOpensInApp = "ArrBarr.spotlightOpensInApp"
        static let appearance = "ArrBarr.appearance"
        static let arrOrder = "ArrBarr.arrOrder"
        static let showTonight = "ArrBarr.showTonight"
        static let showNeedsYou = "ArrBarr.showNeedsYou"
        static let tonightVisibleCount = "ArrBarr.tonightVisibleCount"
        /// Legacy name from an indexer-only toggle; backs `showWarnings`.
        static let showIndexerIssues = "ArrBarr.showIndexerIssues"
        static let welcomeSeenVersion = "ArrBarr.welcomeSeenVersion"
        static let aiEnabled = "ArrBarr.aiEnabled"
        static let chatProvider = "ArrBarr.chatProvider"
        static let mcpEnabled = "ArrBarr.mcpEnabled"
        static let mcpHostPort = "ArrBarr.mcpHostPort"
        static let mcpRequireAuth = "ArrBarr.mcpRequireAuth"
        static let mcpDisabledTools = "ArrBarr.mcpDisabledTools"
    }

    /// Sentinel value stored in `notificationSoundName` to mean "play no sound".
    public static let silentSoundName = "__none__"
    nonisolated static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"
    nonisolated static let appLanguageKey = "ArrBarr.appLanguage"
    nonisolated static let openaiConfigKey = "ArrBarr.openai"
    nonisolated static let tmdbApiKeyKey = "ArrBarr.tmdbApiKey"
    nonisolated static let mediaServerKey = "ArrBarr.mediaServer"
    nonisolated static let prowlarrKey = "ArrBarr.prowlarr"
    private static let log = Logger(category: "Config")

    /// Assignments here are never persisted back (`isLoading`).
    func applyValues(from defaults: UserDefaults) {
        isLoading = true
        defer { isLoading = false }
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
        self.notifyHealth = value(Keys.notifyHealth, false)
        self.notifyRadarr = value(Keys.notifyRadarr, true)
        self.notifySonarr = value(Keys.notifySonarr, true)
        self.notifyLidarr = value(Keys.notifyLidarr, true)
        self.notificationSoundName = value(Keys.notificationSoundName, "")
        self.blurWhisparrPosters = value(Keys.blurWhisparrPosters, true)
        self.showWatchedIndicator = value(Keys.showWatchedIndicator, true)
        self.whisparrAgeConfirmed = value(Keys.whisparrAgeConfirmed, false)
        // Accept any positive value rather than validating against the picker,
        // so changing the option list never resets saved values.
        let storedScale = value(Keys.fontScale, 0.0)
        self.fontScale = storedScale > 0 ? storedScale : 1.0
        self.aiKnowsAboutWhisparr = value(Keys.aiKnowsAboutWhisparr, false)
        self.detachedWindow = value(Keys.detachedWindow, false)
        self.spotlightOpensInApp = value(Keys.spotlightOpensInApp, true)
        self.iCloudSyncEnabled = value(Self.iCloudSyncEnabledKey, true)
        self.appLanguage = value(Self.appLanguageKey, "system")
        self.appearance = value(Keys.appearance, "system")
        #if os(iOS)
        // iOS has no language picker; clear any per-app override an older build left behind.
        self.appLanguage = "system"
        defaults.removeObject(forKey: "AppleLanguages")
        #endif
        self.arrOrder = Self.normalizeArrOrder(defaults.stringArray(forKey: Keys.arrOrder))
        self.showTonight = value(Keys.showTonight, true)
        self.showNeedsYou = value(Keys.showNeedsYou, true)
        self.showWarnings = value(Keys.showIndexerIssues, true)
        #if os(iOS)
        self.showWarnings = false
        self.appearance = "system"
        #endif
        self.tonightVisibleCount = value(Keys.tonightVisibleCount, 3)
        self.welcomeSeenVersion = defaults.string(forKey: Keys.welcomeSeenVersion)
        self.aiEnabled = value(Keys.aiEnabled, false)
        // Coerce to OpenAI only on hardware that can never run Foundation Models: the picker hides that option.
        let storedProvider = ChatProvider(rawValue: value(Keys.chatProvider, "")) ?? .foundationModels
        self.chatProvider = (storedProvider == .foundationModels && !FoundationModelsAvailability.isOffered)
            ? .openai
            : storedProvider
        self.openai = decoded(OpenAIConfig.self, forKey: Self.openaiConfigKey) ?? .empty
        self.openai.apiKey = secrets.read(.openAIKey) ?? self.openai.apiKey
        self.tmdbApiKey = secrets.read(.tmdbKey) ?? (defaults.string(forKey: Self.tmdbApiKeyKey) ?? "")
        self.mediaServer = decoded(MediaServerConfig.self, forKey: Self.mediaServerKey) ?? .empty
        self.mediaServer.token = secrets.read(.mediaServerToken) ?? self.mediaServer.token
        if let cfg = decoded(ServiceConfig.self, forKey: Self.prowlarrKey) { self.prowlarr = cfg }
        self.prowlarr.apiKey = secrets.read(.prowlarrKey) ?? self.prowlarr.apiKey
        // Prowlarr configs saved before it had an Enabled switch persisted as `enabled: false`.
        if !self.prowlarr.enabled, !self.prowlarr.baseURL.isEmpty { self.prowlarr.enabled = true }
        self.mcpEnabled = value(Keys.mcpEnabled, false)
        self.mcpHostPort = value(Keys.mcpHostPort, "127.0.0.1:8080")
        self.mcpRequireAuth = value(Keys.mcpRequireAuth, true)
        self.mcpAuthToken = MCPTokenStore.read() ?? ""
        self.mcpDisabledTools = Set(defaults.stringArray(forKey: Keys.mcpDisabledTools) ?? [])
        defaults.removeObject(forKey: "ArrBarr.mcpAuthUsername")
        defaults.removeObject(forKey: "ArrBarr.mcpAuthPassword")
    }


    /// The stored value, or `fallback` when the key is absent (never touched) or holds another type.
    private func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    /// A stored config that no longer decodes is logged: silently reading it as empty would lose it on the next save.
    private func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            Self.log.error("stored \(key, privacy: .public) no longer decodes: \(error.logKind, privacy: .public)")
            return nil
        }
    }

    func persist<T: Equatable>(_ new: T, _ old: T, _ key: String) {
        guard !isLoading, new != old else { return }
        defaults.set(new, forKey: key)
    }

    func store<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// Foundation reads the process language only from `.standard`, snapshotted at launch, so it takes
    /// effect after one restart.
    nonisolated static func applyAppLanguage(_ language: String) {
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
    }

    // MARK: - Persistence

    nonisolated static func key(_ kind: ServiceKind) -> String { "ArrBarr.config.\(kind.rawValue)" }

    private nonisolated static func load(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        guard let data = defaults.data(forKey: key(kind)),
              let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
        else { return .empty }
        return cfg
    }

    /// Extension-safe: the widget must not construct `ConfigStore.shared` (MainActor, Keychain migration).
    public nonisolated static func decodeServiceConfig(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        load(kind, from: defaults)
    }

    /// Every service save re-saves both of its secrets; rewriting an unchanged one would bump its
    /// generation, and MediaKit drops that instance's cache and sessions on a new generation.
    func setOrDelete(_ value: String, for key: SecretKey) {
        guard (secrets.read(key) ?? "") != value else { return }
        if value.isEmpty { secrets.delete(key) } else { secrets.set(value, for: key) }
        SecretGenerations.bump(key, in: defaults)
    }

    func persist(_ kind: ServiceKind, _ config: ServiceConfig, _ old: ServiceConfig) {
        guard !isLoading, config != old else { return }
        setOrDelete(config.apiKey, for: .apiKey(for: kind))
        setOrDelete(config.password, for: .password(for: kind))
        var stripped = config
        stripped.apiKey = ""
        stripped.password = ""
        store(stripped, forKey: Self.key(kind))
    }

    private func loadService(_ kind: ServiceKind) -> ServiceConfig {
        var cfg = Self.load(kind, from: defaults)
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }

}
