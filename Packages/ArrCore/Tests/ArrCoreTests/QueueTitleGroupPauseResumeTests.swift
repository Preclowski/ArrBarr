import Testing
import Foundation
@testable import ArrCore

@Suite("QueueTitleGroup pause/resume")
@MainActor
struct QueueTitleGroupPauseResumeTests {
    private func item(_ id: String, _ status: QueueItem.Status, downloadId: String? = "", entityId: Int = 1) -> QueueItem {
        QueueItem(
            id: id,
            source: .sonarr,
            arrQueueId: 1,
            downloadId: downloadId == "" ? id : downloadId,
            downloadProtocol: .torrent,
            downloadClient: nil,
            title: "Big Buck Bunny",
            subtitle: nil,
            seasonNumber: 1,
            status: status,
            progress: 0.5,
            sizeTotal: 0,
            sizeLeft: 0,
            timeLeft: nil,
            customFormats: [],
            customFormatScore: 0,
            quality: nil,
            isUpgrade: false,
            contentSlug: nil,
            entityId: entityId
        )
    }

    private func group(_ items: QueueItem...) -> QueueTitleGroup {
        QueueTitleGroup(id: "g", entries: QueueGrouping.group(items))
    }

    private func ids(_ items: [QueueItem]) -> Set<String> { Set(items.map(\.id)) }

    @Test("Anything downloading makes it pause; paused rows are left alone")
    func mixedGroupPauses() {
        let g = group(item("a", .downloading), item("b", .paused), item("c", .queued))
        #expect(g.pauseResumeAction == .pause)
        #expect(ids(g.pauseTargets) == ["a", "c"])
    }

    @Test("Everything paused makes it resume every row")
    func allPausedResumes() {
        let g = group(item("a", .paused), item("b", .paused))
        #expect(g.pauseResumeAction == .resume)
        #expect(ids(g.resumeTargets) == ["a", "b"])
    }

    @Test("Queued rows get play, like on their own row")
    func queuedRowsStart() {
        #expect(group(item("a", .queued), item("b", .queued)).pauseResumeAction == .resume)
        let g = group(item("a", .paused), item("b", .queued))
        #expect(g.pauseResumeAction == .resume)
        #expect(ids(g.resumeTargets) == ["a", "b"])
    }

    @Test("Rows that take neither stay out of the targets")
    func otherStatuses() {
        #expect(group(item("a", .importing), item("b", .completed), item("c", .failed)).pauseResumeAction == nil)

        let g = group(item("a", .importing), item("b", .paused))
        #expect(g.pauseResumeAction == .resume)
        #expect(ids(g.resumeTargets) == ["b"])
    }

    @Test("A pack is one call and one in the count")
    func packCountsOnce() {
        let g = group(item("a", .downloading, downloadId: "pack"), item("b", .downloading, downloadId: "pack"), item("c", .downloading))
        #expect(g.downloadCount == 2)
        #expect(g.pauseTargets.count == 2)
    }

    @Test("A row waiting for its release can be started but not paused")
    func pendingReleaseHasNothingToPause() {
        let g = group(item("a", .downloading), item("b", .queued, downloadId: nil))
        #expect(ids(g.pauseTargets) == ["a"])

        let waiting = group(item("a", .queued, downloadId: nil), item("b", .queued, downloadId: nil))
        #expect(waiting.pauseResumeAction == .resume)
        #expect(waiting.pauseTargets.isEmpty)
        #expect(waiting.resumeTargets.count == 2)
    }

    @Test("The title counts the downloads the action reaches", arguments: [
        ("en", "Pause 3 downloads?", "Start 5 downloads?"),
        ("de", "3 Downloads pausieren?", "5 Downloads starten?"),
        ("es", "¿Pausar 3 descargas?", "¿Iniciar 5 descargas?"),
        ("fr", "Mettre en pause 3 téléchargements ?", "Démarrer 5 téléchargements ?"),
        ("nl", "3 downloads pauzeren?", "5 downloads starten?"),
        ("pl", "Wstrzymać 3 pobrania?", "Rozpocząć 5 pobrań?"),
    ])
    func titleCounts(language: String, pause: String, start: String) {
        let locale = Locale(identifier: language)
        let running = group(item("a", .downloading), item("b", .downloading), item("c", .queued), item("d", .paused))
        #expect(PendingConfirm.pauseResumeAll(running, locale: locale, onPause: {}, onResume: {})?.title == pause)

        let paused = group(item("a", .paused), item("b", .paused), item("c", .paused), item("d", .paused), item("e", .queued))
        #expect(PendingConfirm.pauseResumeAll(paused, locale: locale, onPause: {}, onResume: {})?.title == start)
    }

    @Test("A menu's explicit action asks about its own targets")
    func explicitAction() throws {
        func confirm(_ group: QueueTitleGroup, _ action: QueueTitleGroup.PauseResumeAction) -> PendingConfirm? {
            PendingConfirm.pauseResumeAll(group, action: action, locale: Locale(identifier: "en"), onPause: {}, onResume: {})
        }
        let mixed = group(item("a", .downloading), item("b", .downloading), item("c", .paused))
        #expect(try #require(confirm(mixed, .pause)).title == "Pause 2 downloads?")
        #expect(try #require(confirm(mixed, .resume)).title == "Start 1 download?")

        let running = group(item("a", .downloading), item("b", .downloading))
        #expect(confirm(running, .resume) == nil)
    }

    @Test("Only downloads on a reachable client are targets")
    func controllableNarrowsTargets() {
        let g = group(item("a", .downloading), item("b", .paused))

        let reachable = g.controllable { $0.id == "b" }
        #expect(ids(reachable.pauseTargets).isEmpty)
        #expect(ids(reachable.resumeTargets) == ["b"])
        #expect(reachable.pauseResumeAction == .resume)

        #expect(g.controllable { _ in false }.pauseResumeAction == nil)
    }

    @Test("The current group holds what is in the queue now")
    func currentGroupFollowsTheQueue() {
        let member = item("a", .downloading)
        let id = QueueGrouping.titleKey(for: member)
        let queue = QueueGrouping.group([member, item("joined", .paused), item("other", .downloading, entityId: 2)])

        let current = QueueGrouping.currentGroup(id: id, in: queue)

        #expect(ids(current.allItems) == ["a", "joined"])
        #expect(QueueGrouping.currentGroup(id: "gone", in: queue).pauseResumeAction == nil)
    }

    @Test("A group with nothing to act on asks nothing")
    func nothingToConfirm() {
        let g = group(item("a", .importing), item("b", .importing))
        #expect(PendingConfirm.pauseResumeAll(g, locale: Locale(identifier: "en"), onPause: {}, onResume: {}) == nil)
    }

    @Test("The action runs only after the confirmation is accepted")
    func confirmationGatesTheAction() throws {
        let center = ConfirmCenter()
        center.hasVisibleHost = true
        var paused = 0
        var resumed = 0
        func confirmation(for group: QueueTitleGroup) throws -> PendingConfirm {
            let confirm = PendingConfirm.pauseResumeAll(group, locale: Locale(identifier: "en"),
                                                        onPause: { paused += 1 }, onResume: { resumed += 1 })
            return try #require(confirm)
        }

        let running = group(item("a", .downloading), item("b", .paused))
        center.request(try confirmation(for: running))
        #expect(paused == 0)
        center.cancel()
        #expect(paused == 0)

        center.request(try confirmation(for: running))
        center.confirm()
        #expect(paused == 1)
        #expect(resumed == 0)

        let stopped = group(item("a", .paused), item("b", .paused))
        center.request(try confirmation(for: stopped))
        center.confirm()
        #expect(paused == 1)
        #expect(resumed == 1)
    }
}
