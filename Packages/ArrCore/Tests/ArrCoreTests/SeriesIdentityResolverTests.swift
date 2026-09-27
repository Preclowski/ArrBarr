import Foundation
import Testing
import MediaKit
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
      "ratings": {"value": 7.9, "votes": 1200},
      "images": [{"coverType": "poster", "url": null,
                  "remoteUrl": "https://artworks.thetvdb.com/tvdb-poster.jpg"}],
      "genres": ["Drama"], "statistics": {"seasonCount": 7}, "status": "ended"}]
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
    private let lock = NSLock()
    private var _requests: [URL] = []
    private var _understandsTMDBTerm = false
    private var _externalTVDBId: Int? = Fixtures.tvdbId
    private var _libraryJSON = "[]"

    /// Every URL the gateway asked for during the test.
    var requests: [URL] {
        get { lock.withLock { _requests } }
        set { lock.withLock { _requests = newValue } }
    }
    /// Does the stubbed Sonarr understand `term=tmdb:N`?
    var understandsTMDBTerm: Bool {
        get { lock.withLock { _understandsTMDBTerm } }
        set { lock.withLock { _understandsTMDBTerm = newValue } }
    }
    /// `nil` → TMDB has no tvdb id on file for this show.
    var externalTVDBId: Int? {
        get { lock.withLock { _externalTVDBId } }
        set { lock.withLock { _externalTVDBId = newValue } }
    }
    /// Body for `GET /api/v3/series` (the library snapshot).
    var libraryJSON: String {
        get { lock.withLock { _libraryJSON } }
        set { lock.withLock { _libraryJSON = newValue } }
    }

    func record(_ url: URL) { lock.withLock { _requests.append(url) } }

    func requests(matching needle: String) -> [URL] {
        requests.filter { ($0.absoluteString).contains(needle) }
    }
}

private let resolverState = ResolverStubState()

/// Answers the Sonarr host *and* TMDB, so a test can see every request the
/// resolution made — including the one it must never make.
private let resolverTransport = ScriptedTransport { request in
    let url = request.url
    resolverState.record(url)
    let path = url.path
    let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "term" }?.value ?? ""

    if path.contains("/external_ids") {
        // Slow enough that two concurrent resolutions are both in flight: the store coalesces in-flight reads.
        try await Task.sleep(for: .milliseconds(50))
        return .init(resolverState.externalTVDBId.map { #"{"tvdb_id": \#($0)}"# } ?? #"{"tvdb_id": null}"#)
    }
    if path.hasSuffix("/series/lookup") {
        if term == "tvdb:\(Fixtures.tvdbId)" { return .init(Fixtures.realShow) }
        if term == "tmdb:\(Fixtures.tmdbTVId)" {
            return .init(resolverState.understandsTMDBTerm ? Fixtures.realShow : Fixtures.decoyShow)
        }
        // A title search, or anything else we didn't script. Answering
        // with the decoy is deliberate: if some path ever falls back to
        // matching by name, the test sees the wrong show rather than an
        // empty list.
        return .init(Fixtures.decoyShow)
    }
    if path.hasSuffix("/series") { return .init(resolverState.libraryJSON) }
    return .init("[]")
}

@Suite("Series identity resolution", .serialized, .gateway(resolverTransport))
@MainActor
struct SeriesIdentityResolverTests {

    /// A fresh port per test: `LibraryIndex` keys its snapshot on the base URL,
    /// and a cached empty library from a previous test would silently answer
    /// the one that needs a populated one.
    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://sonarr.identity.test:\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    private func withStub(_ body: () async throws -> Void) async rethrows {
        SeriesIdentityResolver.resetForTesting()
        resolverState.requests = []
        resolverState.understandsTMDBTerm = false
        resolverState.externalTVDBId = Fixtures.tvdbId
        resolverState.libraryJSON = "[]"
        defer { SeriesIdentityResolver.resetForTesting() }
        try await body()
    }

    @Test("The show is resolved through TMDB's external ids, never by title")
    func resolvesByIdNotByTitle() async throws {
        await withStub {
            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8001), tmdbKey: "k")

            #expect(record?.externalId == Fixtures.tvdbId)
            #expect(record?.year == 2005)
            #expect(record?.externalId != Fixtures.decoyTVDBId)
            // The regression itself: no request may carry the bare title as
            // its search term.
            #expect(resolverState.requests(matching: "term=The%20Closer").isEmpty)
            #expect(resolverState.requests(matching: "term=The+Closer").isEmpty)
        }
    }

    @Test("A tmdb: answer that doesn't carry our id is rejected, not trusted")
    func verificationGateRejectsFuzzyAnswer() async throws {
        await withStub {
            // Sonarr replies to `term=tmdb:1234` with a same-titled other show
            // — the shape an older server produces when it treats the prefix as
            // literal text.
            resolverState.understandsTMDBTerm = false

            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8002), tmdbKey: "k")

            #expect(record?.externalId == Fixtures.tvdbId)
            #expect(record?.title == "The Closer")
            #expect(record?.overview == "The one they meant.")
            // Rejecting the fuzzy answer is what forced the TMDB hop.
            #expect(!resolverState.requests(matching: "/external_ids").isEmpty)
        }
    }

    @Test("A Sonarr that understands tmdb: costs one request and no TMDB quota")
    func verifiedTMDBTermShortCircuits() async throws {
        await withStub {
            resolverState.understandsTMDBTerm = true

            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8003), tmdbKey: "k")

            #expect(record?.externalId == Fixtures.tvdbId)
            #expect(resolverState.requests(matching: "/external_ids").isEmpty)
        }
    }

    @Test("An owned series resolves from the library snapshot without asking TMDB")
    func ownedSeriesNeedsNoTMDBRequest() async throws {
        await withStub {
            resolverState.libraryJSON = Fixtures.ownedLibrary

            let tvdbId = await SeriesIdentityResolver.tvdbId(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8004), tmdbKey: "k")

            #expect(tvdbId == Fixtures.tvdbId)
            #expect(resolverState.requests(matching: "/external_ids").isEmpty)
        }
    }

    @Test("No tvdb id anywhere means no substitution at all")
    func unresolvableYieldsNil() async throws {
        await withStub {
            resolverState.externalTVDBId = nil

            let record = await SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: config(port: 8005), tmdbKey: "k")

            // The decoy was available the whole time and was still not taken.
            #expect(record == nil)
        }
    }

    @Test("Concurrent resolutions of the same show coalesce into one")
    func concurrentResolutionsCoalesce() async throws {
        await withStub {
            let cfg = config(port: 8007)
            async let a = SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: cfg, tmdbKey: "k")
            async let b = SeriesIdentityResolver.sonarrRecord(
                tmdbTVId: Fixtures.tmdbTVId, sonarrConfig: cfg, tmdbKey: "k")
            let (first, second) = await (a, b)

            #expect(first?.externalId == Fixtures.tvdbId)
            #expect(second?.externalId == Fixtures.tvdbId)
            #expect(resolverState.requests(matching: "/external_ids").count == 1)
        }
    }

    // MARK: - The call sites

    @Test("Enriching a TMDB series row swaps in the right show, not a namesake")
    func enrichKeepsIdentity() async throws {
        await withStub {
            let vm = SearchViewModel()
            vm.setup(radarrConfig: .empty, sonarrConfig: config(port: 8008),
                     tmdbApiKey: "k")
            defer { vm.query = "" }

            let lean = TMDBSearchMapping.series([tvSummary()]).first!
            #expect(lean.externalId == 0)
            #expect(lean.tmdbTVId == Fixtures.tmdbTVId)

            let enriched = await vm.enrich(lean)

            #expect(enriched?.externalId == Fixtures.tvdbId)
            #expect(enriched?.overview == "The one they meant.")
            #expect(resolverState.requests(matching: "term=The%20Closer").isEmpty)
        }
    }

    /// The half of the symptom that survived the identity fix: the panel used
    /// to adopt the arr record's artwork, so opening a TMDB series swapped a
    /// TMDB poster for TVDB's. Same show, different catalogue — and from the
    /// outside identical to the bug where it really was a different show.
    @Test("Enrichment upgrades the metadata but keeps the poster you tapped")
    func enrichKeepsTheRowsArtwork() async throws {
        await withStub {
            let vm = SearchViewModel()
            vm.setup(radarrConfig: .empty, sonarrConfig: config(port: 8011),
                     tmdbApiKey: "k")
            defer { vm.query = "" }

            let lean = TMDBSearchMapping.series([tvSummary()]).first!
            let tmdbPoster = lean.posterURL
            #expect(tmdbPoster != nil)

            let enriched = await vm.enrich(lean)

            // Identity and metadata come from Sonarr…
            #expect(enriched?.externalId == Fixtures.tvdbId)
            #expect(enriched?.runtime == 45)
            #expect(enriched?.network == "TNT")
            // …the image the user is looking at does not change under them.
            #expect(enriched?.posterURL == tmdbPoster)
        }
    }

    @Test("An unresolved row is never enriched into some other show")
    func enrichReturnsNilRatherThanGuessing() async throws {
        await withStub {
            resolverState.externalTVDBId = nil
            let vm = SearchViewModel()
            vm.setup(radarrConfig: .empty, sonarrConfig: config(port: 8009),
                     tmdbApiKey: "k")
            defer { vm.query = "" }

            let lean = TMDBSearchMapping.series([tvSummary()]).first!
            #expect(await vm.enrich(lean) == nil)
        }
    }

    /// The write path is the one that can't be undone by tapping back.
    @Test("Adding an unresolved series refuses rather than posting a guess")
    func addSeriesRefusesUnresolvedRow() async throws {
        await withStub {
            let client = SearchClient(config: config(port: 8010), source: .sonarr)
            let lean = TMDBSearchMapping.series([tvSummary()]).first!

            await #expect(throws: (any Error).self) {
                try await client.addSeries(
                    lean, qualityProfileId: 1, rootFolderPath: "/tv",
                    monitor: .all, seriesType: .standard,
                    seasonFolder: true, searchOnAdd: false)
            }
            // Nothing was written.
            #expect(resolverState.requests(matching: "/series").allSatisfy {
                $0.absoluteString.contains("lookup") || !$0.absoluteString.hasSuffix("/series")
            })
        }
    }

    private func tvSummary() -> TMDBTVSummary {
        try! tmdbDecoder.decode(TMDBTVSummary.self, from: Data(#"""
        {"id": 1234, "name": "The Closer", "first_air_date": "2005-06-13",
         "vote_average": 7.9, "genre_ids": [18], "overview": "…",
         "poster_path": "/tmdb-poster.jpg"}
        """#.utf8))
    }
}
