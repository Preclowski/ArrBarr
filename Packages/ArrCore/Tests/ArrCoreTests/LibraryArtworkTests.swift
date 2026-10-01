import Foundation
import MediaKit
import Testing
@testable import ArrCore

@Suite("Library artwork on TMDB rows")
struct LibraryArtworkTests {
    private func images(_ json: String) throws -> [ArrImage] {
        try JSONDecoder().decode([ArrImage].self, from: Data(json.utf8))
    }

    private func tmdbRow(id: Int) -> SearchResult {
        SearchResult(
            externalId: id, foreignId: String(id), title: "Sintel", subtitle: nil, year: 2010,
            rating: nil, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil,
            posterURL: URL(string: "https://image.tmdb.org/t/p/w342/tmdb.jpg"), source: .radarr)
    }

    @Test("An owned title's row takes the library's key-free cover")
    func ownedRowTakesLibraryCover() throws {
        let owned = LibraryOwnership(arrId: 7, isDownloaded: true).withPoster(
            images: try images(#"[{"coverType":"poster","remoteUrl":"https://image.tmdb.org/t/p/original/arr.jpg"}]"#),
            mediaServerKeys: [], baseURL: "http://radarr.local:7878")
        let row = tmdbRow(id: 45745).withLibraryOwnership(owned)
        #expect(row.posterURL?.lastPathComponent == "arr.jpg")
        #expect(row.posterRequiresAuth == false)
        #expect(row.inLibraryArrId == 7)
    }

    @Test("A cover behind the arr's key is never handed to a TMDB row")
    func keyedCoverIsSkipped() throws {
        let owned = LibraryOwnership(arrId: 7, isDownloaded: true).withPoster(
            images: try images(#"[{"coverType":"poster","url":"/MediaCover/7/poster.jpg"}]"#),
            mediaServerKeys: [], baseURL: "http://radarr.local:7878")
        #expect(owned.poster == nil)
        let row = tmdbRow(id: 45745).withLibraryOwnership(owned)
        #expect(row.posterURL?.lastPathComponent == "tmdb.jpg")
    }
}
