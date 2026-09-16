import Testing
import Foundation
@testable import ArrCore

/// Three copies of "mirror the field into the VM, then call onQueryChange" —
/// two of which reset the scope on an empty field and one of which did not —
/// collapse into a `didSet` here. The re-entry guard is the subtle half: the
/// reset writes `scope`, whose own `didSet` would otherwise run a second pass
/// over the same empty query.
@Suite("SearchViewModel query")
@MainActor
struct SearchViewModelQueryTests {

    @Test("Assigning query runs the search without an explicit onQueryChange")
    func assignmentRunsTheSearch() {
        let vm = SearchViewModel()
        vm.setup(radarrConfig: ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:1/",
                                             apiKey: "k", username: "", password: ""),
                 sonarrConfig: .empty)
        defer { vm.reset() }

        vm.query = "matrix"
        #expect(vm.parsedInput == .text("matrix"))
        #expect(vm.isSearching)
        #expect(vm.isActive)
    }

    @Test("isActive follows the trimmed query")
    func isActiveFollowsTrimmedQuery() {
        let vm = SearchViewModel()
        #expect(!vm.isActive)
        vm.query = "   "
        #expect(!vm.isActive)
        vm.query = "dune"
        #expect(vm.isActive)
    }

    @Test("A pasted multi-line clipboard lands as one line")
    func pastedNewlinesCollapse() {
        let vm = SearchViewModel()
        defer { vm.reset() }

        vm.query = "blade\nrunner"
        #expect(vm.query == "blade runner")

        // Trailing / repeated line endings leave no stray spaces behind.
        vm.query = "dune\n\n"
        #expect(vm.query == "dune")
    }

    @Test("A newline is as empty as a space — no search runs behind it")
    func newlineOnlyQueryStartsNothing() {
        let vm = SearchViewModel()
        vm.setup(radarrConfig: ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:1/",
                                             apiKey: "k", username: "", password: ""),
                 sonarrConfig: .empty)
        defer { vm.reset() }

        // A pasted line ending. `isActive` calls it empty, so the surface shows
        // nothing — a search behind it is a lookup nobody can see the result of.
        vm.query = "\n"
        #expect(!vm.isActive)
        #expect(!vm.isSearching)
    }

    @Test("Emptying the query resets scope to .all exactly once and keeps libraryOnly")
    func emptyQueryResetsScopeOnce() {
        let vm = SearchViewModel()
        // A live query first: the scope only survives while one is running, so
        // setting it on an empty field would be reset before the test starts.
        vm.query = "dune"
        vm.scope = .series
        vm.libraryOnly = true
        let before = vm.queryChangePasses

        vm.query = ""

        #expect(vm.scope == .all)
        // Sticky, as documented — only the scope is per-search.
        #expect(vm.libraryOnly)
        // One pass, not two: the scope reset must not re-enter onQueryChange.
        #expect(vm.queryChangePasses == before + 1)
    }

    @Test("A scope change the user makes still re-runs the search")
    func userScopeChangeStillSearches() {
        let vm = SearchViewModel()
        vm.query = "dune"
        let before = vm.queryChangePasses
        vm.scope = .movie
        #expect(vm.queryChangePasses == before + 1)
    }
}
