import Foundation
import MediaKit

extension QueueViewModel {
    // MARK: - Connection health

    /// Arr dots come from the queue fetch; download clients and AI are probed by `connectionMonitor`.
    /// `only` limits arr recording to the source that fetched: replaying a stored error burns 3-strike budget.
    func updateConnectionHealth(
        errors: [QueueItem.Source: String], only: QueueItem.Source? = nil
    ) {
        for source in QueueItem.Source.allCases where only == nil || only == source {
            let service = MonitoredService.arr(source.serviceKind)
            if service.isConfigured(in: configStore) {
                ConnectionHealth.shared.record(
                    service,
                    success: errors[source] == nil,
                    detail: nil,
                    message: errors[source]
                )
            } else {
                ConnectionHealth.shared.markUnknown(service)
            }
        }
        for service in MonitoredService.probeTargets where !service.isConfigured(in: configStore) {
            ConnectionHealth.shared.markUnknown(service)
        }
        applyBreakers()
        // The probe sweep only colours dots inside the panel; opening it runs a refresh that lands here.
        guard isPanelVisible else { return }
        let inputs = buildProbeInputs()
        Task { [connectionMonitor] in
            let outcomes = await connectionMonitor.probeIfDue(inputs, force: false)
            for outcome in outcomes {
                ConnectionHealth.shared.record(
                    outcome.service,
                    success: outcome.success,
                    detail: outcome.detail,
                    message: outcome.message
                )
            }
        }
    }

    /// Probe now, bypassing the throttle, and pin the outcome without debounce — a probe of just-saved
    /// settings is proof. The dot drops to grey meanwhile so a stale result never lingers.
    func reprobe(_ service: MonitoredService) {
        ConnectionHealth.shared.markUnknown(service)
        guard service.isConfigured(in: configStore) else { return }
        let inputs = buildProbeInputs()
        Task { [connectionMonitor] in
            let outcome = await connectionMonitor.probe(service, inputs)
            if outcome.success {
                ConnectionHealth.shared.forceOK(service, detail: outcome.detail)
            } else {
                ConnectionHealth.shared.forceDown(service, message: outcome.message ?? "")
            }
        }
    }

    private func buildProbeInputs() -> ConnectionHealthMonitor.ProbeInputs {
        var clients: [ServiceKind: ServiceConfig] = [:]
        for kind in MonitoredService.downloadClientKinds where MonitoredService.arr(kind).isConfigured(in: configStore) {
            clients[kind] = configStore.config(for: kind)
        }
        let openai = configStore.openai.isConfigured ? configStore.openai : nil
        let tmdb = configStore.tmdbApiKey.isEmpty ? nil : configStore.tmdbApiKey
        // Control-gated: a lapsed entitlement must not keep probing the user's server.
        let mediaServer = (configStore.mediaServer.isConfigured && StoreManager.shared.isPro)
            ? configStore.mediaServer : nil
        let prowlarr = MonitoredService.prowlarr.isConfigured(in: configStore)
        return .init(clients: clients, openai: openai, tmdbKey: tmdb, mediaServer: mediaServer,
                     prowlarr: prowlarr)
    }

    /// "Needs you" rows for down download clients and AI; arr issues come from `computeNeedsYou`.
    func serviceIssueRows() -> [NeedsYouItem] {
        return MonitoredService.probeTargets.compactMap { service in
            guard case .down(let message) = ConnectionHealth.shared.state(for: service) else { return nil }
            return NeedsYouItem(serviceIssue: service, message: message)
        }
    }

    /// Same selection order as `QueueAggregator.performTorrent` / `performUsenet`.
    func failedDownloadClientKind(for item: QueueItem) -> ServiceKind? {
        configStore.selectedDownloadClient(for: item.downloadProtocol)
    }

    /// Only unreachable/breaker-open/auth failures pin the client down. A rejection of this one item (a 404, a
    /// usenet `{status:false}`, an undecodable body) must not strip pause/resume from every row.
    func actionFailureProvesClientDown(_ error: Error) -> Bool {
        switch error as? MediaKitError {
        case .unreachable, .breakerOpen, .unauthorized: true
        default: false
        }
    }
}
