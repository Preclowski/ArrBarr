import Testing
import Foundation
@testable import MediaKit

@Suite("Identity")
struct IdentityTests {
    @Test("ids round-trip through their token form")
    func tokenRoundTrip() {
        let ids: [MediaID] = [
            .tmdbMovie(603), .tmdbSeries(1396), .tvdb(81189), .imdb("tt0068646"),
            .musicBrainz("f27ec8db"), .server(.plex, "8fa3"), .arr(.radarr, 12),
        ]
        for id in ids {
            #expect(MediaID(token: id.token) == id)
        }
    }

    @Test("TMDB's two id spaces stay apart")
    func tmdbSpacesAreDistinct() {
        #expect(MediaID.tmdbMovie(603) != MediaID.tmdbSeries(603))
        #expect(MediaID.tmdbMovie(603).impliedKind == .movie)
        #expect(MediaID.tmdbSeries(603).impliedKind == .series)
    }

    @Test("merging needs a shared id — a title match is not enough")
    func mergeRequiresProof() {
        var matrix = MediaIdentity(kind: .movie, ids: [.tmdbMovie(603), .imdb("tt0133093")])
        let sameFilm = MediaIdentity(kind: .movie, ids: [.imdb("tt0133093"), .arr(.radarr, 12)])
        let otherFilm = MediaIdentity(kind: .movie, ids: [.tmdbMovie(604)])

        let mergedKnownFilm = matrix.merge(sameFilm)
        #expect(mergedKnownFilm)
        #expect(matrix.contains(.arr(.radarr, 12)))

        let mergedStranger = matrix.merge(otherFilm)
        #expect(!mergedStranger)
        #expect(!matrix.contains(.tmdbMovie(604)))
    }

    @Test("cache key prefers the portable id over a server-local one")
    func canonicalIDIsPortable() {
        let identity = MediaIdentity(kind: .movie,
                                     ids: [.server(.plex, "8fa3"), .tmdbMovie(603)])
        #expect(identity.canonicalID == .tmdbMovie(603))
        #expect(identity.cacheKey == "movie/tmdb-movie:603")
    }
}

@Suite("Fields")
struct FieldTests {
    @Test("a field set decomposes into its fields")
    func decomposition() {
        let set: MediaFieldSet = [.title, .ratings]
        #expect(Set(set.fields) == [.title, .ratings])
        #expect(MediaFieldSet.all.fields.count == MediaField.allCases.count)
    }

    @Test("freshness is a property of the field, not the call site")
    func freshness() {
        #expect(MediaField.artwork.freshnessClass == .immutable)
        #expect(MediaField.availability.freshnessClass == .volatile)
        #expect(FreshnessClass.volatile.defaultTTL < FreshnessClass.slow.defaultTTL)
    }
}

@Suite("Snapshot merging")
struct SnapshotTests {
    private func fragment(_ identity: MediaIdentity,
                          build: (inout MediaFragment) -> Void) -> MediaFragment {
        var fragment = MediaFragment(identity: identity)
        build(&fragment)
        return fragment
    }

    @Test("first answer wins for single-valued fields")
    func precedenceIsPositional() {
        var snapshot = MediaSnapshot(identity: .tmdbMovie(603))
        snapshot.apply(fragment(.tmdbMovie(603)) { $0.title = TitleFacts(title: "The Matrix") },
                       from: .init(provider: .tmdb, fetchedAt: Date(), fromCache: false))
        snapshot.apply(fragment(.tmdbMovie(603)) { $0.title = TitleFacts(title: "Matrix, The (1999)") },
                       from: .init(provider: .radarr, fetchedAt: Date(), fromCache: false))

        #expect(snapshot.title?.title == "The Matrix")
        #expect(snapshot.provenance[.title]?.provider == .tmdb)
    }

    @Test("ratings union by service, availability unions across sources")
    func multiValuedFieldsMerge() {
        var snapshot = MediaSnapshot(identity: .tmdbMovie(603))
        snapshot.apply(fragment(.tmdbMovie(603)) {
            $0.ratings = Ratings(scores: [.init(service: .tmdb, value: 8.2, voteCount: 100)])
            $0.availability = Availability(owned: true, sources: ["Radarr"])
        }, from: .init(provider: .radarr, fetchedAt: Date(), fromCache: false))
        snapshot.apply(fragment(.tmdbMovie(603)) {
            $0.ratings = Ratings(scores: [.init(service: .imdb, value: 8.7)])
            $0.availability = Availability(watched: true, sources: ["Plex"])
        }, from: .init(provider: .plex, fetchedAt: Date(), fromCache: false))

        #expect(snapshot.ratings?.value(for: .tmdb) == 8.2)
        #expect(snapshot.ratings?.value(for: .imdb) == 8.7)
        #expect(snapshot.availability?.owned == true)
        #expect(snapshot.availability?.watched == true)
        #expect(snapshot.availability?.sources == ["Radarr", "Plex"])
    }

    @Test("a fragment teaches the snapshot new ids")
    func identityGrows() {
        var snapshot = MediaSnapshot(identity: .tmdbMovie(603))
        snapshot.apply(fragment(MediaIdentity(kind: .movie,
                                              ids: [.tmdbMovie(603), .imdb("tt0133093")])) {
            $0.artwork = Artwork(poster: URL(string: "https://example.invalid/p.jpg"))
        }, from: .init(provider: .tmdb, fetchedAt: Date(), fromCache: false))

        #expect(snapshot.identity.imdbID == "tt0133093")
    }

    @Test("failures only stick where nothing answered")
    func failuresAreForEmptyFields() {
        var snapshot = MediaSnapshot(identity: .tmdbMovie(603))
        snapshot.apply(fragment(.tmdbMovie(603)) { $0.title = TitleFacts(title: "The Matrix") },
                       from: .init(provider: .tmdb, fetchedAt: Date(), fromCache: false))
        snapshot.fail([.title, .availability], with: .unreachable(.plex))

        #expect(snapshot.failures[.title] == nil)
        #expect(snapshot.failures[.availability] == .unreachable(.plex))
    }
}

@Suite("Telemetry")
struct TelemetryTests {
    @Test("disabled recorder counts nothing")
    func offByDefault() async {
        let telemetry = MediaTelemetry()
        await telemetry.record(.init(kind: .request, provider: .tmdb,
                                     identity: "movie/tmdb-movie:603", fields: .card))
        #expect(await telemetry.report().providers.isEmpty)
    }

    @Test("usage adds up per provider and per field")
    func counting() async {
        let telemetry = MediaTelemetry(enabled: true)
        await telemetry.record(.init(kind: .request, provider: .tmdb,
                                     identity: "movie/tmdb-movie:603", fields: [.title, .artwork]))
        await telemetry.record(.init(kind: .response, provider: .tmdb,
                                     identity: "movie/tmdb-movie:603", fields: [.title, .artwork],
                                     duration: 0.2, bytes: 2048))
        await telemetry.record(.init(kind: .served, provider: .tmdb,
                                     identity: "movie/tmdb-movie:603", fields: [.title, .artwork]))
        await telemetry.record(.init(kind: .cacheHit, provider: .tmdb,
                                     identity: "movie/tmdb-movie:603", fields: [.title]))
        await telemetry.record(.init(kind: .cacheMiss, provider: .tmdb,
                                     identity: "movie/tmdb-movie:604", fields: [.title]))

        let report = await telemetry.report()
        let tmdb = try! #require(report.providers.first { $0.provider == .tmdb })
        #expect(tmdb.requests == 1)
        #expect(tmdb.responses == 1)
        #expect(tmdb.bytes == 2048)
        #expect(tmdb.cacheHitRate == 0.5)
        #expect(report.fieldRequests[.title] == 1)
        #expect(report.fieldAnswers[.artwork]?[.tmdb] == 1)
    }

    @Test("the same title fetched twice is flagged")
    func repeatedFetches() async {
        let telemetry = MediaTelemetry(enabled: true)
        for _ in 0..<3 {
            await telemetry.record(.init(kind: .request, provider: .tmdb,
                                         identity: "movie/tmdb-movie:603", fields: .title))
        }
        let report = await telemetry.report()
        #expect(report.repeatedFetches["tmdb movie/tmdb-movie:603"] == 3)
        #expect(report.formatted().contains("repeated fetches"))
    }
}
