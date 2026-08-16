import Testing
import Foundation
@testable import ArrCore

@Suite("SearchResultDedup")
struct SearchResultDedupTests {
    private func result(id: Int, foreignId: String = "foreign", title: String = "title", inLibraryArrId: Int?) -> SearchResult {
        SearchResult(
            externalId: id, foreignId: foreignId, title: title, subtitle: nil,
            year: nil, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr,
            inLibraryArrId: inLibraryArrId
        )
    }

    private func queueItem(entityId: Int?) -> QueueItem {
        QueueItem(
            id: "q\(entityId ?? -1)", source: .radarr, arrQueueId: 1,
            downloadId: nil, downloadProtocol: .unknown,
            downloadClient: nil, indexer: nil,
            title: "t", subtitle: nil,
            seasonNumber: nil, episodeNumber: nil, episodeTitle: nil,
            releaseName: nil,
            status: .downloading, progress: 0.5, sizeTotal: 0,
            sizeLeft: 0, timeLeft: nil,
            customFormats: [], customFormatScore: 0,
            quality: nil, releaseGroup: nil, isUpgrade: false,
            contentSlug: nil,
            entityId: entityId
        )
    }

    @Test("Result whose inLibraryArrId matches a singleton queue entityId is removed")
    func removesMatchingSingleton() {
        let lib = [result(id: 1, inLibraryArrId: 42), result(id: 2, inLibraryArrId: 99)]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: 42))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.externalId) == [2])
    }

    @Test("Result matching any member of a group is removed")
    func removesMatchingGroupMember() {
        let lib = [result(id: 1, inLibraryArrId: 7)]
        let group = QueueGroup(id: "g", items: [queueItem(entityId: 5), queueItem(entityId: 7)])
        let queue: [QueueRowEntry] = [.group(group)]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.isEmpty)
    }

    @Test("Results with nil inLibraryArrId are never removed")
    func keepsNilLibraryId() {
        let lib = [result(id: 1, inLibraryArrId: nil)]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: 42))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.externalId) == [1])
    }

    @Test("Queue items with nil entityId never match")
    func nilEntityIdsDontMatch() {
        let lib = [result(id: 1, inLibraryArrId: 42)]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: nil))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.externalId) == [1])
    }

    @Test("Empty queue passes library through unchanged")
    func emptyQueue() {
        let lib = [result(id: 1, inLibraryArrId: 42), result(id: 2, inLibraryArrId: 99)]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: [])
        #expect(out.map(\.externalId) == [1, 2])
    }

    @Test("Preserves order of surviving results")
    func preservesOrder() {
        let lib = [
            result(id: 1, inLibraryArrId: 1),
            result(id: 2, inLibraryArrId: 2),
            result(id: 3, inLibraryArrId: 3),
        ]
        let queue: [QueueRowEntry] = [.single(queueItem(entityId: 2))]
        let out = SearchResultDedup.removingQueueDuplicates(libraryResults: lib, queueRows: queue)
        #expect(out.map(\.externalId) == [1, 3])
    }
}
