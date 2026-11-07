import Testing
import Foundation
import MediaKit
@testable import ArrCore

@Suite("SearchViewModel added row")
@MainActor
struct SearchViewModelAddedRowTests {
    private func row(_ id: Int, source: QueueItem.Source = .radarr, tmdbTVId: Int? = nil) -> SearchResult {
        SearchResult(
            externalId: id, foreignId: id > 0 ? String(id) : "", title: "title \(id)", subtitle: nil,
            year: nil, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: source, tmdbTVId: tmdbTVId
        )
    }

    private func person() throws -> TMDBPerson {
        try JSONDecoder().decode(TMDBPerson.self, from: Data(#"{"id":1,"name":"Someone"}"#.utf8))
    }

    @Test("An added title stays in the results, owned and not downloaded")
    func addedRowStaysOwned() {
        let vm = SearchViewModel()
        vm.radarrResults = [row(1), row(2)]

        vm.markAdded(row(1), arrId: 42)

        #expect(vm.radarrResults.map(\.externalId) == [1, 2])
        #expect(vm.radarrResults[0].inLibraryArrId == 42)
        #expect(vm.radarrResults[0].libraryDownloaded == false)
        #expect(vm.radarrResults[1].inLibraryArrId == nil)
    }

    @Test("Without an id from the arr the row stays as it was")
    func noIdLeavesRow() {
        let vm = SearchViewModel()
        vm.radarrResults = [row(1)]

        vm.markAdded(row(1), arrId: nil)

        #expect(vm.radarrResults == [row(1)])
    }

    @Test("A Starring row gets the mark too")
    func marksStarringRow() throws {
        let vm = SearchViewModel()
        vm.starring = .init(person: try person(), titles: [row(1), row(2)])

        vm.markAdded(row(1), arrId: 42)

        #expect(vm.starring?.titles[0].inLibraryArrId == 42)
        #expect(vm.starring?.titles[1].inLibraryArrId == nil)
    }

    @Test("A TMDB-sourced series row is found after its tvdbId was resolved")
    func marksResolvedSeriesRow() throws {
        let vm = SearchViewModel()
        vm.starring = .init(person: try person(),
                            titles: [row(0, source: .sonarr, tmdbTVId: 9)])

        vm.markAdded(row(0, source: .sonarr, tmdbTVId: 9).withTVDBId(5), arrId: 42)

        #expect(vm.starring?.titles[0].inLibraryArrId == 42)
    }

    @Test("Only the result's own arr is marked")
    func marksOwnArrOnly() {
        let vm = SearchViewModel()
        vm.radarrResults = [row(1)]
        vm.sonarrResults = [row(1, source: .sonarr)]

        vm.markAdded(row(1, source: .sonarr), arrId: 7)

        #expect(vm.sonarrResults[0].inLibraryArrId == 7)
        #expect(vm.radarrResults[0].inLibraryArrId == nil)
    }
}
