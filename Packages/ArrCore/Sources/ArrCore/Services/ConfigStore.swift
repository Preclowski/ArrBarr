import Foundation
import Combine
import os

#if os(macOS)
import ServiceManagement
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

public enum LaunchAtLogin {
    private static let logger = Logger(category: "LaunchAtLogin")

    static var isEnabled: Bool {
        #if os(macOS)
        return SMAppService.mainApp.status == .enabled
        #else
        return false
        #endif
    }

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

@MainActor
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
    @Published public var foregroundInterval: TimeInterval = 5
    @Published public var backgroundInterval: TimeInterval = 30
    @Published public var notifyRadarr: Bool = true
    @Published public var notifySonarr: Bool = true
    @Published public var notifyLidarr: Bool = true
    /// Sound played for queue-event notifications. `""` = system default,
    /// `ConfigStore.silentSoundName` = no sound, otherwise the bare name of a
    /// sound in `/System/Library/Sounds` (e.g. `"Glass"`). See
    /// `NotificationCoalescer` for how it maps to a `UNNotificationSound`.
    @Published public var notificationSoundName: String = ""
    @Published public var blurWhisparrPosters: Bool = true
    /// App Store builds gate enabling Whisparr behind an 18+ confirmation.
    /// Once the user confirms, this stays `true` and they aren't asked again.
    @Published public var whisparrAgeConfirmed: Bool = false
    /// Multiplier applied to every `.scaledFont(size:)` site in the UI.
    /// `1.0` is the native sizing the views were designed against;
    /// `1.10` / `1.20` give bigger-text accessibility presets without
    /// touching every font definition. Plumbed through environment so
    /// any view can opt in just by switching `.font(.system(size:))`
    /// → `.scaledFont(size:)`.
    @Published public var fontScale: Double = 1.0
    @Published public var aiKnowsAboutWhisparr: Bool = false
    @Published public var launchAtLogin: Bool = false
    @Published public var appLanguage: String = "system"
    /// UI appearance preference: "system" / "light" / "dark".
    @Published public var appearance: String = "system"
    @Published public var arrOrder: [String] = ConfigStore.defaultArrOrder
    @Published public var showTonight: Bool = true
    @Published public var showNeedsYou: Bool = true
    @Published public var showIndexerIssues: Bool = true
    @Published public var collapsedArrs: Set<String> = []
    @Published public var tonightHours: Int = 168
    /// Last `WelcomeContent.currentVersion` the user dismissed. `nil` means
    /// they've never seen the welcome screen — first launch shows the
    /// firstRun variant.
    @Published public var welcomeSeenVersion: String? = nil
    @Published public var aiEnabled: Bool = false
    @Published public var chatProvider: ChatProvider = .foundationModels
    @Published public var openai: OpenAIConfig = .empty
    /// Empty string disables TMDB-backed chat tools (`tmdb_search_person`,
    /// `tmdb_person_credits`, `tmdb_discover_*`). When non-empty, the chat
    /// tool catalog appends those tools so the LLM can search by actor /
    /// genre / decade.
    @Published public var tmdbApiKey: String = ""

    // MARK: - MCP server (mock)
    //
    // UI-only for now: these persist the user's intended MCP-server config
    // (enable, bind address, basic auth, per-tool opt-out) but nothing spins
    // up an actual server yet. The Settings "MCP" pane reads/writes these so
    // the choices survive relaunch; wiring a real server later is a drop-in.
    @Published public var mcpEnabled: Bool = false
    /// Bind target as a single `host:port` string. Defaults to localhost only;
    /// the user must opt into `0.0.0.0` to expose on the network.
    @Published public var mcpHostPort: String = "127.0.0.1:8080"
    @Published public var mcpRequireAuth: Bool = false
    /// Bearer token for the MCP server. Backed by the Keychain (the secret never
    /// lives in UserDefaults); this property mirrors it for the Settings UI.
    @Published public var mcpAuthToken: String = MCPTokenStore.read() ?? ""
    /// Live server status, pushed in by the app (`MCPServerController`). Not persisted.
    @Published public var mcpServerStatus: MCPServerStatus = .stopped
    /// Tool names the user has switched OFF. Empty = every catalog tool is
    /// exposed (the sensible default), so we only have to store the opt-outs.
    @Published public var mcpDisabledTools: Set<String> = []

    public static let needsYouOrderKey = "needsyou"
    public static let tonightOrderKey = "tonight"
    public static let defaultArrOrder = ["tonight", "needsyou", "radarr", "sonarr", "lidarr", "whisparr"]
    /// Banner window — hard-locked to 7 days. Used to be configurable
    /// via Settings (12h / 24h / 72h), but the picker was friction for
    /// no real payoff: most users want "what's coming this week" and
    /// the rest were rounding to 72h anyway. Kept as `@Published Int`
    /// for source-compat with subscribers; nothing writes to it now.
    public static let tonightHoursOptions = [168]

    public static let appLanguageOptions: [(code: String, label: String)] = [
        ("system", "System"),
        ("en", "English"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("pl", "Polski"),
    ]

    public var currentLocale: Locale {
        if appLanguage == "system" { return .autoupdatingCurrent }
        return Locale(identifier: appLanguage)
    }

    /// AI is usable only when enabled AND the selected provider has what it
    /// needs. Foundation Models is keyless (its real device/OS availability is
    /// checked at runtime by the provider); the OpenAI path needs a key — an
    /// enabled-but-keyless OpenAI config is treated as "AI off" (chat hidden,
    /// Settings shows the error).
    public var aiConfigured: Bool {
        guard aiEnabled else { return false }
        // Demo mode runs the chat on DemoChatProvider (see ChatViewModelFactory),
        // which needs neither an API key nor on-device Apple Intelligence — so the
        // chat is available regardless of provider/OS as long as AI is enabled.
        if DemoMode.isActive { return true }
        switch chatProvider {
        case .foundationModels: return FoundationModelsAvailability.isSupported
        case .openai:           return openai.isConfigured
        }
    }

    /// Font scale actually applied to the UI. iOS has no user-facing text-size
    /// picker (the shared sizes read a touch small on phone), so it uses a
    /// fixed modest bump; macOS uses the user's preset as-is.
    public var effectiveFontScale: Double {
        #if os(iOS)
        return 1.1
        #else
        return fontScale
        #endif
    }

    /// Picker options for the "text size" preset. Three steps is enough
    /// to cover "fine / a bit bigger / clearly bigger" without paging a
    /// continuous slider that nobody actually fine-tunes.
    public static let fontScaleOptions: [Double] = [1.0, 1.20, 1.45]

    public static let foregroundIntervalOptions: [TimeInterval] = [0, 2, 5, 10, 15, 30]
    public static let backgroundIntervalOptions: [TimeInterval] = [0, 10, 30, 60, 120, 300]

    private var defaults: UserDefaults
    private let secrets: SecretStore
    private var cancellables: Set<AnyCancellable> = []

    /// Backing store for `ConfigStore.shared`: the demo suite while demo is
    /// active, otherwise the App Group suite (falling back to `.standard` if
    /// the entitlement isn't present — e.g. in unit tests).
    ///
    /// Performs the one-shot `.standard` → group migration here so it is
    /// guaranteed to run before the first config read, with no fragile
    /// app-launch call site to forget. Gated to the host app process:
    /// `UserDefaults.standard` is per-bundle, so a widget extension's
    /// `.standard` is a *different, empty* container — letting the extension
    /// migrate would set the done-flag with zero keys copied and strand an
    /// existing user's settings. Extensions read the group suite directly via
    /// `WidgetDataStore` and never reach this path.
    nonisolated public static func resolveDefaults() -> UserDefaults {
        if DemoMode.isActive, let demo = DemoMode.demoDefaults { return demo }
        guard let group = WidgetDataStore.groupDefaults() else { return .standard }
        if !isAppExtension { migrateToGroupSuite(from: .standard, to: group) }
        return group
    }

    /// True when running inside an app extension (e.g. the widget). App
    /// extension bundles are wrapped in a `.appex` directory.
    nonisolated static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// One-shot copy of every `ArrBarr.*` key from `source` into the App Group
    /// `group` suite. Idempotent (guarded by `groupMigrationDoneKey` in `group`),
    /// prefix-scoped (only `ArrBarr.*`), and demo-suite-agnostic (it only ever
    /// touches the two suites passed in — never the demo suite).
    public nonisolated static func migrateToGroupSuite(from source: UserDefaults, to group: UserDefaults) {
        guard !group.bool(forKey: groupMigrationDoneKey) else { return }
        for (key, value) in source.dictionaryRepresentation() where key.hasPrefix("ArrBarr.") {
            group.set(value, forKey: key)
        }
        group.set(true, forKey: groupMigrationDoneKey)
    }

    private static let foregroundIntervalKey = "ArrBarr.foregroundInterval"
    private static let backgroundIntervalKey = "ArrBarr.backgroundInterval"
    private static let notifyRadarrKey = "ArrBarr.notifyRadarr"
    private static let notifySonarrKey = "ArrBarr.notifySonarr"
    private static let notifyLidarrKey = "ArrBarr.notifyLidarr"
    private static let notificationSoundNameKey = "ArrBarr.notificationSoundName"
    /// Sentinel value stored in `notificationSoundName` to mean "play no sound".
    public static let silentSoundName = "__none__"
    private static let blurWhisparrPostersKey = "ArrBarr.blurWhisparrPosters"
    private static let whisparrAgeConfirmedKey = "ArrBarr.whisparrAgeConfirmed"
    private static let fontScaleKey = "ArrBarr.fontScale"
    private static let aiKnowsAboutWhisparrKey = "ArrBarr.aiKnowsAboutWhisparr"
    private static let launchAtLoginKey = "ArrBarr.launchAtLogin"
    private static let appLanguageKey = "ArrBarr.appLanguage"
    private static let appearanceKey = "ArrBarr.appearance"
    private static let arrOrderKey = "ArrBarr.arrOrder"
    private static let showTonightKey = "ArrBarr.showTonight"
    private static let showNeedsYouKey = "ArrBarr.showNeedsYou"
    private static let collapsedArrsKey = "ArrBarr.collapsedArrs"
    private static let tonightHoursKey = "ArrBarr.tonightHours"
    private static let showIndexerIssuesKey = "ArrBarr.showIndexerIssues"
    private static let welcomeSeenVersionKey = "ArrBarr.welcomeSeenVersion"
    private static let aiEnabledKey = "ArrBarr.aiEnabled"
    private static let chatProviderKey = "ArrBarr.chatProvider"
    nonisolated static let openaiConfigKey = "ArrBarr.openai"
    nonisolated static let tmdbApiKeyKey = "ArrBarr.tmdbApiKey"
    private static let mcpEnabledKey = "ArrBarr.mcpEnabled"
    private static let mcpHostPortKey = "ArrBarr.mcpHostPort"
    private static let mcpRequireAuthKey = "ArrBarr.mcpRequireAuth"
    private static let mcpDisabledToolsKey = "ArrBarr.mcpDisabledTools"
    // nonisolated: read from the nonisolated migration helpers below (and the
    // widget extension under Swift 6 strict concurrency), so it must not inherit
    // the class's @MainActor isolation.
    nonisolated private static let groupMigrationDoneKey = "ArrBarr.groupMigrationDone"
    nonisolated private static let secretsMigratedKey = "ArrBarr.secretsMigratedToKeychain"
    /// Exposed for testing only — lets tests assert on the done-flag key name
    /// without making it fully public.
    nonisolated static var groupMigrationDoneKeyForTesting: String { groupMigrationDoneKey }

    public init(defaults: UserDefaults = ConfigStore.resolveDefaults(),
                secrets: SecretStore? = nil) {
        self.defaults = defaults
        let store = secrets ?? Self.makeDefaultSecretStore(defaults: defaults)
        self.secrets = store
        #if APPSTORE
        // Stably-signed + entitled: secrets belong in the (iCloud-synced) Keychain.
        Self.migrateSecretsToKeychain(defaults: defaults, secrets: store)
        #else
        // Ad-hoc / OSS build: the file Keychain prompts on every rebuild, so
        // secrets live in UserDefaults. If a previous build pushed them into the
        // Keychain (and blanked them here), pull them back out once.
        Self.recoverSecretsFromKeychainIfNeeded(defaults: defaults, secrets: store)
        #endif
        applyValues(from: defaults)
        setupSinks()
    }

    /// Production secret backend: the iCloud-synced Keychain only in App Store
    /// builds (stably signed + entitled, so no password prompts); UserDefaults
    /// otherwise, because an ad-hoc-signed build's file-Keychain access prompts
    /// for the login password on every rebuild.
    nonisolated static func makeDefaultSecretStore(defaults: UserDefaults) -> SecretStore {
        #if APPSTORE
        return KeychainSecretStore()
        #else
        return UserDefaultsSecretStore(defaults: defaults)
        #endif
    }

    /// One-time recovery for non-App-Store builds: if an earlier build migrated
    /// secrets INTO the Keychain (and blanked them in UserDefaults), read them
    /// back out into `secrets` (UserDefaults) so the app works without per-launch
    /// Keychain prompts. Prompts once for the items the old build created, then
    /// clears the migration flag so it never runs again. A cancelled prompt
    /// leaves the flag set so the next launch can retry.
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
        if recoveredAny { defaults.set(false, forKey: secretsMigratedKey) }
    }

    /// Load every published value from `defaults`. Called once at init (before
    /// sinks exist, so no spurious writes) and again by `useStore` on a live
    /// swap (sinks are torn down first there, so still no spurious writes).
    /// (Exception: on iOS it normalizes the `AppleLanguages` key, a harmless
    /// write to the target store.)
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
        let fgKey = Self.foregroundIntervalKey
        self.foregroundInterval = defaults.object(forKey: fgKey) != nil ? defaults.double(forKey: fgKey) : 5
        let bgKey = Self.backgroundIntervalKey
        self.backgroundInterval = defaults.object(forKey: bgKey) != nil ? defaults.double(forKey: bgKey) : 30
        self.notifyRadarr = defaults.object(forKey: Self.notifyRadarrKey) != nil ? defaults.bool(forKey: Self.notifyRadarrKey) : true
        self.notifySonarr = defaults.object(forKey: Self.notifySonarrKey) != nil ? defaults.bool(forKey: Self.notifySonarrKey) : true
        self.notifyLidarr = defaults.object(forKey: Self.notifyLidarrKey) != nil ? defaults.bool(forKey: Self.notifyLidarrKey) : true
        self.notificationSoundName = defaults.string(forKey: Self.notificationSoundNameKey) ?? ""
        self.blurWhisparrPosters = defaults.object(forKey: Self.blurWhisparrPostersKey) != nil ? defaults.bool(forKey: Self.blurWhisparrPostersKey) : true
        self.whisparrAgeConfirmed = defaults.bool(forKey: Self.whisparrAgeConfirmedKey)
        // `defaults.double(forKey:)` returns 0.0 when the key isn't set,
        // which we treat as "use the default 1.0". Validating against
        // `fontScaleOptions` would silently reset old saved values when
        // the option list changes — we accept any positive double so
        // upgrades don't kick the user back to Default.
        let storedScale = defaults.double(forKey: Self.fontScaleKey)
        self.fontScale = storedScale > 0 ? storedScale : 1.0
        self.aiKnowsAboutWhisparr = defaults.object(forKey: Self.aiKnowsAboutWhisparrKey) != nil ? defaults.bool(forKey: Self.aiKnowsAboutWhisparrKey) : false
        self.launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) != nil ? defaults.bool(forKey: Self.launchAtLoginKey) : false
        self.appLanguage = defaults.string(forKey: Self.appLanguageKey) ?? "system"
        self.appearance = defaults.string(forKey: Self.appearanceKey) ?? "system"
        #if os(iOS)
        // iOS has no language picker — always follow the system language, and
        // clear any per-app override an older build may have left behind.
        self.appLanguage = "system"
        defaults.removeObject(forKey: "AppleLanguages")
        #endif
        self.arrOrder = Self.normalizeArrOrder(defaults.stringArray(forKey: Self.arrOrderKey))
        self.showTonight = defaults.object(forKey: Self.showTonightKey) != nil ? defaults.bool(forKey: Self.showTonightKey) : true
        self.showNeedsYou = defaults.object(forKey: Self.showNeedsYouKey) != nil ? defaults.bool(forKey: Self.showNeedsYouKey) : true
        self.showIndexerIssues = defaults.object(forKey: Self.showIndexerIssuesKey) != nil ? defaults.bool(forKey: Self.showIndexerIssuesKey) : true
        #if os(iOS)
        // iOS settings are intentionally minimal: indexer warnings are off,
        // foreground polling is a fixed 5s, and the theme always follows the
        // system (no pickers for any of these).
        self.showIndexerIssues = false
        self.foregroundInterval = 5
        self.appearance = "system"
        #endif
        self.collapsedArrs = Set(defaults.stringArray(forKey: Self.collapsedArrsKey) ?? [])
        // Hard-coded to 7 days (168h). Old stored values from when the
        // picker was UI-exposed are ignored — users get the new
        // default regardless.
        self.tonightHours = 168
        self.welcomeSeenVersion = defaults.string(forKey: Self.welcomeSeenVersionKey)
        self.aiEnabled = defaults.object(forKey: Self.aiEnabledKey) != nil
            ? defaults.bool(forKey: Self.aiEnabledKey) : false
        // Default to Apple Intelligence, but coerce to OpenAI on devices that
        // don't support Foundation Models — otherwise the stored value stays
        // `.foundationModels` while the Settings picker (which hides the
        // unsupported option) visually highlights OpenAI, so the UI lies AND
        // the chat resolves to an Unavailable provider.
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
        self.mcpEnabled = defaults.bool(forKey: Self.mcpEnabledKey)
        self.mcpHostPort = defaults.string(forKey: Self.mcpHostPortKey) ?? "127.0.0.1:8080"
        self.mcpRequireAuth = defaults.bool(forKey: Self.mcpRequireAuthKey)
        self.mcpAuthToken = MCPTokenStore.read() ?? ""
        self.mcpDisabledTools = Set(defaults.stringArray(forKey: Self.mcpDisabledToolsKey) ?? [])
        // Drop legacy username/password keys (replaced by the Keychain token).
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
        $foregroundInterval.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.foregroundIntervalKey)
        }.store(in: &cancellables)
        $backgroundInterval.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.backgroundIntervalKey)
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
        $arrOrder.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.arrOrderKey)
        }.store(in: &cancellables)
        $showTonight.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showTonightKey)
        }.store(in: &cancellables)
        $showNeedsYou.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showNeedsYouKey)
        }.store(in: &cancellables)
        $showIndexerIssues.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.showIndexerIssuesKey)
        }.store(in: &cancellables)
        $collapsedArrs.dropFirst().sink { [weak self] val in
            self?.defaults.set(Array(val), forKey: Self.collapsedArrsKey)
        }.store(in: &cancellables)
        $tonightHours.dropFirst().sink { [weak self] val in
            self?.defaults.set(val, forKey: Self.tonightHoursKey)
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
            if val == "system" {
                self.defaults.removeObject(forKey: "AppleLanguages")
            } else {
                self.defaults.set([val], forKey: "AppleLanguages")
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

    /// Re-point the backing store to the demo suite (`on == true`) or the real
    /// profile, in place, reloading all values. Used by the demo toggle on both
    /// platforms so demo edits never reach `.standard`.
    public func useDemoStore(_ on: Bool) {
        useStore(on ? (DemoMode.demoDefaults ?? .standard) : (WidgetDataStore.groupDefaults() ?? .standard))
        // Mirror demo state into the group suite so the widget extension (a
        // separate process that can't see the app's `.standard`) renders demo
        // data too, and nudge WidgetKit to pick it up immediately.
        WidgetDataStore.setDemoActive(on)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Swap to an explicit backing store and reload. Internal seam for tests.
    /// Tears down sinks BEFORE reloading so the reload assignments don't fire
    /// persistence writes or side effects (notably the `launchAtLogin` sink,
    /// which would otherwise (de)register the real login item from the new
    /// store's value). `setupSinks()` re-subscribes with `dropFirst()`, so the
    /// freshly-loaded values are not re-persisted.
    func useStore(_ target: UserDefaults) {
        guard target !== defaults else { return }
        cancellables.removeAll()
        defaults = target
        applyValues(from: target)
        setupSinks()
    }

    /// Reload all published values from the current backing store without
    /// re-firing persistence writes. Used by `KVSyncCoordinator` after it applies
    /// inbound iCloud changes into UserDefaults.
    public func reloadFromDefaults() {
        cancellables.removeAll()
        applyValues(from: defaults)
        setupSinks()
    }

    /// Seed demo configs once. Enables Radarr/Sonarr/Lidarr; leaves Whisparr off
    /// (opt-in, age gated). The seed-done flag lives in the current backing
    /// store, so wiping the demo suite re-arms it. Caller guards on demo being
    /// active (see DemoMode.seedConfigsIfNeeded).
    func seedDemoConfigsIfNeeded() {
        guard !defaults.bool(forKey: DemoMode.seedDoneKey) else { return }
        if radarr == .empty { radarr.enabled = true }
        if sonarr == .empty { sonarr.enabled = true }
        if lidarr == .empty { lidarr.enabled = true }
        // Turn the AI chat on so the demo showcases it out of the box. The chat
        // runs on DemoChatProvider (no key / no Apple Intelligence needed); the
        // aiConfigured demo-override makes the tab appear regardless of provider.
        if !aiEnabled { aiEnabled = true }
        defaults.set(true, forKey: DemoMode.seedDoneKey)
    }

    /// `true` when the user has supplied a TMDB v3 API key. Drives whether the
    /// discovery chat tools are advertised to the LLM.
    public var tmdbEnabled: Bool { !tmdbApiKey.isEmpty }

    /// Lookup the matching `ServiceConfig` for an arr `Source`. Replaces the
    /// four-way switch that several views and view-models duplicate when they
    /// need to pull the poster auth key, base URL, etc.
    public func serviceConfig(for source: QueueItem.Source) -> ServiceConfig {
        switch source {
        case .radarr:   return radarr
        case .sonarr:   return sonarr
        case .lidarr:   return lidarr
        case .whisparr: return whisparr
        }
    }

    /// True when posters from this source should render blurred (currently
    /// only Whisparr, gated by `blurWhisparrPosters`). Eight or so views
    /// previously inlined `source == .whisparr && blurWhisparrPosters`; this
    /// keeps the policy in one place.
    public func shouldBlurPoster(for source: QueueItem.Source) -> Bool {
        source == .whisparr && blurWhisparrPosters
    }

    private func publisher(for kind: ServiceKind) -> Published<ServiceConfig>.Publisher {
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

    public func toggleCollapsed(_ key: String) {
        if collapsedArrs.contains(key) {
            collapsedArrs.remove(key)
        } else {
            collapsedArrs.insert(key)
        }
    }

    public func isCollapsed(_ key: String) -> Bool {
        collapsedArrs.contains(key)
    }

    public func toggleCollapsed(_ arr: QueueItem.Source) { toggleCollapsed(arr.rawValue) }
    public func isCollapsed(_ arr: QueueItem.Source) -> Bool { isCollapsed(arr.rawValue) }

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
        // Migration for users from <0.7.x: prepend "tonight" then "needsyou"
        // so they sit at the top by default (matching the previous layout
        // where the Tonight banner was above and Needs you sat first in the
        // queue tab). Other missing keys get appended in canonical order.
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

    /// Extension-safe config read. The widget process must NOT construct
    /// `ConfigStore.shared` (it is @MainActor and spins up Combine sinks,
    /// keychain migration, and LaunchAtLogin). This decodes a single service's
    /// config straight from a `UserDefaults` suite.
    public nonisolated static func decodeServiceConfig(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        load(kind, from: defaults)
    }

    private func setOrDelete(_ value: String, for key: SecretKey) {
        if value.isEmpty { secrets.delete(key) } else { secrets.set(value, for: key) }
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

    /// Load a service config from `defaults` and merge its secrets back in from
    /// the secret store.
    private func loadService(_ kind: ServiceKind) -> ServiceConfig {
        var cfg = Self.load(kind, from: defaults)   // non-secret fields (secrets blank)
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }

    // MARK: - One-shot migration of plaintext secrets into the SecretStore

    /// One-shot: pull secrets out of legacy plaintext config/openai/tmdb values
    /// in `defaults` into `secrets`, then blank them in `defaults`. Idempotent.
    nonisolated static func migrateSecretsToKeychain(defaults: UserDefaults, secrets: SecretStore) {
        guard !defaults.bool(forKey: secretsMigratedKey) else { return }

        for kind in ServiceKind.allCases {
            guard let data = defaults.data(forKey: key(kind)),
                  var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
            else { continue }
            var changed = false
            if !cfg.apiKey.isEmpty {
                secrets.set(cfg.apiKey, for: .apiKey(for: kind)); cfg.apiKey = ""; changed = true
            }
            if !cfg.password.isEmpty {
                secrets.set(cfg.password, for: .password(for: kind)); cfg.password = ""; changed = true
            }
            if changed, let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: key(kind))
            }
        }

        if let data = defaults.data(forKey: openaiConfigKey),
           var cfg = try? JSONDecoder().decode(OpenAIConfig.self, from: data),
           !cfg.apiKey.isEmpty {
            secrets.set(cfg.apiKey, for: .openAIKey)
            cfg.apiKey = ""
            if let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: openaiConfigKey)
            }
        }

        if let tmdb = defaults.string(forKey: tmdbApiKeyKey), !tmdb.isEmpty {
            secrets.set(tmdb, for: .tmdbKey)
            defaults.removeObject(forKey: tmdbApiKeyKey)
        }

        defaults.set(true, forKey: secretsMigratedKey)
    }

}
