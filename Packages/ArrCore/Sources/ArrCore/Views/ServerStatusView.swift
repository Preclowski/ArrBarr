import SwiftUI

/// Settings → Status: a glanceable server dashboard, one page deep in Settings.
/// Rolls up connection health for every configured service, arr `/health`
/// warnings, live queue activity, and disk space across root mounts — the
/// "is my homelab OK?" glance. Read-only: it observes the shared health/queue
/// singletons and owns only the `/diskspace` fetch (`ServerStatusModel`).
struct ServerStatusView: View {
    @State private var status = ServerStatusModel()

    var body: some View {
        Form {
            servicesSection
            storageSection
            activitySection
            warningsSection
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(Text("settings.status.button", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await status.refresh() }
    }

    // MARK: - Services

    @ViewBuilder
    private var servicesSection: some View {
        let services = Self.configuredServices()
        Section {
            if services.isEmpty {
                Text("status.noServices.label", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(services, id: \.id) { service in
                    serviceRow(service)
                }
            }
        } header: {
            HStack {
                Text("status.services.header", bundle: .module)
                Spacer()
                refreshControl
            }
            .textCase(nil)
        }
    }

    private func serviceRow(_ service: MonitoredService) -> some View {
        let snapshot = ConnectionHealth.shared.snapshot(for: service)
        return HStack(spacing: 10) {
            serviceIcon(service)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                // "Plex", not "Media server": the row sits next to Radarr and
                // Sonarr, which name themselves, and the connected server is
                // the thing whose health this is.
                Text(verbatim: Self.rowTitle(service))
                if let detail = Self.detailText(snapshot.state) {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let count = warningCount(service), count > 0 {
                Label(String(count), systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            statusPill(snapshot.state)
        }
    }

    @ViewBuilder
    private func serviceIcon(_ service: MonitoredService) -> some View {
        if let kind = service.serviceKind {
            ServiceIcon(kind: kind, size: 16)
        } else {
            switch service {
            case .openai: brandMark("brand-openai")
            case .tmdb:   brandMark("brand-tmdb")
            case .mediaServer:
                ServiceIcon(mediaServer: ConfigStore.shared.mediaServer.kind, size: 16)
            case .arr:    EmptyView()
            }
        }
    }

    /// Brand mark from `ServiceIcons.xcassets`, sized like the arr icons beside
    /// it and inheriting the same foreground — dimming it to `.secondary` made
    /// OpenAI and TMDB read as a lesser class of service than the arrs.
    private func brandMark(_ name: String) -> some View {
        Image(name, bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
    }

    private func statusPill(_ state: ConnectionHealthState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.color(for: state))
                .frame(width: 7, height: 7)
            Text(Self.stateLabel(for: state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Warning + error count from the arr's `/health` records (nil for
    /// non-arr services, which don't report health warnings).
    private func warningCount(_ service: MonitoredService) -> Int? {
        guard let source = Self.arrSource(service) else { return nil }
        return QueueViewModel.shared.health.records(for: source)
            .filter { Self.isActionable($0.type) }
            .count
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageSection: some View {
        Section {
            if status.isRefreshing && status.disks.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("status.checking.label", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            } else if status.disks.isEmpty {
                Text("status.noStorage.label", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(status.disks) { disk in
                    diskRow(disk)
                }
            }
        } header: {
            Text("status.storage.header", bundle: .module)
        }
    }

    private func diskRow(_ disk: DiskSpace) -> some View {
        let hasLabel = !(disk.label ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(verbatim: hasLabel ? disk.label! : disk.path)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(
                    format: String(localized: "status.freeOfTotal.label", bundle: .module),
                    Self.bytes(disk.freeSpace),
                    Self.bytes(disk.totalSpace)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            usageBar(fraction: disk.usedFraction, tint: Self.usageTint(free: disk.freeSpace, total: disk.totalSpace))
            if hasLabel {
                Text(verbatim: disk.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Custom bar (GeometryReader + RoundedRectangle) — SwiftUI's linear
    /// `ProgressView` ignores `.frame(height:)`.
    private func usageBar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        let active = Self.activeItems()
        Section {
            if active.isEmpty {
                Text("status.noActiveDownloads.label", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(
                        format: String(localized: "status.activeDownloads.label", bundle: .module),
                        active.count
                    ))
                    Spacer(minLength: 8)
                    let remaining = active.reduce(Int64(0)) { $0 + max(0, $1.sizeLeft) }
                    if remaining > 0 {
                        Text(String(
                            format: String(localized: "status.remaining.label", bundle: .module),
                            Self.bytes(remaining)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("status.activity.header", bundle: .module)
        }
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warningsSection: some View {
        let warnings = Self.warningItems()
        if !warnings.isEmpty {
            Section {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, item in
                    warningRow(source: item.source, record: item.record)
                }
            } header: {
                Text("settings.warnings.header", bundle: .module)
            }
        }
    }

    private func warningRow(source: QueueItem.Source, record: ArrHealthRecord) -> some View {
        let isError = record.type?.lowercased() == "error"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isError ? .red : .orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: source.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: record.message ?? "")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let wiki = record.wikiUrl, let url = URL(string: wiki) {
                Link(destination: url) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .help(Text("detail.openInBrowser.button", bundle: .module))
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Refresh control

    private var refreshControl: some View {
        HStack(spacing: 6) {
            if let last = status.lastRefresh, !status.isRefreshing {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await status.refresh() }
            } label: {
                if status.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(status.isRefreshing)
            .help(Text("status.refresh.button", bundle: .module))
        }
    }

    // MARK: - Data helpers

    /// Every configured monitored service, in display order: arrs, then
    /// download clients, then the AI services.
    /// Display name for a status row. Everything names itself except the media
    /// server, whose `displayName` has to stay generic (the enum case carries
    /// no kind — there is only ever one connection, and it lives in config).
    private static func rowTitle(_ service: MonitoredService) -> String {
        guard case .mediaServer = service else { return service.displayName }
        return ConfigStore.shared.mediaServer.kind.displayName
    }

    private static func configuredServices() -> [MonitoredService] {
        let store = ConfigStore.shared
        return MonitoredService.allCases.filter { $0.isConfigured(in: store) }
    }

    /// Queue items still in flight across every arr.
    private static func activeItems() -> [QueueItem] {
        QueueViewModel.shared.queues.values
            .flatMap { $0 }
            .filter { $0.status != .completed }
    }

    /// Actionable `/health` records (warning + error) across every arr, each
    /// tagged with its source for the row label.
    private static func warningItems() -> [(source: QueueItem.Source, record: ArrHealthRecord)] {
        let health = QueueViewModel.shared.health
        return QueueItem.Source.allCases.flatMap { source in
            health.records(for: source)
                .filter { isActionable($0.type) }
                .map { (source, $0) }
        }
    }

    private static func arrSource(_ service: MonitoredService) -> QueueItem.Source? {
        guard let kind = service.serviceKind else { return nil }
        return QueueItem.Source.allCases.first { $0.serviceKind == kind }
    }

    private static func isActionable(_ type: String?) -> Bool {
        switch type?.lowercased() {
        case "warning", "error": return true
        default: return false
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Green until the disk gets tight, amber under 15% free, red under 7%.
    private static func usageTint(free: Int64, total: Int64) -> Color {
        guard total > 0 else { return .green }
        let freeFraction = Double(free) / Double(total)
        if freeFraction < 0.07 { return .red }
        if freeFraction < 0.15 { return .orange }
        return .green
    }

    private static func color(for state: ConnectionHealthState) -> Color {
        switch state {
        case .ok:      return .green
        case .down:    return .red
        case .unknown: return .secondary
        }
    }

    private static func detailText(_ state: ConnectionHealthState) -> String? {
        switch state {
        case .ok(let detail):     return detail
        case .down(let message):  return message
        case .unknown:            return nil
        }
    }

    private static func stateLabel(for state: ConnectionHealthState) -> String {
        switch state {
        case .ok:      return String(localized: "health.connected.label", bundle: .module)
        case .down:    return String(localized: "health.unreachable.label", bundle: .module)
        case .unknown: return String(localized: "health.unknown.label", bundle: .module)
        }
    }
}
