import Testing
import Foundation
@testable import ArrCore

@Suite("QueueTitleGrouping")
struct QueueTitleGroupingTests {
    private func item(
        id: String,
        title: String,
        source: QueueItem.Source = .sonarr,
        entityId: Int? = nil,
        season: Int? = nil,
        downloadId: String? = nil,
        sizeTotal: Int64 = 0,
        sizeLeft: Int64 = 0,
        progress: Double = 0.5
    ) -> QueueItem {
        QueueItem(
            id: id,
            source: source,
            arrQueueId: id.hashValue,
            downloadId: downloadId ?? id,
            downloadProtocol: .torrent,
            downloadClient: nil,
            title: title,
            subtitle: nil,
            seasonNumber: season,
            status: .downloading,
            progress: progress,
            sizeTotal: sizeTotal,
            sizeLeft: sizeLeft,
            timeLeft: nil,
            customFormats: [],
            customFormatScore: 0,
            quality: nil,
            isUpgrade: false,
            contentSlug: nil,
            entityId: entityId
        )
    }

    private func entries(_ items: [QueueItem]) -> [QueueRowEntry] {
        items.map { .single($0) }
    }

    @Test("Singletons pass through untouched")
    func singletonsPassThrough() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", entityId: 1),
            item(id: "b", title: "Beta", entityId: 2),
        ]))
        #expect(rows.count == 2)
        for row in rows {
            guard case .entry = row else {
                Issue.record("expected pass-through entry, got \(row)")
                return
            }
        }
    }

    @Test("A film's downloads share one row that doesn't expand; a series' group does")
    func onlyFilmsStayOneRow() {
        let film = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", source: .radarr, entityId: 1),
            item(id: "b", title: "Alpha", source: .radarr, entityId: 1),
        ]))
        guard film.count == 1, case .titleGroup(let filmGroup) = film[0] else {
            Issue.record("expected one row for the film")
            return
        }
        #expect(filmGroup.downloadCount == 2)
        #expect(!filmGroup.isExpandable)

        let series = QueueGrouping.groupByTitle(entries([
            item(id: "c", title: "Beta", entityId: 2, season: 1),
            item(id: "d", title: "Beta", entityId: 2, season: 1),
        ]))
        guard case .titleGroup(let seriesGroup) = series[0] else {
            Issue.record("expected a group for the season")
            return
        }
        #expect(seriesGroup.isExpandable)
    }

    @Test("With grouping off a film still gets one row; a series goes flat")
    func groupingOffSparesOnlyFilms() {
        let film = QueueGrouping.displayRows(entries([
            item(id: "a", title: "Alpha", source: .radarr, entityId: 1),
            item(id: "b", title: "Alpha", source: .radarr, entityId: 1),
        ]), source: .radarr, grouping: false)
        #expect(film.count == 1)

        let series = QueueGrouping.displayRows(entries([
            item(id: "c", title: "Beta", entityId: 2, season: 1),
            item(id: "d", title: "Beta", entityId: 2, season: 1),
        ]), source: .sonarr, grouping: false)
        #expect(series.count == 2)
    }

    @Test("A group's status puts trouble before anything running")
    func aggregateStatusPutsTroubleFirst() {
        func group(_ statuses: QueueItem.Status...) -> QueueTitleGroup {
            QueueTitleGroup(id: "g", entries: statuses.enumerated().map { index, status in
                let base = item(id: "\(index)", title: "Alpha", source: .radarr, entityId: 1)
                return .single(QueueItem(
                    id: base.id, source: base.source, arrQueueId: base.arrQueueId,
                    downloadId: base.downloadId, downloadProtocol: base.downloadProtocol,
                    downloadClient: nil, title: base.title, subtitle: nil,
                    status: status, progress: 0.5, sizeTotal: 0, sizeLeft: 0, timeLeft: nil,
                    customFormats: [], customFormatScore: 0, quality: nil, isUpgrade: false,
                    contentSlug: nil, entityId: 1))
            })
        }
        #expect(group(.downloading, .failed).aggregateStatus == .failed)
        #expect(group(.completed, .failed).aggregateStatus == .failed)
        #expect(group(.downloading, .warning).aggregateStatus == .warning)
        #expect(group(.paused, .downloading).aggregateStatus == .downloading)
        #expect(group(.paused, .paused).aggregateStatus == .paused)
        #expect(group(.completed, .paused).aggregateStatus == .completed)
    }

    @Test("Only the first episode of a pack carries the spark")
    func sparkPerDownload() {
        let pack = item(id: "p", title: "Beta", downloadId: "pack")
        let lone = item(id: "l", title: "Beta", downloadId: "lone")
        let ids = QueueGrouping.firstEpisodePerDownload([1, 2, 3, 4], queue: [1: [pack], 2: [pack], 3: [lone]])
        #expect(ids == [1, 3])
    }

    @Test("Two entries of one title form a group at the first member's position")
    func groupsAtFirstPosition() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", entityId: 1),
            item(id: "b", title: "Beta", entityId: 2),
            item(id: "c", title: "Alpha", entityId: 1),
        ]))
        #expect(rows.count == 2)
        guard case .titleGroup(let group) = rows[0] else {
            Issue.record("expected the group first (position of its first member)")
            return
        }
        #expect(group.downloadCount == 2)
        #expect(group.allItems.map(\.id) == ["a", "c"])
        guard case .entry(let single) = rows[1], case .single(let beta) = single else {
            Issue.record("expected Beta as a pass-through entry")
            return
        }
        #expect(beta.id == "b")
    }

    @Test("Same entity id across different arrs never groups")
    func sourcesDoNotCollide() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", source: .sonarr, entityId: 7),
            item(id: "b", title: "Alpha", source: .radarr, entityId: 7),
        ]))
        #expect(rows.count == 2)
    }

    @Test("Missing entityId falls back to normalized title")
    func titleFallback() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha"),
            item(id: "b", title: "alpha"),
        ]))
        #expect(rows.count == 1)
        guard case .titleGroup(let group) = rows[0] else {
            Issue.record("expected a title group")
            return
        }
        #expect(group.downloadCount == 2)
    }

    @Test("A season pack counts as one download inside its title group")
    func packIsOneDownload() {
        let pack = QueueGroup(id: "pack", items: [
            item(id: "p1", title: "Alpha", entityId: 1, downloadId: "pack"),
            item(id: "p2", title: "Alpha", entityId: 1, downloadId: "pack"),
        ])
        let rows = QueueGrouping.groupByTitle([
            .group(pack),
            .single(item(id: "s", title: "Alpha", entityId: 1)),
        ])
        #expect(rows.count == 1)
        guard case .titleGroup(let group) = rows[0] else {
            Issue.record("expected a title group")
            return
        }
        #expect(group.downloadCount == 2)     // pack = 1, single = 1
        #expect(group.allItems.count == 3)    // but 3 underlying queue items
    }

    @Test("A series groups per season, not per show")
    func seriesGroupsPerSeason() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", entityId: 1, season: 1),
            item(id: "b", title: "Alpha", entityId: 1, season: 2),
            item(id: "c", title: "Alpha", entityId: 1, season: 1),
            item(id: "d", title: "Alpha", entityId: 1, season: 2),
        ]))
        #expect(rows.count == 2)
        let groups = rows.compactMap { row -> QueueTitleGroup? in
            if case .titleGroup(let g) = row { return g } else { return nil }
        }
        #expect(groups.map { $0.allItems.map(\.id) } == [["a", "c"], ["b", "d"]])
    }

    @Test("A pack's size counts once, not once per episode row")
    func packSizeCountsOnce() {
        let pack = QueueGroup(id: "pack", items: (1...3).map {
            item(id: "p\($0)", title: "Alpha", entityId: 1, season: 1, downloadId: "pack", sizeTotal: 1000, sizeLeft: 500)
        })
        let group = QueueTitleGroup(id: "k", entries: [
            .group(pack),
            .single(item(id: "s", title: "Alpha", entityId: 1, season: 1, sizeTotal: 1000, sizeLeft: 0)),
        ])
        #expect(group.totalSize == 2000)
        #expect(abs(group.aggregateProgress - 0.75) < 0.0001)
    }

    @Test("Queue search answers once per series, keeping every ownership key")
    func searchCollapsesSeries() {
        let hits = LocalHit.queueRows([
            item(id: "a", title: "Alpha", entityId: 1, season: 1),
            item(id: "b", title: "Beta", entityId: 2, season: 1),
            item(id: "c", title: "Alpha", entityId: 1, season: 2),
        ], source: .sonarr)
        #expect(hits.count == 2)
        guard case .queueSeries(let alpha) = hits[0], case .queue(.single(let beta)) = hits[1] else {
            Issue.record("expected Alpha as one series hit and Beta as a plain row, got \(hits)")
            return
        }
        #expect(alpha.downloadCount == 2)
        #expect(beta.id == "b")
        #expect(hits[0].ownershipKeys.allSatisfy { $0 == OwnershipKey(source: .sonarr, arrId: 1) })
    }

    @Test("Aggregate progress is size-weighted")
    func aggregateProgress() {
        let group = QueueTitleGroup(id: "k", entries: entries([
            item(id: "a", title: "Alpha", sizeTotal: 900, sizeLeft: 0),
            item(id: "b", title: "Alpha", sizeTotal: 100, sizeLeft: 100),
        ]))
        #expect(abs(group.aggregateProgress - 0.9) < 0.0001)
    }

    @Test("Aggregate progress falls back to mean when sizes are unknown")
    func aggregateProgressFallback() {
        let group = QueueTitleGroup(id: "k", entries: entries([
            item(id: "a", title: "Alpha", progress: 0.2),
            item(id: "b", title: "Alpha", progress: 0.8),
        ]))
        #expect(abs(group.aggregateProgress - 0.5) < 0.0001)
    }
}


@Suite("QueueSelection")
struct QueueSelectionTests {
    private func entry(_ id: String, source: QueueItem.Source = .radarr, entityId: Int = 1) -> QueueRowEntry {
        .single(QueueItem(
            id: id, source: source, arrQueueId: 1, downloadId: id, downloadProtocol: .torrent,
            downloadClient: nil, title: "Title \(entityId)", subtitle: nil,
            status: .downloading, progress: 0.5, sizeTotal: 0, sizeLeft: 0, timeLeft: nil,
            customFormats: [], customFormatScore: 0, quality: nil, isUpgrade: false,
            contentSlug: nil, entityId: entityId))
    }

    /// Lone film X, then film F with two downloads.
    private var rows: [[QueueRowEntry]] {
        let display = QueueGrouping.groupByTitle([
            entry("x", entityId: 1), entry("f1", entityId: 2), entry("f2", entityId: 2),
        ])
        return QueueSelection.rows(display, isExpanded: { _ in false })
    }

    @Test("A film is one selectable row; a collapsed series' children aren't selectable at all")
    func rowsPerKind() {
        #expect(rows.map { $0.map(\.id) } == [["single.x"], ["single.f1", "single.f2"]])

        let series = QueueGrouping.groupByTitle([
            entry("a", source: .sonarr, entityId: 3), entry("b", source: .sonarr, entityId: 3),
        ])
        #expect(QueueSelection.rows(series, isExpanded: { _ in false }).isEmpty)
        #expect(QueueSelection.rows(series, isExpanded: { _ in true }).count == 2)
    }

    /// What's shown is what's acted on: the row never reads unselected while a download of it is picked.
    @Test("Part of a film picked selects the whole row and acts on all of it")
    func partOfAFilmCountsAsAll() {
        let film = rows[1]
        #expect(QueueSelection.isSelected(film, in: ["single.f1"]))
        #expect(QueueSelection.selectedEntries(rows: rows, in: ["single.f1"]).map(\.id) == ["single.f1", "single.f2"])
    }

    @Test("Toggling a partly picked film clears all of it")
    func togglePartial() {
        let film = rows[1]
        #expect(QueueSelection.toggled(film, in: ["single.f1"]).isEmpty)
        #expect(QueueSelection.toggled(film, in: []) == ["single.f1", "single.f2"])
    }

    @Test("A range covers whole rows, from either end")
    func rangeCoversWholeRows() {
        #expect(QueueSelection.ids(betweenRowsOf: "single.f1", and: "single.x", rows: rows)
                == ["single.x", "single.f1", "single.f2"])
        #expect(QueueSelection.ids(betweenRowsOf: "single.x", and: "single.f1", rows: rows)
                == ["single.x", "single.f1", "single.f2"])
    }

    @Test("A range from an anchor that left the queue is nil, so the tap falls back to a toggle")
    func rangeFromAGoneAnchor() {
        #expect(QueueSelection.ids(betweenRowsOf: "single.gone", and: "single.x", rows: rows) == nil)
    }
}
