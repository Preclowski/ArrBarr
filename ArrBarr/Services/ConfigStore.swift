import Foundation
import Combine

/// Trzyma konfigurację wszystkich usług w UserDefaults.
/// Świadomie nie używa Keychain — to jest lokalna aplikacja użytkownika do self-hostowanych
/// usług w prywatnej sieci. Jak zajdzie potrzeba, łatwo to wymienić.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var radarr: ServiceConfig
    @Published var sonarr: ServiceConfig
    @Published var sabnzbd: ServiceConfig
    @Published var qbittorrent: ServiceConfig

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.radarr = Self.load(.radarr, from: defaults)
        self.sonarr = Self.load(.sonarr, from: defaults)
        self.sabnzbd = Self.load(.sabnzbd, from: defaults)
        self.qbittorrent = Self.load(.qbittorrent, from: defaults)

        // Persist on every change.
        $radarr.dropFirst().sink { [weak self] in self?.save(.radarr, $0) }.store(in: &cancellables)
        $sonarr.dropFirst().sink { [weak self] in self?.save(.sonarr, $0) }.store(in: &cancellables)
        $sabnzbd.dropFirst().sink { [weak self] in self?.save(.sabnzbd, $0) }.store(in: &cancellables)
        $qbittorrent.dropFirst().sink { [weak self] in self?.save(.qbittorrent, $0) }.store(in: &cancellables)
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
