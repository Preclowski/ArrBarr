import Foundation
import MediaKit

nonisolated extension DemoMocks {

    /// Far outside any real range, so a demo id never collides with live data after a mode switch.
    enum DemoPerson: Int, CaseIterable {
        case derekDeLint = 990_001   // Tears of Steel lead
        case jamesRich   = 990_002   // Pioneer One lead
        case colinLevy   = 990_003   // Sintel director
    }

    public static func searchPeople(query: String) -> [TMDBPerson] {
        let term = query.lowercased()
        guard !term.isEmpty else { return [] }
        return demoPeople.filter { $0.name.lowercased().contains(term) }
    }

    public static func personDetails(personId: Int) -> TMDBPersonDetails? {
        demoPersonDetails.first { $0.id == personId }
    }

    public static func personMovies(personId: Int) -> [SearchResult] {
        switch DemoPerson(rawValue: personId) {
        case .derekDeLint:
            return [
                demoMovieRow(id: 203, title: "Tears of Steel", year: 2012, rating: 6.4,
                             seed: "tearsofsteel", role: roleActor, ownedId: 203),
                demoMovieRow(id: 204, title: "Elephants Dream", year: 2006, rating: 6.1,
                             seed: "elephantsdream", role: roleActor, ownedId: nil),
            ]
        case .colinLevy:
            return [
                demoMovieRow(id: 202, title: "Sintel", year: 2010, rating: 7.3,
                             seed: "sintel", role: roleDirector, ownedId: 202),
                demoMovieRow(id: 201, title: "Big Buck Bunny", year: 2008, rating: 6.9,
                             seed: "bigbuckbunny", role: roleWriter, ownedId: 201),
            ]
        default:
            return []
        }
    }

    public static func personSeries(personId: Int) -> [SearchResult] {
        switch DemoPerson(rawValue: personId) {
        case .jamesRich:
            return [
                demoSeriesRow(tmdbTVId: 301, title: "Pioneer One", year: 2010, rating: 7.1,
                              seed: "pioneerone", role: roleActor, ownedId: 101),
            ]
        default:
            return []
        }
    }

    // MARK: - Fixtures

    /// TMDB's own JSON, decoded like a live answer: MediaKit's records only decode.
    private static func tmdb<T: Decodable>(_ json: String) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(T.self, from: Data(json.utf8))
    }

    private static var demoPeople: [TMDBPerson] {
        tmdb(#"""
        [{"id": 990001, "name": "Derek de Lint", "known_for_department": "Acting",
          "profile_path": "/8fRRmh8EYZBlUtu1Wlop0j22QcP.jpg", "popularity": 12},
         {"id": 990002, "name": "James Rich", "known_for_department": "Acting",
          "profile_path": "/oF7kZnQ0HgqXVCPFmU1t03quHr2.jpg", "popularity": 10},
         {"id": 990003, "name": "Colin Levy", "known_for_department": "Directing", "popularity": 9}]
        """#)
    }

    private static var demoPersonDetails: [TMDBPersonDetails] {
        tmdb(#"""
        [{"id": 990001, "name": "Derek de Lint",
          "biography": "Dutch actor with a four-decade career across European and American film and television; in the demo library he anchors the Blender Foundation's live-action VFX film Tears of Steel as Old Thom.",
          "birthday": "1950-07-17", "place_of_birth": "The Hague, Netherlands",
          "profile_path": "/8fRRmh8EYZBlUtu1Wlop0j22QcP.jpg", "known_for_department": "Acting"},
         {"id": 990002, "name": "James Rich",
          "biography": "Lead of Pioneer One, the BitTorrent-distributed, crowd-funded drama that proved a series could find its audience entirely outside broadcast television.",
          "profile_path": "/oF7kZnQ0HgqXVCPFmU1t03quHr2.jpg", "known_for_department": "Acting"},
         {"id": 990003, "name": "Colin Levy",
          "biography": "Director of the Blender Foundation's open movie Sintel; the demo credits him with story duty on Big Buck Bunny too, so a person can wear more than one role hat.",
          "known_for_department": "Directing"}]
        """#)
    }

    private static var roleActor: String { String(localized: "person.role.actor", bundle: .module) }
    private static var roleDirector: String { String(localized: "person.role.director", bundle: .module) }
    private static var roleWriter: String { String(localized: "person.role.writer", bundle: .module) }

    private static func demoMovieRow(
        id: Int, title: String, year: Int, rating: Double,
        seed: String, role: String, ownedId: Int?
    ) -> SearchResult {
        SearchResult(
            externalId: id, foreignId: String(id), title: title, subtitle: role,
            year: year, rating: rating,
            imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: nil, runtime: nil, genres: [], network: nil,
            certification: nil,
            posterURL: poster(label: title, seed: seed),
            source: .radarr, inLibraryArrId: ownedId
        )
    }

    /// `id: 0` like the real TMDB path: a series row has no tvdbId until something resolves it.
    private static func demoSeriesRow(
        tmdbTVId: Int, title: String, year: Int, rating: Double,
        seed: String, role: String, ownedId: Int?
    ) -> SearchResult {
        SearchResult(
            externalId: 0, foreignId: "", title: title, subtitle: role,
            year: year, rating: rating,
            imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: nil, runtime: nil, genres: [], network: nil,
            certification: nil,
            posterURL: poster(label: title, seed: seed),
            source: .sonarr, inLibraryArrId: ownedId,
            tmdbTVId: tmdbTVId
        )
    }
}
