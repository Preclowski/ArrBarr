import Foundation
import MediaKit

extension QueueViewModel {
    // MARK: - Actions

    public func pause(_ item: QueueItem) async {
        await runAction(.pause, on: item)
    }
    public func resume(_ item: QueueItem) async {
        // A queued item is waiting behind the client's queue limit; "Continue" force-starts it.
        await runAction(item.status == .queued ? .continueDownload : .resume, on: item)
    }
    public func delete(_ item: QueueItem) async {
        await runAction(.delete, on: item)
    }

    /// A real pack's download is removed by the first call only; a virtual bundle's members are each
    /// removed from the client. `aggregator.deleteAll` infers which from the downloadIds.
    public func deleteAll(_ items: [QueueItem]) async {
        guard !items.isEmpty else { return }
        // The UI hides these controls when fully offline; this also blocks Siri / Shortcuts callers.
        guard !isFullyOffline else { return }
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        do {
            try await aggregator.deleteAll(items)
            lastError = nil
            if let source = items.first?.source {
                Task { await self.refreshQueue(source: source) }
            }
        } catch {
            lastError = error.userFacingMessage
        }
    }

    private func runAction(_ action: QueueAggregator.Action, on item: QueueItem) async {
        guard !isFullyOffline else { return }
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        do {
            try await aggregator.perform(action, on: item)
            lastError = nil
            // The command's effect paints the change at once; this refresh replaces it with a fact.
            Task { await self.refreshQueue(source: item.source) }
        } catch {
            let message = error.userFacingMessage
            lastError = message
            // Pin the client red only when the failure proves it down: `canControl` is client-wide, so a single
            // rejected request would strip pause/resume from every row.
            if actionFailureProvesClientDown(error), let kind = failedDownloadClientKind(for: item) {
                ConnectionHealth.shared.forceDown(.arr(kind), message: message)
            }
        }
    }
}
