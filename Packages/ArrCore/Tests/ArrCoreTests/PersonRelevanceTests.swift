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

    @Test("Punctuation folds so hyphens and accents match")
    func punctuationFolding() throws {
        let p = try person("Joseph Gordon-Levitt", popularity: 20)
        let ranked = PersonRelevance.rank([p], query: "gordon levitt")
        #expect(ranked.first == p)
    }
}
