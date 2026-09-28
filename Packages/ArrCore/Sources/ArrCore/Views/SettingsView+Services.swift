import SwiftUI

extension SettingsView {
    // MARK: - Service roster (shared data)

    /// Shared roster for macOS panes and iOS forms; only the chrome differs.
    struct ServiceSpec: Identifiable {
        let kind: ServiceKind
        let title: String
        let config: Binding<ServiceConfig>
        var notify: Binding<Bool>? = nil
        var ageConfirmed: Binding<Bool>? = nil
        var nsfwFilter: Binding<Bool>? = nil
        var id: String { kind.rawValue }
    }

    var mediaManagerSpecs: [ServiceSpec] {
        [
            .init(kind: .radarr, title: "Radarr", config: $configStore.radarr, notify: $configStore.notifyRadarr),
            .init(kind: .sonarr, title: "Sonarr", config: $configStore.sonarr, notify: $configStore.notifySonarr),
            .init(kind: .lidarr, title: "Lidarr", config: $configStore.lidarr, notify: $configStore.notifyLidarr),
            .init(kind: .whisparr, title: "Whisparr", config: $configStore.whisparr,
                  ageConfirmed: $configStore.whisparrAgeConfirmed, nsfwFilter: $configStore.blurWhisparrPosters),
        ]
    }

    var downloadClientSpecs: [ServiceSpec] {
        [
            .init(kind: .sabnzbd, title: "SABnzbd", config: $configStore.sabnzbd),
            .init(kind: .nzbget, title: "NZBGet", config: $configStore.nzbget),
            .init(kind: .qbittorrent, title: "qBittorrent", config: $configStore.qbittorrent),
            .init(kind: .transmission, title: "Transmission", config: $configStore.transmission),
            .init(kind: .rtorrent, title: "rTorrent", config: $configStore.rtorrent),
            .init(kind: .deluge, title: "Deluge", config: $configStore.deluge),
        ]
    }

    func serviceFields(_ spec: ServiceSpec) -> some View {
        ServiceFields(config: spec.config, kind: spec.kind,
                      notifyBinding: spec.notify,
                      ageConfirmedBinding: spec.ageConfirmed,
                      nsfwFilterBinding: spec.nsfwFilter)
    }

    // MARK: - Panes

    @ViewBuilder
    func serviceSectionHeader(_ kind: ServiceKind, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ServiceIcon(kind: kind, size: 12)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title, bundle: .module)
        }
    }

    /// `arrOrder` also carries Upcoming / Needs you; those are filtered out here.
    func orderedByQueueSections(_ specs: [ServiceSpec]) -> [ServiceSpec] {
        let ranked = configStore.arrOrder.compactMap { key in specs.first { $0.kind.rawValue == key } }
        let rankedKinds = Set(ranked.map(\.kind))
        return ranked + specs.filter { !rankedKinds.contains($0.kind) }
    }

    /// Permutes arrs only among arr slots, so Upcoming and Needs you keep their place.
    func moveMediaManagers(from source: IndexSet, to destination: Int) {
        var order = configStore.arrOrder
        let slots = order.indices.filter { QueueItem.Source(rawValue: order[$0]) != nil }
        var keys = slots.map { order[$0] }
        keys.move(fromOffsets: source, toOffset: destination)
        for (slot, key) in zip(slots, keys) { order[slot] = key }
        configStore.arrOrder = order
    }
}
