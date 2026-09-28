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
    private let lock = NSLock()
    private var _behaviour: StubBehaviour = .hang
    var behaviour: StubBehaviour {
        get { lock.withLock { _behaviour } }
        set { lock.withLock { _behaviour = newValue } }
    }
}

private let searchState = SearchStubState()

/// `.hang` never answers: the request sits in flight until the superseding
/// keystroke cancels it.
private let searchTransport = ScriptedTransport { _ in
    guard searchState.behaviour == .fail else {
        try await Task.sleep(for: .seconds(3600))
        return .init()
    }
    return .init(status: 500, "boom")
}

/// arr lookups take 1-3 s, so typing supersedes them constantly. Every one of
/// those cancellations used to be reported to the user as a failure — the raw
/// "The operation couldn't be completed. (Swift.CancellationError error 1.)"
/// landed in the search UI's error slot while a perfectly healthy search was
/// still running behind it.
///
/// `.serialized` because the transport carries shared script state.
@Suite("Search cancellation", .serialized, .gateway(searchTransport))
@MainActor
struct SearchViewModelCancellationTests {

    private var radarrConfig: ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://search.cancel.test:7878",
                      apiKey: "test-key", username: "", password: "")
    }

    /// Drives a search up to the point where its lookups are in flight.
    /// `onQueryChange` debounces for 300 ms before it even starts.
    private func startSearch(_ vm: SearchViewModel, _ query: String) async throws {
        vm.query = query
        try await Task.sleep(for: .milliseconds(600))
    }

    @Test("A lookup cancelled by the next keystroke leaves no error on screen")
    func cancelledLookupIsSilent() async throws {
        searchState.behaviour = .hang

        let vm = SearchViewModel()
        vm.setup(radarrConfig: radarrConfig, sonarrConfig: .empty)
        defer { vm.query = "" }

        try await startSearch(vm, "matrix")
        // The next keystroke supersedes it. `onQueryChange` cancels the
        // in-flight task and clears `errorMessage` — so anything found there
        // afterwards was written by the cancelled lookup's catch block.
        try await startSearch(vm, "matrix reloaded")
        // Let the cancellation finish propagating out of the pipeline.
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
        searchState.behaviour = .fail
        defer { searchState.behaviour = .hang }

        let vm = SearchViewModel()
        vm.setup(radarrConfig: radarrConfig, sonarrConfig: .empty)
        defer { vm.query = "" }

        try await startSearch(vm, "matrix")
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.errorMessage != nil)
        // And it must not be the cancellation text that used to leak through.
        #expect(vm.errorMessage?.contains("CancellationError") != true)
    }
}
