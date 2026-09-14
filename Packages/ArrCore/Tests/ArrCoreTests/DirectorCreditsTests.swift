import Testing
import Foundation
@testable import ArrCore

/// The director as a first-class credit: pulled out of both credit sources,
/// ranked level with actors, and captioned as a director rather than a cast
/// member.
@Suite("DirectorCredits")
struct DirectorCreditsTests {

    private func radarrCredits(_ json: String) throws -> [ArrCredit] {
        try JSONDecoder().decode([ArrCredit].self, from: Data(json.utf8))
    }

    private func tmdbCrew(_ json: String) throws -> [TMDBCreditPerson] {
        try JSONDecoder().decode([TMDBCreditPerson].self, from: Data(json.utf8))
    }

    // MARK: - Radarr `/credit`

    @Test("Radarr crew yields the director, and only the director")
    func radarrDirector() throws {
        let credits = try radarrCredits("""
        [{"personName":"Keanu Reeves","personTmdbId":6384,"character":"Neo","order":0,"type":"cast"},
         {"personName":"Lana Wachowski","personTmdbId":9339,"type":"crew","department":"Directing","job":"Director"},
         {"personName":"Lilly Wachowski","personTmdbId":9340,"type":"crew","department":"Directing","job":"Director"},
         {"personName":"Bill Pope","personTmdbId":1,"type":"crew","department":"Camera","job":"Director of Photography"},
         {"personName":"Sara Ferguson","personTmdbId":2,"type":"crew","department":"Directing","job":"Script Supervisor"}]
        """)
        let directors = CastMember.directors(radarrCredits: credits)
        #expect(directors.map(\.name) == ["Lana Wachowski", "Lilly Wachowski"])
        // The section header already says "Directed by" — the plain job would
        // just repeat it under every name.
        #expect(directors.allSatisfy { $0.role == nil })
        // Tapping the head has to reach the person view, so the TMDB id rides along.
        #expect(directors.first?.tmdbPersonId == 9339)
    }

    @Test("A director credited twice on one title gets one tile")
    func radarrDirectorDeduped() throws {
        let credits = try radarrCredits("""
        [{"personName":"Denis Villeneuve","personTmdbId":137427,"type":"crew","department":"Directing","job":"Director"},
         {"personName":"Denis Villeneuve","personTmdbId":137427,"type":"crew","department":"Directing","job":"Director"}]
        """)
        #expect(CastMember.directors(radarrCredits: credits).count == 1)
    }

    @Test("Cast rows never leak into the directing strip")
    func castStaysOutOfDirectors() throws {
        // A cast row carrying a stray department must not qualify — only crew
        // entries with the Director job do.
        let credits = try radarrCredits("""
        [{"personName":"Actor Person","personTmdbId":3,"character":"Self","order":0,"type":"cast",
          "department":"Directing","job":"Director"}]
        """)
        #expect(CastMember.directors(radarrCredits: credits).isEmpty)
    }

    // MARK: - TMDB

    @Test("TMDB movie crew yields the director with a headshot")
    func tmdbDirector() throws {
        let crew = try tmdbCrew("""
        [{"id":525,"name":"Christopher Nolan","department":"Directing","job":"Director",
          "profile_path":"/xuAIuYSmsUzKlUMBFGVZaWsY3DZ.jpg"},
         {"id":525,"name":"Christopher Nolan","department":"Writing","job":"Screenplay"},
         {"id":947,"name":"Hans Zimmer","department":"Sound","job":"Original Music Composer"}]
        """)
        let directors = CastMember.directors(tmdbCrew: crew)
        #expect(directors.map(\.name) == ["Christopher Nolan"])
        #expect(directors.first?.imageURL != nil)
    }

    @Test("A co-director's job variant is kept on the tile")
    func coDirectorJobShown() throws {
        let crew = try tmdbCrew("""
        [{"id":1,"name":"Main Director","department":"Directing","job":"Director"},
         {"id":2,"name":"Second Unit","department":"Directing","job":"Co-Director"}]
        """)
        let directors = CastMember.directors(tmdbCrew: crew)
        #expect(directors.count == 2)
        #expect(directors.last?.role == "Co-Director")
    }

    @Test("Series creators map from created_by")
    func seriesCreators() throws {
        let creators = try tmdbCrew("""
        [{"id":66633,"name":"Vince Gilligan","profile_path":"/rLSUjr725ez1cK7SKVxC9udO03Y.jpg"}]
        """)
        let members = CastMember.from(tmdbCreators: creators)
        #expect(members.map(\.name) == ["Vince Gilligan"])
        #expect(members.first?.role == nil)
        #expect(members.first?.tmdbPersonId == 66633)
    }

    // MARK: - Ranking + wording

    @Test("A director ranks level with an actor of the same popularity")
    func directorRanksLikeActor() throws {
        func person(_ name: String, _ dept: String) throws -> TMDBPerson {
            try JSONDecoder().decode(TMDBPerson.self, from: Data("""
            {"id": 1, "name": "\(name)", "popularity": 20, "known_for_department": "\(dept)"}
            """.utf8))
        }
        let q = TitleMatch.fold("nolan")
        let director = try person("Nolan", TMDBDepartment.directing)
        let actor = try person("Nolan", TMDBDepartment.acting)
        let composer = try person("Nolan", "Sound")
        #expect(PersonRelevance.score(person: director, normalizedQuery: q)
                == PersonRelevance.score(person: actor, normalizedQuery: q))
        #expect(PersonRelevance.score(person: director, normalizedQuery: q)
                > PersonRelevance.score(person: composer, normalizedQuery: q))
    }

    @Test("A director's filmography is captioned as directed, not starring")
    func captionKey() throws {
        func person(_ dept: String) throws -> TMDBPerson {
            try JSONDecoder().decode(TMDBPerson.self, from: Data("""
            {"id": 1, "name": "X", "known_for_department": "\(dept)"}
            """.utf8))
        }
        #expect(try person(TMDBDepartment.directing).filmographyCaptionKey == "search.directedBy")
        #expect(try person(TMDBDepartment.acting).filmographyCaptionKey == "search.starring")
    }
}
