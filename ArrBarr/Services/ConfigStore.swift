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

    static let foregroundIntervalOptions: [TimeInterval] = [0, 2, 5, 10, 15, 30]
    static let backgroundIntervalOptions: [TimeInterval] = [0, 10, 30, 60, 120, 300]

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private var cancellables: Set<AnyCancellable> = []

    private static let foregroundIntervalKey = "ArrBarr.foregroundInterval"
    private static let backgroundIntervalKey = "ArrBarr.backgroundInterval"
    private static let notifyRadarrKey = "ArrBarr.notifyRadarr"
    private static let notifySonarrKey = "ArrBarr.notifySonarr"
    private static let notifyLidarrKey = "ArrBarr.notifyLidarr"
    private static let launchAtLoginKey = "ArrBarr.launchAtLogin"

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        self.radarr = Self.load(.radarr, from: defaults, secrets: secrets)
        self.sonarr = Self.load(.sonarr, from: defaults, secrets: secrets)
        self.lidarr = Self.load(.lidarr, from: defaults, secrets: secrets)
        self.sabnzbd = Self.load(.sabnzbd, from: defaults, secrets: secrets)
        self.qbittorrent = Self.load(.qbittorrent, from: defaults, secrets: secrets)
        self.nzbget = Self.load(.nzbget, from: defaults, secrets: secrets)
        self.transmission = Self.load(.transmission, from: defaults, secrets: secrets)
        self.rtorrent = Self.load(.rtorrent, from: defaults, secrets: secrets)
        self.deluge = Self.load(.deluge, from: defaults, secrets: secrets)
        let fgKey = Self.foregroundIntervalKey
        self.foregroundInterval = defaults.object(forKey: fgKey) != nil ? defaults.double(forKey: fgKey) : 5
        let bgKey = Self.backgroundIntervalKey
        self.backgroundInterval = defaults.object(forKey: bgKey) != nil ? defaults.double(forKey: bgKey) : 30
        self.notifyRadarr = defaults.object(forKey: Self.notifyRadarrKey) != nil ? defaults.bool(forKey: Self.notifyRadarrKey) : false
        self.notifySonarr = defaults.object(forKey: Self.notifySonarrKey) != nil ? defaults.bool(forKey: Self.notifySonarrKey) : false
        self.notifyLidarr = defaults.object(forKey: Self.notifyLidarrKey) != nil ? defaults.bool(forKey: Self.notifyLidarrKey) : false
        self.launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) != nil ? defaults.bool(forKey: Self.launchAtLoginKey) : false

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

    // MARK: - Persistence

    private static func key(_ kind: ServiceKind) -> String { "ArrBarr.config.\(kind.rawValue)" }
    private static func apiKeyAccount(_ kind: ServiceKind) -> String { "\(kind.rawValue).apiKey" }
    private static func passwordAccount(_ kind: ServiceKind) -> String { "\(kind.rawValue).password" }

    private static func load(_ kind: ServiceKind, from defaults: UserDefaults, secrets: SecretStore) -> ServiceConfig {
        guard let data = defaults.data(forKey: key(kind)),
              var cfg = try? JSONDecoder().decode(ServiceConfig.self, from: data)
        else { return .empty }

        // Migration: if legacy JSON still carries secrets, move them to keychain
        // and rewrite the stripped blob back to defaults.
        var didMigrate = false
        if !cfg.apiKey.isEmpty {
            secrets.write(cfg.apiKey, account: apiKeyAccount(kind))
            didMigrate = true
        }
        if !cfg.password.isEmpty {
            secrets.write(cfg.password, account: passwordAccount(kind))
            didMigrate = true
        }

        cfg.apiKey = secrets.read(account: apiKeyAccount(kind)) ?? cfg.apiKey
        cfg.password = secrets.read(account: passwordAccount(kind)) ?? cfg.password

        if didMigrate {
            var stripped = cfg
            stripped.apiKey = ""
            stripped.password = ""
            if let stripped = try? JSONEncoder().encode(stripped) {
                defaults.set(stripped, forKey: key(kind))
            }
        }
        return cfg
    }

    private func save(_ kind: ServiceKind, _ config: ServiceConfig) {
        secrets.write(config.apiKey, account: Self.apiKeyAccount(kind))
        secrets.write(config.password, account: Self.passwordAccount(kind))

        var stripped = config
        stripped.apiKey = ""
        stripped.password = ""
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: Self.key(kind))
        }
    }
}
