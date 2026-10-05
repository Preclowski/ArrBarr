import Foundation
import MediaKit
import SwiftUI
import os

private let actionLog = Logger(category: "QueueAction")

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
        await beginLeaving(items)
        do {
            try await aggregator.deleteAll(items)
            if let source = items.first?.source {
                Task { await self.refreshQueue(source: source) }
            }
        } catch {
            endLeaving(items)
            if let source = items.first?.source {
                reportFailure("toast.removeFailed.title", error, source: source) { Task { await self.deleteAll(items) } }
            }
        }
    }

    /// Explicit `withAnimation` only: inside macOS `List` cells implicit `.animation` and `visualEffect` don't
    /// animate. The List's own removal closes the gap (fixed ~0.3 s; a manual height collapse snaps), and the
    /// request goes out after, so the server only confirms it.
    private func beginLeaving(_ items: [QueueItem]) async {
        let ids = items.map(\.id)
        withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.28)) { leavingIDs.formUnion(ids) }
        // Two withAnimation calls in one update merge into the first curve; a frame apart keeps them separate.
        try? await Task.sleep(for: .milliseconds(20))
        withAnimation(.timingCurve(0.6, 0, 0.85, 0.3, duration: 0.76)) { slidingIDs.formUnion(ids) }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation { removedIDs.formUnion(ids) }
    }

    private func endLeaving(_ items: [QueueItem]) {
        let ids = items.map(\.id)
        withAnimation(.smooth(duration: 0.4)) {
            removedIDs.subtract(ids)
            leavingIDs.subtract(ids)
            slidingIDs.subtract(ids)
        }
    }

    private func runAction(_ action: QueueAggregator.Action, on item: QueueItem) async {
        guard !isFullyOffline else { return }
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        actionLog.notice("\(String(describing: action), privacy: .public) \(item.source.rawValue, privacy: .public) queue \(item.arrQueueId, privacy: .public)")
        if action == .delete { await beginLeaving([item]) }
        do {
            try await aggregator.perform(action, on: item)
            // The command's effect paints the change at once; this refresh replaces it with a fact.
            Task { await self.refreshQueue(source: item.source) }
        } catch {
            let message = error.localizedDescription
            if action == .delete { endLeaving([item]) }
            reportFailure(action.failureTitle, error, source: item.source) { Task { await self.runAction(action, on: item) } }
            actionLog.error("\(String(describing: action), privacy: .public) queue \(item.arrQueueId, privacy: .public) failed: \(message, privacy: .private)")
            // Pin the client red only when the failure proves it down: `canControl` is client-wide, so a single
            // rejected request would strip pause/resume from every row.
            // Delete, and continue without a download id, went to the arr: nothing proves the client down.
            let reachedClient = action != .delete && item.downloadId?.isEmpty == false
            if reachedClient, actionFailureProvesClientDown(error), let kind = configStore.downloadClient(for: item) {
                ConnectionHealth.shared.forceDown(.arr(kind), message: message)
            }
        }
    }

    /// Away from home is expected: a failure that only repeats what the offline chip already says stays quiet.
    func reportFailure(_ title: LocalizedStringKey, _ error: Error, source: QueueItem.Source,
                       retry: (@MainActor () -> Void)? = nil) {
        let unreachable = switch error as? MediaKitError {
        case .unreachable, .breakerOpen: true
        default: false
        }
        if unreachable, isFullyOffline || lastUnreachable.contains(source) { return }
        toasts.show(.failure(title, error: error, retry: retry))
    }
}

private extension QueueAggregator.Action {
    var failureTitle: LocalizedStringKey {
        switch self {
        case .pause: "toast.pauseFailed.title"
        case .resume, .continueDownload: "toast.resumeFailed.title"
        case .delete: "toast.removeFailed.title"
        }
    }
}
