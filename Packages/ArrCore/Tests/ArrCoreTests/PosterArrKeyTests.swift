import Foundation
import MediaKit
import Testing
@testable import ArrCore

@Suite struct PosterArrKeyTests {
    @Test func theArrKeyGoesToTheArrOnly() throws {
        let arr = try #require(URL(string: "http://radarr.lan:7878/MediaCover/1/poster.jpg"))
        let cdn = try #require(URL(string: "https://image.tmdb.org/t/p/original/a.jpg"))
        let plex = try #require(URL(string: "https://plex.lan/library/metadata/1/thumb/2"))
        let artwork = ArtworkReference(url: plex, headers: [:], sizing: .plexTranscode(photoPath: "/library/metadata/1/thumb/2"), kind: .poster)
        #expect(PosterStore.arrKey("k", for: arr, artwork: nil) == "k")
        #expect(PosterStore.arrKey("k", for: cdn, artwork: nil) == nil)
        #expect(PosterStore.arrKey("k", for: plex, artwork: artwork) == nil)
        #expect(PosterStore.arrKey("", for: arr, artwork: nil) == nil)
    }
}
