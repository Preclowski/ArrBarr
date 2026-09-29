import Testing
import Foundation
@testable import ArrCore

/// The Library, Upcoming and chat surfaces open a detail view by publishing on
/// `Router.detail`; the hosts fire on the request's id changing. These pin the
/// two properties that behaviour rests on — a request lands, and opening the
/// same title twice is two distinct requests (otherwise a re-tap after Back
/// would do nothing).
@MainActor
struct DetailRouterTests {
    @Test func openPublishesTheItem() {
        let router = Router.detail
        DetailRequest.open(source: .radarr, arrId: 42, title: "Big Buck Bunny")
        #expect(router.request?.value.entityId == 42)
        #expect(router.request?.value.source == .radarr)
    }

    @Test func reopeningTheSameTitleIsANewRequest() {
        let router = Router.detail
        DetailRequest.open(source: .sonarr, arrId: 7, title: "Sintel")
        let first = router.request?.id
        DetailRequest.open(source: .sonarr, arrId: 7, title: "Sintel")
        #expect(first != nil)
        #expect(router.request?.id != first)
    }

    /// An Upcoming row is one episode, and the hosts route on these two fields
    /// (macOS to the episode screen, iOS to `DetailView`'s auto-drill). Without
    /// them the tap stopped at the series.
    @Test func anEpisodeLookupCarriesItsCoordinates() {
        DetailRequest.post(DetailRequest.syntheticItem(
            source: .sonarr, entityId: 12, title: "Sintel", seasonNumber: 2, episodeNumber: 5))
        let item = Router.detail.request?.value
        #expect(item?.seasonNumber == 2)
        #expect(item?.episodeNumber == 5)
        // Two episodes of one series must not share an identity.
        DetailRequest.post(DetailRequest.syntheticItem(
            source: .sonarr, entityId: 12, title: "Sintel", seasonNumber: 2, episodeNumber: 6))
        #expect(Router.detail.request?.value.id != item?.id)
    }

    /// The Quiz's "More" on a card that is NOT in the library takes the add
    /// branch — the one that used to post onto the message bus and vanish.
    @Test func theAddPanelRequestCarriesItsOrigin() {
        var result = SearchResult(externalId: 45745, foreignId: "45745", title: "Sintel", subtitle: nil,
                                  year: 2010, rating: nil, imdb: nil, rottenTomatoes: nil, metacritic: nil,
                                  overview: nil, runtime: nil, genres: [], network: nil, certification: nil,
                                  posterURL: nil, source: .radarr)
        SearchAddRequest.post(result, origin: .quiz)
        #expect(Router.searchAdd.request?.value.result.title == "Sintel")
        #expect(Router.searchAdd.request?.value.origin == .quiz)

        // An owned title still opens the detail instead.
        result.inLibraryArrId = 9
        let before = Router.searchAdd.request?.id
        DetailRequest.tap(result, addOrigin: .quiz)
        #expect(Router.searchAdd.request?.id == before)
        #expect(Router.detail.request?.value.entityId == 9)
    }

    /// Lidarr's addable entity is the artist, so a bare `open` has to route to
    /// the artist surface rather than treat the id as an album.
    @Test func lidarrOpensTheArtistSurface() {
        DetailRequest.open(source: .lidarr, arrId: 3, title: "Kevin MacLeod")
        #expect(Router.detail.request?.value.isLidarrArtistLookup == true)
    }

    /// A row menu's entry is carried out once: Back from the history must not reopen it, and an
    /// intent whose detail never loaded must not fire on the next title.
    @Test func aRowIntentIsHandedOverOnce() {
        let movie = DetailRequest.syntheticItem(source: .radarr, entityId: 42, title: "Big Buck Bunny")
        DetailRequest.post(movie, intent: .history)
        #expect(DetailIntents.take(for: movie.id) == .history)
        #expect(DetailIntents.take(for: movie.id) == nil)

        DetailRequest.post(movie, intent: .edit)
        #expect(DetailIntents.take(for: "radarr-7") == nil)
        #expect(DetailIntents.take(for: movie.id) == nil)

        DetailRequest.post(movie, intent: .edit)
        DetailRequest.post(movie)
        #expect(DetailIntents.take(for: movie.id) == nil)
    }

    /// A row offers only what the detail it opens has in its "…".
    @Test func rowsOfferWhatTheirDetailOpens() {
        let movie = DetailRequest.syntheticItem(source: .radarr, entityId: 1, title: "Sintel")
        #expect(DetailIntent.supported(by: movie) == [.automaticSearch, .manualSearch, .edit, .history])
        let series = DetailRequest.syntheticItem(source: .sonarr, entityId: 2, title: "Pioneer One")
        #expect(DetailIntent.supported(by: series) == [.automaticSearch, .edit, .history])
        let artist = DetailRequest.item(source: .lidarr, arrId: 3, title: "Kevin MacLeod")
        #expect(DetailIntent.supported(by: artist) == [.automaticSearch, .edit, .history])
        let album = DetailRequest.item(source: .lidarr, arrId: 4, title: "Ghosts I-IV", isLidarrAlbum: true)
        #expect(DetailIntent.supported(by: album) == [.automaticSearch, .manualSearch, .edit, .history])
        #if os(macOS)
        let episode = DetailRequest.syntheticItem(source: .sonarr, entityId: 2, title: "Pioneer One",
                                                  seasonNumber: 1, episodeNumber: 3)
        #expect(DetailIntent.supported(by: episode) == [.automaticSearch, .manualSearch, .history])
        #endif
    }
}
