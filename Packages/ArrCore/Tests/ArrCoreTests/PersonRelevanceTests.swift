import Testing
import Foundation
@testable import ArrCore

@Suite("PersonRelevance")
struct PersonRelevanceTests {
    private func person(_ name: String, popularity: Double, dept: String = "Acting") throws -> TMDBPerson {
        try JSONDecoder().decode(TMDBPerson.self, from: Data(#"""
        {"id": \#(abs(name.hashValue % 100000)), "name": "\#(name)",
         "popularity": \#(popularity), "known_for_department": "\#(dept)"}
        """#.utf8))
    }

    @Test("Order-free, punctuation-folded name matching ranks by coverage × popularity")
    func rankingBasics() throws {
        let hanks = try person("Tom Hanks", popularity: 40)
        let holland = try person("Tom Holland", popularity: 60)
        let hank = try person("Hank Azaria", popularity: 5)
        let ranked = PersonRelevance.rank([hank, holland, hanks], query: "tom hanks")
        // "tom hanks" fully covers Tom Hanks; the Toms cover half; Hank none.
        #expect(ranked.first == hanks)
        #expect(!ranked.contains(hank))
    }

    @Test("A common short word does not headline a Starring section")
    func headlinerGuardsShortWords() throws {
        let hanks = try person("Tom Hanks", popularity: 40)
        // "tom" is <4 chars → never a headliner even though it prefixes a token.
        #expect(!PersonRelevance.isConfidentHeadliner(hanks, query: "tom"))
        // The full surname clears the bar.
        #expect(PersonRelevance.isConfidentHeadliner(hanks, query: "hanks"))
    }

    @Test("An incidental low-popularity namesake never headlines")
    func headlinerGuardsNamesakes() throws {
        let obscure = try person("Hanks Nobody", popularity: 1)
        #expect(!PersonRelevance.isConfidentHeadliner(obscure, query: "hanks"))
    }

    @Test("A full name matches regardless of popularity")
    func fullNameIgnoresPopularity() throws {
        // The case that sent us here: a TV-only actor sits far below the
        // headliner popularity floor, but "rhea seehorn" can't mean anything
        // else.
        let seehorn = try person("Rhea Seehorn", popularity: 2)
        #expect(!PersonRelevance.isConfidentHeadliner(seehorn, query: "rhea seehorn"))
        #expect(PersonRelevance.isFullNameMatch(seehorn, query: "rhea seehorn"))
        #expect(PersonRelevance.isFullNameMatch(seehorn, query: "  Rhea   Seehorn "))
    }

    @Test("A single token is never a full-name match")
    func fullNameNeedsTwoTokens() throws {
        let seehorn = try person("Rhea Seehorn", popularity: 2)
        #expect(!PersonRelevance.isFullNameMatch(seehorn, query: "seehorn"))
        #expect(!PersonRelevance.isFullNameMatch(seehorn, query: "rhea"))
    }

    @Test("A full-name match needs every token on a distinct name token")
    func fullNameNeedsDistinctTokens() throws {
        let hanks = try person("Tom Hanks", popularity: 40)
        // A repeated token must not satisfy itself twice.
        #expect(!PersonRelevance.isFullNameMatch(hanks, query: "tom tom"))
        // A movie title that happens to prefix one name token isn't a person.
        #expect(!PersonRelevance.isFullNameMatch(hanks, query: "tom cruise"))
    }

    @Test("Punctuation folds so hyphens and accents match")
    func punctuationFolding() throws {
        let p = try person("Joseph Gordon-Levitt", popularity: 20)
        let ranked = PersonRelevance.rank([p], query: "gordon levitt")
        #expect(ranked.first == p)
    }
}
