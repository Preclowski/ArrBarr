import Testing
import Foundation
@testable import ArrCore

@Suite("SearchResultDedup")
struct SearchResultDedupTests {
    private func result(id: Int, foreignId: String = "foreign", title: String = "title",
                        source: QueueItem.Source = .radarr, inLibraryArrId: Int?) -> SearchResult {
        SearchResult(
            externalId: id, foreignId: foreignId, title: title, subtitle: nil,
            year: nil, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: source,
            inLibraryArrId: inLibraryArrId
        )
    }

    private func queueItem(entityId: Int?, source: QueueItem.Source = .radarr) -> QueueItem {
        QueueItem(
            id: "q\(entityId ?? -1)", source: source, arrQueueId: 1,
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

    private func libraryEntry(arrId: Int, source: QueueItem.Source = .radarr) -> LibraryEntry {
        LibraryEntry(
            id: "\(source.rawValue)-\(arrId)", source: source, arrId: arrId,
            title: "t", year: nil, posterURL: nil, posterRequiresAuth: false,
            state: .complete, sizeOnDisk: 0, fileCount: nil, totalCount: nil,
            fileQuality: nil, profileName: nil, customFormats: [], customFormatScore: 0,
            fileName: nil, genres: [], runtime: nil, certification: nil,
            ratingImdb: nil, ratingTmdb: nil, ratingArr: nil,
            releaseStatus: nil, searchIndex: TitleMatch.searchIndex(["t"])
        )
    }

    // MARK: - Queue hits

    @Test("An owned row the queue is already showing is removed")
    func removesMatchingSingleton() {
        let results = [result(id: 1, inLibraryArrId: 42), result(id: 2, inLibraryArrId: 99)]
        let hits: [LocalHit] = [.queue(.single(queueItem(entityId: 42)))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [2])
    }

    @Test("A group contributes every item it packs")
    func removesMatchingGroupMember() {
        let results = [result(id: 1, inLibraryArrId: 7)]
        let group = QueueGroup(id: "g", items: [queueItem(entityId: 5), queueItem(entityId: 7)])
        let hits: [LocalHit] = [.queue(.group(group))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.isEmpty)
    }

    @Test("Queue items with nil entityId never match")
    func nilEntityIdsDontMatch() {
        let results = [result(id: 1, inLibraryArrId: 42)]
        let hits: [LocalHit] = [.queue(.single(queueItem(entityId: nil)))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1])
    }

    // MARK: - Library hits

    @Test("An owned row the browsed library already shows is removed")
    func removesLocallyMatchedLibraryEntry() {
        let results = [
            result(id: 1, source: .radarr, inLibraryArrId: 42),
            result(id: 2, source: .radarr, inLibraryArrId: nil),
        ]
        let hits: [LocalHit] = [.library(libraryEntry(arrId: 42))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [2])
    }

    @Test("An owned row the local match missed is kept")
    func keepsAliasMissedOwnedResult() {
        let results = [result(id: 1, source: .radarr, inLibraryArrId: 42)]
        let hits: [LocalHit] = [.library(libraryEntry(arrId: 7))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1])
    }

    // MARK: - Invariants

    @Test("An id collision across arrs never drops a row")
    func keepsOtherArrOwnedResult() {
        let results = [result(id: 1, source: .sonarr, inLibraryArrId: 42)]
        let hits: [LocalHit] = [
            .library(libraryEntry(arrId: 42, source: .radarr)),
            .queue(.single(queueItem(entityId: 42, source: .radarr))),
        ]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1])
    }

    @Test("Add-new rows are never removed")
    func keepsAddNewResults() {
        let results = [
            result(id: 1, source: .radarr, inLibraryArrId: nil),
            result(id: 2, source: .sonarr, inLibraryArrId: nil),
        ]
        let hits: [LocalHit] = [
            .library(libraryEntry(arrId: 1)),
            .queue(.single(queueItem(entityId: 2))),
        ]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1, 2])
    }

    @Test("No local hits passes everything through unchanged")
    func emptyLocalHits() {
        let results = [result(id: 1, inLibraryArrId: 42), result(id: 2, inLibraryArrId: 99)]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: [])
        #expect(out.map(\.externalId) == [1, 2])
    }

    @Test("Preserves the order of survivors")
    func preservesOrder() {
        let results = [
            result(id: 1, inLibraryArrId: 1),
            result(id: 2, inLibraryArrId: 2),
            result(id: 3, inLibraryArrId: 3),
        ]
        let hits: [LocalHit] = [.queue(.single(queueItem(entityId: 2)))]
        let out = SearchResultDedup.removingLocalDuplicates(results: results, localHits: hits)
        #expect(out.map(\.externalId) == [1, 3])
    }
}
