import Foundation
import MediaKit

/// What an automatic search was for, matched against the queue rows it grabs.
struct SearchSubject: Equatable {
    let source: QueueItem.Source
    /// The movie, series or album id: what a queue row carries as `entityId`.
    let entityId: Int
    var season: Int?
    var episode: Int?

    func matches(_ item: QueueItem) -> Bool {
        item.source == source && item.entityId == entityId
            && (season == nil || item.seasonNumber == season)
            && (episode == nil || item.episodeNumber == episode)
    }
}

struct SearchWatch {
    let id = UUID()
    let subject: SearchSubject
    let title: String
    /// Where "Manual search" goes when nothing was grabbed; nil where the detail has none (a series).
    let manualSearch: QueueItem?
    let baseline: Set<QueueItem.ID>
    var task: Task<Void, Never>?
}

extension QueueViewModel {
    /// Follows a search the user started until a new queue row for `subject` appears, or the arr finishes
    /// the sweep without one. Lives here, not in the detail, so the outcome still arrives after Back.
    /// - Parameter commandId: the arr command. Without it (add-and-search) the watch keys on any search
    ///   for the entity, and says nothing if it never sees one run.
    func watchSearch(_ subject: SearchSubject, title: String, commandId: Int?, manualSearch: QueueItem? = nil) {
        for watch in searchWatches where watch.subject == subject { endSearchWatch(watch.id) }
        var watch = SearchWatch(subject: subject, title: title, manualSearch: manualSearch,
                                baseline: Set(queues[subject.source, default: []].filter(subject.matches).map(\.id)))
        let id = watch.id
        watch.task = Task { [weak self] in await self?.followSearch(id, subject: subject, commandId: commandId) }
        searchWatches.append(watch)
    }

    /// Runs on every committed queue; returns the rows it announced, so no banner repeats them.
    func resolveSearchWatches(source: QueueItem.Source, items: [QueueItem]) -> Set<QueueItem.ID> {
        var toasted: Set<QueueItem.ID> = []
        for watch in searchWatches where watch.subject.source == source {
            guard let grab = items.first(where: { watch.subject.matches($0) && !watch.baseline.contains($0.id) })
            else { continue }
            endSearchWatch(watch.id)
            toasted.insert(grab.id)
            toasts.show(Toast(
                tone: .success, symbol: "arrow.down.circle.fill", title: "toast.grabbed.title",
                detail: [watch.title, grab.quality].compactMap { $0 }.joined(separator: " · "),
                action: .init(label: "toast.show.button") { DetailRequest.post(grab) }))
        }
        return toasted
    }

    private func followSearch(_ id: UUID, subject: SearchSubject, commandId: Int?) async {
        let client = configStore.arrClient(for: subject.source)
        let started = ContinuousClock.now
        var seenRunning = false
        while true {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let elapsed = ContinuousClock.now - started
            // MediaKit stops tracking an arr command at ten minutes; so does this.
            guard elapsed < .seconds(600) else { return endSearchWatch(id) }
            guard let commands = await client.fetchCommands() else { continue }
            guard !Task.isCancelled else { return }
            let running = if let commandId {
                commands.contains { $0.id == commandId && $0.isRunning }
            } else {
                commands.contains { $0.isSearch(for: subject.entityId) }
            }
            if running { seenRunning = true; continue }
            if seenRunning || commandId != nil { break }
            // An add queues its search after it returns; one never seen running isn't reported as empty.
            guard elapsed < .seconds(20) else { return endSearchWatch(id) }
        }
        // The grab lands in the queue just after the command completes.
        await refreshQueue(source: subject.source)
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, let watch = searchWatches.first(where: { $0.id == id }) else { return }
        endSearchWatch(id)
        toasts.show(Toast(
            tone: .neutral, symbol: "magnifyingglass", title: "toast.nothingGrabbed.title", detail: watch.title,
            action: watch.manualSearch.map { item in
                .init(label: "Manual search") { DetailRequest.post(item, intent: .manualSearch) }
            }))
    }

    private func endSearchWatch(_ id: UUID) {
        guard let index = searchWatches.firstIndex(where: { $0.id == id }) else { return }
        searchWatches.remove(at: index).task?.cancel()
    }
}
