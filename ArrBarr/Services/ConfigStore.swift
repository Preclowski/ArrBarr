import Foundation
import Combine
import ServiceManagement
import os

enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "com.preclowski.ArrBarr", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
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
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    @MainActor static let shared = ConfigStore()

    @Published var radarr: ServiceConfig
    @Published var sonarr: ServiceConfig
    @Published var lidarr: ServiceConfig
    @Published var sabnzbd: ServiceConfig
    @Published var qbittorrent: ServiceConfig
    @Published var nzbget: ServiceConfig
    @Published var transmission: ServiceConfig
    @Published var rtorrent: ServiceConfig
    @Published var deluge: ServiceConfig
    @Published var foregroundInterval: TimeInterval
    @Published var backgroundInterval: TimeInterval
    @Published var notifyRadarr: Bool
    @Published var notifySonarr: Bool
    @Published var notifyLidarr: Bool
    @Published var launchAtLogin: Bool
    @Published var appLanguage: String
    @Published var arrOrder: [String]
    @Published var showTonight: Bool
    @Published var showNeedsYou: Bool
    @Published var showIndexerIssues: Bool
    @Published var collapsedArrs: Set<String>
    @Published var tonightHours: Int
    /// Last `WelcomeContent.currentVersion` the user dismissed. `nil` means
    /// they've never seen the welcome screen — first launch shows the
    /// firstRun variant.
    @Published var welcomeSeenVersion: String?

    static let needsYouOrderKey = "needsyou"
    static let tonightOrderKey = "tonight"
    static let defaultArrOrder = ["tonight", "needsyou", "radarr", "sonarr", "lidarr"]
    static let tonightHoursOptions = [12, 24, 72]

    static let appLanguageOptions: [(code: String, label: String)] = [
        ("system", "System"),
        ("en", "English"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("pl", "Polski"),
    ]

    var currentLocale: Locale {
        if appLanguage == "system" { return .autoupdatingCurrent }
        return Locale(identifier: appLanguage)
    }

    static let foregroundIntervalOptions: [TimeInterval] = [0, 2, 5, 10, 15, 30]
    static let backgroundIntervalOptions: [TimeInterval] = [0, 10, 30, 60, 120, 300]

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    private static let foregroundIntervalKey = "ArrBarr.foregroundInterval"
    private static let backgroundIntervalKey = "ArrBarr.backgroundInterval"
    private static let notifyRadarrKey = "ArrBarr.notifyRadarr"
    private static let notifySonarrKey = "ArrBarr.notifySonarr"
    private static let notifyLidarrKey = "ArrBarr.notifyLidarr"
    private static let launchAtLoginKey = "ArrBarr.launchAtLogin"
    private static let appLanguageKey = "ArrBarr.appLanguage"
    private static let arrOrderKey = "ArrBarr.arrOrder"
    private static let showTonightKey = "ArrBarr.showTonight"
    private static let showNeedsYouKey = "ArrBarr.showNeedsYou"
    private static let collapsedArrsKey = "ArrBarr.collapsedArrs"
    private static let tonightHoursKey = "ArrBarr.tonightHours"
    private static let showIndexerIssuesKey = "ArrBarr.showIndexerIssues"
    private static let welcomeSeenVersionKey = "ArrBarr.welcomeSeenVersion"
    private static let keychainMigrationDoneKey = "ArrBarr.keychainMigrationDone"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // One-time migration: pull any leftover Keychain secrets from older
        // versions back into UserDefaults so they're loaded normally below.
        // Without an Apple Developer ID, ad-hoc signed builds change identity
        // every release, which makes Keychain prompt for the user's password
        // on every launch — terrible UX. Storing in the sandbox container's
        // UserDefaults avoids the prompts entirely.
        if !defaults.bool(forKey: Self.keychainMigrationDoneKey) {
            Self.migrateLegacyKeychainSecrets(defaults: defaults)
            defaults.set(true, forKey: Self.keychainMigrationDoneKey)
        }
        self.radarr = Self.load(.radarr, from: defaults)
        self.sonarr = Self.load(.sonarr, from: defaults)
        self.lidarr = Self.load(.lidarr, from: defaults)
        self.sabnzbd = Self.load(.sabnzbd, from: defaults)
        self.qbittorrent = Self.load(.qbittorrent, from: defaults)
        self.nzbget = Self.load(.nzbget, from: defaults)
        self.transmission = Self.load(.transmission, from: defaults)
        self.rtorrent = Self.load(.rtorrent, from: defaults)
        self.deluge = Self.load(.deluge, from: defaults)
        let fgKey = Self.foregroundIntervalKey
        self.foregroundInterval = defaults.object(forKey: fgKey) != nil ? defaults.double(forKey: fgKey) : 5
        let bgKey = Self.backgroundIntervalKey
        self.backgroundInterval = defaults.object(forKey: bgKey) != nil ? defaults.double(forKey: bgKey) : 30
        self.notifyRadarr = defaults.object(forKey: Self.notifyRadarrKey) != nil ? defaults.bool(forKey: Self.notifyRadarrKey) : false
        self.notifySonarr = defaults.object(forKey: Self.notifySonarrKey) != nil ? defaults.bool(forKey: Self.notifySonarrKey) : false
        self.notifyLidarr = defaults.object(forKey: Self.notifyLidarrKey) != nil ? defaults.bool(forKey: Self.notifyLidarrKey) : false
        self.launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) != nil ? defaults.bool(forKey: Self.launchAtLoginKey) : false
        self.appLanguage = defaults.string(forKey: Self.appLanguageKey) ?? "system"
        self.arrOrder = Self.normalizeArrOrder(defaults.stringArray(forKey: Self.arrOrderKey))
        self.showTonight = defaults.object(forKey: Self.showTonightKey) != nil ? defaults.bool(forKey: Self.showTonightKey) : true
        self.showNeedsYou = defaults.object(forKey: Self.showNeedsYouKey) != nil ? defaults.bool(forKey: Self.showNeedsYouKey) : true
        self.showIndexerIssues = defaults.object(forKey: Self.showIndexerIssuesKey) != nil ? defaults.bool(forKey: Self.showIndexerIssuesKey) : true
        self.collapsedArrs = Set(defaults.stringArray(forKey: Self.collapsedArrsKey) ?? [])
        let storedTonight = defaults.object(forKey: Self.tonightHoursKey) as? Int ?? 12
        self.tonightHours = Self.tonightHoursOptions.contains(storedTonight) ? storedTonight : 12
        self.welcomeSeenVersion = defaults.string(forKey: Self.welcomeSeenVersionKey)

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
    }

    private func publisher(for kind: ServiceKind) -> Published<ServiceConfig>.Publisher {
        switch kind {
        case .radarr: $radarr
        case .sonarr: $sonarr
        case .lidarr: $lidarr
        case .sabnzbd: $sabnzbd
        case .qbittorrent: $qbittorrent
        case .nzbget: $nzbget
        case .transmission: $transmission
        case .rtorrent: $rtorrent
        case .deluge: $deluge
        }
    }

    func config(for kind: ServiceKind) -> ServiceConfig {
        switch kind {
        case .radarr: return radarr
        case .sonarr: return sonarr
        case .lidarr: return lidarr
        case .sabnzbd: return sabnzbd
        case .qbittorrent: return qbittorrent
        case .nzbget: return nzbget
        case .transmission: return transmission
        case .rtorrent: return rtorrent
        case .deluge: return deluge
        }
    }

    func toggleCollapsed(_ key: String) {
        if collapsedArrs.contains(key) {
            collapsedArrs.remove(key)
        } else {
            collapsedArrs.insert(key)
        }
    }

    func isCollapsed(_ key: String) -> Bool {
        collapsedArrs.contains(key)
    }

    func toggleCollapsed(_ arr: QueueItem.Source) { toggleCollapsed(arr.rawValue) }
    func isCollapsed(_ arr: QueueItem.Source) -> Bool { isCollapsed(arr.rawValue) }

    func update(_ kind: ServiceKind, with config: ServiceConfig) {
        switch kind {
        case .radarr: radarr = config
        case .sonarr: sonarr = config
        case .lidarr: lidarr = config
        case .sabnzbd: sabnzbd = config
        case .qbittorrent: qbittorrent = config
        case .nzbget: nzbget = config
        case .transmission: transmission = config
        case .rtorrent: rtorrent = config
        case .deluge: deluge = config
        }
    }

    static func normalizeArrOrder(_ stored: [String]?) -> [String] {
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

    private static func key(_ kind: ServiceKind) -> String { "ArrBarr.config.\(kind.rawValue)" }

    private static func load(_ kind: ServiceKind, from defaults: UserDefaults) -> ServiceConfig {
        guard let data = defaults.data(forKey: key(kind)),
              let cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
        else { return .empty }
        return cfg
    }

    private func save(_ kind: ServiceKind, _ config: ServiceConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.key(kind))
        }
    }

    // MARK: - One-time migration from Keychain (0.6.0/0.6.1) back to UserDefaults

    private static func migrateLegacyKeychainSecrets(defaults: UserDefaults) {
        for kind in ServiceKind.allCases {
            guard let data = defaults.data(forKey: key(kind)),
                  var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
            else { continue }

            var changed = false
            if cfg.apiKey.isEmpty,
               let migrated = LegacyKeychain.read(account: "\(kind.rawValue).apiKey") {
                cfg.apiKey = migrated
                changed = true
            }
            if cfg.password.isEmpty,
               let migrated = LegacyKeychain.read(account: "\(kind.rawValue).password") {
                cfg.password = migrated
                changed = true
            }
            if changed, let updated = try? JSONEncoder().encode(cfg) {
                defaults.set(updated, forKey: key(kind))
                LegacyKeychain.delete(account: "\(kind.rawValue).apiKey")
                LegacyKeychain.delete(account: "\(kind.rawValue).password")
            }
        }
    }
}
