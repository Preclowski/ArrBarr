import Foundation

/// Demo-mode people fixtures — the person view, cast-head taps and People
/// search work offline against the same curated open-movie world as the rest
/// of demo mode. Served from the SAME store paths as live data: `PersonStore`
/// and `SearchViewModel.fetchPeople` branch here when `DemoMode.isActive`.
extension DemoMocks {

    /// Synthetic TMDB person ids, far outside any real range so a demo id can
    /// never collide with live data after a mode switch.
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
                demoSeriesRow(title: "Pioneer One", year: 2010, rating: 7.1,
                              seed: "pioneerone", role: roleActor, ownedId: 101),
            ]
        default:
            return []
        }
    }

    // MARK: - Fixtures

    private static var demoPeople: [TMDBPerson] {
        [
            TMDBPerson(id: DemoPerson.derekDeLint.rawValue, name: "Derek de Lint",
                       knownForDepartment: "Acting",
                       profilePath: "/8fRRmh8EYZBlUtu1Wlop0j22QcP.jpg", popularity: 12),
            TMDBPerson(id: DemoPerson.jamesRich.rawValue, name: "James Rich",
                       knownForDepartment: "Acting",
                       profilePath: "/oF7kZnQ0HgqXVCPFmU1t03quHr2.jpg", popularity: 10),
            TMDBPerson(id: DemoPerson.colinLevy.rawValue, name: "Colin Levy",
                       knownForDepartment: "Directing",
                       profilePath: nil, popularity: 9),
        ]
    }

    private static var demoPersonDetails: [TMDBPersonDetails] {
        [
            TMDBPersonDetails(
                id: DemoPerson.derekDeLint.rawValue, name: "Derek de Lint",
                biography: "Dutch actor with a four-decade career across European and American film and television; in the demo library he anchors the Blender Foundation's live-action VFX film Tears of Steel as Old Thom.",
                birthday: "1950-07-17", deathday: nil,
                placeOfBirth: "The Hague, Netherlands",
                profilePath: "/8fRRmh8EYZBlUtu1Wlop0j22QcP.jpg",
                imdbId: nil, knownForDepartment: "Acting"),
            TMDBPersonDetails(
                id: DemoPerson.jamesRich.rawValue, name: "James Rich",
                biography: "Lead of Pioneer One, the BitTorrent-distributed, crowd-funded drama that proved a series could find its audience entirely outside broadcast television.",
                birthday: nil, deathday: nil, placeOfBirth: nil,
                profilePath: "/oF7kZnQ0HgqXVCPFmU1t03quHr2.jpg",
                imdbId: nil, knownForDepartment: "Acting"),
            TMDBPersonDetails(
                id: DemoPerson.colinLevy.rawValue, name: "Colin Levy",
                biography: "Director of the Blender Foundation's open movie Sintel; the demo credits him with story duty on Big Buck Bunny too, so a person can wear more than one role hat.",
                birthday: nil, deathday: nil, placeOfBirth: nil,
                profilePath: nil, imdbId: nil, knownForDepartment: "Directing"),
        ]
    }

    private static var roleActor: String { String(localized: "person.role.actor", bundle: .module) }
    private static var roleDirector: String { String(localized: "person.role.director", bundle: .module) }
    private static var roleWriter: String { String(localized: "person.role.writer", bundle: .module) }

    private static func demoMovieRow(
        id: Int, title: String, year: Int, rating: Double,
        seed: String, role: String, ownedId: Int?
    ) -> SearchResult {
        SearchResult(
            id: id, foreignId: String(id), title: title, subtitle: role,
            year: year, rating: rating,
            imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: nil, runtime: nil, genres: [], network: nil,
            certification: nil,
            posterURL: poster(label: title, seed: seed),
            source: .radarr, inLibraryArrId: ownedId
        )
    }

    private static func demoSeriesRow(
        title: String, year: Int, rating: Double,
        seed: String, role: String, ownedId: Int?
    ) -> SearchResult {
        SearchResult(
            id: 0, foreignId: "", title: title, subtitle: role,
            year: year, rating: rating,
            imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: nil, runtime: nil, genres: [], network: nil,
            certification: nil,
            posterURL: poster(label: title, seed: seed),
            source: .sonarr, inLibraryArrId: ownedId
        )
    }
}
