import Foundation
import Testing
@testable import ArrCore

/// What the stubbed arr should do with a lookup.
private enum StubBehaviour {
    /// Never answer — the request stays in flight until the caller cancels it,
    /// which is exactly what a superseded keystroke does.
    case hang
    /// Answer with a server error, so a *real* failure can be told apart from
    /// a cancelled one.
    case fail
}

private final class SearchStubState: @unchecked Sendable {
    var behaviour: StubBehaviour = .hang
}

/// Stubs `URLSession.shared` — which is what `SearchClient` runs on — for ONE
/// host, so suites running in parallel keep their own traffic.
private final class SearchCancelStub: URLProtocol, @unchecked Sendable {
    static let state = SearchStubState()
    static let host = "search.cancel.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `.hang` deliberately calls nothing back: the task sits in flight
        // until URLSession cancels it and reports `URLError.cancelled`.
        guard Self.state.behaviour == .fail else { return }
        let url = request.url ?? URL(string: "about:blank")!
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("boom".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// arr lookups take 1-3 s, so typing supersedes them constantly. Every one of
/// those cancellations used to be reported to the user as a failure — the raw
/// "The operation couldn't be completed. (Swift.CancellationError error 1.)"
/// landed in the search UI's error slot while a perfectly healthy search was
/// still running behind it.
///
/// `.serialized` because the stub is registered process-wide (that is the only
/// way to reach `URLSession.shared`) and carries shared script state.
@Suite("Search cancellation", .serialized)
@MainActor
struct SearchViewModelCancellationTests {

    private var radarrConfig: ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(SearchCancelStub.host):7878",
                      apiKey: "test-key", username: "", password: "")
    }

    /// Drives a search up to the point where its lookups are in flight.
    /// `onQueryChange` debounces for 300 ms before it even starts.
    private func startSearch(_ vm: SearchViewModel, _ query: String) async throws {
        vm.query = query
        vm.onQueryChange()
        try await Task.sleep(for: .milliseconds(600))
    }

    @Test("A lookup cancelled by the next keystroke leaves no error on screen")
    func cancelledLookupIsSilent() async throws {
        SearchCancelStub.state.behaviour = .hang
        URLProtocol.registerClass(SearchCancelStub.self)
        defer { URLProtocol.unregisterClass(SearchCancelStub.self) }

        let vm = SearchViewModel()
        vm.setup(radarrConfig: radarrConfig, sonarrConfig: .empty)
        defer { vm.reset() }

        try await startSearch(vm, "matrix")
        // The next keystroke supersedes it. `onQueryChange` cancels the
        // in-flight task and clears `errorMessage` — so anything found there
        // afterwards was written by the cancelled lookup's catch block.
        try await startSearch(vm, "matrix reloaded")
        // Let the cancellation finish propagating out of URLSession.
        try await Task.sleep(for: .milliseconds(400))

        #expect(vm.errorMessage == nil)
        // The sticky loader is untouched: a cancelled fetch must not look like
        // a settled search either.
        #expect(vm.isSearching)
    }

    /// The other half — swallowing every error would be just as broken. A real
    /// failure on the search the user is actually waiting for still surfaces.
    @Test("A genuine failure on the current search still surfaces")
    func realFailureStillSurfaces() async throws {
        SearchCancelStub.state.behaviour = .fail
        URLProtocol.registerClass(SearchCancelStub.self)
        defer {
            URLProtocol.unregisterClass(SearchCancelStub.self)
            SearchCancelStub.state.behaviour = .hang
        }

        let vm = SearchViewModel()
        vm.setup(radarrConfig: radarrConfig, sonarrConfig: .empty)
        defer { vm.reset() }

        try await startSearch(vm, "matrix")
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.errorMessage != nil)
        // And it must not be the cancellation text that used to leak through.
        #expect(vm.errorMessage?.contains("CancellationError") != true)
    }

    /// `reset()` is the explicit "leave the search" path and cancels the task
    /// too — that cancellation must be as quiet as a keystroke's.
    @Test("Resetting the search view does not raise an error either")
    func resetIsSilent() async throws {
        SearchCancelStub.state.behaviour = .hang
        URLProtocol.registerClass(SearchCancelStub.self)
        defer { URLProtocol.unregisterClass(SearchCancelStub.self) }

        let vm = SearchViewModel()
        vm.setup(radarrConfig: radarrConfig, sonarrConfig: .empty)

        try await startSearch(vm, "matrix")
        vm.reset()
        try await Task.sleep(for: .milliseconds(400))

        #expect(vm.errorMessage == nil)
        #expect(!vm.isSearching)
    }
}
