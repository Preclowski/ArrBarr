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
        let arrs = [try #require(URL(string: "http://radarr.lan:7878"))]
        #expect(PosterStore.arrKey("k", for: arr, artwork: nil, arrs: arrs) == "k")
        #expect(PosterStore.arrKey("k", for: cdn, artwork: nil, arrs: arrs) == nil)
        #expect(PosterStore.arrKey("k", for: plex, artwork: artwork, arrs: arrs) == nil)
        // Plex whose artwork the index no longer recognises: still not an arr.
        #expect(PosterStore.arrKey("k", for: plex, artwork: nil, arrs: arrs) == nil)
        #expect(PosterStore.arrKey("", for: arr, artwork: nil, arrs: arrs) == nil)
    }

    @Test func oneOriginBehindAProxyIsSplitByPath() throws {
        let arrs = [try #require(URL(string: "https://nas.lan/radarr"))]
        let radarr = try #require(URL(string: "https://nas.lan/radarr/MediaCover/1/poster.jpg"))
        let plex = try #require(URL(string: "https://nas.lan/plex/library/metadata/1/thumb/2"))
        let lookalike = try #require(URL(string: "https://nas.lan/radarrfake/x.jpg"))
        #expect(PosterStore.arrKey("k", for: radarr, artwork: nil, arrs: arrs) == "k")
        #expect(PosterStore.arrKey("k", for: plex, artwork: nil, arrs: arrs) == nil)
        #expect(PosterStore.arrKey("k", for: lookalike, artwork: nil, arrs: arrs) == nil)
    }
}
