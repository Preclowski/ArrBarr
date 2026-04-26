import Foundation
import Combine
import SwiftUI

@MainActor
final class QueueViewModel: ObservableObject {
    @Published private(set) var radarr: [QueueItem] = []
    @Published private(set) var sonarr: [QueueItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let aggregator: QueueAggregator
    private var foregroundTimer: Timer?
    private var backgroundTimer: Timer?

    var activeCount: Int {
        (radarr + sonarr).filter { $0.status != .completed }.count
    }

    init(configStore: ConfigStore = .shared) {
        self.aggregator = QueueAggregator(configStore: configStore)
        startBackgroundPolling()
    }

    deinit {
        foregroundTimer?.invalidate()
        backgroundTimer?.invalidate()
    }

    /// Wywołaj kiedy popover się otwiera. Częste odświeżanie (5s) gdy widoczne.
    func startForegroundPolling() {
        Task { await self.refresh() }
        foregroundTimer?.invalidate()
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    /// Tłem co 30s tylko po to, żeby badge w status barze był aktualny.
    private func startBackgroundPolling() {
        Task { await self.refresh() }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let result = await aggregator.fetch()
        self.radarr = result.radarr
        self.sonarr = result.sonarr
    }

    // MARK: - Actions

    func pause(_ item: QueueItem) async {
        await runAction(.pause, on: item)
    }
    func resume(_ item: QueueItem) async {
        await runAction(.resume, on: item)
    }
    func delete(_ item: QueueItem) async {
        await runAction(.delete, on: item)
    }

    private func runAction(_ action: QueueAggregator.Action, on item: QueueItem) async {
        do {
            try await aggregator.perform(action, on: item)
            lastError = nil
            // Krótka pauza, żeby klient zdążył zmienić stan, potem odśwież.
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refresh()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
