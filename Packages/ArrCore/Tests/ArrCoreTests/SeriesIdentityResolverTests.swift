import Foundation
import Testing
@testable import ArrCore

/// The bug these exist for: opening "The Closer" from Rhea Seehorn's
/// filmography showed a *different* "The Closer" — different poster, different
/// overview, different cast. A TMDB-sourced series row carries a TMDB tv id,
/// Sonarr wants a tvdbId, and the code bridged that gap by looking the show up
/// by **title** and taking the first hit. Two shows share that title, so the
/// first hit was a coin flip; on the add path the same coin flip wrote the
/// wrong series into the user's library.
///
/// Every test here is really one assertion in different clothes: identity is
/// resolved by id or not at all.
private struct Fixtures {
    /// The show the user actually clicked.
    static let tmdbTVId = 1234
    static let tvdbId = 75299
    /// A different show with the same name — what a title search returns first.
    static let decoyTVDBId = 88888

    static let realShow = #"""
    [{"id": 0, "tvdbId": 75299, "tmdbId": 1234, "title": "The Closer", "year": 2005,
      "overview": "The one they meant.", "runtime": 45, "network": "TNT",
      "ratings": {"value": 7.9, "votes": 1200}, "images": [], "genres": ["Drama"],
      "statistics": {"seasonCount": 7}, "status": "ended"}]
    """#

    /// What an older Sonarr answers when it does not understand `tmdb:N` and
    /// searches for the literal string instead — plausible, same title, wrong
    /// show, no matching tmdb id.
    static let decoyShow = #"""
    [{"id": 0, "tvdbId": 88888, "tmdbId": 9999, "title": "The Closer", "year": 2013,
      "overview": "A different show entirely.", "runtime": 30, "network": "Other",
      "ratings": {"value": 6.1, "votes": 40}, "images": [], "genres": ["Comedy"],
      "statistics": {"seasonCount": 1}, "status": "ended"}]
    """#

    /// A Sonarr library that already owns the show, tmdbId included.
    static let ownedLibrary = #"""
    [{"id": 42, "tvdbId": 75299, "tmdbId": 1234, "title": "The Closer", "year": 2005,
      "status": "ended", "monitored": true, "statistics": null, "images": [],
      "seasons": [], "overview": null, "titleSlug": "the-closer"}]
    """#
}

private final class ResolverStubState: @unchecked Sendable {
    /// Every URL the process asked for while the stub was installed.
    var requests: [URL] = []
    /// Does the stubbed Sonarr understand `term=tmdb:N`?
    var understandsTMDBTerm = false
    /// `nil` → TMDB has no tvdb id on file for this show.
    var externalTVDBId: Int? = Fixtures.tvdbId
    /// Body for `GET /api/v3/series` (the library snapshot).
    var libraryJSON = "[]"

    func requests(matching needle: String) -> [URL] {
        requests.filter { ($0.absoluteString).contains(needle) }
    }
}

/// Stubs the Sonarr host *and* TMDB, so a test can see every request the
/// resolution made — including the one it must never make.
private final class ResolverStub: URLProtocol, @unchecked Sendable {
    static let state = ResolverStubState()
    static let sonarrHost = "sonarr.identity.test"

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == sonarrHost || host == "api.themoviedb.org"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        Self.state.requests.append(url)
        let path = url.path
        let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "term" }?.value ?? ""

        let body: String
        if path.contains("/external_ids") {
            body = Self.state.externalTVDBId.map { #"{"tvdb_id": \#($0)}"# } ?? #"{"tvdb_id": null}"#
        } else if path.hasSuffix("/series/lookup") {
            if term == "tvdb:\(Fixtures.tvdbId)" {
                body = Fixtures.realShow
            } else if term == "tmdb:\(Fixtures.tmdbTVId)" {
                body = Self.state.understandsTMDBTerm ? Fixtures.realShow : Fixtures.decoyShow
            } else {
                // A title search, or anything else we didn't script. Answering
                // with the decoy is deliberate: if some path ever falls back to
                // matching by name, the test sees the wrong show rather than an
                // empty list.
                body = Fixtures.decoyShow
            }
        } else if path.hasSuffix("/series") {
            body = Self.state.libraryJSON
        } else {
            body = "[]"
        }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Series identity resolution", .serialized)
@MainActor
struct SeriesIdentityResolverTests {

    /// A fresh port per test: `LibraryIndex` keys its snapshot on the base URL,
    /// and a cached empty library from a previous test would silently answer
    /// the one that needs a populated one.
    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(ResolverStub.sonarrHost):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    private func withStub(_ body: () async throws -> Void) async rethrows {
        SeriesIdentityResolver.resetForTesting()
        ResolverStub.state.requests = []
        ResolverStub.state.understandsTMDBTerm = false
        ResolverStub.state.externalTVDBId = Fixtures.tvdbId
        ResolverStub.state.libraryJSON = "[]"
        URLProtocol.registerClass(ResolverStub.self)
        defer {
            URLProtocol.unregisterClass(ResolverStub.self)
            SeriesIdentityResolver.resetForTesting()
        }
        try await body()
    }

    @Test("The show is resolved through TMDB's external ids, never by title")
    func resolvesByIdNotByTitle() async throws {
        try await withStub {
            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8001), tmdbKey: "k")

            #expect(record?.id == Fixtures.tvdbId)
            #expect(record?.year == 2005)
            #expect(record?.id != Fixtures.decoyTVDBId)
            // The regression itself: no request may carry the bare title as
            // its search term.
            #expect(ResolverStub.state.requests(matching: "term=The%20Closer").isEmpty)
            #expect(ResolverStub.state.requests(matching: "term=The+Closer").isEmpty)
        }
    }

    @Test("A tmdb: answer that doesn't carry our id is rejected, not trusted")
    func verificationGateRejectsFuzzyAnswer() async throws {
        try await withStub {
            // Sonarr replies to `term=tmdb:1234` with a same-titled other show
            // — the shape an older server produces when it treats the prefix as
            // literal text.
            ResolverStub.state.understandsTMDBTerm = false

            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8002), tmdbKey: "k")

            #expect(record?.id == Fixtures.tvdbId)
            #expect(record?.title == "The Closer")
            #expect(record?.overview == "The one they meant.")
            // Rejecting the fuzzy answer is what forced the TMDB hop.
            #expect(!ResolverStub.state.requests(matching: "/external_ids").isEmpty)
        }
    }

    @Test("A Sonarr that understands tmdb: costs one request and no TMDB quota")
    func verifiedTMDBTermShortCircuits() async throws {
        try await withStub {
            ResolverStub.state.understandsTMDBTerm = true

            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8003), tmdbKey: "k")

            #expect(record?.id == Fixtures.tvdbId)
            #expect(ResolverStub.state.requests(matching: "/external_ids").isEmpty)
        }
    }

    @Test("An owned series resolves from the library snapshot without asking TMDB")
    func ownedSeriesNeedsNoTMDBRequest() async throws {
        try await withStub {
            ResolverStub.state.libraryJSON = Fixtures.ownedLibrary

            let tvdbId = await SeriesIdentityResolver.tvdbId(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8004), tmdbKey: "k")

            #expect(tvdbId == Fixtures.tvdbId)
            #expect(ResolverStub.state.requests(matching: "/external_ids").isEmpty)
        }
    }

    @Test("No tvdb id anywhere means no substitution at all")
    func unresolvableYieldsNil() async throws {
        try await withStub {
            ResolverStub.state.externalTVDBId = nil

            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8005), tmdbKey: "k")

            // The decoy was available the whole time and was still not taken.
            #expect(record == nil)
        }
    }

    @Test("A repeat resolution is served from cache")
    func repeatResolutionIsCached() async throws {
        try await withStub {
            let cfg = config(port: 8006)
            _ = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: cfg, tmdbKey: "k")
            let firstCount = ResolverStub.state.requests.count

            let again = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: cfg, tmdbKey: "k")

            #expect(again?.id == Fixtures.tvdbId)
            #expect(ResolverStub.state.requests.count == firstCount)
        }
    }

    @Test("Concurrent resolutions of the same show coalesce into one")
    func concurrentResolutionsCoalesce() async throws {
        try await withStub {
            let cfg = config(port: 8007)
            async let a = SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: cfg, tmdbKey: "k")
            async let b = SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: cfg, tmdbKey: "k")
            let (first, second) = await (a, b)

            #expect(first?.id == Fixtures.tvdbId)
            #expect(second?.id == Fixtures.tvdbId)
            #expect(ResolverStub.state.requests(matching: "/external_ids").count == 1)
        }
    }

    // MARK: - The call sites

    @Test("Enriching a TMDB series row swaps in the right show, not a namesake")
    func enrichKeepsIdentity() async throws {
        try await withStub {
            let vm = SearchViewModel()
            vm.setup(radarrConfig: .empty, sonarrConfig: config(port: 8008),
                     tmdbApiKey: "k")
            defer { vm.reset() }

            let lean = TMDBSearchMapping.series([tvSummary()]).first!
            #expect(lean.id == 0)
            #expect(lean.tmdbTVId == Fixtures.tmdbTVId)

            let enriched = await vm.enrich(lean)

            #expect(enriched?.id == Fixtures.tvdbId)
            #expect(enriched?.overview == "The one they meant.")
            #expect(ResolverStub.state.requests(matching: "term=The%20Closer").isEmpty)
        }
    }

    @Test("An unresolved row is never enriched into some other show")
    func enrichReturnsNilRatherThanGuessing() async throws {
        try await withStub {
            ResolverStub.state.externalTVDBId = nil
            let vm = SearchViewModel()
            vm.setup(radarrConfig: .empty, sonarrConfig: config(port: 8009),
                     tmdbApiKey: "k")
            defer { vm.reset() }

            let lean = TMDBSearchMapping.series([tvSummary()]).first!
            #expect(await vm.enrich(lean) == nil)
        }
    }

    /// The write path is the one that can't be undone by tapping back.
    @Test("Adding an unresolved series refuses rather than posting a guess")
    func addSeriesRefusesUnresolvedRow() async throws {
        try await withStub {
            let client = SearchClient(config: config(port: 8010), source: .sonarr)
            let lean = TMDBSearchMapping.series([tvSummary()]).first!

            await #expect(throws: (any Error).self) {
                try await client.addSeries(
                    lean, qualityProfileId: 1, rootFolderPath: "/tv",
                    monitor: .all, seriesType: .standard,
                    seasonFolder: true, searchOnAdd: false)
            }
            // Nothing was written.
            #expect(ResolverStub.state.requests(matching: "/series").allSatisfy {
                $0.absoluteString.contains("lookup") || !$0.absoluteString.hasSuffix("/series")
            })
        }
    }

    private func tvSummary() -> TMDBTVSummary {
        try! JSONDecoder().decode(TMDBTVSummary.self, from: Data(#"""
        {"id": 1234, "name": "The Closer", "first_air_date": "2005-06-13",
         "vote_average": 7.9, "genre_ids": [18], "overview": "…"}
        """#.utf8))
    }
}
