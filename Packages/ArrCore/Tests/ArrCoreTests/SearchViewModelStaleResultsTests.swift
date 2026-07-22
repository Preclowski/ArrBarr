import Testing
import Foundation
@testable import ArrCore

/// The second search has to *look* like a search. Rows from the previous query
/// are kept while the user refines (so typing never flickers list ↔ spinner),
/// but a brand-new term drops them — otherwise the screen is byte-identical to
/// the settled first search and there is no visible loading state at all.
@Suite("SearchViewModel stale results")
@MainActor
struct SearchViewModelStaleResultsTests {
    private func result(id: Int) -> SearchResult {
        SearchResult(
            id: id, foreignId: "f\(id)", title: "title \(id)", subtitle: nil,
            year: nil, rating: nil, imdb: nil, rottenTomatoes: nil,
            metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: nil, source: .radarr,
            inLibraryArrId: nil
        )
    }

    /// Drives the VM to the state right after a first search settled: rows on
    /// screen for `query`, loader off.
    private func settled(on query: String) -> SearchViewModel {
        let vm = SearchViewModel()
        vm.query = query
        vm.onQueryChange()
        vm.radarrResults = [result(id: 1), result(id: 2)]
        vm.isSearching = false
        return vm
    }

    @Test("A completely different term clears the previous rows")
    func newTermClearsResults() {
        let vm = settled(on: "matrix")
        vm.query = "inception"
        vm.onQueryChange()
        #expect(vm.radarrResults.isEmpty)
        #expect(vm.isSearching)
        #expect(!vm.hasResults)
    }

    @Test("Typing further into the same term keeps the rows up")
    func refinementKeepsResults() {
        let vm = settled(on: "matrix")
        vm.query = "matrix 2"
        vm.onQueryChange()
        #expect(vm.radarrResults.count == 2)
        #expect(vm.isSearching)
        #expect(vm.hasResults)
    }

    @Test("Backspacing keeps the rows up too")
    func backspaceKeepsResults() {
        let vm = settled(on: "matrix")
        vm.query = "matri"
        vm.onQueryChange()
        #expect(vm.radarrResults.count == 2)
    }

    @Test("Case differences alone are still a refinement")
    func caseInsensitiveRefinement() {
        let vm = settled(on: "matrix")
        vm.query = "Matrix"
        vm.onQueryChange()
        #expect(vm.radarrResults.count == 2)
    }

    @Test("Clearing the field clears rows and the loader")
    func emptyQueryClearsEverything() {
        let vm = settled(on: "matrix")
        vm.query = ""
        vm.onQueryChange()
        #expect(vm.radarrResults.isEmpty)
        #expect(!vm.isSearching)
    }

    /// Clear-then-retype must not count the empty string as "completely
    /// different" and it must not resurrect anything either.
    @Test("Retyping after a clear starts a fresh search")
    func retypeAfterClear() {
        let vm = settled(on: "matrix")
        vm.query = ""
        vm.onQueryChange()
        vm.query = "i"
        vm.onQueryChange()
        #expect(vm.radarrResults.isEmpty)
        #expect(vm.isSearching)
    }
}
