import Foundation
import Observation

/// The history list's rows, loaded a batch of rows at a time.
///
/// Paging counts rows, not arr records. The arrs log per file, so a page of
/// Sonarr records folds into a handful of season-pack rows while the same page
/// of Radarr is that many rows — a fixed record count showed a long Radarr
/// history next to a stub of a Sonarr one. A batch keeps fetching pages until
/// it has added `rowsPerBatch` rows, the arr runs out, or it has fetched
/// `maxPagesPerBatch` pages (so a wall of per-track imports can't page on
/// forever).
///
/// Pairing and folding re-run over everything loaded so far, so an import and
/// the deletion it caused — or one season pack — split across a page boundary
/// join up once the next page arrives.
///
/// Observable state changes once per batch, never per page: every change
/// re-lays out the whole list, and mid-batch churn is what made it jump.
@MainActor
@Observable
final class HistoryFeed {
    typealias Fetch = @MainActor (_ source: QueueItem.Source, _ page: Int) async -> HistoryResult

    /// Records per arr request.
    static let pageSize = 100

    private(set) var items: [HistoryItem] = []
    /// A first load with nothing to show yet.
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = true
    /// Set only when nothing loaded at all.
    private(set) var error: String?
    /// When the rows were last loaded from the top. The list buckets its hour
    /// sections against this rather than the clock, so rows don't hop sections
    /// while it's open.
    private(set) var loadedAt: Date?

    private struct Cursor {
        var raw: [HistoryItem] = []
        var nextPage = 1
        var hasMore = true
        var error: String?
    }

    private struct Batch {
        var cursors: [QueueItem.Source: Cursor]
        var rows: [HistoryItem]
    }

    @ObservationIgnored private var cursors: [QueueItem.Source: Cursor]
    /// One load at a time — a reload and a load-more interleaving their pages
    /// would mix two cursor states.
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private let sources: [QueueItem.Source]
    @ObservationIgnored private let rowsPerBatch: Int
    @ObservationIgnored private let maxPagesPerBatch: Int
    @ObservationIgnored private let fetch: Fetch

    init(sources: [QueueItem.Source], rowsPerBatch: Int = 25, maxPagesPerBatch: Int = 5, fetch: @escaping Fetch) {
        self.sources = sources
        self.rowsPerBatch = rowsPerBatch
        self.maxPagesPerBatch = maxPagesPerBatch
        self.fetch = fetch
        self.cursors = Self.freshCursors(for: sources)
    }

    /// Loads the first batch — or, when rows are already showing, reloads it
    /// behind them and swaps them in only if it brought any, so an unreachable
    /// arr keeps the last good history on screen instead of an error.
    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let firstLoad = items.isEmpty
        if firstLoad { isLoading = true }
        let result = await batch(from: Self.freshCursors(for: sources), rows: [])
        if firstLoad || !result.rows.isEmpty {
            apply(result)
            loadedAt = Date()
        }
        isLoading = false
    }

    func loadMore() async {
        guard !isBusy, hasMore else { return }
        isBusy = true
        isLoadingMore = true
        defer {
            isBusy = false
            isLoadingMore = false
        }
        apply(await batch(from: cursors, rows: items))
    }

    /// `loadMore` decoupled from the caller: it's asked from a row's
    /// `onAppear`, and a row scrolling away must not cancel a batch halfway.
    func requestMore() {
        Task { await loadMore() }
    }

    private func batch(from start: [QueueItem.Source: Cursor], rows startRows: [HistoryItem]) async -> Batch {
        var cursors = start
        var rows = startRows
        let target = rows.count + rowsPerBatch
        var pages = 0
        while rows.count < target, cursors.values.contains(where: { $0.hasMore }), pages < maxPagesPerBatch {
            for source in sources where cursors[source]?.hasMore == true {
                var cursor = cursors[source] ?? Cursor()
                let result = await fetch(source, cursor.nextPage)
                if let message = result.error {
                    cursor.error = message
                    cursor.hasMore = false
                } else {
                    cursor.raw += result.items
                    cursor.nextPage += 1
                    cursor.hasMore = result.hasMore
                }
                cursors[source] = cursor
            }
            pages += 1
            rows = Self.merged(sources: sources, cursors: cursors)
        }
        return Batch(cursors: cursors, rows: rows)
    }

    private func apply(_ batch: Batch) {
        cursors = batch.cursors
        items = batch.rows
        hasMore = batch.cursors.values.contains { $0.hasMore }
        let errors = sources.compactMap { batch.cursors[$0]?.error }
        error = batch.rows.isEmpty && !errors.isEmpty ? errors.joined(separator: " · ") : nil
    }

    private static func freshCursors(for sources: [QueueItem.Source]) -> [QueueItem.Source: Cursor] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0, Cursor()) })
    }

    /// Every source's loaded pages, paired and folded; several sources merge
    /// newest first.
    private static func merged(sources: [QueueItem.Source], cursors: [QueueItem.Source: Cursor]) -> [HistoryItem] {
        let perSource = sources.map { HistoryItem.prepared(cursors[$0]?.raw ?? []) }
        guard perSource.count > 1 else { return perSource.first ?? [] }
        return perSource.joined().sorted { $0.date > $1.date }
    }
}
