import Foundation
import Combine

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var radarr: ServiceConfig
    @Published var sonarr: ServiceConfig
    @Published var sabnzbd: ServiceConfig
    @Published var qbittorrent: ServiceConfig
    @Published var foregroundInterval: TimeInterval
    @Published var backgroundInterval: TimeInterval

    static let foregroundIntervalOptions: [TimeInterval] = [0, 2, 5, 10, 15, 30]
    static let backgroundIntervalOptions: [TimeInterval] = [0, 10, 30, 60, 120, 300]

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    private static let foregroundIntervalKey = "ArrBarr.foregroundInterval"
    private static let backgroundIntervalKey = "ArrBarr.backgroundInterval"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.radarr = Self.load(.radarr, from: defaults)
        self.sonarr = Self.load(.sonarr, from: defaults)
        self.sabnzbd = Self.load(.sabnzbd, from: defaults)
        self.qbittorrent = Self.load(.qbittorrent, from: defaults)
        let fgKey = Self.foregroundIntervalKey
        self.foregroundInterval = defaults.object(forKey: fgKey) != nil ? defaults.double(forKey: fgKey) : 5
        let bgKey = Self.backgroundIntervalKey
        self.backgroundInterval = defaults.object(forKey: bgKey) != nil ? defaults.double(forKey: bgKey) : 30

        $radarr.dropFirst().sink { [weak self] cfg in
            MainActor.assumeIsolated { self?.save(.radarr, cfg) }
        }.store(in: &cancellables)
        $sonarr.dropFirst().sink { [weak self] cfg in
            MainActor.assumeIsolated { self?.save(.sonarr, cfg) }
        }.store(in: &cancellables)
        $sabnzbd.dropFirst().sink { [weak self] cfg in
            MainActor.assumeIsolated { self?.save(.sabnzbd, cfg) }
        }.store(in: &cancellables)
        $qbittorrent.dropFirst().sink { [weak self] cfg in
            MainActor.assumeIsolated { self?.save(.qbittorrent, cfg) }
        }.store(in: &cancellables)
        $foregroundInterval.dropFirst().sink { [weak self] val in
            MainActor.assumeIsolated { self?.defaults.set(val, forKey: Self.foregroundIntervalKey) }
        }.store(in: &cancellables)
        $backgroundInterval.dropFirst().sink { [weak self] val in
            MainActor.assumeIsolated { self?.defaults.set(val, forKey: Self.backgroundIntervalKey) }
        }.store(in: &cancellables)
    }

    func config(for kind: ServiceKind) -> ServiceConfig {
        switch kind {
        case .radarr: return radarr
        case .sonarr: return sonarr
        case .sabnzbd: return sabnzbd
        case .qbittorrent: return qbittorrent
        }
    }

    func update(_ kind: ServiceKind, with config: ServiceConfig) {
        switch kind {
        case .radarr: radarr = config
        case .sonarr: sonarr = config
        case .sabnzbd: sabnzbd = config
        case .qbittorrent: qbittorrent = config
        }
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
}
