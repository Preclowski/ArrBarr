import Foundation
import Testing
@testable import MediaKit

@Suite struct IdentityTests {
    @Test func mediaIDRoundTrips() {
        for id in [MediaID.tmdbMovie(603), .tvdb(81189), .imdb("TT0133093"), .arr(InstanceID(.radarr), 15), .server(InstanceID(.plex), "1234"), .musicBrainz(.musicBrainzAlbum, "abc")] {
            #expect(MediaID(id.description) == id)
        }
        #expect(MediaID.imdb("TT0133093").value == "tt0133093")
        #expect(MediaID("nonsense") == nil)
    }

    @Test func plexGuidParsing() {
        let ids = ExternalIDParsing.plexGuids(["tmdb://603", "imdb://tt0133093", "tvdb://12", "plex://movie/5d77", "com.plexapp.agents.imdb://tt0068646?lang=en"], kind: .movie)
        #expect(ids == [.tmdbMovie(603), .imdb("tt0133093"), .tvdb(12), .imdb("tt0068646")])
        #expect(ExternalIDParsing.plexGuids(["tmdb://1399"], kind: .series) == [.tmdbSeries(1399)])
    }

    @Test func servarrAndJellyfinParsing() {
        #expect(ExternalIDParsing.servarrIDs(tmdbId: 603, imdbId: "tt0133093", tvdbId: 0, foreignId: nil, kind: .movie) == [.tmdbMovie(603), .imdb("tt0133093")])
        #expect(ExternalIDParsing.servarrIDs(tmdbId: nil, imdbId: nil, tvdbId: nil, foreignId: "mbid-1", kind: .artist) == [.musicBrainz(.musicBrainzArtist, "mbid-1")])
        #expect(ExternalIDParsing.jellyfinProviderIDs(["Tmdb": "603", "Imdb": "tt0133093"], kind: .movie) == [.tmdbMovie(603), .imdb("tt0133093")])
    }

    @Test func identityStoreRecordsBothDirectionsAndForgetsAnInstance() async throws {
        let db = try SQLiteDatabase(location: .memory, log: NoLog())
        let store = IdentityStore(database: db, clock: TestClock())
        let radarr = InstanceID(.radarr)
        await store.record([Crosswalk(from: .tmdbMovie(603), to: .arr(radarr, 15), kind: .movie, confidence: .asserted, source: .arrRecord, fetchedAt: Date())])
        #expect(await store.known(.tmdbMovie(603), in: .arr(radarr)) == .arr(radarr, 15))
        #expect(await store.known(.arr(radarr, 15), in: .tmdbMovie) == .tmdbMovie(603))
        #expect(await store.known(.tmdbMovie(603), in: .arr(radarr), minimum: .asserted) == .arr(radarr, 15))
        await store.forget(instance: radarr)
        #expect(await store.known(.tmdbMovie(603), in: .arr(radarr)) == nil)
        let fresh = IdentityStore(database: db, clock: TestClock())
        #expect(await fresh.known(.tmdbMovie(603), in: .arr(radarr)) == nil)
    }

    @Test func identityMatchesOnSharedIDOnly() {
        let a = MediaIdentity(kind: .movie, ids: [.tmdbMovie(603), .imdb("tt0133093")])
        let b = MediaIdentity(kind: .movie, ids: [.imdb("tt0133093")])
        let c = MediaIdentity(kind: .series, ids: [.imdb("tt0133093")])
        #expect(a.matches(b) && !a.matches(c))
        #expect(a.merging(b).ids.count == 2)
    }
}
