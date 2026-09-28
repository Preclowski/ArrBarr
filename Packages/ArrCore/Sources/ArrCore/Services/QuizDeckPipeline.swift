import Foundation

/// Bounded fan-out that hands the deck cards in pick order as they land, not after the last lookup.
actor QuizDeckPipeline {

    typealias Pick = (title: String, year: Int?, tmdbId: Int?)

    nonisolated struct Setup: Sendable {
        let kind: String
        let libraryMode: String
        let append: Bool
        /// Dedup keys the live deck has already shown (appended rounds only).
        let shown: Set<String>
        let suppressed: Set<String>
        /// False on a headless surface: resolve, never touch the deck.
        let delivers: Bool
    }

    nonisolated struct Outcome: Sendable {
        let resolved: [DiscoverItem]
        let delivered: Set<String>
        /// "Title (Year)" of every pick no lookup hit matched.
        let unresolved: [String]
    }

    nonisolated let setup: Setup
    private let width: Int
    private let resolve: @Sendable (Pick) async -> DiscoverItem?

    private var picks: [Pick] = []
    private var results: [Int: DiscoverItem?] = [:]
    private var nextToStart = 0
    private var released = 0
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var delivered: Set<String> = []
    private var totalIsFinal = false
    private var cancelled = false
    private var deliveryTail: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(setup: Setup, width: Int = 8, resolve: @escaping @Sendable (Pick) async -> DiscoverItem?) {
        self.setup = setup
        self.width = max(1, width)
        self.resolve = resolve
    }

    /// Only the tail beyond what was already fed is new.
    func feed(_ all: [Pick], isFinal: Bool = false) {
        guard !cancelled else { return }
        if all.count > picks.count { picks.append(contentsOf: all[picks.count...]) }
        if isFinal { totalIsFinal = true }
        pump()
    }

    func finish() async -> Outcome {
        await withTaskCancellationHandler {
            if !isSettled {
                await withCheckedContinuation { finishWaiters.append($0) }
            }
            await deliveryTail?.value
        } onCancel: {
            Task { await self.cancel() }
        }
        let resolved = (0..<picks.count).compactMap { results[$0] ?? nil }
        let unresolved = (0..<picks.count).compactMap { index -> String? in
            guard case .some(.none) = results[index] else { return nil }
            let pick = picks[index]
            return pick.year.map { "\(pick.title) (\($0))" } ?? pick.title
        }
        return Outcome(resolved: resolved, delivered: delivered, unresolved: unresolved)
    }

    func cancel() {
        cancelled = true
        inFlight.values.forEach { $0.cancel() }
        resumeWaiters()
    }

    private var isSettled: Bool { cancelled || results.count == picks.count }

    private func pump() {
        while inFlight.count < width, nextToStart < picks.count {
            let index = nextToStart
            let pick = picks[index]
            nextToStart += 1
            inFlight[index] = Task { [resolve] in
                let item = await resolve(pick)
                self.completed(index, item)
            }
        }
    }

    private func completed(_ index: Int, _ item: DiscoverItem?) {
        inFlight[index] = nil
        guard !cancelled else { return }
        results[index] = item

        var batch: [DiscoverItem] = []
        while let slot = results[released] {
            released += 1
            guard let item = slot, passes(item), delivered.insert(item.dedupKey).inserted else { continue }
            batch.append(item)
        }
        enqueueDelivery(batch)
        pump()
        if isSettled { resumeWaiters() }
    }

    private func passes(_ item: DiscoverItem) -> Bool {
        if setup.libraryMode != "library", item.result.inLibraryArrId != nil { return false }
        if setup.suppressed.contains(item.dedupKey) { return false }
        if setup.append, setup.shown.contains(item.dedupKey) { return false }
        return true
    }

    /// Chained so batches reach the deck in order even though each main-actor hop suspends.
    private func enqueueDelivery(_ batch: [DiscoverItem]) {
        guard setup.delivers else { return }
        let previous = deliveryTail
        let extends = setup.append || delivered.count > batch.count
        let done = results.count
        let total = picks.count
        let isFinal = totalIsFinal
        deliveryTail = Task { [weak self] in
            await previous?.value
            guard await self?.cancelled == false else { return }
            await MainActor.run {
                let deck = DiscoverViewModel.shared
                if batch.isEmpty {
                    deck.noteResolving(done: done, total: total, totalIsFinal: isFinal)
                } else {
                    deck.open(items: batch, append: extends)
                }
            }
        }
    }

    private func resumeWaiters() {
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }
}
