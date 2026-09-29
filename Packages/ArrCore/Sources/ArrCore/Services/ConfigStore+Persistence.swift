import Foundation
import Combine

extension ConfigStore {
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
    private static let detachedWindowKey = "ArrBarr.detachedWindow"
    private static let spotlightOpensInAppKey = "ArrBarr.spotlightOpensInApp"
    nonisolated static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"
    nonisolated static let appLanguageKey = "ArrBarr.appLanguage"
    private static let appearanceKey = "ArrBarr.appearance"
    private static let arrOrderKey = "ArrBarr.arrOrder"
    private static let showTonightKey = "ArrBarr.showTonight"
    private static let showNeedsYouKey = "ArrBarr.showNeedsYou"
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

    /// Called with sinks torn down, so assignments here are never persisted back.
    func applyValues(from defaults: UserDefaults) {
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

    func setupSinks() {
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

    // MARK: - Persistence

    nonisolated static func key(_ kind: ServiceKind) -> String { "ArrBarr.config.\(kind.rawValue)" }

    private nonisolated static func load(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        guard let data = defaults.data(forKey: key(kind)),
              let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
        else { return .empty }
        return cfg
    }

    /// Extension-safe: the widget must not construct `ConfigStore.shared` (MainActor,
    /// Combine sinks, Keychain migration).
    public nonisolated static func decodeServiceConfig(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        load(kind, from: defaults)
    }

    /// Every service sink re-saves both of its secrets; rewriting an unchanged one would bump its
    /// generation, and MediaKit drops that instance's cache and sessions on a new generation.
    private func setOrDelete(_ value: String, for key: SecretKey) {
        guard (secrets.read(key) ?? "") != value else { return }
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

}
